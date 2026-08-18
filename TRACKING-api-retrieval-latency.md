# TRACKING — API Retrieval RAGFlow latency không ổn định

> File sống. Cập nhật liên tục trong lúc fix, không đợi tới cuối phiên.
> Issue liên quan đến branch `fix_api_retrieval` (anh Kiên đang làm việc trực tiếp trên đó).
> Bắt đầu: 2026-08-18.

## 1. Mục tiêu

Anh Cường báo lại issue: API retrieval (search) của RAGFlow **không ổn định** — cùng một
query, lúc trả về **~2s**, lúc **>20s**.

**Đây KHÔNG phải issue mới** — là Issue #4 / Issue 10 đã điều tra trước đó, nhưng bối cảnh
đã thay đổi đáng kể (xem mục 2). File này bám tiếp đúng issue đó ở scale mới.

> ## 🔴🔴 NGHI PHẠM HÀNG ĐẦU (2026-08-18 12:18): CONNECTION LEAK — xem 3.18
>
> **Bằng chứng đo được:**
> - **104 CLOSE_WAIT / 283 connection (37%)** — `CLOSE_WAIT` = phía bên kia đã đóng nhưng **app chưa
>   gọi `close()`**, nằm đó vô thời hạn, mỗi cái giữ 1 fd + 1 slot pool. **Đây là leak.**
> - **`conn8992` tăng ĐƠN ĐIỆU 88 → 94** trong lúc 1 request chạy, **không bao giờ giảm**.
>   Chuỗi theo thời gian: **67 → 88 → 94**.
> - **Latency LEO THANG, không phải dao động ngẫu nhiên:**
>   12:06 Postman **17.40s** → 12:18 curl **25.351s** → 12:16 Postman **10 phút 19.38 giây**.
>
> **⭐ Giải thích được nghịch lý trung tâm** — "mọi backend đo riêng đều nhanh (ES <1ms, embedding
> 150ms, LLM 1.25s) nhưng tổng lại 3.6s→10 phút": đo bằng `curl` **từ ngoài** thì lấy **connection
> mới sạch** ⟹ nhanh. Trong pod, connection cũ kẹt CLOSE_WAIT **không tái dùng được** ⟹ phải mở mới,
> và khi tiến tới trần (pool size / `ulimit -n`) thì **việc LẤY ĐƯỢC connection** thành phần chậm —
> thời gian đó **vô hình** với ES stats, với curl ngoài, và **không tiêu CPU** (khớp 10–20%).
>
> **⭐ PHÉP THỬ QUYẾT ĐỊNH (chưa chạy):** `rollout restart` rồi đo ngay.
> Nhanh hẳn (1-3s) rồi chậm dần ⟹ **root cause chốt**. Vẫn chậm ⟹ leak là bug thật nhưng không
> phải nguyên nhân chính.
>
> **Đã loại trừ hết (mỗi cái có số đo, đừng điều tra lại):** Elasticsearch (<1ms/query) ·
> network client (6ms) · payload (270KB/6ms) · **CPU pod (10–20%)** · **embedding (150ms, biên độ 2×)** ·
> **LLM qwen3-32b (1.25s, biên độ 1.02×)** · `topk` 1024 vs 256 (A/B 4–4) · `metadata_condition`
> (bỏ đi còn chậm hơn) · `minimum_should_match` · load-balance 3 pod · tokenizer/stopword tiếng Việt.
>
> **⚠️ Đã suy luận sai 3 lần** (topk, rerank CPU, embedding) — đều vì đoán từ source thay vì đo
> (Bài học 0d). Lần này có số đo trực tiếp, nhưng **vẫn phải chạy phép thử restart để chốt.**

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
| 1 | Query tiếng Việt build ra clause OR chứa hư từ (thiếu stopword) → match rộng ES | Cao | ⚠️ **WORKAROUND KHÔNG ĐỦ** — xem 3.2, workaround v0.26 giảm nhẹ nhưng KHÔNG giữ ổn định ở scale 1.9M (30 mẫu: min 1.98s, max 28.2s, chỉ 37% dưới 5s) | Đã custom image v0.26 (anh Cường). Cần đo tiếp xem còn dư địa cải thiện ở tầng tokenizer/query hay đã hết, chuyển hướng sang Issue 3 |
| 2 | Patch cũ `minimum_should_match` (initContainer, từ Issue #4) có thể THỪA/conflict với code v0.26 upstream đã có sẵn tham số này | Trung bình | ✅ **LOẠI TRỪ** — xem lệnh 3.1, code trong pod khớp đúng gốc v0.26, không bị đè | — |
| 3 | Latency tại scale MỚI (1.9M doc) dao động mạnh 1.98s-28.2s (30 mẫu thật, 3.2) — nghi bottleneck ở ES do scale (index/shard/HNSW/GC) | Cao | ✅ **LOẠI TRỪ (3.7/3.8)** — ES stats thật: query trung bình **<1ms** trên node chính, tệ nhất 4.4ms. Delta 1 request retrieval = ~287 query / ~1.74s ES trong tổng 3.6s. ES **không** phải bottleneck | Đóng hướng ES. Chuyển toàn bộ sang tầng Python (Issue 5/6/7) |
| 4 | Retrieval tranh tài nguyên với luồng **ingest liên tục** từ bên đẩy tài liệu (Kiên nêu) | Cao | ✅ **XÁC NHẬN (3.6)** — nhưng contention KHÔNG ở ES/worker API mà ở **CPU pod + embedding service**. Log: `task_executor` (PID 445) xử lý ≥8 doc/23s liên tục, `Embedding chunks (0.59s→1.43s)` nối nhau, cùng KB đang test, cùng pod với `ragflow_server` (PID 48) | Fix 1: tách `task_executor` ra deployment riêng |
| 5 | 🔴 **ROOT CAUSE A — Embedding query bị xếp hàng sau ingest.** Mỗi retrieval gọi `emb_mdl.encode_queries` (`search.py:56`) / `get_vector` (`:199`) tới `qwen3-8b-embedding` qua API ngoài | Cao | 🔴 **CHỐT (3.6 + source)** — cùng embedding service đang bị ingest bơm liên tục 0.59-1.43s/batch → retrieval phải đợi. Giải thích trực tiếp dao động 2s↔28s | Fix 1 + Fix 3 (tách/scale embedding endpoint) |
| 6 | ~~ROOT CAUSE B — `topk=1024`~~ | — | ❌ **PHỦ ĐỊNH (3.11/3.12)** — A/B xen kẽ 8 cặp: `topk=256` KHÔNG nhanh hơn (mean 13.9 vs 15.8s, thắng/thua 4–4; `topk=1024` cho 2 lần nhanh nhất 2.15s/2.96s). Kết quả trả về y hệt (cùng 10 chunk, cùng thứ tự) | Đóng hướng. Không cần sửa `topk` |
| 7 | ~~ROOT CAUSE C — re-tokenize/rerank CPU-bound~~ | — | ❌ **PHỦ ĐỊNH (3.13)** — **CPU pod chỉ 10–20%** (Kiên quan sát trực tiếp). Nếu tokenize/rerank 1024 candidate thì CPU phải cao. Khớp với 3.11/3.12 | Đóng hướng. `pyvi` không phải vấn đề hiệu năng |
| 9 | 🔴 **HỆ QUẢ TỪ CPU 10–20%: latency là I/O WAIT, không phải CPU.** Sau khi loại ES (<1ms), network client (6ms), payload (270KB), CPU (10–20%) ⟹ chỉ còn lời gọi **`qwen3-8b-embedding` qua API ngoài** | Cao | 🔴 **ỨNG VIÊN DUY NHẤT CÒN LẠI** — logic loại trừ đã đóng kín, nhưng ❓ **chưa đo trực tiếp** embedding service | Đo latency embedding trực tiếp khi ingest chạy vs nghỉ (việc tiếp theo) |
| 8 | Giả thuyết `metadata_condition contains` gây N+1 / filter-in-Python | Cao | ❌ **PHỦ ĐỊNH (3.9)** — bỏ hẳn `metadata_condition` KHÔNG nhanh hơn, còn **chậm hơn** (14.2s/19.2s vs 3.6-10.2s) | Đóng hướng này. Ghi vào Bài học |

| 10 | ~~ROOT CAUSE A — embedding xếp hàng sau ingest~~ | — | ❌ **PHỦ ĐỊNH (3.15)** — đo trực tiếp LiteLLM `10.208.137.53:8992` **đúng lúc ingest chạy**: **~150ms**, min 0.116 max 0.238 (**biên độ 2×**); 5 request song song về cùng lúc ⟹ **không có hàng đợi FIFO**. Chiếm 4% tổng, không đóng góp vào dao động | Đóng hướng. `EMBEDDING_BATCH_SIZE=16` cũng vô can |
| 11 | 🔴 **VẤN ĐỀ CÒN LẠI: 1.7s–26.3s không thuộc tầng nào đã đo.** ES 1.7s + embedding 0.15s + network 0.006s ≈ 1.9s, thực tế 3.6–28.2s | Cao | 🔴 **OPEN — chưa có nghi phạm nào có bằng chứng.** CPU 10–20% ⟹ I/O wait, nhưng cả 2 đích I/O đã biết đều nhanh | **Profile trực tiếp trong process** (`py-spy dump --pid 48`) khi request đang chậm, hoặc bisect bằng `vector_similarity_weight` 1.0/0.0/0.6. KHÔNG suy luận từ source nữa |

| 12 | ~~LLM `qwen3-32b`~~ | — | ❌ **PHỦ ĐỊNH (3.17)** — 1.236/1.259/1.258s, **biên độ 1.02×** | Đóng hướng |
| 13 | ❌ ~~CONNECTION LEAK gây chậm~~ **PHỦ ĐỊNH (3.20)**: cw tăng đơn điệu 296→322 nhưng latency nhảy loạn; run=9 chỉ 1.97s khi cw=317. Leak là bug thật nhưng KHÔNG gây chậm. Dữ kiện cũ: **104 CLOSE_WAIT/283 conn (37%)**; `conn8992` tăng đơn điệu 67→88→94 không bao giờ giảm; latency leo thang 17.4s→25.4s→**10 phút 19s** | **Rất cao** | 🔴 **NGHI PHẠM HÀNG ĐẦU, có bằng chứng đo được (3.18)** — giải thích được nghịch lý "backend nhanh nhưng tổng chậm" + CPU thấp + I/O wait + xu hướng xấu dần | **Phép thử quyết định: `rollout restart` rồi đo ngay.** Nhanh hẳn rồi chậm dần ⟹ chốt. Tiếp: `ulimit -n`, đếm fd PID 48, xem CLOSE_WAIT nối tới port nào |

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

### 3.2 Build feedback loop — gọi retrieval API N lần liên tục, đo latency mỗi lần, ghi timestamp — ✅ ĐÃ CHẠY (30 mẫu)

**Vì sao cần script này (không phải gọi curl 1 lần rồi đoán):** issue là "cùng query, lúc 2s lúc
>20s" — non-deterministic theo thời gian. Cần loop đủ số lần (khuyến nghị 30-50 lần liên tục) để:
(a) xác nhận lại được symptom (tránh trường hợp giờ đã hết mà chỉ nhớ nhầm), (b) có phân phối
latency thật (min/max/p50/p95) thay vì 1-2 lần đo cảm tính, (c) có timestamp để đối chiếu với log
pod ở bước sau (xem pod nào trả lời request nào, verify/loại giả thuyết lệch tải giữa 3 pod).

**Lần đầu đưa lệnh (❌ FAIL, đã thử):**
- Chạy trên **cmd.exe Windows** của anh: `for i in $(seq 1 30); do ... done` là cú pháp **bash**,
  CMD không hiểu → lỗi `was unexpected at this time`. Bài học: không giả định shell của máy client
  mà không hỏi trước.
- Chạy trên **bash trong cụm** (`vrp-kubeengine04`): lỗi `curl: option --data-raw: is unknown`.
  `curl` trong môi trường này là bản tối giản (có thể BusyBox curl hoặc build rút gọn), không có
  cờ `--data-raw` (chỉ được thêm vào curl từ bản 7.43.0/2015) — dù shell là bash nên vòng `for` +
  `$(seq...)` chạy đúng, chỉ riêng cờ curl bị thiếu. Khớp với bài học đã ghi trong
  `TRACKING-ragflow-v0.26.4-upgrade.md`: *"Image tối giản không có netstat/ss/curl — đừng phụ
  thuộc vào chúng"* — ở đây là bastion/cluster tool, không phải image RAGFlow, nhưng cùng chung
  đặc điểm môi trường air-gapped tối giản hoá tool.

**Lệnh sửa lại (dùng `-d` thay `--data-raw`, chạy bash trong cụm — anh đã chọn môi trường này vì
gần network với RAGFlow nhất, latency đo được sát thực tế hơn so với gọi từ máy Windows ra xa):**

```
for i in $(seq 1 30); do echo "run=$i time=$(date +%H:%M:%S)"; curl -s -o /dev/null -w "http_code=%{http_code} time_total=%{time_total}s\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; sleep 1; done
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `for i in $(seq 1 30); do ... done` | Lặp 30 lần — đủ để thấy phân phối latency (min/max), không quá nhiều để tránh làm phiền hệ thống đang phục vụ thật |
| `echo "run=$i time=$(date +%H:%M:%S)"` | In số lần chạy + giờ:phút:giây NGAY TRƯỚC khi gọi — để đối chiếu với log pod ở bước 3.3 (biết request nào ứng với dòng log nào) |
| `curl -s` | Chế độ "silent" — ẩn progress bar của curl, CHỈ giữ lại output do `-w` định nghĩa |
| `-o /dev/null` | Vứt bỏ BODY response (không cần xem JSON trả về, chỉ cần đo thời gian) |
| `-w "http_code=%{http_code} time_total=%{time_total}s\n"` | Định dạng output tự viết: `%{http_code}` là mã HTTP (200 = OK, phát hiện request lỗi/timeout lẫn trong loop), `%{time_total}` là tổng thời gian round-trip — con số latency cần thu thập |
| `-X POST` | **THAY `--request POST`** — cùng ý nghĩa (chỉ định phương thức HTTP POST), dùng dạng viết tắt `-X` vì tương thích rộng hơn trên curl tối giản |
| `-H '...'` | **THAY `--header '...'`** — cùng ý nghĩa (gắn HTTP header), viết tắt để tương thích |
| `-d '{...}'` | **THAY `--data-raw '{...}'`** — đây là điểm SỬA CHÍNH gây lỗi lần trước. `-d`/`--data` là cờ gửi body CƠ BẢN NHẤT của curl, có từ bản đầu tiên, chắc chắn có trên mọi bản curl (kể cả BusyBox). Khác biệt duy nhất với `--data-raw`: `-d` coi chuỗi bắt đầu bằng `@` là tên file cần đọc — JSON của mình không bắt đầu bằng `@` nên hành vi giống hệt `--data-raw` trong trường hợp này, an toàn để đổi |
| `sleep 1` | Nghỉ 1 giây giữa các lần gọi — tránh gọi dồn dập gây tải giả tạo làm sai lệch kết quả đo |

**Kỳ vọng đọc được:** nếu thấy `time_total` dao động rõ giữa các lần (ví dụ vài dòng ~2s xen với
vài dòng ~15-20s) → xác nhận lại được symptom, tiến hành bước 3.3 đối chiếu log pod. Nếu MỌI lần
đều ổn định (~2-5s) → có thể symptom đã giảm/không còn tái hiện ở thời điểm đo này — cần đo thêm
tại giờ cao điểm hoặc hỏi anh Cường thời điểm chính xác xảy ra >20s.

**Output:**

```
run=1 time=09:48:34
http_code=200 time_total=14.263s
run=2 time=09:48:49
http_code=200 time_total=14.278s
run=3 time=09:49:05
http_code=200 time_total=2.298s
run=4 time=09:49:08
http_code=200 time_total=9.902s
run=5 time=09:49:19
http_code=200 time_total=19.369s
run=6 time=09:49:39
http_code=200 time_total=1.983s
run=7 time=09:49:42
http_code=200 time_total=11.078s
run=8 time=09:49:54
http_code=200 time_total=28.194s
run=9 time=09:50:23
http_code=200 time_total=2.165s
run=10 time=09:50:27
http_code=200 time_total=9.243s
run=11 time=09:50:37
http_code=200 time_total=18.116s
run=12 time=09:50:56
http_code=200 time_total=3.952s
run=13 time=09:51:01
http_code=200 time_total=4.884s
run=14 time=09:51:07
http_code=200 time_total=26.249s
run=15 time=09:51:34
http_code=200 time_total=2.011s
run=16 time=09:51:37
http_code=200 time_total=6.192s
run=17 time=09:51:44
http_code=200 time_total=10.564s
run=18 time=09:51:56
http_code=200 time_total=2.623s
run=19 time=09:52:00
http_code=200 time_total=6.516s
run=20 time=09:52:07
http_code=200 time_total=17.843s
run=21 time=09:52:26
http_code=200 time_total=4.985s
run=22 time=09:52:32
http_code=200 time_total=11.161s
run=23 time=09:52:44
http_code=200 time_total=15.784s
run=24 time=09:53:01
http_code=200 time_total=2.265s
run=25 time=09:53:04
http_code=200 time_total=10.118s
run=26 time=09:53:15
http_code=200 time_total=19.207s
run=27 time=09:53:35
http_code=200 time_total=2.300s
run=28 time=09:53:39
http_code=200 time_total=4.868s
run=29 time=09:53:45
http_code=200 time_total=7.471s
run=30 time=09:53:53
http_code=200 time_total=16.713s
```

**Đọc được gì:**
- **30/30 lần `http_code=200`** — không có request nào lỗi/timeout, mọi lần dao động là do
  THỜI GIAN XỬ LÝ, không phải lỗi kết nối/retry. Loại trừ nghi ngờ "một số request bị lỗi rồi
  retry gây delay giả" — mọi lần đều thành công, chỉ khác thời gian.
- **Phân phối latency (30 mẫu, tính bằng script, không ước lượng):**
  min=1.983s, max=28.194s (**~14.2x chênh lệch**), mean=10.22s, median=9.57s.
  Chia khoảng: <5s: 11/30, 5-10s: 5/30, 10-20s: 12/30, ≥20s: 2/30.
- ⟹ **Symptom KHÔNG phải bimodal** (2 cụm tách biệt "nhanh" và "chậm") mà là **phân phối liên
  tục, trải đều** từ 2s đến 28s — nhìn theo timeline (`time=`) không thấy pattern rõ theo giờ
  (ví dụ không phải "phút đầu nhanh, phút sau chậm dần"): run=3 (2.3s) ngay sau run=1,2 (14.2s,
  14.3s), rồi run=5 lại 19.4s, run=6 lại 1.98s — **dao động run-kế-run rất mạnh, không có xu
  hướng tăng/giảm dần theo thời gian đo (không phải warm-up hay degradation dần)**.
- ⟹ **QUAN TRỌNG — mâu thuẫn với lời kể ban đầu:** anh Cường báo "lúc 2s lúc >20s" và Kiên kể lại
  workaround v0.26 đã giảm về "1.2s-5s @ KB 141k" — nhưng số liệu THẬT ở KB 1.9M hiện tại cho
  thấy **latency KHÔNG hề ổn định quanh vùng thấp**: chỉ 11/30 (~37%) dưới 5s, còn lại (~63%)
  từ 5s đến 28s. Tức là workaround tokenizer có thể vẫn còn tác dụng MỘT PHẦN (vẫn có nhiều lần
  <5s), nhưng **không đủ để giữ ổn định ở scale 1.9M** — khớp với nghi vấn đã ghi ở Issue 3
  (mục 4): bottleneck có thể đã chuyển từ "match quá rộng do thiếu stopword" sang "cost tăng
  theo kích thước index/segment ở quy mô triệu-document", vì ngay cả khi query build tốt, ES
  vẫn phải quét/score trên tập dữ liệu lớn hơn 13x so với lúc đo 141k.
- ❓ **Chưa xác nhận được liệu dao động run-kế-run mạnh (2s rồi ngay 14s) có tương quan với POD
  nào trả lời không** — đây là lý do bước 3.3 (đối chiếu log pod theo timestamp `time=` ở trên)
  vẫn cần làm, để loại hoặc xác nhận giả thuyết lệch tải giữa 3 pod đã nêu ở Issue 3.

### 3.3 Đối chiếu log 3 pod ragflow trong đúng khoảng thời gian đã đo (09:48:34 → 09:53:53) — ✅ ĐÃ CHẠY (trích một đoạn)

**Vì sao cần lệnh này:** số liệu 3.2 cho thấy dao động MẠNH giữa các request liên tiếp (không
theo xu hướng thời gian, không phải warm-up/degradation dần) — gợi ý nguyên nhân thay đổi theo
TỪNG request, ví dụ pod nào trả lời. Cần map mỗi `run=N time=HH:MM:SS` (đã có ở 3.2) với dòng log
tương ứng trên từng pod để biết: (a) 30 request có chia đều cho 3 pod không, (b) latency cao có
rơi tập trung vào 1 pod cụ thể không.

Chạy trên `vrp-kubeengine04` (hoặc máy có `kubectl` context), lấy log CẢ 3 pod, giới hạn đúng
khung giờ đã đo (thêm đệm phía trước để không bỏ sót request biên):

```
kubectl -n ragflow logs ragflow-57d9856dff-5kgvd -c ragflow --since-time=2026-08-18T09:47:00+07:00 | grep -E "retrieval|POST /api/v1"
```

```
kubectl -n ragflow logs ragflow-57d9856dff-pljxz -c ragflow --since-time=2026-08-18T09:47:00+07:00 | grep -E "retrieval|POST /api/v1"
```

```
kubectl -n ragflow logs ragflow-57d9856dff-q9kz2 -c ragflow --since-time=2026-08-18T09:47:00+07:00 | grep -E "retrieval|POST /api/v1"
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-n ragflow` | Namespace, đã dùng ở 3.1 |
| `logs POD_NAME` | Xem log của pod cụ thể — chạy 3 LẦN, mỗi lần 1 tên pod trong 3 pod đã biết từ 3.1 (`5kgvd`, `pljxz`, `q9kz2`) — **không dùng `-l app=ragflow` gộp 3 pod vì log sẽ trộn lẫn không phân biệt được pod nào**, phải tách riêng để so sánh |
| `-c ragflow` | Container, giống 3.1 — pod này chỉ có 1 container nhưng vẫn nên ghi rõ để chắc chắn |
| `--since-time=2026-08-18T09:47:00+07:00` | Chỉ lấy log TỪ thời điểm này — định dạng ISO 8601 kèm timezone `+07:00` (giờ Việt Nam) vì `kubectl logs` mặc định hiểu UTC nếu không ghi rõ offset, ghi sai timezone sẽ lấy nhầm log của giờ khác. Chọn `09:47:00` (sớm hơn `run=1` lúc `09:48:34` khoảng 1.5 phút) để chắc chắn không bỏ lỡ dòng log đầu |
| `\| grep -E "retrieval\|POST /api/v1"` | Lọc chỉ giữ dòng log liên quan tới request retrieval — `-E` cho phép dùng `\|` (OR) trong pattern; nếu log RAGFlow không có đúng 2 từ khóa này, cần đổi pattern sau khi xem thử log thô (`kubectl logs ... \| tail -50` không lọc) |

**Kỳ vọng đọc được:** đếm số dòng match ở mỗi pod — nếu 3 pod có số lượng request gần bằng nhau
(~10 mỗi pod) → xác nhận traffic được chia đều (round-robin/LB hoạt động đúng). Ghép timestamp
log với `time=` ở bảng 3.2 để biết pod nào xử lý run nào, rồi đối chiếu latency cao (>15s) có rơi
tập trung vào 1 pod cụ thể không.

**Output (pod `ragflow-57d9856dff-5kgvd`, TRÍCH — Kiên chỉ chụp được 1 đoạn, log dài hơn):**

```
[app@vrp-kubeengine04 ~]$ kubectl -n ragflow logs ragflow-57d9856dff-5kgvd -c ragflow --since-time=2026-08-18T09:47:00+0800 | grep -E "retrieval|POST /api/v1"
[2026-08-18 10:47:03 +0800] [48] [INFO] 127.0.0.1:38754 POST /api/v1/datasets/73932b965e5e11f192725fd51894c519/documents 1.1 200 1436 45844
[2026-08-18 10:47:03 +0800] [48] [INFO] 127.0.0.1:38758 POST /api/v1/datasets/73932b965e5e11f192725fd51894c519/chunks 1.1 200 1430 48831
[2026-08-18 10:47:03 +0800] [48] [INFO] 127.0.0.1:38764 POST /api/v1/datasets/73932b965e5e11f192725fd51894c519/documents 1.1 200 1430 43026
... (trích, lược nhiều dòng documents/chunks liên tục, tần suất cao, gần như không ngừng)
[2026-08-18 10:49:07 +0800] [48] [INFO] 127.0.0.1:42370 POST /api/v1/retrieval 1.1 200 270774 2290443
[2026-08-18 10:49:08 +0800] [48] [INFO] 127.0.0.1:42428 POST /api/v1/datasets/73932b965e5e11f192725fd51894c519/chunks 1.1 200 1430 49938
... (tiếp tục documents/chunks liên tục tới 10:49:32+ theo ảnh chụp)
```

**Đọc được gì:**
- **Format log:** `[timestamp] [PID_worker] [INFO] IP:PORT METHOD PATH HTTP_VER STATUS DURATION_MS SIZE_BYTES`.
  Cột áp út là **duration tính bằng MILLISECOND** (không phải giây) — dòng
  `POST /api/v1/retrieval 1.1 200 270774 2290443` ⟹ **duration = 270,774ms = 270.8 GIÂY**,
  size response = 2,290,443 bytes (~2.2MB, khớp việc trả về nhiều chunk kết quả).
- **PID worker `[48]` giống nhau ở MỌI dòng** trong log trích — toàn bộ traffic hiển thị đi qua
  1 worker process trong pod này (Quart/Gunicorn 1 worker, khớp ghi nhận cũ *"Web/API dùng
  app.run() single-process"* ở `TRACKING-ragflow-v0.26.4-upgrade.md`).
- ⟹ **XÁC NHẬN đúng lưu ý của Kiên**: log cho thấy hàng loạt request
  `POST /api/v1/datasets/.../documents` và `.../chunks` chạy **LIÊN TỤC, tần suất cao** (nhiều
  request/giây, từ 10:47:03 kéo dài không ngừng tới ít nhất 10:49:32 theo ảnh chụp) — đây là
  API của bên **đẩy tài liệu lên** (ingest/upload), không phải retrieval. Request
  `/api/v1/retrieval` (lúc 10:49:07) chạy **CÙNG THỜI ĐIỂM** với luồng ingest dồn dập này.
- 🔴 **GIẢ THUYẾT MỚI, MẠNH HƠN mọi giả thuyết trước (tokenizer/stopword/ES scale):** retrieval
  API đang phải **cạnh tranh tài nguyên (CPU/worker/connection pool tới ES) với luồng ingest
  liên tục chạy trên CÙNG pod, CÙNG 1 worker process**. Nếu 1 request retrieval rơi vào đúng lúc
  worker đang bận xử lý dồn dập request ingest, nó phải đợi tới lượt → giải thích trực tiếp
  pattern "cùng query, lúc 2s lúc 20s" tốt hơn: không liên quan gì đến kích thước KB hay
  minimum_should_match — liên quan đến **THỜI ĐIỂM gọi trùng với tải ingest** đang chạy trên
  CÙNG pod. Đây khớp với quan sát ở 3.2: dao động run-kế-run mạnh không theo xu hướng thời gian
  (không phải warm-up/GC theo lịch, mà theo tải ingest THAY ĐỔI liên tục tại từng thời điểm gọi).
- **Verify timezone (đã tính, KHÔNG còn nghi ngờ):** log hiển thị `+0800` nhưng là do container
  set timezone khác Việt Nam — quy đổi UTC xác nhận `10:49:07 +0800` == `09:49:07 +0700`, **cùng
  1 thời điểm thực**, không lệch giờ thật, chỉ lệch cách hiển thị con số. Log dòng
  `10:49:07 +0800 POST /api/v1/retrieval ... 270774ms` ⟹ retrieval này **BẮT ĐẦU lúc 09:49:07
  giờ VN, kết thúc lúc 09:49:07 + 270.8s ≈ 09:53:38 giờ VN**.
  So với bảng 3.2: KHÔNG có `run=N` nào bắt đầu đúng `09:49:07` (run=6 lúc 09:49:39, run=7 lúc
  09:49:42 — gần nhưng không khớp giây) ⟹ **dòng log retrieval 270.8s này KHÔNG PHẢI do loop 3.2
  gây ra** — là một request retrieval KHÁC, từ nguồn khác (ai đó/hệ thống khác đang gọi retrieval
  song song với lúc Kiên chạy loop) ⟹ xác nhận thêm: **có traffic retrieval + ingest chạy đồng
  thời từ nhiều nguồn**, không chỉ riêng loop test — môi trường đang có tải thật, không phải môi
  trường sạch để đo. Điều này làm giả thuyết "tranh tài nguyên với ingest" MẠNH LÊN (có thật một
  request retrieval mất 270s trong lúc ingest chạy dồn dập) nhưng cũng nghĩa là **số liệu 3.2 đo
  được cũng bị ảnh hưởng bởi tải thật đang chạy nền, không phải baseline "sạch"**.
- ❓ **Còn cần làm để chốt chắc chắn:**
  1. Lấy log retrieval ĐẦY ĐỦ (không chỉ 1 dòng trích) trong đúng khung giờ 09:48:34-09:53:53 VN
     (= 10:48:34-10:53:53 theo giờ hiển thị log +0800) để map từng `run=N` ở 3.2 với dòng log
     tương ứng — lệnh 3.4 dưới.
  2. Đếm/đo tương quan: có phải MỌI lần retrieval chậm đều trùng thời điểm ingest traffic cao?
     Hay có lần retrieval chậm dù không có ingest chạy song song (sẽ loại giả thuyết này)?
  3. Hỏi bên đẩy tài liệu: có đang chạy batch ingest liên tục 24/7 không, hay chỉ theo lịch/đợt —
     nếu 24/7 liên tục, đây gần như chắc chắn là root cause chính, không phải ES/tokenizer.

### 3.4 Lấy log retrieval đúng khung giờ 3.2 + đếm mật độ ingest — ✅ ĐÃ CHẠY

**Lỗi gặp phải (ghi lại vì là đường cụt):** lệnh ban đầu dùng `--until-time` → `error: unknown flag: --until-time`.
Cờ này **KHÔNG tồn tại** trong kubectl version trên cụm (chỉ có `--since-time`/`--since`). Phải cắt đuôi bằng `awk`.

Chạy trên `vrp-kubeengine04`:

```
kubectl -n ragflow logs ragflow-57d9856dff-5kgvd -c ragflow --since-time=2026-08-18T10:48:00+08:00 > /tmp/log_5kgvd_full.txt
```

```
awk '$0 >= "[2026-08-18 10:48:00" && $0 <= "[2026-08-18 10:54:30~"' /tmp/log_5kgvd_full.txt > /tmp/log_5kgvd_window.txt
```

```
grep "POST /api/v1/retrieval" /tmp/log_5kgvd_window.txt
```

```
grep -c "POST /api/v1" /tmp/log_5kgvd_window.txt
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-n ragflow` | namespace |
| `-c ragflow` | container chính (pod có nhiều container, gồm initContainer `codePatch`) |
| `--since-time=...+08:00` | mốc BẮT ĐẦU, RFC3339. Dùng giờ hiển thị log (+0800), đã verify tương đương giờ VN (+0700) cùng thời điểm thực |
| `--until-time` | ❌ **KHÔNG TỒN TẠI** trong kubectl này — nguồn lỗi. Thay bằng `awk` |
| `awk '$0 >= "..." && $0 <= "..."'` | `$0`=cả dòng. So sánh **chuỗi**; vì timestamp `[YYYY-MM-DD HH:MM:SS` nằm đầu dòng, so sánh chuỗi trùng với so sánh thời gian → cắt khoảng không cần parse date |
| `"...10:54:30~"` | `~` (ASCII 126) > mọi chữ số → bao trọn dòng có timestamp `10:54:30.xxx`, không sót dòng cuối |
| `grep -c` | `-c` = chỉ in SỐ dòng khớp, không in nội dung → đo tổng mật độ traffic |

**Output:**

```
[2026-08-18 10:49:07 +0800] [48] [INFO] 127.0.0.1:42370 POST /api/v1/retrieval 1.1 200 270774 2290443
[2026-08-18 10:49:41 +0800] [48] [INFO] 127.0.0.1:43298 POST /api/v1/retrieval 1.1 200 270772 1974664
[2026-08-18 10:50:26 +0800] [48] [INFO] 127.0.0.1:48568 POST /api/v1/retrieval 1.1 200 270773 2157772
[2026-08-18 10:51:00 +0800] [48] [INFO] 127.0.0.1:49324 POST /api/v1/retrieval 1.1 200 270773 3944767
[2026-08-18 10:51:36 +0800] [48] [INFO] 127.0.0.1:50146 POST /api/v1/retrieval 1.1 200 270771 2002632
[2026-08-18 10:51:59 +0800] [48] [INFO] 127.0.0.1:50624 POST /api/v1/retrieval 1.1 200 270769 2614918
[2026-08-18 10:52:31 +0800] [48] [INFO] 127.0.0.1:51240 POST /api/v1/retrieval 1.1 200 270772 4976925
[2026-08-18 10:53:03 +0800] [48] [INFO] 127.0.0.1:51962 POST /api/v1/retrieval 1.1 200 270772 2257145
[2026-08-18 10:53:38 +0800] [48] [INFO] 127.0.0.1:52654 POST /api/v1/retrieval 1.1 200 270775 2290397
```
```
329
```

**Đọc được gì:**

1. ⚠️ **SỬA LẠI NHẬN ĐỊNH SAI TRƯỚC ĐÓ:** cột `270774` từng bị tôi đọc là **duration = 270.8 giây**.
   **SAI.** Nó gần như **bất biến** (270769–270775, chênh 6 đơn vị) trong khi latency đo thật dao động
   1.98–28.2s. Không metric latency nào đứng yên như vậy. Lệnh 3.7 xác nhận đây là **response size (bytes)**.
2. **Log access của RAGFlow KHÔNG có field duration** (xác nhận ở 3.5) → **hướng "đối chiếu slow-retrieval
   với mật độ ingest qua log" là ĐƯỜNG CỤT**, không ghép cặp được. Muốn tương quan phải đo từ client.
3. `329` request `/api/v1` trong 6.5 phút ≈ **0.84 req/s liên tục** trên riêng pod này. Chỉ **9** là
   retrieval → **320 request còn lại là ingest**. Tỷ lệ **320:9** — tải ingest áp đảo.
4. Loop 3.2 gửi **30** request nhưng pod này chỉ nhận **9** → load balancing CÓ hoạt động, 21 request kia
   vào 2 pod `pljxz`/`q9kz2`. Mọi phân tích log 1 pod chỉ thấy **30% dữ liệu**.
5. Tất cả dòng cùng PID `[48]` = một process `ragflow_server` phục vụ cả retrieval lẫn ingest API.

---

### 3.5 Giải mã format log + tìm field duration — ✅ ĐÃ CHẠY

Chạy trên `vrp-kubeengine04`:

```
grep "POST /api/v1/retrieval" /tmp/log_5kgvd_window.txt | head -1 | cat -A | head -5
```

```
grep -nE "elapsed|duration|took|latency|seconds" /tmp/log_5kgvd_window.txt | head -20
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `head -1` | chỉ 1 dòng mẫu — đủ để giải mã format |
| `cat -A` | `-A` = show-all: hiện MỌI ký tự vô hình (`$`=hết dòng, `^I`=tab, `M-BM-`=non-ASCII/ANSI). Mục đích: kiểm tra log có bị **ANSI color code** chèn giữa các cột không — nếu có thì số cột đếm bị lệch, và đó sẽ là lý do đọc sai cột duration |
| `-n` (grep 2) | in số dòng — để biết dòng duration (nếu có) nằm cách dòng `POST` bao xa, từ đó biết cách ghép cặp |
| `-E` | extended regex, để viết `a\|b\|c` không cần escape |
| 5 từ khoá `elapsed\|duration\|took\|latency\|seconds` | **chưa biết** RAGFlow log duration bằng từ nào: `took` là từ ES dùng, `elapsed`/`duration` là từ app thường dùng → rải rộng để không bỏ sót |

**Output:**

```
[2026-08-18 10:49:07 +0800] [48] [INFO] 127.0.0.1:42370 POST /api/v1/retrieval 1.1 200 270774 2290443$
```
```
(RỖNG — không dòng nào khớp)
```

**Đọc được gì:**

1. `cat -A` chỉ có `$` ở cuối dòng, **không có ANSI escape** → màu đỏ thấy trên terminal là do grep tự tô,
   không nằm trong log. Các cột đếm là đúng thứ tự thật, không bị lệch.
2. grep 5 từ khoá **RỖNG hoàn toàn** trong 6.5 phút log → **RAGFlow không log duration ở access log.**
   Format thật: `[ts] [PID] [LEVEL] client_ip:port METHOD PATH HTTP_ver status resp_bytes ???`
   (kiểu Hypercorn/Quart, không có field thời gian). ⟹ **Loại trừ dứt điểm** khả năng lấy latency từ log.
3. ❓ Cột cuối (1.9M–4.9M) vẫn **chưa xác định** là gì (3.7 chứng minh nó KHÔNG phải response size).

---

### 3.6 Đọc log tầng ứng dụng + đo ES stats tổng thể — ✅ ĐÃ CHẠY (⭐ lệnh phát hiện root cause)

Chạy trên `vrp-kubeengine04`:

```
kubectl -n ragflow logs ragflow-57d9856dff-5kgvd -c ragflow --since=3m | grep -iE "TOTAL:|search|rerank|embedding|es_conn|took" | tail -40
```

```
curl -sk -u 'aihub_prod:<REDACTED>' 'https://10.211.145.107:8051/_nodes/stats/indices/search?pretty' | python3 -c "import sys,json;d=json.load(sys.stdin);[print(k, v['indices']['search']) for k,v in d['nodes'].items()]"
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `--since=3m` | thời lượng tương đối (3 phút trước tới nay) — khác `--since-time` (mốc tuyệt đối). Dùng vì chỉ cần ảnh chụp tải hiện tại |
| `grep -iE` | `-i` = bỏ qua hoa/thường (log có thể viết `Search`/`SEARCH`); `-E` = extended regex cho phép OR |
| `tail -40` | 40 dòng CUỐI (mới nhất) — khác `head`, vì ta cần trạng thái hiện tại chứ không phải lúc bắt đầu |
| `curl -sk` | `-s` = silent (tắt progress bar); `-k` = **bỏ qua verify TLS cert**. Cần `-k` vì ES dùng self-signed cert, không có `-k` thì curl từ chối kết nối |
| `-u 'user:pass'` | HTTP Basic Auth cho ES |
| `_nodes/stats/indices/search` | endpoint ES trả **counter tích luỹ** từ lúc node start: `query_total`, `query_time_in_millis`, `fetch_total`, `fetch_time_in_millis` |
| `?pretty` | ES format JSON dễ đọc |

**Output — log ứng dụng (trích, khung 11:17:28 → 11:17:40):**

```
2026-08-18 11:17:28,626 INFO  445 set_progress(...), progress_msg: 11:17:28 Page(1~100000001): Embedding chunks (0.59s)
2026-08-18 11:17:28,827 INFO  445 handle_task done for task {"id": "56c6cff49ab311f1b5b2fba64e6ce34f", "doc_id": "4f7697fc9ab311f1b5b2fba64e6ce34f", ... "kb_id": "73932b965e5e11f192725fd51894c519", ... "name": "20909862.txt", "size": 7004, "language": "Vietnamese", "embd_id": "qwen3-8b-embedding__OpenAI-API@OpenAI-API-Compatible", ... "raptor": {"use_raptor": true, ...}, "graphrag": {"use_graphrag": true, ...}}
2026-08-18 11:17:29,125 INFO  445 Embedding chunks (1.05s)
2026-08-18 11:17:29,860 INFO  445 handle_task done for task {... "name": "27882806.txt", "size": 9201 ...}
2026-08-18 11:17:30,127 INFO  445 Embedding chunks (0.55s)
2026-08-18 11:17:30,603 INFO  445 handle_task done for task {... "name": "25220668.txt", "size": 8459 ...}
2026-08-18 11:17:37,872 INFO  445 handle_task done for task {... "name": "21912540.txt", "size": 6416 ...}
2026-08-18 11:17:39,415 INFO  445 Embedding chunks (0.83s)
2026-08-18 11:17:39,766 INFO  445 Embedding chunks (1.13s)
2026-08-18 11:17:39,808 INFO  445 handle_task done for task {... "name": "23443097.txt", "size": 7102 ...}
2026-08-18 11:17:40,102 INFO  445 Embedding chunks (1.43s)
2026-08-18 11:17:40,333 INFO  445 handle_task done for task {... "name": "23347601.txt", "size": 7940 ...}
```

**Output — ES node stats (counter tích luỹ, các node có traffic):**

| Node | query_total | query_time_ms | **ms/query** | fetch_total | fetch_time_ms | **ms/fetch** |
|---|---|---|---|---|---|---|
| eWg9YVA3 | 16,277,736 | 13,370,121 | **0.82** | 15,612,217 | 16,944,114 | **1.09** |
| 7HUT_vNn | 1,379,296 | 6,018,103 | **4.36** | 637,145 | 17,030,994 | **26.7** |
| 1FIQxNkV | 12,250,950 | 10,619,741 | **0.87** | 7,786,881 | 34,070,618 | **4.38** |
| YbBCACJR | 999,832 | 3,619,367 | **3.62** | 611,600 | 22,256,959 | **36.4** |
| IIE4PFzF | 12,912,312 | 10,836,603 | **0.84** | 9,380,973 | 17,690,475 | **1.89** |

(5 node khác: tất cả counter = 0, không nhận traffic)

**Đọc được gì:**

1. 🔴 **ES KHÔNG PHẢI BOTTLENECK — loại trừ dứt điểm.** `query_time/query_total` = **0.82–0.87ms** trên 3 node
   chính, tệ nhất 4.36ms. Cộng cả fetch, xấu nhất ~40ms. Retrieval mất 3.6–28s → ES chiếm phần cực nhỏ.
   ⟹ **Mọi giả thuyết ES đều bị phủ định:** tokenizer làm match rộng, KB 1.9M doc, HNSW graph, shard/segment,
   `minimum_should_match`. **Đây là lý do fix `minimum_should_match` thất bại suốt 3 phiên: nhắm sai tầng.**
2. 🔴 **Xác nhận contention với ingest, nhưng ở tầng khác:** PID `445` = `task_executor` (khác PID `48` =
   `ragflow_server`), **cùng pod**. Xử lý ≥**8 document trong 23 giây**, không nghỉ. `Embedding chunks` mất
   **0.59s / 1.05s / 0.55s / 0.83s / 1.13s / 1.43s** nối liền nhau.
3. 🔴 **`kb_id: 73932b965e5e11f192725fd51894c519` = CHÍNH KB đang test retrieval.** Ingest và retrieval đánh
   cùng dataset, cùng lúc.
4. 🔴 **`embd_id: qwen3-8b-embedding` gọi qua API ngoài** — ingest gọi liên tục. Retrieval cũng phải gọi
   embedding cho câu hỏi (`search.py:56/199`) ⟹ **xếp hàng sau ingest**. Đây là cơ chế gây dao động 2s↔28s.
5. `use_raptor: true` + `use_graphrag: true` → ingest còn nặng hơn nữa (RAPTOR gọi LLM `qwen3-32b` để
   summarize, GraphRAG extract entity) — càng chiếm CPU/LLM quota.
6. Không có dòng log nào về retrieval/search ⟹ RAGFlow **không instrument** tầng retrieval → không tách
   tầng được từ log, phải đo bằng ES counter delta (3.8).

---

### 3.7 Tách tầng thời gian bằng curl timing + xác định response thật chứa gì — ✅ ĐÃ CHẠY

Chạy trên `vrp-kubeengine04`:

```
curl -s -o /tmp/resp.json -w "http=%{http_code} size_download=%{size_download} size_upload=%{size_upload} start_transfer=%{time_starttransfer} total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'
```

```
wc -c /tmp/resp.json
```

```
python3 -c "import json;d=json.load(open('/tmp/resp.json'));c=d.get('data',{}).get('chunks',[]);print('chunks:',len(c));print('total:',d.get('data',{}).get('total'));print('keys per chunk:',list(c[0].keys()) if c else None);print('len vector field:',len(str(c[0].get('vector',''))) if c else 0)"
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-o /tmp/resp.json` | ghi body ra file (không in terminal) — cần giữ để bước sau phân tích cấu trúc |
| `-w "..."` | write-out: in biến curl SAU khi request xong. Cách duy nhất lấy timing breakdown không cần tool ngoài |
| `%{size_download}` | byte response nhận được — đối chiếu với cột `270774` trong log để xác định cột đó là gì |
| `%{size_upload}` | byte request gửi lên — nếu ~400 mà log ghi 270774 thì log đang ghi cột khác |
| `%{time_starttransfer}` | ⭐ **cờ quyết định**: thời điểm nhận **byte ĐẦU TIÊN** của response = lúc server xử lý xong |
| `%{time_total}` | tổng đến byte cuối |
| `wc -c` | `-c` = đếm **byte** (không phải `-l` dòng, không phải `-w` từ) — verify độc lập với `size_download` |
| `len vector field` | kiểm tra response có nhét embedding 1024 chiều vào từng chunk không (thứ duy nhất phình được tới MB) |

**Vì sao cặp `time_starttransfer` + `time_total` là chìa khoá:** hiệu số `total − starttransfer` = thời gian
**thuần truyền tải payload**. Nếu tổng 10s mà `starttransfer` = 9.9s → server tính chậm, payload vô can.
Nếu `starttransfer` = 2s mà `total` = 10s → 8 giây chỉ để đẩy dữ liệu qua mạng.

**Output:**

```
http=200 size_download=270773 size_upload=315 start_transfer=10.152 total=10.158
```
```
270773 /tmp/resp.json
```
```
chunks: 10
total: 10
keys per chunk: ['content', 'content_ltks', 'dataset_id', 'doc_type_kwd', 'document_id', 'document_keyword', 'id', 'image_id', 'important_keywords', 'mom_id', 'positions', 'row_id', 'similarity', 'tag_kwd', 'term_similarity', 'vector_similarity']
len vector field: 0
```

**Đọc được gì:**

1. ✅ **Giải mã xong cột log:** `size_download=270773` khớp cột `270774/270772/...` ⟹ cột đó là
   **response size (bytes)**, xác nhận nhận định 3.4 điểm 1 (và huỷ hẳn cách đọc "270.8 giây").
   `size_upload=315` (request chỉ 315 byte) ⟹ log **không** ghi request size.
   ❓ Cột cuối (1.9M–4.9M) vẫn chưa biết là gì — **không phải** response size.
2. 🔴 **Payload/network/serialize KHÔNG phải bottleneck — loại trừ.** `start_transfer=10.152` vs
   `total=10.158` ⟹ chỉ **6 ms** để truyền hết 270KB. **10.152 giây trước đó là server tính toán.**
   ⟹ **100% thời gian nằm TRONG server**, không phải mạng/DNS/TCP/serialize.
3. `len vector field: 0` ⟹ **không** có embedding nào bị trả về. 270KB chỉ là 10 chunk text +
   `content_ltks` (token list — thứ làm phình size nhưng vô hại về thời gian).
4. **`chunks: 10, total: 10` mà mất 10.1 giây** để trả về 10 kết quả. Toàn bộ chi phí là tính toán nội bộ.

---

### 3.8 Đo CHÍNH XÁC ES tiêu bao nhiêu trong 1 request retrieval (counter delta + baseline đối chứng) — ✅ ĐÃ CHẠY

**Nguyên tắc:** ES chỉ có counter tích luỹ, không có per-request. Lấy snapshot **trước/sau** 1 request rồi
trừ ⟹ delta = chi phí request đó. Nhưng có ingest chạy song song gây nhiễu ⟹ **phải đo baseline** cùng độ
dài thời gian mà KHÔNG gửi retrieval, rồi trừ tiếp.

Chạy trên `vrp-kubeengine04` — 3 lệnh đầu **liên tiếp không nghỉ**:

```
curl -sk -u 'aihub_prod:<REDACTED>' 'https://10.211.145.107:8051/_nodes/stats/indices/search' > /tmp/es_before.json
```

```
curl -s -o /dev/null -w "retrieval_total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'
```

```
curl -sk -u 'aihub_prod:<REDACTED>' 'https://10.211.145.107:8051/_nodes/stats/indices/search' > /tmp/es_after.json
```

```
python3 -c "
import json
b=json.load(open('/tmp/es_before.json'))['nodes']
a=json.load(open('/tmp/es_after.json'))['nodes']
tq=tf=tqt=tft=0
for k in a:
    x=a[k]['indices']['search']; y=b[k]['indices']['search']
    dq=x['query_total']-y['query_total']; dqt=x['query_time_in_millis']-y['query_time_in_millis']
    df=x['fetch_total']-y['fetch_total']; dft=x['fetch_time_in_millis']-y['fetch_time_in_millis']
    if dq or df: print(k[:8],'queries=',dq,'query_ms=',dqt,'fetches=',df,'fetch_ms=',dft)
    tq+=dq; tqt+=dqt; tf+=df; tft+=dft
print('=== ES TONG: queries=',tq,'query_ms=',tqt,'fetch_ms=',tft,'=> ES tong ms=',tqt+tft)
"
```

**Baseline đối chứng (KHÔNG gửi retrieval, cùng độ dài ~4s):**

```
curl -sk -u 'aihub_prod:<REDACTED>' 'https://10.211.145.107:8051/_nodes/stats/indices/search' > /tmp/es_idle_before.json; sleep 4; curl -sk -u 'aihub_prod:<REDACTED>' 'https://10.211.145.107:8051/_nodes/stats/indices/search' > /tmp/es_idle_after.json
```

```
python3 -c "
import json
b=json.load(open('/tmp/es_idle_before.json'))['nodes']
a=json.load(open('/tmp/es_idle_after.json'))['nodes']
tq=tqt=tft=0
for k in a:
    x=a[k]['indices']['search']; y=b[k]['indices']['search']
    tq+=x['query_total']-y['query_total']
    tqt+=x['query_time_in_millis']-y['query_time_in_millis']
    tft+=x['fetch_time_in_millis']-y['fetch_time_in_millis']
print('BASELINE 4s KHONG retrieval: queries=',tq,'query_ms=',tqt,'fetch_ms=',tft,'=> tong ms=',tqt+tft)
"
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `> /tmp/es_before.json` / `_after` | 2 snapshot counter để trừ — **bắt buộc** vì ES không có per-request metric |
| `-o /dev/null` | bỏ response body (đã phân tích ở 3.7), chỉ cần timing |
| `sleep 4` | ⭐ **vì sao 4 giây:** khớp xấp xỉ `retrieval_total=3.6s` của lần đo trên. Baseline phải **cùng độ dài** mới trừ được nhiễu ingest công bằng |
| `; ` giữa các lệnh baseline | nối trong **một** dòng để 2 snapshot cách nhau đúng ~4s, không bị thời gian gõ lệnh chen vào |
| `if dq or df:` | chỉ in node có thay đổi — 5/10 node counter = 0, in ra chỉ gây rối |
| `k[:8]` | cắt 8 ký tự đầu node-id cho gọn (node-id ES dài 22 ký tự) |

**Output — có retrieval:**

```
retrieval_total=3.603
7HUT_vNn queries= 4 query_ms= 2 fetches= 4 fetch_ms= 6
IIE4PFzF queries= 167 query_ms= 181 fetches= 99 fetch_ms= 50
1FIQxNkV queries= 105 query_ms= 537 fetches= 23 fetch_ms= 38
eWg9YVA3 queries= 96 query_ms= 100 fetches= 93 fetch_ms= 7
YbBCACJR queries= 19 query_ms= 420 fetches= 11 fetch_ms= 480
=== ES TONG: queries= 391 query_ms= 1240 fetch_ms= 581 => ES tong ms= 1821
```

**Output — baseline không retrieval:**

```
BASELINE 4s KHONG retrieval: queries= 104 query_ms= 77 fetch_ms= 7 => tong ms= 84
```

**Đọc được gì:**

1. **Trừ baseline ⟹ 1 request retrieval sinh ~`391 − 104 = 287` ES query, tiêu ~`1821 − 84 = 1737 ms` ES.**
2. 🔴 **`retrieval_total = 3.603s`, ES = 1.737s ⟹ 1.87 giây (52%) nằm ở PYTHON.** Và lần đo 3.7 cùng query
   y hệt mất **10.158s** ⟹ phần Python khi đó ~8.4s. **Phần dao động mạnh nằm ở Python, không ở ES**
   (ES ổn định <1ms/query theo 3.6).
3. **287 ES query cho MỘT request** — khớp với `topk=1024` ở `search.py:142`: ES phải trả về tới 1024
   candidate, chia trên nhiều shard/node ⟹ hàng trăm query nội bộ.
4. **Cùng một query, 2 lần đo cách nhau vài phút: 3.603s vs 10.158s (2.8×)** — tự nó **tái hiện đúng triệu
   chứng** anh Cường báo, và tái hiện được trong môi trường đo có kiểm soát.
5. Baseline `104 query/4s` = ~26 query/s từ ingest — xác nhận lại tải ingest liên tục (khớp 3.4 điểm 3).

---

### 3.9 ⭐ PHÉP THỬ PHÂN ĐỊNH: `metadata_condition` có phải nguyên nhân không — ✅ ĐÃ CHẠY, giả thuyết bị PHỦ ĐỊNH

**Giả thuyết đem ra thử (falsifiable):** `metadata_condition` với `comparison_operator: contains` không dịch
được thành ES filter ⟹ RAGFlow phải lấy nhiều batch rồi filter trong Python cho tới khi đủ 10 kết quả
⟹ N+1, và số vòng lặp phụ thuộc mật độ user `900034475` trong 1.9M doc ⟹ giải thích dao động.

**Dự đoán:** nếu đúng, **bỏ** `metadata_condition` (giữ nguyên mọi tham số khác) sẽ nhanh hẳn và ổn định.

Chạy trên `vrp-kubeengine04`:

```
for i in 1 2 3 4 5; do curl -s -o /dev/null -w "KHONG_metadata run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6}'; done
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `for i in 1 2 3 4 5` | liệt kê tường minh thay vì `$(seq 1 5)` — chạy được cả trên shell tối giản |
| body JSON | **giống hệt** lệnh 3.7/3.8, **chỉ khác**: bỏ hẳn khối `metadata_condition`. Đổi đúng MỘT biến ⟹ phép thử hợp lệ |
| 5 lần lặp | 1 lần không phân biệt được với dao động ngẫu nhiên; 5 lần đủ thấy xu hướng |

**Output:**

```
KHONG_metadata run=1 total=19.199
KHONG_metadata run=2 total=14.244
^C
```

(dừng sớm ở run=3 vì đã quá rõ; lần chạy lại bị mất SSH `Connection closed` — xem Bài học)

**Đọc được gì:**

1. ❌ **GIẢ THUYẾT BỊ PHỦ ĐỊNH DỨT ĐIỂM.** Bỏ `metadata_condition` **KHÔNG** nhanh hơn — mà còn **CHẬM HƠN**:
   **14.2s / 19.2s** so với **3.6s / 10.2s** khi CÓ metadata. Dự đoán ngược hoàn toàn với thực tế.
2. ⟹ `metadata_condition` **không phải nguyên nhân**; ngược lại nó còn hoạt động như **filter thu hẹp tập
   candidate**, giúp NHANH hơn. Đóng hướng này.
3. **Hệ quả quan trọng hơn:** khi bỏ filter, tập candidate rộng hơn ⟹ chậm hơn ⟹ **chi phí tỷ lệ với SỐ
   CANDIDATE phải xử lý trong Python**, không phải với số doc ES phải match. Đây là bằng chứng độc lập
   ủng hộ **Root cause B (`topk=1024`)** và **C (rerank/re-tokenize 1024 chunk)**.

---

### 3.10 Đọc source thật trong container (v0.26 custom image) — ✅ ĐÃ CHẠY

Chạy trên `vrp-kubeengine04`:

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- grep -n "def retrieval\|def search\|get_fields\|rerank\|encode_queries\|for.*in.*chunk\|\.get(\|sql_retrieval" /ragflow/rag/nlp/search.py
```

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- grep -rn "def get\b\|def getFields\|def search" /ragflow/rag/utils/es_conn.py
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `exec <pod> -c ragflow --` | chạy lệnh TRONG container. `--` tách tham số của kubectl với lệnh cần chạy — thiếu `--` thì kubectl hiểu sai cờ |
| `grep -n` | in số dòng — cần để trích dẫn chính xác vị trí code, và để so với source GitHub xem custom image lệch bao nhiêu |
| `-r` (lệnh 2) | recursive — dư ở đây vì chỉ 1 file, giữ lại vô hại |
| `def get\b` | `\b` = word boundary ⟹ khớp `def get(` nhưng KHÔNG khớp `def get_fields(`. Cần vì muốn phân biệt 2 hàm khác nhau |
| **Vì sao đọc source trong pod, không đọc GitHub** | image là **custom build của anh Cường**, số dòng và nội dung **lệch** so với upstream. Bài học đã ghi: từng kết luận sai vì đọc source v0.24.0 trong khi prod chạy v0.26.4 |

**Output — `rag/nlp/search.py` (trích các dòng quyết định):**

```
 56:        qv, _ = await thread_pool_exec(emb_mdl.encode_queries, txt)
 83:        chunk_doc_ids = [chunk.get("doc_id") for chunk in sres.field.values() if chunk and chunk.get("doc_id")]
134:    async def search(self, req, idx_names: str | list[str], kb_ids: list[str], emb_mdl=None, highlight: bool | list | None = None, rank_feature: dict | None = None):
141:        pg = int(req.get("page", 1)) - 1
142:        topk = int(req.get("topk", 1024))
143:        ps = int(req.get("size", topk))
175:        qst = req.get("question", "")
199:            matchDense = await self.get_vector(qst, emb_mdl, topk, req.get("similarity", 0.1))
245:        return self.SearchResult(total=total, ids=ids, query_vector=q_vec, aggregation=aggs, highlight=highlight, field=self.dataStore.get_fields(res, src + ["_score"]), keywords=keywords)
292:        for i in range(len(chunk_v)):
299:            chunks_tks = [rag_tokenizer.tokenize(self.qryr.rmWWW(ck)).split() for ck in chunks]
422:        fields = self.dataStore.get_fields(res, [vec_field])
434:    def rerank_with_knn(self, sres, query, knn_scores: dict[str, float], tkweight=0.3, vtweight=0.7, cfield="content_ltks", rank_feature: dict | None = None):
456:        vtsim = np.array([knn_scores.get(chunk_id, 0.0) for chunk_id in sres.ids], dtype=np.float64)
461:    def rerank(self, sres, query, tkweight=0.3, vtweight=0.7, cfield="content_ltks", rank_feature: dict | None = None):
468:            vector = sres.field[chunk_id].get(vector_column, zero_vector)
481:            title_tks = [t for t in sres.field[i].get("title_tks", "").split() if t]
515:            vtsim = rerank_mdl.similarity(query, docs)
525:    def _rerank_window(page_size: int, top: int = 0) -> int:
549:    async def retrieval(
562:        rerank_mdl=None,
576:        RERANK_LIMIT = self._rerank_window(page_size, top if rerank_mdl else 0)
615:        if rerank_mdl and sres.total > 0:
616:            sim, tsim, vsim = self.rerank_by_model(
634:            sim, tsim, vsim = self.rerank(
647:            sim, tsim, vsim = self.rerank_with_knn(
708:            "vector": chunk.get(vector_column, zero_vector),
747:    def sql_retrieval(self, sql, fetch_size=128, format="json"):
874:            chunk = self.dataStore.get(cid, idx_nms[0], kb_ids)
924:            chunk = self.dataStore.get(id, idx_nms[0], [ck["kb_id"] for ck in cks])
```

**Output — `rag/utils/es_conn.py`:**

```
136:    def search(
```

**Output phụ (khi thử `import rag.nlp.search`) — tiết lộ thư viện đã cài:**

```
/ragflow/.venv/lib/python3.13/site-packages/pyvi/ViTokenizer.py:81: SyntaxWarning: invalid escape sequence '\.'
/ragflow/.venv/lib/python3.13/site-packages/pyvi/ViTokenizer.py:82: SyntaxWarning: invalid escape sequence '\d'
...
ImportError: cannot import name 'REDIS_CONN' from partially initialized module 'rag.utils.redis_conn' (most likely due to a circular import)
```

**Đọc được gì:**

1. 🔴 **`search.py:142` — `topk = int(req.get("topk", 1024))`.** Mặc định **1024 candidate** mỗi request.
   `:199` truyền `topk` xuống `get_vector` (kNN). Khớp chính xác với **287 ES query/request** đo ở 3.8.
2. 🔴 **`search.py:56` — `emb_mdl.encode_queries`** và **`:199` `get_vector`**: mỗi retrieval **bắt buộc gọi
   embedding model** (`qwen3-8b-embedding`, API ngoài). Đây là điểm **dùng chung tài nguyên với ingest**
   (3.6 cho thấy ingest gọi embedding 0.59–1.43s/batch liên tục) ⟹ **cơ chế gây dao động**.
3. 🔴 **`search.py:299` — `rag_tokenizer.tokenize(...) for ck in chunks`**: **tokenize LẠI** toàn bộ chunk trả
   về, **trong Python, mỗi request**. Với `topk=1024` đây là công việc CPU rất lớn.
4. 🔴 **`:434/:461/:456/:468` — `rerank` / `rerank_with_knn`** dùng numpy trên vector của toàn bộ candidate;
   `:576` `RERANK_LIMIT = self._rerank_window(...)`. Toàn bộ CPU-bound, **cùng process với API**.
5. ⭐ **Phát hiện thêm: image custom có cài `pyvi`** (`site-packages/pyvi/ViTokenizer.py`) — thư viện tokenize
   tiếng Việt. **Đây là xác nhận trực tiếp cách anh Cường "fix tokenizer"**: thay/bổ sung `rag_tokenizer`
   bằng pyvi. Giải quyết được vấn đề tách từ (root cause cũ), **nhưng thêm chi phí CPU** đúng tại
   `search.py:299` nơi tokenize lại toàn bộ candidate mỗi request.
6. `ImportError: circular import redis_conn` chỉ xảy ra khi import module lẻ **ngoài** context app
   ⟹ **không phải bug runtime**, bỏ qua. (`SyntaxWarning` của pyvi cũng vô hại.)
7. `es_conn.py` chỉ có **1** hàm `search` (dòng 136) — không có hàm nào lặp query ẩn ở tầng này
   ⟹ 287 query đến từ **`topk=1024` chia trên shard**, không phải từ vòng lặp trong `es_conn.py`.


### 3.11 ⭐ PHÉP THỬ A/B XEN KẼ: `topk=1024` vs `topk=256` — ✅ ĐÃ CHẠY, Fix 2 bị LOẠI BỎ

**Vì sao phải xen kẽ, không đo rời:** baseline dao động 1.98–28.2s. Đo 5 lần `topk=256` rồi so với
5 lần `topk=1024` đo lúc khác ⟹ chênh lệch sẽ bị tải ingest chi phối, không đọc được gì. Chạy **hai
request trong CÙNG một vòng lặp**, cách nhau vài giây ⟹ cùng điều kiện tải ⟹ so được **từng cặp**.

Chạy trên `vrp-kubeengine04` (1 vòng lặp, 2 curl liên tiếp mỗi vòng — body giống hệt nhau, chỉ khác
`"topk":256`):

```
for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w "topk1024 run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; curl -s -o /dev/null -w "topk256  run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"topk":256,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; done
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| 2 `curl` trong 1 vòng `for` | ⭐ **điểm quyết định của phép thử** — đảm bảo cả hai chịu cùng tải ingest. Nếu tách 2 loop riêng thì kết quả vô giá trị |
| `"topk":256` | biến DUY NHẤT thay đổi giữa 2 request. `search.py:142` đọc `req.get("topk", 1024)` ⟹ client gửi thì override được default, **không cần deploy/sửa code** |
| `-o /dev/null` | bỏ body, chỉ cần timing |
| 8 vòng | đủ để thấy xu hướng qua nhiễu; 4-5 vòng thì một outlier đủ làm lệch kết luận |

**Output:**

```
topk1024 run=1 total=13.121
topk256  run=1 total=19.135
topk1024 run=2 total=2.151
topk256  run=2 total=10.261
topk1024 run=3 total=21.033
topk256  run=3 total=4.998
topk1024 run=4 total=27.170
topk256  run=4 total=13.103
topk1024 run=5 total=14.207
topk256  run=5 total=16.340
topk1024 run=6 total=2.957
topk256  run=6 total=17.375
topk1024 run=7 total=19.835
topk256  run=7 total=15.267
topk1024 run=8 total=25.514
topk256  run=8 total=14.777
```

**So sánh từng cặp:**

| run | topk=1024 | topk=256 | Nhanh hơn |
|---|---|---|---|
| 1 | 13.121 | 19.135 | 1024 |
| 2 | **2.151** | 10.261 | 1024 |
| 3 | 21.033 | 4.998 | 256 |
| 4 | 27.170 | 13.103 | 256 |
| 5 | 14.207 | 16.340 | 1024 |
| 6 | **2.957** | 17.375 | 1024 |
| 7 | 19.835 | 15.267 | 256 |
| 8 | 25.514 | 14.777 | 256 |
| **Mean** | **15.75s** | **13.91s** | — |

**Đọc được gì:**

1. ❌ **`topk` KHÔNG PHẢI NGUYÊN NHÂN — Fix 2 BỊ LOẠI BỎ.** Thắng/thua chia **4–4**. Chênh mean 12%
   (15.75 vs 13.91) **nằm hoàn toàn trong nhiễu** — biên độ nội tại của mỗi nhóm còn lớn hơn nhiều
   (1024: 2.15→27.17 = 12.6×; 256: 5.00→19.14 = 3.8×).
2. **`topk=1024` cho 2 lần NHANH NHẤT toàn bộ phép đo** (2.151s và 2.957s) — nhanh hơn *mọi* lần đo
   `topk=256`. Nếu `topk` là nguyên nhân thì điều này không thể xảy ra.
3. ⟹ **Xử lý 768 candidate dư (1024−256) rẻ đến mức không đo được.** Root cause B và C **bị phủ định**.

---

### 3.12 Verify recall giữa `topk=1024` và `topk=256` — ✅ ĐÃ CHẠY

```
curl -s -X POST '...' -d '{... KHONG co topk ...}' | python3 -c "import sys,json;d=json.load(sys.stdin);print('\n'.join(f\"{c['id'][:12]} sim={c['similarity']:.4f}\" for c in d['data']['chunks']))" > /tmp/r1024.txt
```

```
curl -s -X POST '...' -d '{... "topk":256 ...}' | python3 -c "..." > /tmp/r256.txt
```

```
diff /tmp/r1024.txt /tmp/r256.txt && echo "GIONG NHAU HOAN TOAN - topk=256 an toan" || echo "CO KHAC BIET - xem diff tren"
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `c['id'][:12]` | cắt 12 ký tự đầu chunk-id — đủ phân biệt, dễ đọc, dễ diff |
| `sim={...:.4f}` | in similarity 4 chữ số thập phân — để phát hiện khác biệt nhỏ về scoring |
| `diff A B && echo ... \|\| echo ...` | `&&` chạy khi diff exit 0 (giống nhau), `\|\|` chạy khi exit≠0 (khác) ⟹ tự in kết luận |

**Output:**

```
5fab1cc9ec8a sim=0.7104        (r1024)  |  5fab1cc9ec8a sim=0.7105  (r256)
bfec6db16566 sim=0.5599                 |  bfec6db16566 sim=0.5599
df8cd55deb60 sim=0.5399                 |  df8cd55deb60 sim=0.5399
bc169c4effe4 sim=0.5292                 |  bc169c4effe4 sim=0.5292
ef33eec926c2 sim=0.4961                 |  ef33eec926c2 sim=0.4961
d916776f43ac sim=0.4901                 |  d916776f43ac sim=0.4902
3d0e3edbd3b7 sim=0.4770                 |  3d0e3edbd3b7 sim=0.4771
9232be58c9dd sim=0.4590                 |  9232be58c9dd sim=0.4590
9c34c673689c sim=0.4528                 |  9c34c673689c sim=0.4529
c316444b6bc0 sim=0.4371                 |  c316444b6bc0 sim=0.4372
```
```
CO KHAC BIET - xem diff tren
```

**Đọc được gì:**

1. **Cùng 10 chunk, CÙNG id, CÙNG thứ tự.** Khác biệt duy nhất là **chữ số thập phân thứ 4** của
   similarity (0.7104 vs 0.7105; 0.4901 vs 0.4902). `diff` báo "khác" chỉ vì so **chuỗi text**.
2. ⟹ **`topk=256` cho kết quả y hệt `topk=1024`** — không mất recall. Nhưng cũng **không nhanh hơn**
   (3.11) ⟹ 768 candidate dư đó **vô hại về cả chất lượng lẫn thời gian**. Bằng chứng độc lập nữa
   cho thấy tầng rerank/tokenize **không phải** bottleneck.

---

### 3.13 ⭐ QUAN SÁT CỦA KIÊN: CPU pod chỉ 10–20% — bằng chứng quyết định đổi hướng

**Kiên quan sát trực tiếp trên monitoring:** CPU usage của pod ragflow **chỉ 10–20%**, không tăng
khi retrieval chậm.

**Đọc được gì (đây là suy luận quan trọng nhất của cả phiên):**

1. ❌ **Root cause C (re-tokenize + rerank CPU-bound) BỊ PHỦ ĐỊNH.** Nếu Python đang tokenize/rerank
   1024 candidate thì CPU phải cao — thực tế 10–20%. Khớp với 3.11 (giảm topk 4× không nhanh hơn)
   và 3.12 (kết quả y hệt).
2. 🔴 **15 giây đó là thời gian CHỜ (I/O wait), KHÔNG phải thời gian TÍNH.** Process nằm im chờ
   response từ bên ngoài ⟹ CPU thấp là **hệ quả tất yếu**, không phải nghịch lý.
3. ⟹ **Chờ ai?** Đã loại trừ: ES (<1ms/query, 3.6/3.8), network tới client (6ms, 3.7),
   payload (270KB, 3.7), CPU nội bộ (10–20%, mục này). **Chỉ còn MỘT ứng viên: lời gọi
   `qwen3-8b-embedding` qua API ngoài** (`search.py:56` `encode_queries`, `:199` `get_vector`).
4. ⟹ **CPU thấp là bằng chứng ỦNG HỘ Root cause A, không phải chống lại nó.** Retrieval chờ
   embedding; embedding đang bị `task_executor` bơm liên tục (3.6: 0.59–1.43s/batch, ≥8 doc/23s).
5. **Hệ quả cho hướng fix:** Fix 1 (tách `task_executor` khỏi pod API) sẽ **KHÔNG đủ** nếu chỉ tách
   process — vì contention không ở CPU pod mà ở **embedding service dùng chung**. ⟹ **Fix 3 (tách/scale
   endpoint embedding) chuyển thành fix CHÍNH**, không còn là phụ.

---

### 3.14 Tìm endpoint thật của embedding service — ✅ ĐÃ CHẠY

**Vì sao phải đào:** `service_conf.yaml` trong container **KHÔNG dùng được** — `base_url: 'http://:80'`
(rỗng), `api_key: 'xxx'`, phần dưới toàn bị comment (`# factory: 'BAAI'`, `# name: 'bge-m3'`) ⟹ đó là
**template mặc định**, không phải cấu hình đang chạy. Cấu hình model thật nằm trong **MySQL**.

Và `kubectl get svc -n ragflow` chỉ có `ragflow-mysql` (ClusterIP 172.16.138.99:3306), `minio`, `redis`
⟹ **không có service embedding/LiteLLM nào trong namespace này** ⟹ nó nằm ngoài namespace.

Chạy trên `vrp-kubeengine04`:

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- env | grep -iE "base_url|api_base|openai|embed|llm|litellm"
```

**Output:**

```
EMBEDDING_BATCH_SIZE=16
```

**Đọc được gì:** biến duy nhất khớp. Endpoint **không** nằm trong env ⟹ phải lấy từ DB.
`EMBEDDING_BATCH_SIZE=16` — xem phân tích ở cuối mục này, đây là con số quan trọng.

**Bảng `tenant_llm` (schema cũ v0.24): RỖNG.** v0.26 đã migrate sang schema mới:
`tenant_model_provider` / `tenant_model_instance` / `tenant_model` / `tenant_model_group`
(còn thấy `tenant_model_instance_bak_20260731` = backup lúc migrate).

⚠️ **Lệnh sai đã thử (ghi lại):** `select id, provider, model_name, model_type, base_url from
tenant_model_instance;` → `ERROR 1054 (42S22): Unknown column 'provider' in 'field list'`.
Schema mới khác dự đoán ⟹ phải `select *` trước khi đoán tên cột.

```
select * from tenant_model_provider;
```

**Output:**

```
| id                               | create_date         | provider_name         | tenant_id                        |
| 8af1a5e69a2811f1b5b2fba64e6ce34f | 2026-08-17 18:43:54 | OpenAI-API-Compatible | 0775713275d111f198e53d33b00035ba |
| 909c21f68cbd11f1aa37635d6e0f142c | 2026-07-31 16:55:22 | OpenAI-API-Compatible | 22cdb01e486a11f1ac9749e86cfe939a |
2 rows in set (0.00 sec)
```

```
select * from tenant_model_instance;
```

**Output:**

```
| id                               | create_date         | instance_name      | provider_id                      | api_key                  | status | extra                                                        |
| 05e030d29a2a11f1b5b2fba64e6ce34f | 2026-08-17 18:54:30 | LiteLLM            | 8af1a5e69a2811f1b5b2fba64e6ce34f | <REDACTED> | active | {"base_url": "http://10.208.137.53:8992/", "region": "default"} |
| 5d3e78d28cd511f18d5d67e68cb92881 | 2026-07-31 19:45:44 | qwen3-8b-embedding | 909c21f68cbd11f1aa37635d6e0f142c | <REDACTED> | active | {"base_url": "http://10.208.137.53:8992/", "region": "default"} |
2 rows in set (0.01 sec)
```

**Đọc được gì:**

1. 🎯 **ENDPOINT TÌM ĐƯỢC: `http://10.208.137.53:8992/`** — API key `<REDACTED>`.
2. 🔴 **CẢ HAI instance (`LiteLLM` và `qwen3-8b-embedding`) dùng CÙNG MỘT `base_url`** ⟹ đây là
   **LiteLLM gateway**, và embedding đi qua chính gateway đó. **Không có đường riêng cho retrieval.**
3. **`10.208.137.53` là IP NODE, không phải ClusterIP** (ClusterIP là dải `172.16.x.x`, ví dụ MySQL
   `172.16.138.99`) ⟹ LiteLLM chạy **ngoài namespace `ragflow`**, truy cập qua **NodePort 8992**.
   Giải thích vì sao `get svc -n ragflow` không thấy nó.
4. `tenant_id = 22cdb01e486a11f1ac9749e86cfe939a` **khớp chính xác** `tenant_id` trong log ingest ở 3.6
   ⟹ xác nhận đúng tenant/luồng đang chạy, không phải cấu hình mồ côi.
5. Cả 2 `status = active`.

**⭐ Phân tích `EMBEDDING_BATCH_SIZE=16` (giả thuyết cơ chế, ❓ chưa verify):**

Biến này áp cho **ingest**: mỗi lần `task_executor` gửi **16 chunk** lên embedding trong MỘT request.
Log 3.6 `Embedding chunks (0.59s → 1.43s)` chính là thời gian cho **16 chunk một lượt**.

Trong khi đó **retrieval chỉ cần embed 1 câu hỏi**. Nếu LiteLLM/backend xử lý **tuần tự (FIFO,
không ưu tiên)**, request 1-câu của retrieval phải **đợi hết các batch 16-chunk đang xếp trước nó**.
Với ingest ≥8 doc/23s, hàng đợi lúc nào cũng có việc ⟹ **thời gian chờ phụ thuộc đúng lúc đó hàng đợi
dài bao nhiêu** ⟹ khớp hoàn hảo với dao động 2s↔28s và với CPU pod chỉ 10–20% (đang chờ, không tính).

⟹ Gợi ra một fix rẻ chưa có trong danh sách: **giảm `EMBEDDING_BATCH_SIZE`** làm mỗi đơn vị công việc
của ingest ngắn hơn ⟹ retrieval chờ ít hơn (cơ chế "nhường đường"). Đánh đổi: ingest chậm hơn chút.
**PHẢI verify hàng đợi có tuần tự thật không** (phép đo song song ở 3.15) trước khi tin cơ chế này.

---

### 3.15 🔴 BƯỚC 0 — Đo trực tiếp embedding service: EMBEDDING VÔ CAN (giả thuyết thứ 3 bị phủ định)

Chạy trên `vrp-kubeengine04`, **đúng lúc ingest đang hoạt động**.

```
curl -s -X GET 'http://10.208.137.53:8992/v1/models' -H 'Authorization: Bearer <REDACTED>' | python3 -m json.tool | head -40
```

**Output (trích):** `qwen3-8b-embedding`, `qwen3.5-397b-a17b-fp8`, `qwen3-embedding`, `bge-m3`,
`dall-e-3`, `qwen3-32b`, `qwen3.5-35b-a3b` — tất cả `owned_by: openai` (LiteLLM chuẩn hoá).
⟹ Gateway sống, tên model `qwen3-8b-embedding` đúng.

**Đo tuần tự 10 lần:**

```
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -w "embed run=$i total=%{time_total}\n" -X POST 'http://10.208.137.53:8992/v1/embeddings' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"model":"qwen3-8b-embedding","input":"quy tắc quy trình quy định về điều lệnh"}'; done
```

```
embed run=1 total=0.218    embed run=6  total=0.161
embed run=2 total=0.148    embed run=7  total=0.144
embed run=3 total=0.116    embed run=8  total=0.154
embed run=4 total=0.117    embed run=9  total=0.119
embed run=5 total=0.148    embed run=10 total=0.165
```

**Đo 5 request SONG SONG** (kiểm tra hàng đợi FIFO):

```
for i in 1 2 3 4 5; do (curl -s -o /dev/null -w "parallel$i total=%{time_total}\n" -X POST 'http://10.208.137.53:8992/v1/embeddings' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"model":"qwen3-8b-embedding","input":"quy tắc quy trình quy định về điều lệnh"}' &) ; done; sleep 30
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `( ... &)` | subshell nền ⟹ 5 request bay đi **CÙNG LÚC**, không đợi nhau. Nếu viết `curl; curl; ...` thì thành tuần tự, không kiểm được hàng đợi |
| `sleep 30` | giữ shell sống để output từ các subshell kịp in ra (không có thì shell thoát, mất output) |
| **Vì sao cần phép đo này** | Nếu thời gian **tăng dần** (1s,2s,3s...) ⟹ xử lý tuần tự/FIFO ⟹ xác nhận cơ chế "retrieval đợi sau batch ingest". Nếu **về cùng lúc** ⟹ song song tốt, cơ chế đó sai |

```
parallel3 total=0.124
parallel4 total=0.176
parallel5 total=0.183
parallel2 total=0.218
parallel1 total=0.238
```

**Đọc được gì:**

1. 🔴 **EMBEDDING KHÔNG PHẢI NGUYÊN NHÂN — Root cause A BỊ PHỦ ĐỊNH.** Latency **~150ms**
   (min 0.116, max 0.238) ⟹ **biên độ chỉ 2×**, cực kỳ ổn định. So với retrieval 3.6–28.2s
   (biên độ 14×): embedding chiếm **~0.15s / 3.6s = 4%**, và **không đóng góp gì vào phần dao động**.
2. 🔴 **KHÔNG có hàng đợi FIFO.** 5 request song song về trong 0.124–0.238s, **không tăng dần**
   ⟹ LiteLLM xử lý đồng thời tốt. ⟹ **Giả thuyết `EMBEDDING_BATCH_SIZE=16` gây nghẽn hàng đợi: SAI.**
3. ⭐ **Quan trọng nhất: phép đo này chạy ĐÚNG LÚC INGEST ĐANG HOẠT ĐỘNG.** Nghĩa là ngay cả khi
   `task_executor` bơm batch 16-chunk liên tục, embedding **vẫn** trả về trong 150ms
   ⟹ **không có contention ở embedding service.** Toàn bộ Root cause A sụp đổ.
4. 🔴 **SỐ HỌC KHÔNG KHỚP — đây là điều cần giải thích tiếp:**
   ES 1.7s + embedding 0.15s + network 0.006s ≈ **1.9s**, nhưng tổng thực tế **3.6s → 28.2s**.
   ⟹ **Còn 1.7s đến 26.3s KHÔNG THUỘC bất kỳ tầng nào đã đo.**

---

### 3.16 Bảng tổng kết loại trừ — mọi tầng đã đo đều KHÔNG phải nguyên nhân

| Tầng | Chi phí đo được | Biên độ | Lệnh | Trạng thái |
|---|---|---|---|---|
| Elasticsearch | 1.7s tổng, **<1ms/query** | ổn định | 3.6, 3.8 | ❌ loại |
| Network → client | **6ms** | — | 3.7 | ❌ loại |
| Payload/serialize | 270KB, trong 6ms | — | 3.7 | ❌ loại |
| CPU pod | **10–20%** | — | 3.13 | ❌ loại |
| **Embedding (LiteLLM)** | **~150ms** | **2×** | **3.15** | ❌ **loại** |
| `topk` 1024 vs 256 | không khác | 4–4 | 3.11, 3.12 | ❌ loại |
| `metadata_condition` | bỏ đi CHẬM HƠN | — | 3.9 | ❌ loại |
| **TỔNG đã giải thích** | **~1.9s** | | | |
| **THỰC TẾ** | **3.6s → 28.2s** | **14×** | 3.2 | 🔴 **thiếu 1.7–26.3s** |

**Đọc được gì:** phần chậm VÀ phần dao động **không nằm ở tầng nào đã đo**. Phải profile trực tiếp
trong process (`py-spy dump`) hoặc bisect bằng biến thể request — **không suy luận từ source nữa**
(xem Bài học 0d).

---

## 4. Issue chi tiết — 3 root cause từng chốt ĐỀU BỊ PHỦ ĐỊNH, chưa tìm ra nguyên nhân

### 4.0 Bảng tách tầng thời gian (số liệu thật, không suy đoán)

Cùng MỘT query, đo 4 lần trong ~40 phút:

| Lần đo | Tổng | ES | Python | Ghi chú |
|---|---|---|---|---|
| 3.7 (có metadata) | **10.158s** | ~1.7s (suy từ 3.8) | **~8.4s** | `start_transfer=10.152` ⟹ network chỉ 6ms |
| 3.8 (có metadata) | **3.603s** | **1.737s** (đo trực tiếp) | **1.87s** | delta ES counter, đã trừ baseline |
| 3.9 run=1 (bỏ metadata) | **19.199s** | — | — | bỏ filter ⟹ CHẬM hơn |
| 3.9 run=2 (bỏ metadata) | **14.244s** | — | — | |

**Kết luận tách tầng:**
- **Network/DNS/TCP/serialize: ~6ms** ⟹ loại trừ (3.7).
- **ES: 1.7s, query trung bình <1ms/query** ⟹ **KHÔNG phải bottleneck** (3.6 + 3.8).
- **Python trong `ragflow_server`: 1.9s → 8.4s, dao động 4.5×** ⟹ **ĐÂY LÀ TOÀN BỘ VẤN ĐỀ.**

### 4.1 ❌ ~~ROOT CAUSE A — Embedding xếp hàng sau ingest~~ — ĐÃ BỊ PHỦ ĐỊNH (3.15)

> **KẾT LUẬN NÀY ĐÃ SAI — đây là lần sai thứ 3 của phiên.** Đo trực tiếp LiteLLM
> `http://10.208.137.53:8992/v1/embeddings` **đúng lúc ingest đang chạy**: **~150ms**, min 0.116,
> max 0.238 ⟹ **biên độ chỉ 2×**. 5 request song song về cùng lúc ⟹ **không có hàng đợi FIFO**.
> Embedding chiếm ~4% tổng thời gian và **không đóng góp gì vào phần dao động**.
>
> **Vì sao lập luận cũ sai:** tôi lấy log ingest `Embedding chunks (0.59s–1.43s)` làm bằng chứng
> rằng embedding chậm. Nhưng đó là thời gian ingest xử lý **16 chunk một lượt** (`EMBEDDING_BATCH_SIZE=16`),
> **không nói gì** về latency mà một request 1-câu của retrieval phải chờ. Phải tự gọi thẳng vào
> service mà đo — và khi đo thì nó nhanh.
>
> Giữ lại phần dưới để ghi nhận lập luận đã dùng.

**Lập luận cũ (đã bị phủ định):**
**Cơ chế:**
1. Mỗi request retrieval **bắt buộc** embed câu hỏi: `search.py:56` `emb_mdl.encode_queries`,
   `search.py:199` `get_vector(qst, emb_mdl, topk, ...)` → gọi `qwen3-8b-embedding` qua **API ngoài**.
2. Cùng lúc, `task_executor` (PID **445**) đang ingest **không ngừng**: log 3.6 cho thấy ≥**8 document
   / 23 giây**, mỗi document sinh nhiều batch `Embedding chunks` mất **0.59s–1.43s**, gọi **cùng**
   `qwen3-8b-embedding`, trên **cùng KB** `73932b965e5e11f192725fd51894c519` đang test.
3. Ingest còn bật `use_raptor: true` + `use_graphrag: true` → thêm lời gọi LLM `qwen3-32b` để
   summarize/extract entity → chiếm thêm quota và CPU.
4. ⟹ Request embedding của retrieval **xếp hàng sau** tải ingest. Chờ bao lâu phụ thuộc **đúng lúc đó
   ingest đang ở đâu trong batch** → **hoàn toàn ngẫu nhiên theo thời điểm**.

**Bằng chứng:** 3.6 (log PID 445 + `embd_id` + `kb_id`), 3.4 điểm 3 (tỷ lệ traffic **320 ingest : 9 retrieval**),
4.0 (Python dao động 1.9s→8.4s trong khi ES ổn định <1ms).

**Vì sao đây là lời giải cho "cùng query lúc 2s lúc 20s":** không có tham số nào của query thay đổi giữa
các lần đo — thứ duy nhất thay đổi là **trạng thái tải của ingest tại thời điểm đó**.

### 4.2 ❌ ~~ROOT CAUSE B — `topk=1024`~~ — ĐÃ BỊ PHỦ ĐỊNH (3.11/3.12)

> **KẾT LUẬN NÀY ĐÃ SAI.** A/B xen kẽ 8 cặp cho thấy `topk=256` không nhanh hơn `topk=1024`
> (mean 13.91s vs 15.75s, thắng/thua 4–4), và kết quả trả về y hệt. Giữ lại phần dưới để ghi nhận
> lập luận đã dùng và vì sao nó sai: **suy từ source code (`topk=1024`) và số ES query (287) sang kết
> luận về latency, mà không đo A/B trước.** 1024 candidate là thật, nhưng chi phí xử lý chúng rẻ
> đến mức không đo được.

**Lập luận cũ (đã bị phủ định):**

`search.py:142`: `topk = int(req.get("topk", 1024))` — client không gửi `topk` ⟹ mặc định **1024**.
`search.py:143`: `ps = int(req.get("size", topk))`.
`search.py:199`: `topk` được truyền xuống kNN làm `num_candidates`.

**Hệ quả đo được:** **287 ES query cho 1 request** (3.8, đã trừ baseline) — 1024 candidate phân trên
nhiều shard/node. Rồi **toàn bộ 1024 candidate được kéo về Python** để rerank.

**Trả về chỉ 10 chunk** (3.7: `chunks: 10, total: 10`) — tức **99% công việc bị bỏ đi** sau khi đã trả giá.

### 4.3 ❌ ~~ROOT CAUSE C — Re-tokenize + rerank CPU-bound~~ — ĐÃ BỊ PHỦ ĐỊNH (3.13)

> **KẾT LUẬN NÀY ĐÃ SAI.** **CPU pod chỉ 10–20%** — nếu đang tokenize/rerank 1024 candidate thì CPU
> phải cao. Cộng với 3.11 (giảm topk 4× không nhanh hơn) và 3.12 (kết quả y hệt). Giữ lại để ghi
> nhận: **đọc source thấy vòng lặp nặng ⟹ kết luận CPU-bound, mà không kiểm tra CPU thực tế.**

**Lập luận cũ (đã bị phủ định):**

- `search.py:299`: `chunks_tks = [rag_tokenizer.tokenize(self.qryr.rmWWW(ck)).split() for ck in chunks]`
  — **tokenize LẠI** từng candidate, mỗi request. Image custom cài **`pyvi`** (3.10 điểm 5) → tokenizer
  tiếng Việt tốt hơn nhưng **nặng CPU hơn** đúng tại điểm nóng này.
- `search.py:434/461`: `rerank_with_knn` / `rerank` + numpy (`:456`, `:468`) trên vector của toàn bộ candidate.
- `search.py:576`: `RERANK_LIMIT = self._rerank_window(page_size, top if rerank_mdl else 0)`.
- Tất cả **CPU-bound**, chạy **trong cùng pod / cùng CPU limit** với `task_executor` đang ingest.

**Bằng chứng độc lập từ 3.9:** bỏ `metadata_condition` ⟹ tập candidate rộng hơn ⟹ **CHẬM HƠN** (14–19s).
Chi phí tỷ lệ với **số candidate Python phải xử lý**, không tỷ lệ với số doc ES match. Điều này cũng
**giải thích vì sao fix `minimum_should_match` vô hiệu**: nó giảm số doc ES match — tầng vốn chỉ tốn 1.7s.

### 4.4 ❌ Các giả thuyết ĐÃ BỊ LOẠI TRỪ (đừng điều tra lại)

| Giả thuyết | Bị loại bởi | Bằng chứng |
|---|---|---|
| ES chậm do scale 1.9M doc / HNSW / shard / GC | 3.6, 3.8 | query trung bình **<1ms**, tệ nhất 4.4ms; ES chỉ 1.7/3.6s |
| Tokenizer làm match rộng ⟹ ES scoring nhiều doc | 3.6, 3.8 | ES không phải bottleneck ⟹ giảm match set không giúp |
| `minimum_should_match` thiếu ở nhánh tiếng Việt | 3.1 + 3.6 | Code v0.26 đã có sẵn ở 3 vị trí; và tầng ES vốn không chậm |
| ES nằm ngoài cụm ⟹ network hop chậm | 3.7 | `total − start_transfer` = **6ms**; ES stats <1ms/query |
| Response payload khổng lồ (2–5MB) làm chậm | 3.7 | Response chỉ **270KB**, `len vector field: 0`, truyền hết trong 6ms |
| `metadata_condition contains` gây N+1 filter-in-Python | 3.9 | Bỏ hẳn metadata ⟹ **CHẬM HƠN** (14–19s vs 3.6–10.2s) |
| Load-balance lệch giữa 3 pod ragflow | 3.4 điểm 4 | 30 request chia ra, pod này nhận 9 ⟹ LB hoạt động |
| Patch cũ `minimum_should_match` conflict/đè code v0.26 | 3.1 | 3 match đúng dòng 92/165/229, khớp gốc upstream |
| Retrieval mất 270.8 giây (đọc từ log) | 3.4, 3.7 | Cột đó là **response size**, không phải duration. Log **không có** field duration |

---

## 4.5 🔴 HƯỚNG ĐIỀU TRA TIẾP — CHƯA CÓ FIX NÀO ĐƯỢC XÁC NHẬN

> **Trạng thái thật:** cả 3 root cause từng "chốt" (A/B/C) đều đã bị phủ định bằng số đo.
> **Không có fix nào sẵn sàng để deploy.** Mọi đề xuất fix trước đó trong file này đã bị gạch.

### Vấn đề cần giải thích

| | |
|---|---|
| ES | 1.7s |
| Embedding | 0.15s |
| Network + serialize | 0.006s |
| **Tổng giải thích được** | **~1.9s** |
| **Thực tế** | **3.6s → 28.2s** |
| **🔴 KHÔNG GIẢI THÍCH ĐƯỢC** | **1.7s → 26.3s** |

CPU pod chỉ **10–20%** ⟹ đây là **I/O wait**, không phải tính toán. Nhưng cả hai đích I/O đã biết
(ES, LiteLLM) đều nhanh và ổn định. ⟹ **Đang chờ một thứ chưa được nhìn tới.**

### BƯỚC TIẾP — profile trực tiếp, KHÔNG suy luận từ source

**Vì sao bắt buộc profile:** đã sai 3 lần vì đoán từ code (Bài học 0d). Cần biết process **đứng ở
dòng nào** khi request chậm, không phải đoán dòng nào *trông* nặng.

**❌ Cách 1 — `py-spy dump`: ĐÃ THỬ, KHÔNG DÙNG ĐƯỢC.**

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'pip install py-spy 2>/dev/null | tail -1; ls /ragflow/.venv/bin/py-spy 2>/dev/null || which py-spy'
```
```
command terminated with exit code 1
```

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'py-spy dump --pid 48'
```
```
sh: 1: py-spy: not found
command terminated with exit code 127
```

**Đọc được gì:** `pip install` thất bại (exit 1) — image tối giản, **không có network ra ngoài** để
tải package. `py-spy` không có sẵn (exit 127). ⟹ **Không profile được trong container.**
Khớp bài học cũ đã ghi: *"Image tối giản không có netstat/ss/curl"*.

⟹ Phải dùng cách đo **từ ngoài** (Cách 2) hoặc bật log có sẵn (Cách 3).

**Cách 2 — bisect bằng `vector_similarity_weight`** (không cần cài gì):

```
for i in 1 2 3; do curl -s -o /dev/null -w "ca_hai      run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6}'; curl -s -o /dev/null -w "vector_only run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":1.0}'; curl -s -o /dev/null -w "text_only   run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.0}'; done
```

| Biến thể | Nghĩa | Nếu nhanh/chậm thì suy ra gì |
|---|---|---|
| `vector_similarity_weight: 1.0` | **chỉ kNN/vector**, bỏ luồng full-text + tokenize | nhanh ⟹ chi phí ở luồng full-text |
| `vector_similarity_weight: 0.0` | **chỉ full-text/BM25**, bỏ kNN | nhanh ⟹ chi phí ở luồng vector/kNN |
| `vector_similarity_weight: 0.6` | cả hai (mặc định đang dùng) | — |
| **cả ba đều chậm như nhau** | ⟹ chi phí ở phần **DÙNG CHUNG** sau khi có kết quả (fetch field, build response) hoặc thứ chưa nhìn tới | |

Ba biến thể chạy **xen kẽ trong cùng vòng lặp** — bắt buộc, vì nền dao động 14× (bài học 0c).

**Cách 3 — bật debug log của RAGFlow.** `search.py:590` có `logging.debug(f"[Search] global_offset=...
rerank_limit=... page_size=... page=...")` và `:606` `"[Search] retrieval weights: trace_id=%s ..."`
⟹ code **CÓ** instrument sẵn ở DEBUG level, chỉ chưa bật. Nếu bật được `LOG_LEVEL=DEBUG` sẽ có
timing/trace từ chính RAGFlow.

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- env | grep -iE "log_level|debug"
```

### 🔴 MANH MỐI MỚI từ Postman (2026-08-18 12:06) — nội dung chunk là văn bản DO LLM SINH

**Quan sát:** Postman gọi cùng endpoint/body, `Status: 200 OK`, **`Time: 17.40 s`**,
**`Size: 264.6 KB`** (khớp 270KB đã đo ở 3.7). Nhưng **nội dung response** tiết lộ điều mới:

```
"content": "Document: Về việc bổ sung, thống nhất một số quy định về điều lệnh, nghi lễ\nVăn bản
được cung cấp có tên là \"Cong van ve viec bo sung, dieu chinh dieu lenh, nghi le.pdf\". Tuy nhiên,
nội dung cụ thể của văn bản này hiện đang ở trạng thái file trống, nghĩa là không có bất kỳ thông
tin, điều khoản hay quy định nào được ghi nhận trong tài liệu đính kèm. Do đó, việc xây dựng một
bản tóm tắt chi tiết về các nội dung cụ thể như các điều khoản bổ sung, các quy định mới về điều
lệnh ... là không thể thực hiện được dựa trên dữ liệu hiện có.\nTrong bối cảnh hành chính và văn
bản quy phạm pháp luật, một văn bản có tiêu đề như \"Về việc bổ sung, thống nhất một số quy định
về điều lệnh, nghi lễ\" thường sẽ đóng vai trò là một công văn hướng dẫn, quyết định hoặc thông
báo của cơ quan có thẩm quyền (thường là Bộ Quốc phòng, Tổng cục Chính trị hoặc các cơ quan quản
lý nhà nước liên quan đến lực lượng vũ trang) nhằm mục đích hoàn thiện hệ thống quy định hiện
hành. Thông thường, các văn bản thuộc loại này sẽ giải quyết các vấn đề phát sinh trong quá trình
thực hiện điều lệnh, nghi lễ, hoặc thống nhất các cách hiểu, cách làm chưa đồng bộ giữa các đơn
vị, các cấp. Nội dung dự kiến của một văn bản như vậy, nếu không bị trống, thường sẽ bao gồm các
phần chính sau:\nThứ nhất, phần mở đầu thường nêu rõ căn cứ pháp lý để ban hành văn bản ...
Thứ hai, phần nội dung chính sẽ tập trung vào việc liệt kê cụ thể các điểm cần bổ sung hoặc điều
chỉnh. Đối với lĩnh vực điều lệnh ..."
```

**Đọc được gì:**

1. 🔴 **Đây KHÔNG phải nội dung tài liệu gốc — đây là văn bản DO LLM SINH RA.** Bằng chứng nội tại:
   - Tự thuật về file: *"nội dung cụ thể của văn bản này hiện đang ở trạng thái file trống"*
   - Tự thừa nhận không làm được: *"việc xây dựng một bản tóm tắt chi tiết ... là không thể thực hiện được"*
   - Suy đoán chứ không trích: *"thường sẽ đóng vai trò là"*, *"Nội dung dự kiến của một văn bản như vậy"*
   ⟹ Đây là **output của RAPTOR** (`use_raptor: true`, xác nhận ở log 3.6) — bản tóm tắt phân cấp
   do `qwen3-32b` sinh lúc ingest.
2. ⟹ **Chunk trong KB này rất dài** (mỗi cái là một đoạn văn LLM sinh, dài gấp nhiều lần chunk gốc).
   Giải thích vì sao response 270KB cho chỉ 10 chunk. ❓ Có ảnh hưởng tới `search.py:299` (tokenize
   lại từng chunk) — nhưng CPU chỉ 10–20% nên **khó là thủ phạm chính**.
3. 🔴 **NGHI PHẠM MỚI, ĐÍCH I/O THỨ BA CHƯA ĐO: LLM `qwen3-32b`.** Đã đo embedding (150ms, vô can),
   đã đo ES (<1ms, vô can) — nhưng **chưa bao giờ đo LLM**. `search.py:515`
   `rerank_mdl.similarity(query, docs)` và các đường liên quan tới RAPTOR có thể gọi LLM
   **trong luồng retrieval**, không chỉ lúc ingest.
   **Vì sao khớp:** một lời gọi `qwen3-32b` mất **nhiều giây** và **dao động mạnh** theo độ dài
   output ⟹ giải thích được ĐỒNG THỜI: CPU thấp (chờ LLM), I/O wait, dao động 2s↔28s không theo
   query, và 1.7–26.3s không thuộc ES/embedding.
   ⚠️ **Vẫn là giả thuyết** — theo Bài học 0d, **phải đo trực tiếp `qwen3-32b` trước khi kết luận.**

**Lệnh cần chạy (đo LLM qua cùng gateway):**

```
for i in 1 2 3; do curl -s -o /dev/null -w "llm_chat run=$i total=%{time_total}\n" -X POST 'http://10.208.137.53:8992/v1/chat/completions' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"xin chào"}],"max_tokens":50}'; done
```

**Lệnh xác định "đang chờ ai" mà KHÔNG cần py-spy** — đếm connection tới gateway trong lúc retrieval chạy.
Terminal 1 bắn retrieval, Terminal 2 chạy đồng thời:

```
for i in 1 2 3 4 5 6 7 8 9 10; do echo "t=$i conn_8992=$(kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'grep -c 2320 /proc/net/tcp' 2>/dev/null)"; done
```

| Thành phần | Ý nghĩa |
|---|---|
| `grep -c 2320` | `/proc/net/tcp` ghi port dạng **hex**. `8992` thập phân = **`0x2320`** ⟹ đếm số connection đang mở tới LiteLLM gateway |
| `-c` | chỉ in SỐ dòng khớp |
| Chạy 10 vòng | lấy chuỗi thời gian trong lúc retrieval 17s đang chạy, thấy được connection **tăng rồi giữ** hay **bằng 0** |
| **Cách đọc** | connection tới 8992 **tăng và giữ** trong lúc retrieval chậm ⟹ retrieval đang chờ gateway (LLM/embedding). **Bằng 0 / không đổi** ⟹ không gọi gateway ⟹ thủ phạm ở nơi khác |

⟹ Đây là cách xác định **process đang chờ ai** mà không cần `py-spy` (đã loại vì không cài được).

---

### 3.17 Đo LLM `qwen3-32b` + đếm connection gateway — ✅ ĐÃ CHẠY, LLM VÔ CAN (nghi phạm thứ 4 bị loại)

```
for i in 1 2 3; do curl -s -o /dev/null -w "llm_chat run=$i total=%{time_total}\n" -X POST 'http://10.208.137.53:8992/v1/chat/completions' -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '{"model":"qwen3-32b","messages":[{"role":"user","content":"xin chào"}],"max_tokens":50}'; done
```

**Output:**
```
llm_chat run=1 total=1.236
llm_chat run=2 total=1.259
llm_chat run=3 total=1.258
```

```
for i in 1 2 3 4 5 6 7 8 9 10; do echo "t=$i conn_8992=$(kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'grep -c 2320 /proc/net/tcp' 2>/dev/null)"; done
```

**Output:**
```
t=1 conn_8992=67    t=6  conn_8992=67
t=2 conn_8992=67    t=7  conn_8992=67
t=3 conn_8992=67    t=8  conn_8992=67
t=4 conn_8992=67    t=9  conn_8992=67
t=5 conn_8992=67    t=10 conn_8992=67
```

**Đọc được gì:**

1. ❌ **LLM `qwen3-32b` KHÔNG PHẢI THỦ PHẠM — nghi phạm thứ 4 bị loại.** 1.236 / 1.259 / 1.258s
   ⟹ **biên độ 1.02×**, ổn định gần như tuyệt đối. (Lưu ý: `max_tokens:50`; lời gọi RAPTOR thật
   sinh nhiều token hơn nên sẽ lâu hơn — nhưng **độ ổn định** này đã đủ cho thấy gateway/LLM không
   phải nguồn dao động 14×.)
2. ⚠️ **`conn_8992=67` BẤT BIẾN qua 10 lần đo — nhưng phép đo này KHÔNG VALID để kết luận về
   retrieval.** Vòng đếm chạy **sau khi** retrieval đã xong (2 lệnh tuần tự, không đồng thời)
   ⟹ 67 chỉ là **connection nền của ingest**, không nói gì về việc retrieval có gọi gateway hay không.
   Phải đo lại với vòng đếm chạy **nền song song** (`&`) trước khi bắn retrieval.
3. 🔴 **Nhưng con số 67 tự nó đáng chú ý:** pod đang giữ **67 connection mở** tới LiteLLM gateway.
   Đây là con số lớn và **bất biến** ⟹ dấu hiệu của **connection pool** (giữ sẵn), không phải
   connection tạo/đóng theo request.

### 🔴 NGHI PHẠM MỚI (khớp chặt nhất với toàn bộ dữ kiện): CONNECTION POOL CẠN

**Cơ chế giả định:** mỗi backend **đo riêng lẻ đều nhanh** — nhưng đó là khi đo **từ ngoài bằng curl,
với connection riêng mới**. Trong pod, RAGFlow dùng **connection pool DÙNG CHUNG**. Nếu ingest
(320 request/6.5 phút, 3.4) chiếm hết slot pool, retrieval phải **chờ để LẤY ĐƯỢC connection**
trước khi kịp gửi request đi.

**Vì sao giả thuyết này giải thích được cái nghịch lý trung tâm — "mọi tầng đo riêng đều nhanh
nhưng tổng lại chậm":** vì thời gian chờ nằm ở **khoảng GIỮA các tầng**, không nằm TRONG tầng nào.
Nó **vô hình** với mọi phép đo đã làm:

| Phép đo đã làm | Vì sao không thấy thời gian chờ pool |
|---|---|
| ES `_nodes/stats` | chỉ đo từ lúc query **đã tới** ES, không đo lúc chờ lấy connection |
| `curl` embedding/LLM từ ngoài | curl tạo **connection riêng mới**, không dùng pool của app |
| CPU pod 10–20% | đang chờ **semaphore/lock**, không tiêu CPU |
| `curl -w` tổng thời gian | thấy tổng chậm nhưng **không tách** được chờ-pool ra khỏi chờ-backend |

⟹ Khớp **đồng thời cả 4 dữ kiện**: CPU thấp · I/O wait · mọi backend nhanh · dao động theo thời điểm
(pool đầy hay rỗng phụ thuộc đúng lúc đó ingest đang chiếm bao nhiêu slot).

⚠️ **VẪN LÀ GIẢ THUYẾT.** Theo Bài học 0d: **không xây fix lên đây trước khi đo.**

**Lệnh cần chạy để kiểm:**

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'awk "NR>1{print \$4}" /proc/net/tcp | sort | uniq -c | sort -rn'
```

| Thành phần | Ý nghĩa |
|---|---|
| cột `$4` của `/proc/net/tcp` | **trạng thái TCP** dạng hex: `01`=ESTABLISHED, `06`=TIME_WAIT, `08`=CLOSE_WAIT, `0A`=LISTEN |
| `sort \| uniq -c \| sort -rn` | đếm mỗi trạng thái, xếp giảm dần |
| **Cách đọc** | nhiều **CLOSE_WAIT** ⟹ app không đóng connection đúng cách, **pool rò rỉ dần cạn**. Nhiều **TIME_WAIT** ⟹ mở/đóng liên tục thay vì tái dùng ⟹ mỗi request phải handshake lại |

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'echo "gateway_8992: $(grep -c 2320 /proc/net/tcp)"; echo "ES_8051: $(grep -c 1F73 /proc/net/tcp)"; echo "mysql_3306: $(grep -c 0CEA /proc/net/tcp)"; echo "TONG: $(($(wc -l < /proc/net/tcp)-1))"'
```

| Port | Hex | Ghi chú |
|---|---|---|
| 8992 (LiteLLM gateway) | `2320` | đã biết = 67 |
| 8051 (ES) | `1F73` | chưa đo |
| 3306 (MySQL) | `0CEA` | chưa đo |
| TỔNG | — | `wc -l` trừ 1 dòng header |

**Đo lại `conn_8992` cho ĐÚNG (vòng đếm chạy NỀN trước khi bắn retrieval):**

```
(for i in $(seq 1 25); do echo "t=$i conn8992=$(kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'grep -c 2320 /proc/net/tcp' 2>/dev/null)"; done &) ; curl -s -o /dev/null -w "RETRIEVAL total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}' ; sleep 20
```

| Thành phần | Ý nghĩa |
|---|---|
| `( ... &)` đặt TRƯỚC curl | ⭐ **sửa lỗi của phép đo cũ** — vòng đếm phải chạy **nền, khởi động trước** để thực sự đồng thời với retrieval |
| `sleep 20` | giữ shell sống cho vòng nền in hết output |
| **Cách đọc** | `conn8992` **nhảy lên >67 rồi tụt về** ⟹ retrieval có gọi gateway. **Giữ nguyên 67 suốt** ⟹ retrieval KHÔNG gọi gateway ⟹ đang chờ chỗ khác (pool? MySQL? event loop?) |

---

### 3.18 🔴🔴 BẰNG CHỨNG MẠNH NHẤT: 104 CLOSE_WAIT + connection tăng đơn điệu = CONNECTION LEAK

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'awk "NR>1{print \$4}" /proc/net/tcp | sort | uniq -c | sort -rn'
```

**Output:**
```
    126 06
    104 08
     42 01
      7 05
      3 0A
      1 04
```

**Giải mã trạng thái TCP (cột 4, hex):**

| Hex | Trạng thái | Số | Nghĩa |
|---|---|---|---|
| `06` | TIME_WAIT | **126** | connection đã đóng, chờ hết 2×MSL. Nhiều ⟹ mở/đóng liên tục thay vì tái dùng |
| `08` | **CLOSE_WAIT** | **104** | 🔴 **phía bên kia ĐÃ đóng, nhưng APP CHƯA gọi `close()`** — nằm đó **vô thời hạn**, mỗi cái giữ 1 file descriptor + 1 slot pool. **Đây là CONNECTION LEAK** |
| `01` | ESTABLISHED | 42 | đang dùng thật |
| `05` | FIN_WAIT2 | 7 | đang đóng |
| `0A` | LISTEN | 3 | socket lắng nghe |
| `04` | FIN_WAIT1 | 1 | đang đóng |
| | **TỔNG** | **283** | |

**Đo `conn8992` ĐỒNG THỜI với retrieval (đã sửa lỗi phép đo cũ — vòng đếm chạy nền trước):**

```
(for i in $(seq 1 25); do echo "t=$i conn8992=$(kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'grep -c 2320 /proc/net/tcp' 2>/dev/null)"; done &) ; curl ... ; sleep 20
```

**Output:**
```
88                          <- baseline truoc khi ban (grep 2320)
0                           <- grep 1F91 (port 8081): khong co connection nao
command terminated with exit code 1     <- binh thuong: grep khong tim thay -> exit 1
--- baseline tren, gio ban retrieval ---
t=1  conn8992=88     t=10 conn8992=92     t=19 conn8992=92
t=2  conn8992=89     t=11 conn8992=92     t=20 conn8992=92
t=3  conn8992=89     t=12 conn8992=92     t=21 conn8992=93
t=4  conn8992=89     t=13 conn8992=92     t=22 conn8992=94
t=5  conn8992=89     t=14 conn8992=92     t=23 conn8992=94
t=6  conn8992=89     t=15 conn8992=92     t=24 conn8992=94
t=7  conn8992=90     t=16 conn8992=92     t=25 conn8992=94
t=8  conn8992=91     t=17 conn8992=92
t=9  conn8992=92     t=18 conn8992=92
RETRIEVAL total=25.351
```

**Postman cùng thời điểm (ảnh 12:16 PM):** `Status: 200 OK`, **`Time: 10 m 19.38 s`**, `Size: 264.59 KB`.

**Đọc được gì:**

1. 🔴 **104 CLOSE_WAIT / 283 connection (37%) = CONNECTION LEAK, có thật, đo được.**
   `CLOSE_WAIT` không tự hết — nó tồn tại **cho tới khi app gọi `close()`** hoặc process chết.
   App đang **rò rỉ connection**.
2. 🔴 **`conn8992` TĂNG ĐƠN ĐIỆU 88 → 94 trong lúc 1 request retrieval chạy, KHÔNG BAO GIỜ GIẢM.**
   Và so với phép đo trước đó (3.17): **67 → 88 → 94**. Connection tới gateway **chỉ tăng**.
3. 🔴 **LATENCY LEO THANG THEO THỜI GIAN — khớp mô hình leak:**
   | Thời điểm | Latency | conn_8992 |
   |---|---|---|
   | ~12:02 (3.15) | — | **67** |
   | 12:06 Postman | **17.40s** | — |
   | 12:18 curl | **25.351s** | **88 → 94** |
   | 12:16 Postman | **10 phút 19.38 giây** | — |
   ⟹ Càng nhiều request, càng nhiều connection kẹt CLOSE_WAIT, càng chậm. **Không phải dao động
   ngẫu nhiên mà là XU HƯỚNG XẤU DẦN.**
4. ⭐ **GIẢI THÍCH ĐƯỢC NGHỊCH LÝ TRUNG TÂM** ("mọi backend đo riêng đều nhanh nhưng tổng lại chậm"):
   khi đo bằng `curl` **từ ngoài**, ta lấy **connection mới sạch** ⟹ nhanh. Trong pod, connection cũ
   mắc kẹt CLOSE_WAIT **không tái dùng được** ⟹ mỗi request phải **mở connection mới**, và khi tiến
   tới giới hạn (pool size / `ulimit -n` file descriptor) thì **việc LẤY ĐƯỢC connection** trở thành
   phần chậm — thời gian đó **vô hình** với ES stats, với curl ngoài, và không tiêu CPU (khớp 10–20%).
5. **Dự đoán kiểm chứng được (falsifiable):** nếu đây là root cause thì **restart pod sẽ làm nhanh trở
   lại ngay**, rồi chậm dần theo số request. ⟹ **Đây là phép thử quyết định** (xem lệnh dưới).
6. `grep -c 1F91` = 0 ⟹ không có connection tới port 8081. `exit code 1` của lệnh đầu là **bình
   thường** (grep không match ⟹ exit 1), không phải lỗi.

**Lệnh cần chạy tiếp:**

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'echo "== ulimit nofile =="; ulimit -n; echo "== so fd dang mo cua PID 48 =="; ls /proc/48/fd 2>/dev/null | wc -l; echo "== tong socket =="; awk "NR>1" /proc/net/tcp | wc -l'
```

| Thành phần | Ý nghĩa |
|---|---|
| `ulimit -n` | **trần file descriptor** của process. Đây là con số quyết định: nếu số fd đang mở tiến gần trần ⟹ xác nhận cơ chế "chờ lấy được connection" |
| `ls /proc/48/fd \| wc -l` | đếm fd **thực tế** PID 48 (ragflow_server) đang giữ. So với `ulimit -n` để biết còn cách trần bao xa |
| `awk "NR>1" ... \| wc -l` | tổng socket TCP (trừ header) |

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'awk "NR>1 && \$4==\"08\" {print \$3}" /proc/net/tcp | sort | uniq -c | sort -rn | head'
```

| Thành phần | Ý nghĩa |
|---|---|
| `\$4==\"08\"` | lọc **chỉ** dòng CLOSE_WAIT |
| `print \$3` | in địa chỉ đích (hex) của các connection bị leak |
| **Cách đọc** | phần lớn là `2320` (8992) ⟹ leak ở HTTP client gọi **LiteLLM**. Là `1F73` (8051) ⟹ leak ở **ES client**. Là `0CEA` (3306) ⟹ **MySQL** |

**⭐ PHÉP THỬ QUYẾT ĐỊNH — restart pod rồi đo ngay:**

```
kubectl -n ragflow rollout restart deployment/ragflow -n ragflow
```

```
kubectl -n ragflow rollout status deployment/ragflow --timeout=300s
```

```
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -w "sau_restart run=$i total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; done
```

**Cách đọc phép thử này:**
- **Nhanh hẳn ngay sau restart (1-3s) rồi chậm dần** ⟹ 🔴 **ROOT CAUSE CHỐT: connection leak.**
  Fix: tìm chỗ không đóng connection trong code, hoặc workaround bằng restart định kỳ + tăng `ulimit`.
- **Vẫn chậm ngay sau restart** ⟹ leak **không phải** nguyên nhân chính (dù vẫn là bug thật cần sửa),
  phải điều tra tiếp.

⚠️ **Cần báo trước các bên đang cắm API** — `rollout restart` có downtime ngắn.

---

### 3.19 🎯 CHỐT VỊ TRÍ LEAK: 227 CLOSE_WAIT tới LiteLLM gateway — nhưng KHÔNG cạn fd

**Output:**

```
=== 1. ulimit + fd PID 48 ===
1048576
45
=== 2. CLOSE_WAIT noi toi dau ===
    227 3589D00A:2320
      8 3FD510AC:2328
      1 0100007F:83A2
      1 0100007F:8392
      1 0100007F:835E
      1 0100007F:835C
      1 0100007F:8354
      1 0100007F:834C
      1 0100007F:8338
      1 0100007F:8336
=== 3. theo doi CLOSE_WAIT tang khong ===
t=1 tong=488 close_wait=245
t=2 tong=488 close_wait=245
t=3 tong=488 close_wait=245
t=4 tong=488 close_wait=245
t=5 tong=489 close_wait=246
=== 4. rerank model ===
| model_name                      | model_type | status | extra                                  |
| qwen3-8b-embedding              | embedding  | active | {"max_tokens": 256000}                 |
| qwen3.5-35b-a3b                 | chat       | active | {"max_tokens": 256000, "is_tools": true} |
| openai/qwen3-5-27b-v1           | chat       | active | {"max_tokens": ...}                    |
| qwen3-8b-embedding___OpenAI-API | embedding  | active | {"is_tools": false, "max_tokens": 200000} |
```

**Giải mã địa chỉ hex (little-endian):**

| Hex | Giải mã | Là gì |
|---|---|---|
| `3589D00A:2320` | `0A.D0.89.35` = **10.208.137.53** : `0x2320`=**8992** | 🔴 **LiteLLM gateway** — 227 CLOSE_WAIT |
| `3FD510AC:2328` | `AC.10.D5.3F` = **172.16.213.63** : `0x2328`=**9000** | **MinIO** — 8 CLOSE_WAIT |
| `0100007F:83xx` | **127.0.0.1** : port cao | localhost nội bộ, lẻ tẻ 1 cái mỗi port |

**Đọc được gì:**

1. 🎯 **CHỐT VỊ TRÍ LEAK: 227/245 CLOSE_WAIT (93%) đi tới `10.208.137.53:8992` = LiteLLM gateway.**
   ⟹ Leak nằm ở **HTTP client gọi LiteLLM** (embedding + chat), **một chỗ duy nhất**, không rải rác.
   MinIO leak nhẹ (8 cái) — bug thật nhưng nhỏ.
2. ❌ **BỎ lập luận "cạn file descriptor".** `ulimit -n` = **1,048,576** (cực cao), fd PID 48 chỉ **45**
   ⟹ **không hề cạn fd**. Cơ chế "retrieval chờ vì hết fd" mà tôi nêu ở 3.18 điểm 4: **SAI**.
3. ⚠️ **Giải mâu thuẫn "fd=45 nhưng close_wait=245":** `/proc/net/tcp` liệt kê socket của **cả network
   namespace** (mọi process trong pod, gồm `task_executor` PID 445), còn `/proc/48/fd` chỉ đếm của
   **riêng PID 48**. ⟹ Phần lớn 245 CLOSE_WAIT thuộc **`task_executor`**, không phải API process.
4. **CLOSE_WAIT đã TĂNG so với lần đo trước** (3.18: **104/283** → giờ **245/488**), nhưng trong 5 lần
   đo liền nhau thì **đứng yên** (245→246, chỉ +1). ⟹ Leak tăng **theo mỗi request**, không theo
   thời gian trôi. Khớp: giữa 2 lần đo có nhiều request ingest + retrieval chạy.
5. **KHÔNG có model nào `model_type = rerank`** ⟹ rerank dùng **đường local**
   (`search.py:634` `self.rerank()`), **không gọi model ngoài**. ⟹ Loại nghi phạm "rerank model".
6. 🔴 **Giả thuyết leak PHẢI ĐỔI CƠ CHẾ:** không phải "client cạn fd", mà có thể là
   **phía LiteLLM gateway bị cạn** — 227 connection nửa-đóng treo trên gateway có thể làm nó hết
   worker/connection slot, **dù gateway vẫn trả lời curl đơn lẻ nhanh** (curl mở connection mới,
   được phục vụ ngay; còn RAGFlow tái dùng pool đã đầy connection chết).
   ❓ **Vẫn là giả thuyết** — phép thử restart sẽ phân định.

---

### 3.20 🔴🔴 PHÂN BỐ LƯỠNG CỰC — leak KHÔNG gây chậm, dấu hiệu TIMEOUT/RETRY

⚠️ **Phép thử restart BỊ VÔ HIỆU:** Kiên bấm `^C` khi rollout đang chạy
(`Waiting for deployment "ragflow" rollout to finish: 1 out of 3 new replicas have been updated`)
⟹ `POD_MOI=ragflow-57d9856dff-5kgvd` là **pod CŨ, chưa restart**, và `cw8992` bắt đầu từ **296**
chứ không phải 0. **10 mẫu dưới đây đo trên pod CHƯA restart.**
(Kiên có quan sát thêm: sau restart gọi Postman 2 lần liên tiếp được **4s/5s** — ❓ chưa đo có hệ thống.)

**Output:**

```
=== TRUOC restart ===
cw_8992=261
truoc_restart total=2.646
=== RESTART ===
deployment.apps/ragflow restarted
Waiting for deployment "ragflow" rollout to finish: 1 out of 3 new replicas have been updated...
^C
POD_MOI=ragflow-57d9856dff-5kgvd
=== SAU restart: 10 mau + cw moi mau ===
run=1  total=3.023   cw8992=296
run=2  total=2.048   cw8992=298
run=3  total=28.643  cw8992=303
run=4  total=4.025   cw8992=303
run=5  total=3.985   cw8992=305
run=6  total=27.555  cw8992=310
run=7  total=4.184   cw8992=310
run=8  total=30.854  cw8992=319
run=9  total=1.973   cw8992=317
run=10 total=33.196  cw8992=322
```

**Đọc được gì:**

1. ❌ **CONNECTION LEAK KHÔNG PHẢI NGUYÊN NHÂN — nghi phạm thứ 5 bị loại.**
   `cw8992` tăng **đơn điệu** 296→322, nhưng latency **nhảy loạn**: 3.0, 2.0, **28.6**, 4.0, 4.0,
   **27.6**, 4.2, **30.9**, **1.97**, **33.2**.
   **Bằng chứng phản bác trực tiếp:** `run=9` chỉ **1.973s** khi `cw=317` (gần cao nhất);
   `run=2` = 2.048s khi `cw=298`. **Không có tương quan nào** giữa CLOSE_WAIT và latency.
   ⟹ Leak vẫn là **bug thật** (227 socket bỏ rơi, cần báo anh Cường sửa) nhưng **không gây chậm.**
2. 🔴 **PHÁT HIỆN MỚI, QUAN TRỌNG NHẤT: PHÂN BỐ LƯỠNG CỰC (bimodal), có KHOẢNG TRỐNG hoàn toàn.**

   | Nhóm | Số mẫu | Giá trị |
   |---|---|---|
   | **Nhanh** | 6/10 | 1.97, 2.05, 3.02, 3.99, 4.03, 4.18 |
   | **Khoảng giữa 5–27s** | **0/10** | — **KHÔNG CÓ MẪU NÀO** |
   | **Chậm** | 4/10 | 27.56, 28.64, 30.85, 33.20 |

3. ⭐ **Ý nghĩa của phân bố lưỡng cực: đây là TIMEOUT/RETRY, KHÔNG phải tài nguyên cạn dần.**
   - Tài nguyên cạn dần (pool/CPU/memory) ⟹ latency tăng **mượt** (5s, 8s, 12s, 18s...).
   - Lưỡng cực với **khoảng trống hoàn toàn** ⟹ có **đường nhanh ~2–4s**, và khi trúng một điều kiện
     nào đó thì **cộng thêm một KHỐI thời gian gần như CỐ ĐỊNH ~25–29 giây**.
   - **25–30 giây là chữ ký kinh điển của TIMEOUT rồi RETRY** (connect timeout 30s, hoặc 1 lần thử
     thất bại + retry).
4. 🔴 **Cơ chế giả định (khớp cả leak lẫn lưỡng cực):** pool đưa ra một connection **đã chết**
   (chính là những cái kẹt CLOSE_WAIT) ⟹ request gửi vào đó **treo tới khi timeout (~25-30s)**
   ⟹ retry bằng connection mới ⟹ thành công. Nếu **lấy được connection sống ngay** ⟹ nhanh 2–4s.
   ⟹ **Leak không gây chậm TRỰC TIẾP, nhưng là NGUỒN của các connection chết** làm request trúng timeout.
   ⟹ **Fix KHÔNG phải "restart để dọn"**, mà là: **pool biết kiểm tra connection còn sống (pre-ping)**,
   hoặc **giảm timeout**, hoặc **sửa chỗ leak** để pool không còn connection chết.
   ❓ **Vẫn là giả thuyết** — cần xác nhận con số timeout và tìm config tương ứng (lệnh 3.21).
5. **`truoc_restart total=2.646`** khi `cw=261` — cũng nhanh. Càng củng cố điểm 1.
6. ⚠️ **Cần đo lại phép thử restart cho ĐÚNG** — chờ `rollout status` xong hẳn (3/3 replicas),
   KHÔNG bấm `^C`, rồi lấy tên pod mới.

**Lệnh cần chạy tiếp (3.21): 25 mẫu đo phân bố + tìm config timeout**

```
for i in $(seq 1 25); do curl -s -o /dev/null -w "run=$i connect=%{time_connect} start=%{time_starttransfer} total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{...}'; done
```

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- sh -c 'grep -rn "timeout" /ragflow/rag/utils/es_conn.py | head -15; grep -rn "timeout\|retry\|max_retries\|pool" /ragflow/common/settings.py 2>/dev/null | head -20'
```

```
kubectl -n ragflow exec ragflow-57d9856dff-5kgvd -c ragflow -- env | grep -iE "timeout|retry|pool"
```

| Thành phần | Ý nghĩa |
|---|---|
| `%{time_connect}` | thời gian TCP handshake tới **RAGFlow** (không phải tới backend) — để loại trừ chậm ở tầng ngoài |
| `%{time_starttransfer}` | byte đầu tiên về ⟹ server xử lý xong. Hiệu `total − start` = thời gian truyền |
| 25 mẫu | cần cỡ mẫu lớn hơn 10 để xác nhận **khoảng trống 5–27s** là thật, không phải may |
| `grep timeout es_conn.py` | tìm config timeout của ES client. **Ghi chú:** phiên trước có patch `sed 's/timeout=600/timeout=30/g'` trên file này (`05-FIX.md` mục 3) ⟹ **con số 30 này rất đáng nghi**, khớp khối 25-30s! |
| `grep pool` | tìm cấu hình connection pool (size, pre-ping, recycle) |

🔴 **Nghi phạm cụ thể xuất hiện:** `05-FIX.md` mục 3 ghi có patch `postStart`:
`sed -i 's/timeout=600/timeout=30/g' /ragflow/rag/utils/es_conn.py`. **`timeout=30` khớp chính xác
khối thời gian chậm 27.5–33.2s đo được!** ⟹ Phải kiểm patch này còn áp dụng không và nó đang
timeout cái gì.

---

### Nghi phạm chưa được kiểm tra (liệt kê để không quên, KHÔNG phải kết luận)

Tất cả đều ở mức **giả thuyết chưa có bằng chứng** — không được xây fix lên bất kỳ cái nào trước khi đo:

| Nghi phạm | Vì sao đáng nghi | Cách kiểm |
|---|---|---|
| **Async event loop bị block** | RAGFlow là Quart/ASGI, chạy `app.run()` = **single process**. Một coroutine gọi hàm sync nặng sẽ block **toàn bộ** event loop ⟹ mọi request khác đứng chờ. Khớp hoàn hảo với: CPU thấp, I/O wait, dao động theo thời điểm, và việc ingest API (`/documents`, `/chunks`) cùng process | `py-spy dump` khi chậm; hoặc đo latency 1 request **khi không có ingest** |
| ❌ ~~LLM `qwen3-32b`~~ **ĐÃ ĐO, VÔ CAN (3.17)**: 1.236/1.259/1.258s, biên độ 1.02× | Response chứa văn bản **do LLM sinh** (RAPTOR output — xem manh mối Postman ở trên). Một lời gọi LLM mất **nhiều giây**, dao động mạnh theo độ dài output ⟹ khớp đồng thời CPU thấp + I/O wait + dao động 2s↔28s + phần 1.7-26.3s chưa giải thích | Đo `/v1/chat/completions` model `qwen3-32b`; đếm connection tới port 8992 lúc retrieval chậm |
| ❌ ~~Rerank model~~ **ĐÃ KIỂM (3.19): KHÔNG có model_type=rerank** ⟹ rerank chạy local, không gọi model ngoài | `search.py:515` `rerank_mdl.similarity(query, docs)`, `:615` `if rerank_mdl and sres.total > 0`. **Chưa kiểm** rerank model có được cấu hình không, và nếu có thì gọi tới đâu | `select * from tenant_model;` xem có rerank model; đo endpoint đó |
| **MySQL** | `document_keyword`/`docnm_kwd` có thể query MySQL cho từng chunk. **Chưa đo MySQL** | `SHOW PROCESSLIST` khi request chậm; hoặc bật slow query log |
| **MinIO** | Chưa đo. Retrieval có thể fetch gì từ object storage | log/metrics MinIO |
| 🔴🔴 **CONNECTION LEAK (CLOSE_WAIT) — ĐÃ CÓ BẰNG CHỨNG, xem 3.18** | Nếu pool tới ES/MySQL nhỏ và ingest chiếm hết ⟹ retrieval chờ **lấy connection**, không phải chờ query. ES query nhanh nhưng **chờ pool** thì không hiện trong ES stats | đếm connection trong `/proc/net/tcp`; tìm config pool size |

⭐ **Nghi phạm số 1 theo mức độ khớp bằng chứng: async event loop bị block.** Nó giải thích được
**đồng thời** cả 4 dữ kiện: CPU thấp, I/O wait, dao động theo thời điểm chứ không theo query, và
tất cả traffic (retrieval + ingest API) dùng **cùng 1 process PID 48** (3.4). Nhưng **vẫn chỉ là
giả thuyết** — phải `py-spy dump` mới biết.

### Phép đo rẻ nên làm ngay: đo khi ingest NGHỈ

Nếu tạm dừng được luồng ingest (hoặc chờ lúc bên đẩy tài liệu nghỉ), đo lại 10 mẫu retrieval.
Đây là phép thử **một biến** rẻ nhất và mạnh nhất còn lại:
- **Nhanh + ổn định khi ingest nghỉ** ⟹ contention với ingest là thật, nhưng ở tầng **chưa xác định**
  (event loop / pool / MySQL) — thu hẹp được rất nhiều.
- **Vẫn chậm + vẫn dao động** ⟹ ingest vô can hoàn toàn, vấn đề nội tại của retrieval ở scale này.

### Tiêu chí "fix dứt điểm" (định lượng, để biết khi nào xong)

| Tiêu chí | Baseline hiện tại | Mục tiêu |
|---|---|---|
| Median latency | 9.57s | < 3s |
| Max latency (30 mẫu) | 28.2s | < 6s |
| Biên độ (max/min) | **14.2×** | **< 3×** ⟵ đây mới là "ổn định" |
| % request < 5s | 37% (11/30) | > 90% |

**Quan trọng:** "biên độ" là tiêu chí quyết định. Anh Cường báo issue là **"không ổn định"**, nên giảm
median mà biên độ vẫn 14× thì **chưa fix xong**.

---

## 5. Bài học

0. ⭐ **BÀI HỌC LỚN NHẤT CỦA PHIÊN — "đọc source thấy vòng lặp nặng" KHÔNG PHẢI bằng chứng về latency.**
   Tôi chốt 2 root cause (B: `topk=1024`, C: rerank CPU-bound) **chỉ từ đọc source + đếm ES query**,
   nghe rất hợp lý: 1024 candidate, tokenize lại từng cái, numpy trên vector — "đương nhiên" phải chậm.
   **Cả hai đều SAI.** Cái làm lộ ra:
   - **Kiên chỉ ra CPU pod chỉ 10–20%.** Một câu quan sát monitoring phủ định cả hai giả thuyết —
     CPU-bound thì CPU phải cao.
   - **A/B xen kẽ 8 cặp (3.11):** `topk=256` không nhanh hơn, thắng/thua 4–4, và `topk=1024` cho 2 lần
     nhanh nhất toàn phép đo (2.15s/2.96s).
   ⟹ **Phản xạ cần nhớ: trước khi tin một đoạn code là bottleneck, (a) xem CPU/IO có khớp không,
   (b) chạy A/B đổi ĐÚNG một biến. Code nặng ≠ code chậm** — 768 candidate dư hoá ra rẻ đến mức
   không đo được.

0b. ⭐ **CPU thấp trong khi latency cao = I/O WAIT, và đó là thông tin cực mạnh để loại trừ.**
   CPU 10–20% không phải nghịch lý cần giải thích — nó **thu hẹp** nghi phạm xuống chỉ còn "đang chờ
   ai đó bên ngoài". Kết hợp với các phép loại trừ đã có (ES <1ms, network client 6ms, payload 270KB)
   thì tập nghi phạm đóng kín lại còn **một**: lời gọi embedding. Một chỉ số monitoring cơ bản làm
   được việc mà cả buổi đọc source không làm được.

0c. **Phép thử A/B phải XEN KẼ, không đo rời.** Với hệ dao động 1.98–28.2s, đo 5 lần cấu hình A rồi
   5 lần cấu hình B ở thời điểm khác ⟹ kết quả bị tải nền chi phối hoàn toàn. Đặt **2 request trong
   CÙNG vòng lặp** (3.11) mới so được từng cặp. Nếu 3.11 đo rời, rất có thể tôi đã kết luận sai
   "topk=256 nhanh hơn 12%" và đi deploy một fix vô nghĩa.

0d. ⭐⭐ **ĐÃ SAI 3 LẦN LIÊN TIẾP, CÙNG MỘT KIỂU SAI.** Ba root cause tôi từng "chốt":
   | # | Giả thuyết | Suy từ đâu | Bị phủ định bởi |
   |---|---|---|---|
   | B | `topk=1024` nặng | source `search.py:142` + 287 ES query | A/B xen kẽ 8 cặp (3.11): 4–4, kết quả y hệt |
   | C | rerank/tokenize CPU-bound | source `search.py:299/434/461` | **CPU chỉ 10–20%** (3.13, Kiên quan sát) |
   | A | embedding xếp hàng sau ingest | log ingest `Embedding chunks 0.59-1.43s` + `EMBEDDING_BATCH_SIZE=16` | **đo trực tiếp: 150ms, biên độ 2×, song song tốt** (3.15) |

   **Mẫu sai giống nhau cả 3 lần:** thấy một đoạn code/log *trông có vẻ* tốn kém ⟹ kết luận nó là
   bottleneck ⟹ xây cả hướng fix lên đó. Mỗi lần đều **hợp lý về mặt cơ chế** nhưng **sai về mặt số**.

   ⟹ **Quy tắc bắt buộc từ giờ trong issue này: KHÔNG kết luận tầng nào là bottleneck trước khi có
   số đo TRỰC TIẾP của chính tầng đó.** Log "mất 1.43s" của ingest không nói gì về latency mà
   retrieval phải chờ — phải tự gọi thẳng vào service đó mà đo (3.15). Một phép đo 30 giây đã phủ
   định thứ tôi mất cả buổi xây lập luận.

1. **Đo tách tầng trước khi tối ưu tầng nào.** Suốt 3 phiên hướng điều tra nhắm vào ES (tokenizer,
   stopword, `minimum_should_match`, scale 1.9M doc). Số đo thật: **ES <1ms/query, chiếm 1.7/3.6s;
   Python chiếm phần còn lại và là phần dao động.** Fix `minimum_should_match` thất bại vì **nhắm sai
   tầng** — không phải vì làm sai.

2. **Đọc sai cột log thành duration.** Tôi đọc `... 200 270774 2290443` là "270,774ms = 270.8 giây".
   **Cái làm lộ ra là sai:** giá trị gần như **bất biến** (270769–270775) trong khi latency đo thật dao
   động 1.98–28.2s. Không metric latency nào đứng yên như vậy. 3.7 chứng minh đó là **response size**.
   ⟹ **Phản xạ cần nhớ: trước khi tin một cột log là duration, kiểm tra nó có BIẾN THIÊN cùng với
   latency đo được từ client hay không.**

3. **RAGFlow không log duration ở access log** (3.5: grep `elapsed|duration|took|latency|seconds` →
   rỗng). Muốn latency phải đo từ **client** (`curl -w`), muốn tách tầng ES phải dùng **counter delta**
   `_nodes/stats` — và **bắt buộc trừ baseline** vì ingest gây nhiễu counter (3.8: 391 → 287 sau khi trừ).

4. **Giả thuyết `metadata_condition` gây N+1: SAI, và sai theo hướng ngược.** Bỏ filter đi thì **CHẬM
   HƠN** (14–19s vs 3.6–10.2s). Filter thu hẹp candidate ⟹ giúp NHANH hơn. Bài học: giả thuyết nào cũng
   phải nêu **dự đoán falsifiable** rồi thử — nếu chỉ suy luận thì hướng này đã thành nhiều giờ đào sai.

5. **`--until-time` không tồn tại trong kubectl trên cụm** (chỉ có `--since-time`/`--since`). Cắt cửa sổ
   log bằng `awk '$0 >= "[ts_dau" && $0 <= "[ts_cuoi~"'` — so sánh chuỗi trùng với so sánh thời gian vì
   timestamp `[YYYY-MM-DD HH:MM:SS` nằm đầu dòng. Ký tự `~` (ASCII 126) làm chặn trên để không sót
   dòng có phần thập phân giây.

6. **Phải đọc source THẬT trong container, không đọc GitHub.** Image là custom build của anh Cường:
   phát hiện có cài **`pyvi`** — thứ không có trong upstream, và chính là cách tokenizer được "fix".
   Cái này không thể biết được nếu chỉ đọc source trên GitHub. (Bài học lặp lại: từng kết luận dựa trên
   v0.24.0 trong khi prod chạy v0.26.4.)

7. **Nhìn vào PID trong log để phân biệt process.** PID `48` = `ragflow_server` (API), PID `445` =
   `task_executor` (ingest). Ban đầu tôi kết luận "cùng 1 worker process xử lý cả hai" vì chỉ thấy PID 48
   trong access log — sai; hai process khác nhau nhưng **cùng pod / cùng CPU limit**, nên vẫn tranh
   tài nguyên. Phân biệt này đổi hướng fix từ "tăng worker" sang "tách deployment".

8. **`ImportError: circular import` khi `kubectl exec python3 -c "import ..."` không phải bug.** Import
   module lẻ ngoài context app thì `settings.py` chưa init xong. Muốn đọc code thì `grep`/`sed` file,
   đừng import.

9. **SSH qua VDI bị `Connection closed` khi lệnh chạy lâu.** Loop curl 5 lần × ~15-19s vượt idle timeout.
   Với lệnh chạy dài nên giảm số vòng lặp, hoặc dùng `nohup ... &` + đọc file kết quả.

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| 🔴 **Bearer token RAGFlow đã bị commit vào file tracking và push lên GitHub (PR #8)** | Session 2026-08-18 | **Token lộ trên remote.** Cần **rotate token** và redact khỏi git history. Đã redact ở các lệnh mới (`<REDACTED>`) nhưng **commit cũ vẫn còn** |
| 🔴 **Mật khẩu ES (`aihub_prod`) xuất hiện trong lệnh 3.6/3.8** | Session 2026-08-18 | Đã redact thành `<REDACTED>` trong file. Kiểm tra lại không lọt vào commit nào |
| `codePatch` initContainer patch `minimum_should_match` vẫn bật trong `values.yaml` | `TRACKING-ragflow-v0.26.4-upgrade.md` mục 6 | Đã verify (3.1) là **no-op vô hại** — code v0.26 có sẵn tham số. Không cần gỡ gấp, nhưng nên dọn để tránh nhiễu về sau. Bài học đã biết: "sed không khớp vẫn exit 0 → patch trượt âm thầm" |
| `investigate_issue_4/scratch/vi_stopwords_TODO.py` tạo sẵn nhưng chưa điền | Session 2026-08-18 | **KHÔNG CẦN NỮA** — ES không phải bottleneck (4.4), và image đã có `pyvi`. Nên xoá hoặc ghi rõ là đã đóng, tránh người sau đi lại hướng cụt |
| Chưa biết cột cuối trong access log (1.9M–4.9M) là gì | 3.5, 3.7 | Không ảnh hưởng kết luận (đã có cách đo latency khác), nhưng đừng suy luận gì từ cột này |
| `use_raptor: true` + `use_graphrag: true` trên KB production 1.9M doc | 3.6 | Mỗi document tốn thêm nhiều lời gọi LLM `qwen3-32b`. Nếu nghiệp vụ không dùng ⟹ đang đốt tài nguyên vô ích |
| Chỉ đo/đọc log **1 trong 3** pod ragflow | 3.4 điểm 4 | Kết luận dựa trên ~30% traffic. Root cause là cấu trúc (chung pod, chung embedding) nên vẫn đúng cho cả 3, nhưng số liệu định lượng thì chưa đầy đủ |

## 7. Việc tiếp theo

> **Không có fix nào sẵn sàng deploy.** Cả 3 root cause từng chốt đều đã bị phủ định. Việc tiếp theo
> là **điều tra**, không phải fix.

### 🔴 Ngay lập tức — chốt giả thuyết connection leak (3.18)
- [ ] ⭐ **PHÉP THỬ QUYẾT ĐỊNH: `rollout restart deployment/ragflow` rồi đo 10 mẫu NGAY.**
      Nhanh hẳn (1-3s) rồi chậm dần ⟹ **root cause chốt**. Vẫn chậm ⟹ leak không phải nguyên nhân chính.
      ⚠️ Báo trước các bên đang cắm API (có downtime ngắn)
- [ ] `ulimit -n` + đếm fd của PID 48 — xác nhận có tiến gần trần file descriptor không
- [ ] Xem **104 CLOSE_WAIT nối tới port nào** (`$4=="08"` rồi đếm `$3`): `2320`=LiteLLM,
      `1F73`=ES, `0CEA`=MySQL ⟹ biết leak ở client nào
- [ ] Theo dõi `CLOSE_WAIT` + tổng socket theo thời gian, xác nhận **tăng đơn điệu**
- [ ] Nếu chốt là leak: tìm chỗ thiếu `close()`/`async with` trong code client tương ứng
      (đọc source trong container, không đọc GitHub)

### Đã có output, chưa phân tích
- [ ] Bisect `vector_similarity_weight` 1.0/0.0/0.6 — **anh Kiên đã chạy nhưng chưa gửi output**
- [ ] `select * from tenant_model;` — kiểm có rerank model được cấu hình không (chưa từng kiểm)

### Ngắn hạn — kiểm các nghi phạm chưa đo (mục 4.5)
- [ ] MySQL: `SHOW PROCESSLIST` khi request chậm / bật slow query log
- [ ] Connection pool: đếm connection trong `/proc/net/tcp`, tìm config pool size ES/MySQL
- [ ] MinIO: có nằm trong đường retrieval không
- [ ] Lấy log/số liệu từ **2 pod còn lại** (`pljxz`, `q9kz2`) — hiện chỉ đo 1/3 pod

### Dài hạn
- [ ] **Thêm instrumentation latency cho tầng retrieval** — cả phiên này phải đo tách tầng thủ công
      vì RAGFlow không log duration. Đây là nợ kỹ thuật gốc làm chậm mọi lần debug
- [ ] **Fix 4 (vẫn đáng làm bất kể root cause):** hỏi nghiệp vụ có thực sự dùng `use_raptor` +
      `use_graphrag`? Nếu không ⟹ tắt, giảm mạnh tải LLM/embedding toàn hệ thống
- [ ] **Fix 1 (kiến trúc, không phải latency):** tách `task_executor` ra deployment riêng — lợi ích
      là cô lập lỗi + scale độc lập, KHÔNG phải cải thiện latency (CPU chỉ 10–20%)
- [ ] Đóng `investigate_issue_4/scratch/vi_stopwords_TODO.py` — hướng stopword đã bị loại trừ

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Giảm `topk` 1024 → 256 làm **giảm recall** (bỏ sót kết quả liên quan) | Cao | So danh sách chunk trả về giữa 2 mức trên nhiều câu hỏi thật TRƯỚC khi áp dụng rộng. Đây là trade-off nghiệp vụ, cần anh Cường quyết |
| Tách `task_executor` gây **xử lý trùng task** nếu Redis Consumer Group cấu hình sai | Cao | Verify consumer group + `XACK` hoạt động đúng trên môi trường test trước; theo dõi có document nào bị index 2 lần |
| KB tiếp tục tăng (1.9M → ?) | Cao | Root cause là **chi phí Python tỷ lệ với `topk`, không tỷ lệ với KB size** (3.9 chứng minh) ⟹ fix có tính bền theo scale. Nhưng vẫn cần đo lại sau mỗi mốc tăng lớn |
| Không có staging, mọi patch test trực tiếp trên môi trường có tải thật | Trung bình | Fix 2 cách 1 không cần deploy (chỉ đổi payload) ⟹ thử trước. Fix 1 cần rollout ⟹ báo trước bên đang cắm API |
| Token/mật khẩu đã lộ trong git history | Cao | Rotate token; xem xét `git filter-repo` hoặc chấp nhận và rotate nếu repo nội bộ |
| Kết luận dựa trên đo ở **1/3 pod** và số mẫu nhỏ (2-4 lần cho một số phép đo) | Trung bình | Root cause đã có bằng chứng **cấu trúc** (source code + log process + ES stats), không chỉ dựa số mẫu. Nhưng số liệu định lượng nên đo lại đầy đủ 30 mẫu sau mỗi fix |
