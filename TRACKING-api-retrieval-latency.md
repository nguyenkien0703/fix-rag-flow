# TRACKING — API Retrieval RAGFlow latency không ổn định

> File sống. Cập nhật liên tục trong lúc fix, không đợi tới cuối phiên.
> Issue liên quan đến branch `fix_api_retrieval` (anh Kiên đang làm việc trực tiếp trên đó).
> Bắt đầu: 2026-08-18.

## 1. Mục tiêu

Anh Cường báo lại issue: API retrieval (search) của RAGFlow **không ổn định** — cùng một
query, lúc trả về **~2s**, lúc **>20s**.

**Đây KHÔNG phải issue mới** — là Issue #4 / Issue 10 đã điều tra trước đó, nhưng bối cảnh
đã thay đổi đáng kể (xem mục 2). File này bám tiếp đúng issue đó ở scale mới.

> ## ✅ ROOT CAUSE ĐÃ CHỐT (2026-08-18) — đọc mục 4 và 4.5
>
> **Bottleneck KHÔNG nằm ở Elasticsearch.** Số đo: ES trung bình **<1ms/query**, chiếm **1.7s
> trong 3.6s**; network chỉ **6ms**. Toàn bộ phần chậm và **toàn bộ phần dao động** nằm ở
> **Python trong `ragflow_server`** (1.9s → 8.4s giữa 2 lần đo cùng query).
>
> Ba nguyên nhân, tất cả ở tầng Python:
> - **A. Embedding query xếp hàng sau ingest** → gây **BẤT ỔN ĐỊNH**. Retrieval phải embed câu hỏi
>   qua `qwen3-8b-embedding`, cùng endpoint mà `task_executor` đang bơm liên tục (≥8 doc/23s,
>   0.59–1.43s mỗi batch), **cùng pod, cùng KB**.
> - **B. `topk=1024` mặc định** (`search.py:142`) → gây **CHẬM CƠ BẢN**. 1024 candidate kéo về
>   Python (đo được **287 ES query/request**) nhưng chỉ trả về **10 chunk** → 99% công bỏ đi.
> - **C. Re-tokenize + rerank 1024 candidate trong Python** (`search.py:299/434/461`), CPU-bound,
>   cùng CPU limit với ingest. Image custom cài **`pyvi`** → tokenizer tốt hơn nhưng nặng CPU hơn.
>
> **Vì sao mọi fix trước thất bại:** `minimum_should_match` giảm số doc ES match — nhưng ES vốn
> không phải bottleneck. **Nhắm sai tầng suốt 3 phiên.**
>
> **Fix dứt điểm (mục 4.5):** Fix 1 tách `task_executor` khỏi pod API (giải quyết bất ổn định) +
> Fix 2 giảm `topk` 1024→256 (giải quyết chậm cơ bản, thử được ngay không cần deploy).

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
| 6 | 🔴 **ROOT CAUSE B — `topk=1024` mặc định.** `search.py:142` `topk = int(req.get("topk", 1024))` → ES trả 1024 candidate về Python mỗi request | Cao | 🔴 **CHỐT (source + 3.8)** — khớp với ~287 ES query/request. 1024 candidate phải qua rerank + re-tokenize + numpy trong Python | Fix 2: giảm `topk` 1024 → 256 (cắt 4× tải Python) |
| 7 | 🔴 **ROOT CAUSE C — Re-tokenize 1024 chunk trong Python mỗi request.** `search.py:299` `rag_tokenizer.tokenize(...)` chạy trên toàn bộ chunk trả về; `:434/:461` `rerank`/`rerank_with_knn` + numpy | Cao | 🔴 **CHỐT (source)** — CPU-bound, chạy TRONG CÙNG process/pod với `task_executor`. Image custom có cài **`pyvi`** (ảnh 3.5) → tokenizer tiếng Việt tốt hơn nhưng **nặng CPU hơn** | Fix 1 (hết tranh CPU) + Fix 2 (giảm số chunk phải tokenize) |
| 8 | Giả thuyết `metadata_condition contains` gây N+1 / filter-in-Python | Cao | ❌ **PHỦ ĐỊNH (3.9)** — bỏ hẳn `metadata_condition` KHÔNG nhanh hơn, còn **chậm hơn** (14.2s/19.2s vs 3.6-10.2s) | Đóng hướng này. Ghi vào Bài học |

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


## 4. Issue chi tiết — ROOT CAUSE ĐÃ CHỐT

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

### 4.1 🔴 ROOT CAUSE A — Embedding query xếp hàng sau luồng ingest (nguyên nhân chính của **BẤT ỔN ĐỊNH**)

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

### 4.2 🔴 ROOT CAUSE B — `topk=1024` mặc định (nguyên nhân chính của **CHẬM CƠ BẢN**)

`search.py:142`: `topk = int(req.get("topk", 1024))` — client không gửi `topk` ⟹ mặc định **1024**.
`search.py:143`: `ps = int(req.get("size", topk))`.
`search.py:199`: `topk` được truyền xuống kNN làm `num_candidates`.

**Hệ quả đo được:** **287 ES query cho 1 request** (3.8, đã trừ baseline) — 1024 candidate phân trên
nhiều shard/node. Rồi **toàn bộ 1024 candidate được kéo về Python** để rerank.

**Trả về chỉ 10 chunk** (3.7: `chunks: 10, total: 10`) — tức **99% công việc bị bỏ đi** sau khi đã trả giá.

### 4.3 🔴 ROOT CAUSE C — Re-tokenize + rerank 1024 candidate trong Python, cùng process với ingest

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

## 4.5 ⭐ HƯỚNG FIX DỨT ĐIỂM

Xếp theo đòn bẩy. Tất cả làm được qua `values.yaml` + `helm upgrade`, **không build image**
(theo ràng buộc `pullPolicy: Never` đã ghi ở `investigate_issue_4/05-FIX.md`).

### FIX 1 — Tách `task_executor` ra khỏi pod API ⭐⭐⭐ (giải quyết BẤT ỔN ĐỊNH, đòn bẩy lớn nhất)

**Vấn đề nó giải:** Root cause A + phần contention của C.

**Hiện tại:** 1 container chạy **3 process** — `ragflow_server.py` (API, PID 48), `task_executor.py`
(ingest, PID 445), `sync_data_source.py`. Chung CPU limit, chung memory, chung embedding endpoint.

**Sau fix:** 2 workload riêng.
- Deployment `ragflow-api`: chỉ `ragflow_server.py`. Nhận traffic NodePort 8999. CPU dành riêng.
- Deployment `ragflow-worker`: chỉ `task_executor.py`. Scale độc lập theo tải ingest.

**An toàn khi tách:** `task_executor` tiêu thụ task qua **Redis Stream Consumer Group** ⟹ nhiều instance
không xử lý trùng task. Đây là cơ chế upstream thiết kế sẵn cho việc scale worker.

**Kỳ vọng:** latency retrieval hết phụ thuộc chu kỳ ingest ⟹ **hết dao động 2s↔28s**. Đây là phần
"không ổn định" mà anh Cường báo.

❓ **Cần verify trước khi làm:** đọc `values.yaml` + entrypoint/`docker-entrypoint.sh` trong image để xác
định cách tách process (biến môi trường bật/tắt component, hoặc override `command`/`args`).

### FIX 2 — Giảm `topk` 1024 → 256 ⭐⭐ (giải quyết CHẬM CƠ BẢN, rẻ nhất, làm được ngay)

**Vấn đề nó giải:** Root cause B + khối lượng của C.

Cắt **4×** số candidate phải: kéo về từ ES, tokenize lại (`:299`), rerank + numpy (`:434/:461`).
Vì chỉ trả về 10 chunk, 256 candidate vẫn thừa dư địa cho rerank chọn top 10.

**Cách 1 — không sửa code, làm được NGAY (khuyến nghị thử trước):** thêm `"topk": 256` vào JSON request.
`search.py:142` đọc `req.get("topk", 1024)` ⟹ client gửi thì override được default.

```
curl -s -o /dev/null -w "topk256 total=%{time_total}\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer <TOKEN>' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"topk":256,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'
```

**Cách 2 — sed đổi default** (nếu bên gọi API không chịu sửa payload), thêm vào `codePatch` initContainer:

```
sed -i 's/req.get("topk", 1024)/req.get("topk", 256)/' /ragflow/rag/nlp/search.py
```

⚠️ **Rủi ro:** giảm `topk` có thể giảm recall (bỏ sót kết quả liên quan nằm ngoài top 256). **Phải verify
chất lượng** — chạy vài câu hỏi thật, so danh sách 10 chunk trả về giữa `topk=1024` và `topk=256`.
Nếu trùng nhau ⟹ an toàn. Đây là **trade-off latency vs recall**, quyết định nghiệp vụ.

### FIX 3 — Tách/scale embedding service ⭐ (dọn phần xếp hàng còn lại sau Fix 1)

**Vấn đề nó giải:** phần còn lại của Root cause A.

Sau Fix 1, retrieval và ingest hết tranh CPU pod, **nhưng vẫn dùng chung** endpoint
`qwen3-8b-embedding`. Hai lựa chọn:
- **3a:** tăng replica embedding service (nếu nó là deployment tự quản trong cụm).
- **3b:** cấu hình **endpoint embedding riêng** cho retrieval vs ingest, để tải ingest không làm nghẽn
  đường của retrieval. (Cần kiểm tra RAGFlow v0.26 có cho tách embedding model theo mục đích không.)

❓ **Cần biết trước:** `qwen3-8b-embedding` đang được serve ở đâu, bởi ai (LiteLLM? vLLM? service riêng?),
có scale được không.

### FIX 4 — Giảm cường độ ingest (đàm phán vận hành, không phải code)

Không phải fix kỹ thuật nhưng là đòn bẩy thật: đề nghị bên đẩy tài liệu **giới hạn concurrency** hoặc
chuyển ingest sang **giờ thấp điểm**. Kể cả sau Fix 1, ingest vẫn tranh embedding/LLM quota.

Cũng nên xem lại: `use_raptor: true` + `use_graphrag: true` khiến mỗi document tốn thêm nhiều lời gọi LLM.
Nếu nghiệp vụ không thực sự dùng RAPTOR/GraphRAG ⟹ tắt đi sẽ giảm mạnh tải toàn hệ thống.

### Thứ tự thực hiện đề xuất

1. **Fix 2 cách 1** (thêm `topk:256` vào 1 request curl) — **0 rủi ro, 0 downtime**, đo ngay được hiệu quả.
   Nếu latency giảm đáng kể ⟹ xác nhận Root cause B bằng thực nghiệm.
2. **Fix 1** — làm chính, giải quyết bất ổn định. Cần downtime ngắn (rollout).
3. Đo lại 30 mẫu như 3.2 sau mỗi fix, so trực tiếp với baseline hiện có
   (min 1.98s / max 28.2s / mean 10.22s / median 9.57s).
4. **Fix 3 / Fix 4** nếu sau 1+2 vẫn còn dao động.

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

### Ngay lập tức (0 rủi ro, đo được ngay)
- [ ] Chạy **Fix 2 cách 1** — thêm `"topk": 256` vào 1 request curl, so latency với baseline 3.6–10.2s
- [ ] Nếu nhanh hơn rõ: chạy 30 mẫu như 3.2 với `topk=256`, so bảng phân bố với baseline
- [ ] Verify recall: so danh sách 10 chunk trả về giữa `topk=1024` và `topk=256` trên 3-5 câu hỏi thật
- [ ] 🔴 **Rotate Bearer token RAGFlow** (đã lộ trên GitHub PR #8)

### Ngắn hạn (fix chính)
- [ ] Đọc `values.yaml` + entrypoint image để xác định cách tách `task_executor` khỏi pod API
- [ ] Triển khai **Fix 1** — 2 deployment `ragflow-api` / `ragflow-worker`
- [ ] Verify Redis Stream Consumer Group hoạt động đúng khi worker tách riêng (không xử lý trùng task)
- [ ] Đo lại 30 mẫu sau Fix 1, đối chiếu **tiêu chí biên độ < 3×** ở mục 4.5
- [ ] Hỏi bên đẩy tài liệu: ingest chạy 24/7 hay theo lịch? Có giới hạn concurrency được không?

### Dài hạn
- [ ] **Fix 3** — xác định `qwen3-8b-embedding` được serve ở đâu, có scale/tách endpoint được không
- [ ] **Fix 4** — đánh giá lại có thực sự cần `use_raptor` + `use_graphrag` trên KB này
- [ ] Thêm instrumentation latency cho tầng retrieval (RAGFlow không log) — để lần sau không phải đo
      tách tầng thủ công như phiên này
- [ ] Đóng `investigate_issue_4/scratch/vi_stopwords_TODO.py`, ghi rõ hướng stopword đã bị loại trừ

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Giảm `topk` 1024 → 256 làm **giảm recall** (bỏ sót kết quả liên quan) | Cao | So danh sách chunk trả về giữa 2 mức trên nhiều câu hỏi thật TRƯỚC khi áp dụng rộng. Đây là trade-off nghiệp vụ, cần anh Cường quyết |
| Tách `task_executor` gây **xử lý trùng task** nếu Redis Consumer Group cấu hình sai | Cao | Verify consumer group + `XACK` hoạt động đúng trên môi trường test trước; theo dõi có document nào bị index 2 lần |
| KB tiếp tục tăng (1.9M → ?) | Cao | Root cause là **chi phí Python tỷ lệ với `topk`, không tỷ lệ với KB size** (3.9 chứng minh) ⟹ fix có tính bền theo scale. Nhưng vẫn cần đo lại sau mỗi mốc tăng lớn |
| Không có staging, mọi patch test trực tiếp trên môi trường có tải thật | Trung bình | Fix 2 cách 1 không cần deploy (chỉ đổi payload) ⟹ thử trước. Fix 1 cần rollout ⟹ báo trước bên đang cắm API |
| Token/mật khẩu đã lộ trong git history | Cao | Rotate token; xem xét `git filter-repo` hoặc chấp nhận và rotate nếu repo nội bộ |
| Kết luận dựa trên đo ở **1/3 pod** và số mẫu nhỏ (2-4 lần cho một số phép đo) | Trung bình | Root cause đã có bằng chứng **cấu trúc** (source code + log process + ES stats), không chỉ dựa số mẫu. Nhưng số liệu định lượng nên đo lại đầy đủ 30 mẫu sau mỗi fix |
