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
| RAGFlow version | v0.26.4, image custom `10.60.10.184:8083/vmlp/lfnovo/ragflow:v2-latest` — build từ v0.26.x, "đã sửa phần build query cho tiếng Việt" (comment values.yaml) | Screenshot values.yaml 2026-08-18 |
| Search engine | Elasticsearch (external, ngoài cụm k8s RAGFlow) | `investigate_issue_4/04-root-cause.md` |
| ES endpoint THẬT (values.yaml `service_conf.es.hosts`) | `https://10.211.145.107:8051`, user `aihub_prod` | Screenshot values.yaml 2026-08-18 — khớp env test cũ, có `https://` (tracking cũ ghi thiếu scheme) |
| KB test cũ (lúc chốt root cause) | `voffice-docs-sum`, **141,978** doc | `investigate_issue_4/04-root-cause.md` |
| KB hiện tại | dataset **Voffice-doc-sum**, **1,901,802 files** (UI RAGFlow, 2026-08-18 09:28) — tăng liên tục, khớp con số ~1.9M đã báo trước | Screenshot UI RAGFlow 2026-08-18 |
| RAGFlow retrieval API test endpoint | `http://10.208.137.54:8999/api/v1/retrieval` (Bearer token riêng, NodePort 8999) | Kiên xác nhận 2026-08-18 |
| **Số pod RAGFlow (Web/API)** | `replicas: 3` trong values.yaml — **CHỦ Ý thiết kế**, không phải bất thường | Screenshot values.yaml, khớp `kubectl get pods` (3.1) |
| Kiến trúc pod | 1 container/pod chạy CHUNG Web/API + `task_executor`. Theo comment values.yaml: *"An toàn để scale: task_executor dùng Redis Stream Consumer Group nên mỗi task chỉ giao cho đúng 1 consumer (không bao giờ 1 file bị 2 pod). Xử lý Web/API stateless theo request"* | Screenshot values.yaml 2026-08-18 |

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Query tiếng Việt build ra clause OR chứa hư từ (thiếu stopword) → match rộng ES | Cao | ⚠️ **WORKAROUND** (giảm nhẹ, chưa xác nhận hết) | Đã custom image v0.26 (anh Cường), latency giảm 15-20s → 1.2-5s @ 141k. **Chưa đo lại số liệu chính xác sau upgrade** |
| 2 | Patch cũ `minimum_should_match` (initContainer, từ Issue #4) có thể THỪA/conflict với code v0.26 upstream đã có sẵn tham số này | Trung bình | ✅ **LOẠI TRỪ** — xem lệnh 3.1, code trong pod khớp đúng gốc v0.26, không bị đè | — |
| 3 | Latency tại scale MỚI (1.9M doc) chưa từng được đo — nghi bottleneck mới (index/shard/HNSW/GC, **hoặc load-balance không đều giữa 3 pod ragflow phát hiện ở 3.1**) khác root cause cũ | Cao | 🔶 **OPEN** | Đo lại theo `investigate_issue_4/measure3.sh` trên KB hiện tại, đo riêng từng pod |

## 3. Lệnh đã chạy

> Nguyên tắc: mọi lệnh dưới đây PHẢI có output thật kèm theo trước khi coi là "đã chạy".
> Lệnh chưa có output chỉ là **đề xuất**, đánh dấu `⏳ CHỜ OUTPUT`.

### 3.1 Verify patch `minimum_should_match` cũ có còn tồn tại / có conflict với code v0.26 gốc không — ✅ ĐÃ CHẠY, xem output dưới

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
  trên 2 node (`vrp-kubeengine05`, `vrp-kubeengine06`). Ban đầu nghi là bất thường, NHƯNG đã xác
  minh ở values.yaml: `replicas: 3` là **chủ ý thiết kế**, không phải lỗi/pod restart bất thường.
  ❓ **Giả thuyết cần đo, KHÔNG kết luận vội**: comment values.yaml khẳng định Web/API xử lý
  "stateless theo request" và task_executor tách riêng qua Redis Consumer Group — nếu đúng, mọi
  pod API về lý thuyết PHẢI xử lý cùng 1 request giống nhau, không có lý do 1 pod nặng hơn pod
  khác. Giả thuyết "lệch tải giữa 3 pod gây latency dao động" do đó YẾU hơn dự đoán ban đầu —
  cần đo trực tiếp (map response time với pod nào trả lời) để xác nhận hoặc loại, không suy diễn
  từ comment code.

### 3.2 Build feedback loop — gọi retrieval API N lần liên tục, đo latency mỗi lần, ghi timestamp — ⏳ CHỜ OUTPUT

**Vì sao cần script này (không phải gọi curl 1 lần rồi đoán):** issue là "cùng query, lúc 2s lúc
>20s" — non-deterministic theo thời gian. Cần loop đủ số lần (khuyến nghị 30-50 lần liên tục) để:
(a) xác nhận lại được symptom (tránh trường hợp giờ đã hết mà chỉ nhớ nhầm), (b) có phân phối
latency thật (min/max/p50/p95) thay vì 1-2 lần đo cảm tính, (c) có timestamp để đối chiếu với log
pod ở bước sau (xem pod nào trả lời request nào, verify/loại giả thuyết lệch tải giữa 3 pod).

Chạy trên máy có thể gọi ra `10.208.137.54:8999` (không cần SSH vào cụm — endpoint NodePort mở
sẵn ra ngoài theo ảnh anh gửi):

```
for i in $(seq 1 30); do echo "run=$i time=$(date +%H:%M:%S)"; curl -s -o /dev/null -w "http_code=%{http_code} time_total=%{time_total}s\n" --location --request POST 'http://10.208.137.54:8999/api/v1/retrieval' --header 'Authorization: Bearer ragflow-2KB-U6NBJYU62kIUtOhRv-kAL-LbhPmXaPbZfPPEaEw' --header 'Content-Type: application/json' --data-raw '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; sleep 1; done
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `for i in $(seq 1 30); do ... done` | Lặp 30 lần — đủ để thấy phân phối latency (min/max), không quá nhiều để tránh làm phiền hệ thống đang phục vụ thật |
| `echo "run=$i time=$(date +%H:%M:%S)"` | In số lần chạy + giờ:phút:giây NGAY TRƯỚC khi gọi — để đối chiếu với log pod ở bước 3.3 (biết request nào ứng với dòng log nào) |
| `curl -s` | Chế độ "silent" — ẩn progress bar của curl (thanh `%`, tốc độ tải...), CHỈ giữ lại output do `-w` định nghĩa — nếu bỏ `-s`, output sẽ rất rối vì lẫn progress bar |
| `-o /dev/null` | Vứt bỏ BODY response (không cần xem nội dung JSON trả về, chỉ cần đo thời gian) — nếu không có cờ này, toàn bộ JSON kết quả sẽ in ra màn hình lẫn với số liệu thời gian |
| `-w "http_code=%{http_code} time_total=%{time_total}s\n"` | Định dạng output tự viết: `%{http_code}` là mã HTTP trả về (200 = OK, để phát hiện nếu có request lỗi/timeout lẫn trong loop), `%{time_total}` là tổng thời gian round-trip tính bằng giây — đây là con số latency cần thu thập |
| `--location` | Anh đã biết — tự động follow redirect (3xx), giữ nguyên như curl gốc anh dùng |
| `--request POST` | Anh đã biết — phương thức HTTP POST |
| `--header 'Authorization: Bearer ...'` | Anh đã biết — token xác thực API |
| `--header 'Content-Type: application/json'` | Anh đã biết — báo cho server biết body là JSON |
| `--data-raw '{...}'` | Anh đã biết — body JSON gửi lên, giữ NGUYÊN request mẫu anh đã cung cấp (không đổi câu hỏi/dataset, để đo đúng CÙNG 1 query như triệu chứng anh Cường báo) |
| `sleep 1` | Nghỉ 1 giây giữa các lần gọi — tránh gọi dồn dập gây tải giả tạo làm sai lệch kết quả đo (không muốn latency cao là do TỰ mình gây tải, phải giống pattern sử dụng thật) |

**Kỳ vọng đọc được:** nếu thấy `time_total` dao động rõ giữa các lần (ví dụ vài dòng ~2s xen với
vài dòng ~15-20s) → xác nhận lại được symptom, tiến hành bước 3.3 đối chiếu log pod. Nếu MỌI lần
đều ổn định (~2-5s) → có thể symptom đã giảm/không còn tái hiện ở thời điểm đo này — cần đo thêm
tại giờ cao điểm hoặc hỏi anh Cường thời điểm chính xác xảy ra >20s.

**Output:** _(dán nguyên văn — 30 dòng `run=... time_total=...`)_

**Đọc được gì:** _(điền sau khi có output)_

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
