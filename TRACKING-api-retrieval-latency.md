# TRACKING — API Retrieval RAGFlow latency không ổn định

> File sống. Cập nhật liên tục trong lúc fix, không đợi tới cuối phiên.
> Issue liên quan đến branch `fix_api_retrieval` (anh Kiên đang làm việc trực tiếp trên đó).
> Bắt đầu: 2026-08-18.

## 1. Mục tiêu

Anh Cường báo lại issue: API retrieval (search) của RAGFlow **không ổn định** — cùng một
query, lúc trả về **~2s**, lúc **>20s**.

**Đây KHÔNG phải issue mới** — là Issue #4 / Issue 10 đã điều tra trước đó, nhưng bối cảnh
đã thay đổi đáng kể (xem mục 2). File này bám tiếp đúng issue đó ở scale mới.

### Bối cảnh hệ thống

| Thành phần | Giá trị | Nguồn |
|---|---|---|
| RAGFlow version | v0.26.4, image đã custom bởi anh Cường | Kiên xác nhận 2026-08-18 |
| Search engine | Elasticsearch (external, ngoài cụm k8s RAGFlow) | `investigate_issue_4/04-root-cause.md` |
| ES endpoint (env test cũ) | `10.211.145.107:8051`, user `aihub_prod` | `investigate_issue_4/03-measurements.md` |
| KB test cũ (lúc chốt root cause) | `voffice-docs-sum`, **141,978** doc | `investigate_issue_4/04-root-cause.md` |
| KB hiện tại | **1,899,860** doc (~13.4x so với lúc điều tra), tiếp tục tăng | Kiên xác nhận 2026-08-18 |
| RAGFlow retrieval API test endpoint | `http://10.208.137.54:8999/api/v1/retrieval` (Bearer token riêng) | Kiên xác nhận 2026-08-18 |

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Query tiếng Việt build ra clause OR chứa hư từ (thiếu stopword) → match rộng ES | Cao | ⚠️ **WORKAROUND** (giảm nhẹ, chưa xác nhận hết) | Đã custom image v0.26 (anh Cường), latency giảm 15-20s → 1.2-5s @ 141k. **Chưa đo lại số liệu chính xác sau upgrade** |
| 2 | Patch cũ `minimum_should_match` (initContainer, từ Issue #4) có thể THỪA/conflict với code v0.26 upstream đã có sẵn tham số này | Trung bình | ✅ **LOẠI TRỪ** — xem lệnh 3.1, code trong pod khớp đúng gốc v0.26, không bị đè | — |
| 3 | Latency tại scale MỚI (1.9M doc) chưa từng được đo — nghi bottleneck mới (index/shard/HNSW/GC, **hoặc load-balance không đều giữa 3 pod ragflow phát hiện ở 3.1**) khác root cause cũ | Cao | 🔶 **OPEN** | Đo lại theo `investigate_issue_4/measure3.sh` trên KB hiện tại, đo riêng từng pod |

## 3. Lệnh đã chạy

> Nguyên tắc: mọi lệnh dưới đây PHẢI có output thật kèm theo trước khi coi là "đã chạy".
> Lệnh chưa có output chỉ là **đề xuất**, đánh dấu `⏳ CHỜ OUTPUT`.

### 3.1 Verify patch `minimum_should_match` cũ có còn tồn tại / có conflict với code v0.26 gốc không — ⏳ CHỜ OUTPUT

**Vì sao cần chạy trước tiên:** code v0.26 upstream đã tự có sẵn `minimum_should_match` ở
`rag/nlp/query.py` (dòng 92/165/229, theo `TRACKING-ragflow-v0.26.4-upgrade.md` mục Issue 10).
Patch cũ (từ Issue #4, deploy qua initContainer sed) vẫn đang bật trong `values.yaml`. Nếu 2 bên
conflict hoặc sed trượt âm thầm (không báo lỗi dù không khớp — đã từng xảy ra, xem "Bài học" file
tracking upgrade), số liệu đo latency ở bước sau sẽ bị nhiễu bởi trạng thái code không rõ ràng.

Chạy trên node có quyền `kubectl` vào namespace `ragflow`:

```
kubectl -n ragflow get pods
```

| Cờ | Ý nghĩa |
|---|---|
| `-n ragflow` | Chỉ định namespace `ragflow` — không dùng `--namespace` dài dòng, `-n` là viết tắt chuẩn của kubectl |
| `get pods` | Liệt kê pod đang chạy trong namespace, để lấy đúng tên pod RAGFlow (không phải pod ES/mysql/minio/redis) cho lệnh tiếp theo |

Sau khi có tên pod RAGFlow (không phải es/minio/mysql/redis), chạy:

```
kubectl -n ragflow exec POD_NAME -c ragflow -- grep -n minimum_should_match /ragflow/rag/nlp/query.py
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-n ragflow` | Namespace, giống lệnh trên |
| `exec POD_NAME` | Chạy lệnh BÊN TRONG pod đang sống — thay `POD_NAME` bằng tên thật lấy từ lệnh trên |
| `-c ragflow` | Container `ragflow` — pod có thể có nhiều container (main app + sidecar), `-c` chỉ định đúng container chứa code Python cần grep |
| `--` | Ngăn cách flag của `kubectl` với lệnh sẽ chạy trong container — không có dấu này kubectl có thể hiểu nhầm `grep`/`-n` là flag của chính nó |
| `grep -n` | In số dòng kèm nội dung khớp — cờ `-n` ở đây thuộc về `grep`, KHÁC với `-n` của kubectl phía trước (trùng ký tự, khác chương trình, dễ nhầm) |
| `minimum_should_match` | Chuỗi cần tìm |
| `/ragflow/rag/nlp/query.py` | Đường dẫn file TRONG container (không phải trên máy host) |

**Kỳ vọng đọc được:** nếu thấy **3 dòng** khớp (dòng ~92/165/229, đúng số lượng code gốc v0.26
theo tracking cũ) → code sạch, patch cũ không đè gì thêm (không tăng số dòng, không có dòng lệch
format). Nếu thấy **4 dòng** hoặc nội dung có 2 lần `minimum_should_match` lồng nhau trong 1 dòng
→ patch cũ đã ghi đè/nhân đôi lên code gốc → cần gỡ patch cũ trong `values.yaml` trước khi đo tiếp.

**Output:**

```
[app@vrp-kubeengine04 ~]$ kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- grep -n minimum_should_match /ragflow/rag/nlp/query.py
92:            return MatchTextExpr(self.query_fields, query, 100, {"minimum_should_match": min_match, "original_query": original_query}), keywords
165:            return MatchTextExpr(self.query_fields, query, 100, {"minimum_should_match": min_match, "original_query": original_query}), keywords
229:            return MatchTextExpr(self.query_fields, " ".join(keywords), 100, {"minimum_should_match": min(3, round(len(keywords) / 10)), "original_query": " ".join(origin_keywords)})
[app@vrp-kubeengine04 ~]$ kubectl get pods -n ragflow -o wide
NAME                        READY   STATUS    RESTARTS   AGE     IP             NODE
ragflow-57d9856dff-5kgvd    1/1     Running   0          4d5h    172.16.83.16   vrp-kubeengine06
ragflow-57d9856dff-pljxz    1/1     Running   0          4d5h    172.16.83.15   vrp-kubeengine06
ragflow-57d9856dff-q9kz2    1/1     Running   0          15h     172.16.78.26   vrp-kubeengine05
ragflow-minio-0             1/1     Running   0          3d15h   172.16.93.71   vrp-kubeengine07
ragflow-mysql-0             1/1     Running   0          4d9h    172.16.83.7    vrp-kubeengine06
ragflow-redis-0             1/1     Running   0          3d15h   172.16.93.75   vrp-kubeengine07
```

**Đọc được gì:**
- Đúng **3 dòng** khớp (92/165/229) — trùng khớp CHÍNH XÁC số dòng và nội dung đã ghi nhận trong
  `TRACKING-ragflow-v0.26.4-upgrade.md` mục Issue 10 ("Code v0.26 đã có sẵn `minimum_should_match`
  dòng 92/165/229"). Không có dòng thứ 4, không có `minimum_should_match` lồng đôi trong 1 dòng.
- ⟹ **Loại trừ được Issue 2**: patch cũ (initContainer sed từ Issue #4) **KHÔNG đang ghi đè/nhân
  đôi lên code gốc v0.26**. Code hiện tại trong pod khớp đúng với code gốc upstream v0.26 — sed
  patch cũ (nếu còn bật trong `values.yaml`) đang ở trạng thái **no-op an toàn** (chuỗi cần khớp
  để patch có thể đã không còn tồn tại dạng cũ trong file v0.26, nên sed không có gì để sửa, không
  gây lỗi, không tăng dòng). Không cần gỡ patch cũ gấp — nó không gây nhiễu số liệu đo sắp tới.
- ⟹ Cluster có **3 pod ragflow** (không phải 1 như baseline cũ lúc điều tra Issue #4/#10) — trải
  trên 2 node (`vrp-kubeengine05`, `vrp-kubeengine06`). Đây là thông tin MỚI, chưa từng ghi nhận
  trước — cần cân nhắc khi đo latency: có thể latency dao động do **load-balance không đều giữa
  3 pod** (ví dụ 1 pod mới restart 15h AGE, còn 2 pod khác 4d5h AGE — không đồng nhất tuổi/trạng
  thái) chứ không chỉ do ES/tokenizer. Đây là hướng nghi phạm MỚI, thêm vào Issue 3.

---

## 4. Issue chi tiết

### Issue 1 — Query tiếng Việt match rộng do thiếu stopword (⚠️ WORKAROUND)

**Root cause (đã chốt ở `investigate_issue_4/04-root-cause.md` mục 10, v0.24.0):**
`rag/nlp/term_weight.py::Dealer.stop_words` chỉ chứa stopword tiếng Trung. Hư từ tiếng Việt
("và"...) không bị lọc, tokenize thành 1 clause OR riêng trong ES `query_string` với boost đầy
đủ → tự nó match ~100% corpus → ES phải full-text scoring hàng chục nghìn document/query.

**Đã thử — Fail:** thêm `minimum_should_match=30%` cho nhánh non-Chinese trong `query.py` (patch
qua initContainer, deploy thật, verify code chạy đúng). ES vẫn ăn đúng config nhưng **không giảm
được match set** — ép min_match=100% chỉ giảm 141,340 → 140,469 (99.4%). ❌ Không phải root cause
đúng, vì `minimum_should_match` chỉ giới hạn SỐ LƯỢNG mệnh đề cần khớp, không sửa NỘI DUNG mệnh đề
— nếu 1 mệnh đề (chứa hư từ) đã match gần hết corpus, siết số lượng không giúp gì.

**Workaround hiện tại (chưa xác nhận đầy đủ):** anh Cường custom image v0.26, tokenizer có vẻ
không tách quá nhỏ như trước → latency giảm 15-20s → 1.2-5s @ KB 141k (theo lời kể, ❓ chưa có
số liệu đo trực tiếp sau upgrade). **Chưa đọc lại source `term_weight.py`/`rag_tokenizer.py` bản
v0.26 để xác nhận stopword tiếng Việt đã được thêm hay tokenizer đổi cơ chế khác.**

**Hướng xử lý tiếp:** đọc lại source v0.26 (khác source v0.24.0 đã điều tra) trước khi quyết định
có cần thêm stopword tiếng Việt (`investigate_issue_4/scratch/vi_stopwords_TODO.py` đã tạo sẵn
placeholder) hay không.

### Issue 2 — Patch cũ có thể thừa/conflict (❓ chưa xác minh)

Xem lệnh 3.1. Chưa có output nên chưa kết luận được.

### Issue 3 — Latency chưa đo ở scale 1.9M doc (🔶 OPEN)

KB đã tăng từ 141k → 1,899,860 doc (~13.4x), dự kiến tiếp tục tăng. Chưa có bất kỳ số liệu đo nào
ở scale này. Nghi ngờ: root cause cũ (match rộng do tokenize) có thể chưa hết hoàn toàn (chỉ giảm
% nhờ tokenizer tốt hơn) VÀ/HOẶC có bottleneck MỚI xuất hiện ở quy mô triệu-document (kích thước
index/shard, HNSW graph lớn hơn, GC pressure do nhiều segment hơn) — chưa từng lộ ra ở 141k vì
dataset lúc đó còn nhỏ so với ngưỡng gây vấn đề này.

**Hướng xử lý tiếp (theo thứ tự):**
1. Verify Issue 2 xong trước (tránh nhiễu số liệu).
2. Chạy lại `investigate_issue_4/measure3.sh` (hoặc viết lại nếu script cũ hardcode point vào
   KB 141k cũ) trên KB 1.9M hiện tại.
3. So sánh 3 mốc: 141k/v0.24 (~13-15s) → tương đương/v0.26 custom (~1.2-5s, theo lời kể) →
   1.9M/v0.26 hiện tại (chưa đo — số liệu quan trọng nhất cần lấy).
4. Nếu latency ở 1.9M tăng vượt mức dự đoán tuyến tính từ baseline nhỏ hơn → nghi bottleneck mới,
   điều tra riêng (không lặp lại hướng tokenizer).

## 5. Bài học

_(điền khi phát sinh — chỉ ghi cái không hiển nhiên)_

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| `codePatch` initContainer patch `minimum_should_match` (Issue #4 cũ) vẫn bật trong `values.yaml` | `TRACKING-ragflow-v0.26.4-upgrade.md` mục 6 | Code v0.26 đã có sẵn tham số này → patch có thể thừa, sed trượt âm thầm không cảnh báo |
| File `investigate_issue_4/scratch/vi_stopwords_TODO.py` tạo sẵn nhưng chưa điền | Session 2026-08-18 | Đừng áp dụng fix stopword ngay khi chưa đọc lại source v0.26 — có thể đã không còn cần |

## 7. Việc tiếp theo

### Ngay lập tức
- [ ] Chạy lệnh 3.1, dán output vào file này
- [ ] Xác nhận patch cũ có conflict/thừa không

### Ngắn hạn
- [ ] Đọc lại `rag/nlp/term_weight.py` + `rag/nlp/query.py` bản v0.26 (source thật trong container,
      không phải GitHub — số dòng/nội dung có thể lệch do custom image)
- [ ] Đo lại latency trên KB 1.9M doc hiện tại, dùng đúng query mẫu đã có sẵn (endpoint
      `http://10.208.137.54:8999/api/v1/retrieval`)
- [ ] Update mục 4 Issue 3 với số liệu thật

### Dài hạn
- [ ] Nếu phát hiện bottleneck mới do scale (không phải tokenizer), mở investigate riêng — không
      gộp chung với Issue #4 cũ để tránh nhầm root cause

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| KB tiếp tục tăng, không giảm | Cao | Bất kỳ fix nào cũng cần test ở scale lớn hơn hiện tại, không chỉ verify tại thời điểm đo |
| Không có staging, mọi patch test trực tiếp trên môi trường có tải thật | Trung bình | Test 1 câu hỏi cụ thể trước, quan sát vài phút, báo trước bên đang cắm API |
