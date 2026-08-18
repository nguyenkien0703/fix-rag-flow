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
| 1 | Query tiếng Việt build ra clause OR chứa hư từ (thiếu stopword) → match rộng ES | Cao | ⚠️ **WORKAROUND KHÔNG ĐỦ** — xem 3.2, workaround v0.26 giảm nhẹ nhưng KHÔNG giữ ổn định ở scale 1.9M (30 mẫu: min 1.98s, max 28.2s, chỉ 37% dưới 5s) | Đã custom image v0.26 (anh Cường). Cần đo tiếp xem còn dư địa cải thiện ở tầng tokenizer/query hay đã hết, chuyển hướng sang Issue 3 |
| 2 | Patch cũ `minimum_should_match` (initContainer, từ Issue #4) có thể THỪA/conflict với code v0.26 upstream đã có sẵn tham số này | Trung bình | ✅ **LOẠI TRỪ** — xem lệnh 3.1, code trong pod khớp đúng gốc v0.26, không bị đè | — |
| 3 | Latency tại scale MỚI (1.9M doc) dao động mạnh 1.98s-28.2s (30 mẫu thật, 3.2) — nghi bottleneck mới (index/shard/HNSW/GC, **hoặc load-balance không đều giữa 3 pod ragflow**) khác root cause cũ | Cao | 🔶 **OPEN**, đang đo | Đối chiếu log 3 pod theo timestamp (lệnh 3.3/3.4) để xác nhận/loại giả thuyết lệch tải |
| 4 | 🔴 **GIẢ THUYẾT MỚI, ĐANG DẪN ĐẦU (Kiên nêu, xác nhận 1 phần qua log 3.3):** retrieval API tranh tài nguyên (worker/CPU/connection ES) với luồng **ingest liên tục** (`/documents`, `/chunks`) từ bên đẩy tài liệu, chạy CÙNG pod, CÙNG 1 worker process | Cao | ❓ **1 bằng chứng, chưa đủ để chốt** — 1 request retrieval log được mất 270.8s đúng lúc ingest traffic dồn dập, nhưng thời điểm đó KHÔNG khớp chính xác với bất kỳ `run=N` nào ở 3.2 | Lệnh 3.4: lấy log đầy đủ đúng khung giờ 3.2, đối chiếu retrieval-chậm với mật độ ingest ngay trước đó |

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
for i in $(seq 1 30); do echo "run=$i time=$(date +%H:%M:%S)"; curl -s -o /dev/null -w "http_code=%{http_code} time_total=%{time_total}s\n" -X POST 'http://10.208.137.54:8999/api/v1/retrieval' -H 'Authorization: Bearer ragflow-2KB-U6NBJYU62kIUtOhRv-kAL-LbhPmXaPbZfPPEaEw' -H 'Content-Type: application/json' -d '{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6,"metadata_condition":{"logic":"and","conditions":[{"name":"listuserview_useridtwo","comparison_operator":"contains","value":"900034475"}]}}'; sleep 1; done
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

### 3.3 Đối chiếu log 3 pod ragflow trong đúng khoảng thời gian đã đo (09:48:34 → 09:53:53) — ⏳ CHỜ OUTPUT

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

### 3.4 Lấy log retrieval ĐẦY ĐỦ đúng khung giờ đã đo ở 3.2 + đếm mật độ ingest cùng lúc — ⏳ CHỜ OUTPUT

**Vì sao cần lệnh này:** 3.3 mới cho 1 dòng log retrieval trích ngẫu nhiên, không nằm đúng khung
giờ loop 3.2 (09:48:34-09:53:53 giờ VN = 10:48:34-10:53:53 theo giờ hiển thị log +0800). Cần lấy
**toàn bộ** dòng `/api/v1/retrieval` VÀ đếm số dòng `/documents`+`/chunks` (ingest) xảy ra ngay
trước mỗi dòng retrieval, để so khớp trực tiếp: request retrieval nào chậm có đúng là lúc ingest
đang dồn dập không.

Chạy trên `vrp-kubeengine04`, dùng khung giờ hiển thị log (+0800, đã verify tương đương giờ VN
loop 3.2 đã chạy):

```
kubectl -n ragflow logs ragflow-57d9856dff-5kgvd -c ragflow --since-time=2026-08-18T10:48:00+08:00 --until-time=2026-08-18T10:54:30+08:00 > /tmp/log_5kgvd_window.txt
```

```
grep "POST /api/v1/retrieval" /tmp/log_5kgvd_window.txt
```

```
grep -c "POST /api/v1" /tmp/log_5kgvd_window.txt
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `--since-time=...T10:48:00+08:00` | Bắt đầu lấy log — dùng giờ HIỂN THỊ trong log (+0800) đã verify tương đương `09:48:00` giờ VN (+0700) lúc `run=1` bắt đầu, trừ lùi 34 giây cho tròn phút |
| `--until-time=...T10:54:30+08:00` | **CỜ MỚI so với lệnh 3.3** — giới hạn điểm KẾT THÚC lấy log (3.3 chỉ có `--since-time`, không chặn trên nên lấy tới hiện tại, log quá dài). `10:54:30` = sau `run=30` (09:53:53 VN = 10:53:53 +0800) khoảng 37 giây, đủ để bắt cả request nào bắt đầu cuối loop nhưng kéo dài thêm |
| `> /tmp/log_5kgvd_window.txt` | Ghi log ra file tạm — vì bước sau cần `grep` 2 LẦN trên CÙNG dữ liệu (đếm dòng retrieval + đếm tổng dòng ingest), ghi file 1 lần tránh gọi lại `kubectl logs` 2 lần (chậm, tốn API server) |
| `grep "POST /api/v1/retrieval"` | Lọc CHỈ dòng retrieval trong file đã lưu — không cần `-E` vì chỉ tìm 1 chuỗi cố định, không cần OR |
| `grep -c "POST /api/v1"` | Đếm (`-c`) SỐ DÒNG khớp — dùng để biết tổng số request (ingest + retrieval) trong khung giờ, đối chiếu mật độ tải chung |

**Kỳ vọng đọc được:** liệt kê được đủ dòng retrieval trong đúng khung giờ loop 3.2 (kỳ vọng ~10
dòng nếu 30 request chia đều 3 pod). So khớp thời gian bắt đầu mỗi dòng retrieval với `run=N` ở
3.2 — nếu request retrieval chậm (>15s) đều rơi vào giai đoạn log có nhiều dòng ingest ngay trước
đó → xác nhận mạnh giả thuyết tranh tài nguyên. Nếu không có tương quan rõ → phải quay lại nghi
ES/tokenizer/scale.

**Output:** _(dán nguyên văn kết quả 2 lệnh grep)_

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
