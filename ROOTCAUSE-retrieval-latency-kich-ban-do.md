# KỊCH BẢN ĐO PHÂN ĐỊNH — truy root cause API retrieval latency

> File thi hành. Đi kèm `TRACKING-api-retrieval-latency.md` (file sống ghi lịch sử).
> File này KHÔNG lặp lại lịch sử — chỉ chứa **các phép đo còn lại**, xếp theo **sức phân định giảm dần**.
> Bắt đầu: 2026-08-18. Ràng buộc phiên: **ingest KHÔNG dừng được** ⟹ mọi phép đo dưới đây
> đã thiết kế để chạy **trong lúc ingest vẫn chạy**.

---

## 0. Quy tắc thi hành (đọc trước khi chạy lệnh đầu tiên)

Rút từ Bài học 0d của file tracking — **đã sai 3 lần cùng một kiểu**:

| # | Quy tắc | Vì sao |
|---|---|---|
| R1 | **Viết dự đoán TRƯỚC khi chạy.** Mỗi phép đo đã có sẵn ô "Nếu A ⟹ …, nếu B ⟹ …" | Đọc kết quả rồi mới giải thích thì kết quả nào cũng "khớp giả thuyết" |
| R2 | **KHÔNG kết luận tầng nào là bottleneck trước khi có số đo TRỰC TIẾP của chính tầng đó** | 3 lần sai đều do suy từ source/log sang latency |
| R3 | **A/B phải XEN KẼ trong cùng vòng lặp**, không đo rời | Nền dao động 23× nuốt trọn mọi so sánh đo rời |
| R4 | **Cỡ mẫu ≥ 20** trước khi kết luận hình dạng phân bố | 10 mẫu từng tạo ảo giác "khoảng trống 5–27s" (3.20 → bị 3.21 phủ định) |
| R5 | **Patch `sed` phải verify bằng `grep` sau khi apply**, không tin exit code | `sed 's/timeout=600/timeout=30/'` đã trượt âm thầm 2 lần |
| R6 | Mọi phép đo ghi kèm **thời điểm** và **tên pod** | Đang chỉ đo 1/3 pod; latency xấu dần theo phiên |
| R7 | **Gán biến từ `kubectl -o jsonpath` xong phải `echo` kiểm tra trước khi dùng** | Xem "Sự cố thi hành" ngay dưới — mảng rỗng gán chuỗi rỗng, lệnh sau chết với thông báo lạc hướng |

### ⚠️ Sự cố thi hành 2026-08-18 13:47 — label selector sai (đã sửa)

Lệnh Đ1 lần đầu **không chạy được**. Nguyên văn:

```
error: error executing jsonpath "{.items[0].metadata.name}": array index out of bounds: index 0, length 0
object given to jsonpath engine was:
   map[string]interface {}{"apiVersion":"v1", "items":[]interface {}{}, "kind":"List", ...}
```
rồi mọi lệnh sau: `error: pod, type/name or --filename must be specified`

**Chẩn đoán:** `"items":[]` + `kind:"List"` = API server **trả lời thành công**, tập kết quả rỗng.
Nếu sai namespace sẽ là `namespaces "x" not found`, thiếu quyền sẽ là `Forbidden`.
⟹ thu hẹp về đúng một khả năng: **label `app=ragflow` không tồn tại**.

**Label THẬT** (`kubectl -n ragflow get pods --show-labels`):

| Pod | Label dùng để lọc |
|---|---|
| `ragflow-b68585df9-2dhbz` / `-45ffm` / `-brm7m` | `app.kubernetes.io/component=ragflow` |
| `ragflow-mysql-0` | `app.kubernetes.io/component=mysql` |
| `ragflow-minio-0` | `app.kubernetes.io/component=minio` |
| `ragflow-redis-0` | `app.kubernetes.io/component=redis` |

Chart Helm `ragflow-0.1.1` dùng label chuẩn `app.kubernetes.io/*`, **không** dùng `app=`.
⟹ Đã sửa toàn bộ lệnh trong file này sang `-l app.kubernetes.io/component=ragflow`.

**Bài học (cùng họ với "sed trượt âm thầm"):** `-o jsonpath` trên mảng rỗng **không** làm lệnh gán
thất bại — nó gán chuỗi rỗng, rồi để lệnh SAU chết với thông báo hoàn toàn khác
("pod must be specified"), làm lạc hướng chẩn đoán sang quyền/namespace.
Dòng `echo "POD=$POD"` trong kịch bản đã làm đúng việc của nó: phơi ra `POD=` rỗng.

### 📌 Trạng thái cụm lúc bắt đầu đo (2026-08-18 ~13:50)

**3 pod ragflow đều `AGE 9m49s` — vừa restart xong.** Đây là cơ hội không tính trước:

- Phép thử **Đ7** (restart rồi đo) trở thành **miễn phí, không cần downtime** — cụm đã ở trạng thái sạch.
- ⟹ **Đổi thứ tự ưu tiên:** chạy Đ1 **và** Đ2 trong cùng cửa sổ này, trước khi pod kịp "già".
- Cách đọc kết quả Đ2 trong bối cảnh pod mới 10 phút tuổi:

| Kết quả Đ2 trên pod vừa restart | Suy ra |
|---|---|
| Vẫn dao động 2→40s | ❌ Loại giả thuyết "tích tụ theo uptime" ⟹ nghẽn mang tính **CẤU TRÚC**, có ngay từ lúc khởi động |
| Nhanh & ổn định (biên độ <3×) | Có mốc "trạng thái sạch" để so lại sau vài giờ ⟹ xác nhận yếu tố tích tụ |

### Ba dữ kiện ràng buộc mọi giả thuyết mới

Giả thuyết nào cũng phải giải thích **đồng thời** cả ba, nếu không thì loại luôn không cần đo:

| # | Dữ kiện | Nguồn |
|---|---|---|
| D1 | **CPU pod chỉ 10–20%** khi latency 48s | 3.13 |
| D2 | **Mọi đích I/O đo riêng đều nhanh & ổn định**: ES <1ms/query, embedding 150ms (biên độ 2×), LLM 1.25s (biên độ 1.02×) | 3.6, 3.15, 3.17 |
| D3 | **Phân bố LIÊN TỤC** 2.07→48.41s (không lưỡng cực, không mốc cố định) | 3.21, 25 mẫu |

**Suy ra (logic, chưa phải kết luận):** D1 loại "tính toán nặng". D2 loại "backend chậm".
D3 loại "timeout/retry cố định". Còn lại đúng một lớp: **một điểm nghẽn TUẦN TỰ bên trong process
Python, nơi thời gian chờ tỉ lệ liên tục với độ dài hàng đợi tại thời điểm đó.**

---

## 1. Phát hiện mới từ source (chưa có trong file tracking)

Đọc `common/misc_utils.py` (bản v0.24.0 local — ⚠️ **phải verify lại trong container v0.26.4**, xem Đ1):

```python
@once
def _thread_pool_executor():
    max_workers_env = os.getenv("THREAD_POOL_MAX_WORKERS", "128")
    ...
    return ThreadPoolExecutor(max_workers=max_workers)

async def thread_pool_exec(func, *args, **kwargs):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_thread_pool_executor(), func, *args)
```

**Đọc được gì — điều này ĐỔI thứ tự nghi phạm:**

1. Pool mặc định **128 worker**, không phải pool nhỏ. Muốn chờ 46s ở pool 128 thì phải có
   **hàng nghìn** tác vụ pending. ⟹ giả thuyết *"thread pool `max_workers` nhỏ"* (nghi phạm số 1
   cũ của file tracking) **yếu đi đáng kể** — trừ khi env prod set thấp (Đ1 kiểm).
2. Nhưng `ThreadPoolExecutor(128)` trong CPython ⟹ **128 thread tranh GIL**. Retrieval khi đó
   không chờ *slot pool*, nó chờ **GIL**.
3. `@once` ⟹ executor là **singleton toàn process**. Mọi thứ gọi qua `thread_pool_exec` — retrieval
   VÀ các API ingest chạy cùng process — **dùng chung đúng một pool**.

**Vì sao "tranh GIL" khớp cả D1/D2/D3** (giả thuyết, không phải kết luận):

| Dữ kiện | Tranh GIL giải thích thế nào |
|---|---|
| D1 — CPU 10–20% | Phần lớn 128 thread đang I/O wait (đã nhả GIL); tại một thời điểm chỉ **một** thread chạy bytecode ⟹ CPU tổng không thể cao dù hàng đợi dài |
| D2 — backend đều nhanh | Backend chỉ được gọi **sau khi** thread giành được GIL; bản thân lời gọi vẫn nhanh |
| D3 — phân bố liên tục | Thời gian chờ GIL tỉ lệ **liên tục** với số thread đang tranh ⟹ không có mốc cố định |
| Xấu dần theo phiên (28→33→48s) | Tải ingest tích tụ ⟹ số thread tranh tăng dần |
| `connect=1ms` | Nghẽn ở tầng ứng dụng, không ở TCP |

⚠️ **Vẫn chỉ là giả thuyết.** Theo R2, không xây fix lên nó trước khi Đ2/Đ3 cho số đo.

---

## 2. Bảng phép đo — xếp theo SỨC PHÂN ĐỊNH giảm dần

| Mã | Phép đo | Phân định được gì | Rủi ro | Cần dừng ingest? |
|---|---|---|---|---|
| **Đ1** | Đọc source + env THẬT trong container v0.26.4 | Xác nhận/bác bỏ số 128; tìm mọi điểm nghẽn tuần tự | Không | Không |
| **Đ2** | ⭐ **Đo 1 vs N request song song** | **Phân định dứt điểm: nghẽn TUẦN TỰ hay không.** Mạnh nhất còn lại | Thấp | Không |
| **Đ3** | ⭐ Bật `LOG_LEVEL=DEBUG` lấy timing nội bộ | Chỉ đúng **đoạn code** tiêu thời gian — hết đoán | Thấp (đổi env, cần rollout) | Không |
| **Đ4** | Đo latency **theo cường độ ingest** (tương quan) | Thay thế phép thử "ingest nghỉ" mà không cần đàm phán | Không | Không |
| **Đ5** | Bisect `vector_similarity_weight` (đã chạy, thiếu output) | Nghẽn ở nhánh vector / full-text / dùng chung | Không | Không |
| **Đ6** | MySQL `SHOW PROCESSLIST` lúc request chậm | Đích I/O DUY NHẤT chưa từng đo | Không | Không |
| **Đ7** | Phép thử restart LÀM LẠI CHO ĐÚNG | Xác nhận yếu tố tích tụ theo uptime | **Có downtime ngắn** | Không |

> **Thứ tự chạy đề nghị: Đ1 → Đ2 → Đ3.** Ba cái này gần như chắc chắn khoanh được vùng.
> Đ4–Đ7 chỉ chạy nếu Đ2/Đ3 chưa dứt điểm.

---

## Đ1 — Đọc source + env THẬT trong container v0.26.4

**Mục đích:** file tracking đã có bài học *"phải đọc source THẬT trong container, không đọc GitHub"*
(image custom của anh Cường, có `pyvi` không có trong upstream). Số `128` ở trên đọc từ v0.24.0
local ⟹ **chưa chắc đúng với prod**.

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| `THREAD_POOL_MAX_WORKERS` **không set** hoặc = 128 | Pool rộng ⟹ **loại** giả thuyết "pool nhỏ"; dồn nghi ngờ sang **GIL / event loop** |
| Set **thấp** (≤ 16) | 🔴 Pool nhỏ thành nghi phạm số 1 trở lại ⟹ Đ2 sẽ thấy nghẽn đúng ở ngưỡng đó |
| Không có `thread_pool_exec` trong v0.26.4 | Cấu trúc khác hẳn ⟹ đọc lại đường đi request từ đầu |

**Lệnh:**

```bash
POD=$(kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}')
echo "POD=$POD  TS=$(date '+%F %T')"

echo "=== 1. env lien quan concurrency ==="
kubectl -n ragflow exec "$POD" -c ragflow -- env | grep -iE "thread|worker|pool|concurren|max_|batch" || echo "(rong)"

echo "=== 2. dinh nghia thread pool THAT ==="
kubectl -n ragflow exec "$POD" -c ragflow -- sh -c \
  'grep -rn -A12 "def _thread_pool_executor" /ragflow/common/misc_utils.py 2>/dev/null || grep -rn "ThreadPoolExecutor" /ragflow/common/ /ragflow/api/ 2>/dev/null | head -20'

echo "=== 3. moi diem nghen tuan tu tiem tang ==="
kubectl -n ragflow exec "$POD" -c ragflow -- sh -c \
  'grep -rn -E "Semaphore|Lock\(|max_workers|ThreadPoolExecutor|limiter" /ragflow/api/ /ragflow/rag/ /ragflow/common/ 2>/dev/null | grep -v test | head -30'

echo "=== 4. server chay bang gi (1 process hay nhieu worker) ==="
kubectl -n ragflow exec "$POD" -c ragflow -- sh -c \
  'grep -rn -E "app.run|hypercorn|gunicorn|uvicorn|workers" /ragflow/api/ragflow_server.py 2>/dev/null | head -10; echo "--- process dang chay ---"; ps -eo pid,pcpu,nlwp,args 2>/dev/null | head -15'
```

<details>
<summary><b>Giải nghĩa từng cờ</b> (liệt kê cả cờ đã biết để đối chiếu)</summary>

```
kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}'
│ ├─ -n ragflow        namespace chứa deployment
│ ├─ -l app.kubernetes.io/component=ragflow    label selector, lọc đúng pod ragflow (bỏ pod khác trong ns)
│ └─ -o jsonpath=...   in ĐÚNG tên pod đầu tiên, không kèm header
│                      → gán vào biến, tránh gõ tay tên pod đổi sau mỗi rollout

kubectl exec "$POD" -c ragflow -- <cmd>
│ ├─ -c ragflow        chỉ định container (1 container/pod nhưng ghi rõ cho chắc)
│ └─ --                dấu ngăn: mọi thứ sau đây là lệnh chạy TRONG container,
│                      không phải cờ của kubectl

grep -rn -E "..." <dir>
│ ├─ -r                đệ quy xuống thư mục con
│ ├─ -n                in SỐ DÒNG — bắt buộc, để trích dẫn file:line về sau
│ ├─ -E                regex mở rộng, cho phép dùng | làm "hoặc"
│ └─ -A12              in thêm 12 dòng SAU dòng khớp (After) — để thấy trọn thân hàm

grep -iE "thread|worker|..."
│ └─ -i                không phân biệt hoa thường (env có thể Thread_Pool / THREAD_POOL)

grep -v test          -v = đảo ngược, LOẠI dòng chứa "test"
                      → file test đầy ThreadPoolExecutor(max_workers=5) gây nhiễu

ps -eo pid,pcpu,nlwp,args
│ ├─ -e                mọi process (không chỉ của shell hiện tại)
│ ├─ -o                tự chọn cột thay vì layout mặc định
│ └─ nlwp              ⭐ SỐ THREAD của process ("number of light-weight processes")
│                      → cột QUAN TRỌNG NHẤT: nếu PID 48 có hàng trăm thread
│                        thì giả thuyết tranh GIL có cơ sở định lượng

|| echo "(rong)"       grep không khớp thì exit 1; chuỗi này làm output nói rõ
                       "đã chạy, không có kết quả" thay vì im lặng
2>/dev/null            nuốt stderr (file không tồn tại) để output sạch
```
</details>

**Output — ✅ ĐÃ CHẠY 2026-08-18 13:50:55, pod `ragflow-b68585df9-2dhbz`:**

```
=== 1. env concurrency ===
EMBEDDING_BATCH_SIZE=16
   (KHONG co THREAD_POOL_MAX_WORKERS)

=== 2. thread pool THAT ===  /ragflow/common/misc_utils.py
245:def _thread_pool_executor():
246-    max_workers_env = os.getenv("THREAD_POOL_MAX_WORKERS", "128")
247-    try:
248-        max_workers = int(max_workers_env)
249-    except ValueError:
250-        max_workers = 128
251-    if max_workers < 1:
252-        max_workers = 1
253-    return ThreadPoolExecutor(max_workers=max_workers)
256-async def thread_pool_exec(func, *args, **kwargs):
257-    # loop.run_in_executor() submits the callable without propagating the caller's

=== 3. diem nghen tuan tu ===
/ragflow/api/db/services/file_service.py:22:  from concurrent.futures import ThreadPoolExecutor
/ragflow/api/db/services/file_service.py:625:   with ThreadPoolExecutor(max_workers=12) as exe:
/ragflow/api/db/services/file_service.py:844:   with ThreadPoolExecutor(max_workers=5) as exe:
/ragflow/api/db/db_models.py:622: class DatabaseLock(Enum):
/ragflow/api/ragflow_server.py:57: redis_lock = RedisDistributedLock("update_progress", lock_value=lock_value, timeout=60)
/ragflow/api/apps/services/canvas_replica_service.py:199: lock = RedisDistributedLock(
/ragflow/api/channels/wecom/channel.py:153/165/514: asyncio.Lock()
/ragflow/api/channels/whatsapp/*: asyncio.Lock()
/ragflow/api/utils/file_utils.py:43: sys.modules[LOCK_KEY_pdfplumber] = threading.Lock()

=== 4. process + so thread ===
/ragflow/api/ragflow_server.py:165:
    app.run(host=settings.HOST_IP, port=settings.HOST_PORT, use_reloader=RuntimeConfig.DEBUG, debug=False)

--- ps ---
PID %CPU NLWP COMMAND
  1   0.0    1 bash ./entrypoint.sh --enable-adminserver
 23   0.0    1 bash ./entrypoint.sh --enable-adminserver
 25   5.8   10 python3 admin/server/admin_server.py
 26   0.0    1 nginx: master process /usr/sbin/nginx
 27-34 0.0   1 nginx: worker process  (×8)
 35   0.0    1 bash ./entrypoint.sh --enable-adminserver
 36   0.0    1 bash ./entrypoint.sh --enable-adminserver
```

**Đọc được gì:**

1. ✅ **Xác nhận: `THREAD_POOL_MAX_WORKERS` KHÔNG được set trong env** ⟹ dùng mặc định **128**.
   Code trong container v0.26.4 **khớp y hệt** bản v0.24.0 local đã đọc (mục 1).
   ⟹ Theo bảng dự đoán Đ1: **pool rộng ⟹ loại giả thuyết "pool nhỏ"**. Đ2 sau đó xác nhận lại.
2. **Các `Lock` tìm thấy đều KHÔNG nằm trên đường retrieval:** `wecom`/`whatsapp` là channel chat
   (không dùng), `RedisDistributedLock("update_progress")` thuộc luồng **ingest**,
   `threading.Lock()` cho `pdfplumber` thuộc luồng **parse tài liệu**,
   `ThreadPoolExecutor(max_workers=12/5)` trong `file_service.py` thuộc luồng **file/upload**.
   ⟹ Không có lock/pool riêng nào chặn đường retrieval.
3. `app.run(...)` — server chạy **Quart dev server, một process**, đúng như đã biết.
4. 🔴 **BẤT THƯỜNG CẦN LÀM RÕ: `ps | head -15` KHÔNG thấy `ragflow_server.py` lẫn `task_executor`.**
   Chỉ thấy `admin_server.py` (PID 25, NLWP=10) + 8 nginx worker + vài `entrypoint.sh`.
   PID **48** (`ragflow_server`) và PID **445** (`task_executor`) — hai process được nhắc suốt các
   phiên trước — **không xuất hiện**. Nguyên nhân có thể: `head -15` cắt mất, hoặc pod vừa restart
   nên PID khác. ⟹ **Phải chạy lại `ps` không cắt** (xem Đ8).

---

## Đ2 — ⭐ PHÉP THỬ MẠNH NHẤT: 1 request vs N request song song

**Phép đo phân định quan trọng nhất còn lại**, và **không cần dừng ingest** — thay thế được phép
thử "đo lúc ingest nghỉ" mà file tracking đang bị chặn bởi vận hành.

**Ý tưởng:** nếu có điểm nghẽn **tuần tự** trong process (GIL, pool nhỏ, event loop bị block, lock),
thì N request gửi **cùng lúc** sẽ **không** chạy song song — chúng nối đuôi. Dấu hiệu định lượng:
thời gian request **cuối cùng** ≈ N × thời gian một request đơn lẻ.
Nếu KHÔNG có nghẽn tuần tự, cả N cùng về gần như một lúc.

**Đây chính là kỹ thuật đã dùng để phủ định giả thuyết embedding ở 3.15**
(*"5 request song song về cùng lúc ⟹ không có hàng đợi FIFO"*) — giờ áp dụng vào **chính RAGFlow**
thay vì vào backend.

**Dự đoán viết TRƯỚC (R1) — bảng quyết định, đọc kết quả theo đúng nó:**

| Kết quả | Suy ra | Bước tiếp |
|---|---|---|
| **5 request song song về gần cùng lúc**, tổng ≈ thời gian 1 request | ❌ **KHÔNG có nghẽn tuần tự** ⟹ loại GIL, loại pool, loại event loop block. Vấn đề nằm ở **thứ mỗi request tự chờ** | Đ3 + Đ6 |
| **Nối đuôi rõ**: t₁≈2s, t₂≈4s, t₃≈6s, t₄≈8s, t₅≈10s | 🔴 **CHỐT: nghẽn tuần tự, mức song song ≈ 1** ⟹ event loop bị block bởi lời gọi sync, hoặc lock toàn cục | Đ3 để chỉ đúng dòng code |
| Nhóm theo bậc (vd 4 cái về cùng lúc, cái thứ 5 chờ) | 🔴 **Pool/semaphore có kích thước = số cái về cùng lúc** | Đối chiếu số đó với Đ1 |
| Song song tốt NHƯNG mỗi cái đều chậm 20–40s | Nghẽn **không** tuần tự, mà là thứ mọi request đều phải chờ như nhau | Đ3 + Đ6 |

**Lệnh:**

```bash
TOKEN='<REDACTED — dien token>'
URL='http://10.208.137.54:8999/api/v1/retrieval'
BODY='{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6}'

echo "=== A. BASELINE: 3 request TUAN TU (do nen tai thoi diem nay) ==="
date '+%F %T'
for i in 1 2 3; do
  curl -s -o /dev/null -w "tuan_tu run=$i total=%{time_total}\n" \
    -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY"
done

echo "=== B. 5 request SONG SONG (cung thoi diem ban) ==="
date '+%F %T'
START=$(date +%s.%N)
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "song_song run=$i total=%{time_total}\n" \
    -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY" &
done
wait
END=$(date +%s.%N)
echo "TONG_WALL_CLOCK=$(echo "$END - $START" | bc)"
```

<details>
<summary><b>Giải nghĩa từng cờ + vì sao bắt buộc có phần A</b></summary>

```
curl -s -o /dev/null -w "...\n"
│ ├─ -s                silent: tắt thanh tiến trình, không lẫn vào output
│ ├─ -o /dev/null      VỨT BỎ response body (270KB) — chỉ cần thời gian;
│ │                    giữ body sẽ nhiễu phép đo bằng chi phí ghi ra terminal
│ └─ -w "..."          write-out: in ĐÚNG biến thời gian curl đo được
│                      %{time_total} = tổng từ lúc bắt đầu tới khi xong

-X POST                phương thức HTTP (mặc định curl là GET)
-H 'Content-Type: ...' báo server body là JSON, thiếu thì API trả 400/415
-d "$BODY"             dữ liệu gửi kèm. NHÁY KÉP để $BODY được khai triển
                       (nháy đơn sẽ gửi nguyên chữ "$BODY")

&                      ⭐ HẠT NHÂN CỦA PHÉP THỬ: đẩy curl chạy NỀN
                       → 5 curl bắn ra gần như cùng thời điểm thay vì đợi nhau.
                         Đây là cách tạo "5 request song song".
wait                   chặn shell tới khi MỌI job nền kết thúc
                       → thiếu wait thì script thoát trước, mất output

date +%s.%N            giây từ epoch + nano giây
│ └─ để tính TONG_WALL_CLOCK = thời gian thực của CẢ CHÙM 5 request
bc                     máy tính dấu phẩy động (shell không tự trừ số thập phân)
```

**Vì sao bắt buộc có phần A (baseline tuần tự) — quy tắc R3:**
Nền dao động 23× (2.07→48.41s). Nếu chỉ chạy B rồi thấy "5 cái đều 20s", **không kết luận được gì**
— có thể lúc đó nền đang chậm sẵn. Phải có A ngay sát B để biết **1 request đơn lẻ tại đúng thời
điểm đó** mất bao lâu, rồi mới so được.

**Chỉ số cần tính khi đọc kết quả:**
```
Muc song song thuc te ≈ (5 × median cua A) / TONG_WALL_CLOCK
```
- ≈ **5** ⟹ song song hoàn hảo, KHÔNG có nghẽn tuần tự.
- ≈ **1** ⟹ 🔴 hoàn toàn nối đuôi — chốt nghẽn tuần tự.
- ≈ **2–3** ⟹ nghẽn một phần, đối chiếu con số với Đ1.
</details>

**Output — ✅ ĐÃ CHẠY 2026-08-18 13:52–13:53, pod `ragflow-b68585df9-2dhbz` (AGE ~13 phút):**

```
=== A. 3 request TUAN TU ===   2026-08-18 13:52:43
tuan_tu run=1 total=23.810
tuan_tu run=2 total=10.377
tuan_tu run=3 total=13.016

=== B. 5 request SONG SONG === 2026-08-18 13:53:30
song_song run=4 total=6.173
song_song run=2 total=7.870
song_song run=5 total=7.872
song_song run=1 total=11.217
song_song run=3 total=11.218
TONG_WALL_CLOCK=11.251661563
```

### 🔴🔴 KẾT LUẬN Đ2 — KHÔNG CÓ NGHẼN TUẦN TỰ. Loại 3 nghi phạm hàng đầu cùng lúc.

**Tính theo đúng công thức đã định TRƯỚC:**

```
median cua A = 13.016s
Muc song song thuc te = (5 × 13.016) / 11.2517 = 5.78
```

| Dự đoán viết trước | Ngưỡng | Thực tế | Khớp? |
|---|---|---|---|
| Song song hoàn hảo | ≈ 5 | **5.78** | ✅ **ĐÂY** |
| Nối đuôi hoàn toàn | ≈ 1 | | ❌ |
| Nghẽn một phần | 2–3 | | ❌ |

**Đọc được gì:**

1. ❌ **LOẠI: tranh GIL** (nghi phạm #1) · ❌ **LOẠI: event loop bị block** (#2) ·
   ❌ **LOẠI: thread pool nhỏ** (#3). Cả ba đều dự báo request nối đuôi.
   Nếu nghẽn tuần tự thì request cuối phải ≈ 5 × 13s ≈ **65s**; thực tế cả chùm xong trong **11.25s**.
2. ⭐ **DỮ KIỆN ĐẮT NHẤT: request trong chùm SONG SONG lại NHANH HƠN khi chạy một mình.**
   - Tuần tự (1 request/lần): 10.377 – 23.810s
   - Song song (5 request/lần): **6.173 – 11.218s**
   ⟹ **Tăng tải 5× mà latency GIẢM.** Mọi giả thuyết tranh chấp tài nguyên đều dự báo ngược lại
   (thêm tải ⟹ chậm hơn). ⟹ **Độ chậm KHÔNG đến từ tải, cũng không đến từ tranh chấp.**
3. ⚠️ **GIẢ THUYẾT "TRANH GIL" CỦA TÔI Ở LƯỢT TRƯỚC LÀ SAI** — và sai đúng kiểu Bài học 0d:
   suy từ cấu trúc code (`ThreadPoolExecutor(128)` + `@once` singleton) sang latency mà chưa đo.
   **Đây là lần thứ 4 của mẫu sai này.** Ghi lại để không tái phạm.
4. 🔴 **Pod mới ~13 phút tuổi vẫn chậm 23.8s** ⟹ ❌ **LOẠI luôn giả thuyết "tích tụ theo uptime"**
   (Đ7 coi như đã trả lời). Nghẽn mang tính **CẤU TRÚC**, có ngay từ lúc khởi động.
5. ⟹ **Không gian nghi phạm còn lại thu hẹp mạnh:** thứ gây chậm phải là cái mà **mỗi request tự
   chờ một cách độc lập**, không xếp hàng với nhau, không tranh nhau — và **rẻ hơn khi làm hàng loạt**
   (điểm 2 gợi ý có **cache/kết nối được hâm nóng** khi request đi liền nhau).

---

## Đ3 — ⭐ Bật `LOG_LEVEL=DEBUG` lấy timing nội bộ

**Mục đích:** hết đoán dòng nào chậm. Code **đã có sẵn** instrument, chỉ chưa bật —
`search.py:590` `logging.debug(f"[Search] global_offset=... rerank_limit=... page_size=...")`
và `search.py:606` `"[Search] retrieval weights: trace_id=%s ..."`.

Đây cũng là cách gỡ rào cản *"không profile được trong container"* (py-spy không cài được vì image
tối giản, không có network ra ngoài) — **không cần cài gì thêm**.

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| Log DEBUG hiện, có `trace_id` + mốc thời gian giữa các giai đoạn | 🎯 Đọc trực tiếp giai đoạn nào nuốt 40s ⟹ **kết thúc giai đoạn đoán** |
| Log hiện nhưng **không có mốc thời gian** giữa các bước | Chỉ biết tới bước nào, không biết mất bao lâu ⟹ cần chèn timing hoặc quay lại Đ2/Đ6 |
| Bật không lên (không đọc env này) | Tìm tên biến đúng trong `common/log_utils.py` hoặc `settings.py` |

**Bước 1 — tìm ĐÚNG tên biến điều khiển log level (đừng đoán):**

```bash
POD=$(kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}')
kubectl -n ragflow exec "$POD" -c ragflow -- sh -c \
  'grep -rn -E "LOG_LEVEL|setLevel|basicConfig|DEBUG" /ragflow/common/log_utils.py /ragflow/api/settings.py /ragflow/common/settings.py 2>/dev/null | head -20'
```

**Bước 2 — bật (sau khi Bước 1 xác nhận tên biến):**

```bash
kubectl -n ragflow set env deployment/ragflow LOG_LEVEL=DEBUG
kubectl -n ragflow rollout status deployment/ragflow --timeout=300s
```

> ⚠️ **R5 + bài học 3.20:** phải để `rollout status` chạy **xong hẳn (3/3 replicas)**.
> Lần trước bấm `^C` giữa chừng ⟹ đo nhầm trên pod cũ, cả phép thử thành vô nghĩa.

**Bước 3 — bắn 1 request rồi lấy log đúng cửa sổ đó:**

```bash
POD=$(kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}')
kubectl -n ragflow logs "$POD" -c ragflow -f --tail=0 > /tmp/dbg.log 2>&1 &
LOGPID=$!
sleep 2
curl -s -o /dev/null -w "total=%{time_total}\n" -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY"
sleep 3
kill $LOGPID
grep -E "\[Search\]|trace_id" /tmp/dbg.log | head -40
```

<details>
<summary><b>Giải nghĩa từng cờ</b></summary>

```
kubectl set env deployment/ragflow LOG_LEVEL=DEBUG
│ └─ sửa env TRÊN DEPLOYMENT ⟹ tự kích hoạt rollout tạo pod mới.
│    Khác với "exec ... export" (chỉ đổi trong shell, process Python không thấy)

kubectl rollout status deployment/ragflow --timeout=300s
│ ├─ rollout status    CHẶN cho tới khi mọi replica mới sẵn sàng
│ └─ --timeout=300s    tự bỏ cuộc sau 5 phút thay vì treo vô hạn
│                      → dùng cái này thay cho ngồi nhìn rồi bấm ^C

kubectl logs "$POD" -c ragflow -f --tail=0
│ ├─ -f                follow — bám theo log mới, như tail -f
│ └─ --tail=0          ⭐ KHÔNG in log CŨ, chỉ lấy từ thời điểm này trở đi
│                      → không có cờ này sẽ ngập log lịch sử, không tìm ra
│                        dòng thuộc về request vừa bắn

> /tmp/dbg.log 2>&1 &  ghi cả stdout lẫn stderr ra file, chạy nền
LOGPID=$!              $! = PID của job nền vừa tạo → để kill chính xác nó
sleep 2                cho log follower kịp bám trước khi bắn request
                       (thiếu bước này rất dễ mất đúng mấy dòng đầu)
kill $LOGPID           dừng follower, nếu không nó chạy mãi

grep -E "\[Search\]|trace_id"
│ └─ \[ \]             ngoặc vuông là ký tự đặc biệt của regex,
│                      phải escape bằng \ để tìm ĐÚNG chuỗi "[Search]"
```

**⚠️ Rủi ro cần biết trước khi bật:** `LOG_LEVEL=DEBUG` trên hệ đang ingest 1.9M doc sẽ sinh **rất
nhiều** log. Kế hoạch: bật → đo → **tắt ngay** (`kubectl set env deployment/ragflow LOG_LEVEL-`,
dấu `-` ở cuối nghĩa là *xoá biến*). Đừng để qua đêm — rủi ro đầy đĩa.
</details>

**Output:**

```
⏳ CHỜ OUTPUT
```

---

## Đ4 — Đo latency theo CƯỜNG ĐỘ INGEST (thay cho phép thử "ingest nghỉ")

**Mục đích:** file tracking coi *"đo 10 mẫu khi ingest nghỉ"* là phép thử một biến mạnh nhất còn lại,
nhưng nó **bị chặn bởi vận hành**. Phép đo này lấy **cùng thông tin** bằng cách khai thác **dao động
tự nhiên** của cường độ ingest: thay vì bật/tắt, ta **đo song song** latency retrieval và cường độ
ingest rồi xét **tương quan**.

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| Mẫu chậm rơi đúng lúc cường độ ingest **cao**; mẫu nhanh lúc ingest **thấp** | 🔴 **Contention với ingest được xác nhận** — không cần đàm phán dừng ingest nữa |
| Latency dao động **độc lập** với cường độ ingest | ❌ Ingest vô can ⟹ vấn đề nội tại của retrieval ⟹ đóng luôn hướng "tranh tài nguyên với ingest" (Issue 4) |

**Lệnh** (20 mẫu — R4 — kèm đếm dòng log ingest trong 10s ngay trước mỗi mẫu):

```bash
POD=$(kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 20); do
  N=$(kubectl -n ragflow logs "$POD" -c ragflow --since=10s 2>/dev/null | grep -c "Embedding chunks")
  T=$(curl -s -o /dev/null -w "%{time_total}" -X POST "$URL" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")
  echo "run=$i ingest_10s=$N latency=$T at=$(date '+%T')"
done
```

<details>
<summary><b>Giải nghĩa từng cờ</b></summary>

```
kubectl logs --since=10s
│ └─ chỉ lấy log của 10 GIÂY gần nhất
│    → dùng làm "đồng hồ đo cường độ ingest tức thời"
│    (bài học 5 file tracking: KHÔNG có --until-time trên cụm này,
│     chỉ có --since / --since-time)

grep -c "Embedding chunks"
│ └─ -c = ĐẾM số dòng khớp, không in nội dung
│    → mỗi dòng "Embedding chunks" = một batch ingest vừa xử lý xong
│      ⟹ N càng lớn = ingest càng đang bơm mạnh

$(seq 1 20)            sinh dãy 1..20 → 20 mẫu (R4: ≥20 mới nói về phân bố)
$( ... )               command substitution: lấy OUTPUT của lệnh làm giá trị biến
date '+%T'             chỉ giờ:phút:giây — để đối chiếu ngược với log sau này (R6)
```

**Cách đọc:** xếp 20 dòng theo `latency` tăng dần, nhìn cột `ingest_10s`.
Cột đó cũng tăng theo ⟹ tương quan dương ⟹ contention thật.
Nhảy loạn ⟹ ingest vô can. (Đúng kiểu lập luận đã dùng ở 3.20 để **phủ định** connection leak:
`cw` tăng đơn điệu trong khi latency nhảy loạn ⟹ không tương quan ⟹ loại.)
</details>

**Output:**

```
⏳ CHỜ OUTPUT
```

---

## Đ5 — Bisect `vector_similarity_weight` (đã chạy, CHƯA GỬI OUTPUT)

File tracking mục 7 ghi: *"anh Kiên đã chạy nhưng chưa gửi output"*. **Chỉ cần dán output cũ vào đây**,
không phải chạy lại. Lệnh đầy đủ ở `TRACKING-api-retrieval-latency.md` mục 4.5 "Cách 2".

| Biến thể | Nghĩa | Nếu nhanh ⟹ suy ra |
|---|---|---|
| `vector_similarity_weight: 1.0` | chỉ kNN/vector | chi phí nằm ở luồng full-text |
| `vector_similarity_weight: 0.0` | chỉ full-text/BM25 | chi phí nằm ở luồng vector/kNN |
| `vector_similarity_weight: 0.6` | cả hai (mặc định) | — |
| **cả ba chậm như nhau** | | chi phí ở phần **dùng chung** ⟹ khớp giả thuyết nghẽn tuần tự (Đ2) |

**Output:**

```
⏳ CHỜ OUTPUT (Kiên đã chạy, cần dán lại)
```

---

## Đ6 — MySQL: nghi phạm chưa từng đo

**Vì sao đáng nghi:** là **đích I/O duy nhất trong đường retrieval chưa hề được đo**. ES, embedding,
LLM đều đã đo và đều nhanh (D2) — MySQL thì chưa. Và nó khớp D1 (chờ MySQL không tiêu CPU).

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| Lúc request chậm có query treo lâu / nhiều `Waiting for lock` | 🔴 MySQL thành nghi phạm hàng đầu |
| Processlist sạch, không query nào lâu | ❌ Loại MySQL ⟹ mọi đích I/O đã đo hết ⟹ nghẽn **chắc chắn** nằm trong process Python |

**Lệnh** (chạy **song song** với một request đang chậm — bắn request ở terminal khác):

```bash
MYSQLPOD=$(kubectl -n ragflow get pods -l app=mysql -o jsonpath='{.items[0].metadata.name}')
for i in 1 2 3 4 5 6; do
  echo "--- lan $i  $(date '+%T') ---"
  kubectl -n ragflow exec "$MYSQLPOD" -- mysql -uroot -p"$MYSQL_PW" -e \
    "SELECT id,user,time,state,LEFT(info,80) AS q FROM information_schema.processlist WHERE command<>'Sleep' ORDER BY time DESC LIMIT 10;" 2>/dev/null
  sleep 3
done
```

<details>
<summary><b>Giải nghĩa từng cờ</b></summary>

```
mysql -uroot -p"$MYSQL_PW" -e "SQL"
│ ├─ -u                user
│ ├─ -p"..."           mật khẩu DÍNH LIỀN cờ (có khoảng trắng là mysql hiểu sai)
│ │                    ⚠️ đặt vào biến môi trường, ĐỪNG gõ thẳng — nợ kỹ thuật
│ │                    file tracking đã có mục "mật khẩu lọt vào git"
│ └─ -e "..."          execute: chạy 1 câu SQL rồi thoát, không vào shell tương tác
│                      (quan trọng: shell tương tác sẽ treo trong kubectl exec)

SELECT ... FROM information_schema.processlist
│ ├─ command<>'Sleep'  ⭐ LOẠI connection đang rảnh — chúng chiếm phần lớn danh sách
│ │                    và không nói gì về hiệu năng
│ ├─ time              số GIÂY query hiện tại đã chạy → cột cần nhìn nhất
│ ├─ state             query đang làm gì ("Waiting for table lock", "Sending data"…)
│ ├─ LEFT(info,80)     cắt câu SQL còn 80 ký tự cho vừa màn hình
│ └─ ORDER BY time DESC  query lâu nhất lên đầu

lặp 6 lần × sleep 3    ⟹ lấy mẫu ~18 giây, đủ phủ trọn một request chậm (20–48s)
                        (chụp 1 lần rất dễ trượt đúng khoảnh khắc nghẽn)
```
</details>

**Output:**

```
⏳ CHỜ OUTPUT
```

---

## Đ7 — Làm lại phép thử restart CHO ĐÚNG

> ✅ **CẬP NHẬT 2026-08-18 13:50 — KHÔNG CẦN CHẠY, KHÔNG CẦN DOWNTIME NỮA.**
> 3 pod ragflow đo được `AGE 9m49s` ⟹ cụm **đã vừa restart xong**. Chỉ cần chạy **Đ2 ngay bây giờ**
> là có luôn dữ liệu "sau restart" mà không phải rollout lần nữa. Giữ mục này làm tham chiếu
> cho lần sau, hoặc để đo lại **sau vài giờ** nhằm so với mốc sạch hiện tại.

⚠️ **Có downtime ngắn — phải báo trước các bên đang cắm API.** Chỉ chạy nếu Đ1–Đ3 chưa dứt điểm.
Lần trước (3.20) hỏng vì bấm `^C` giữa rollout ⟹ đo nhầm pod cũ.

```bash
kubectl -n ragflow rollout restart deployment/ragflow
kubectl -n ragflow rollout status deployment/ragflow --timeout=600s   # KHONG bam ^C
POD=$(kubectl -n ragflow get pods -l app.kubernetes.io/component=ragflow -o jsonpath='{.items[0].metadata.name}')
echo "POD_MOI=$POD  $(date '+%T')"
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "run=$i total=%{time_total}\n" -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY"
done
```

| Kết quả | Suy ra |
|---|---|
| 20 mẫu **đều nhanh & ổn định** (biên độ <3×) | 🔴 Có yếu tố **tích tụ theo uptime** ⟹ khớp giả thuyết hàng đợi/thread rò rỉ dần |
| Vẫn dao động 2→40s ngay sau restart | ❌ Không phải tích tụ ⟹ nghẽn mang tính **cấu trúc**, có ngay từ lúc khởi động |

**Output:**

```
⏳ CHỜ OUTPUT
```

---

## 3. Tiêu chí "fix xong" (giữ nguyên từ file tracking — đừng nới)

| Tiêu chí | Baseline | Mục tiêu |
|---|---|---|
| Median latency | 9.57s | < 3s |
| Max latency (30 mẫu) | 48.4s | < 6s |
| **Biên độ (max/min)** | **23×** | **< 3×** ⟵ tiêu chí quyết định |
| % request < 5s | 37% | > 90% |

Anh Cường báo issue là **"không ổn định"** ⟹ giảm median mà biên độ vẫn 20× thì **chưa xong**.

---

## 4. Nhật ký thi hành

| Thời điểm | Phép đo | Kết quả một dòng | Giả thuyết bị loại / được củng cố |
|---|---|---|---|
| | Đ1 | ⏳ | |
| | Đ2 | ⏳ | |
| | Đ3 | ⏳ | |

---

## 5. Bảng nghi phạm hiện tại (cập nhật sau mỗi phép đo)

**Cập nhật sau Đ1 + Đ2 (2026-08-18 13:53):**

| # | Nghi phạm | Trạng thái |
|---|---|---|
| 1 | ~~**Tranh GIL** giữa 128 thread~~ | ❌ **LOẠI (Đ2)** — mức song song thực tế **5.78**, không nối đuôi |
| 2 | ~~**Event loop bị block**~~ | ❌ **LOẠI (Đ2)** — cùng lý do; nếu block thì 5 request phải nối đuôi ≈65s |
| 3 | ~~Thread pool `max_workers` nhỏ~~ | ❌ **LOẠI (Đ1+Đ2)** — env không set ⟹ 128; và Đ2 không thấy nghẽn |
| — | ~~Tích tụ theo uptime~~ | ❌ **LOẠI (Đ2)** — pod mới 13 phút vẫn chậm 23.8s ⟹ Đ7 coi như đã trả lời |
| 4 | **MySQL** chậm/khoá | ❓ **NGHI PHẠM SỐ 1 HIỆN TẠI** — đích I/O DUY NHẤT chưa đo (Đ6) |
| 5 | MinIO trong đường retrieval | ❓ chưa kiểm có nằm trong đường không |
| 6 | 🆕 **Chi phí per-request độc lập** (mỗi request tự trả, không tranh nhau) | ❓ **khớp Đ2 chặt nhất** — xem Đ8/Đ9 |
| — | *15 giả thuyết cũ đã bị phủ định* | ❌ xem bảng "đường cụt" ở `TRACKING-api-retrieval-latency.md` mục 4.6 — **KHÔNG lặp lại** |

### 🔴 Ràng buộc MỚI từ Đ2 — mọi giả thuyết từ đây phải thỏa thêm D4/D5

| # | Dữ kiện mới | Nguồn |
|---|---|---|
| **D4** | **Không có nghẽn tuần tự** — 5 request đồng thời xong trong thời gian của 1 request (song song 5.78×) | Đ2 |
| **D5** | ⭐ **Tăng tải 5× thì latency GIẢM** (10.4–23.8s → 6.2–11.2s) | Đ2 |

**D5 rất mạnh và rất lạ.** Nó loại **toàn bộ** họ giả thuyết "tranh chấp tài nguyên" (thêm tải phải
chậm hơn, không thể nhanh hơn). Và nó gợi ý cơ chế ngược: có thứ gì đó **được hâm nóng / tái sử dụng**
khi các request đi liền nhau — cache, connection pool đã ấm, JIT, hoặc lazy-init được trả một lần
rồi dùng chung.

⟹ Nghi phạm mới đáng giá nhất: **một chi phí khởi tạo/làm nguội xảy ra khi request đi RỜI RẠC**
(cache hết hạn, connection bị đóng do idle timeout rồi phải mở lại, model/tokenizer bị load lại).

---

## Đ8 — Liệt kê ĐẦY ĐỦ process + thread (làm rõ bất thường của Đ1 điểm 4)

`ps | head -15` ở Đ1 **không thấy** `ragflow_server.py` lẫn `task_executor`. Phải xem trọn danh sách.

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| Thấy `ragflow_server.py` với `NLWP` lớn (>100) | Pool 128 đang được dùng thật ⟹ khớp Đ2 (song song tốt) |
| Thấy `ragflow_server.py` với `NLWP` nhỏ (<20) | Pool hầu như không dùng ⟹ đường retrieval chủ yếu là async, không qua thread pool |
| **Không có `task_executor` trong pod này** | 🔴 Ingest chạy ở pod KHÁC ⟹ **giả thuyết "retrieval tranh tài nguyên với ingest cùng pod" (Issue 4) sụp đổ** |

```bash
POD=ragflow-b68585df9-2dhbz
kubectl -n ragflow exec "$POD" -c ragflow -- sh -c 'ps -eo pid,pcpu,pmem,nlwp,etime,args --sort=-pcpu'
```

**Output:**

```
⏳ CHỜ OUTPUT
```

---

## Đ9 — ⭐ PHÉP THỬ KHOẢNG NGHỈ: kiểm chứng D5 (tải cao lại nhanh hơn)

**Đây là phép đo phân định mạnh nhất tiếp theo**, vì nó nhắm thẳng vào D5 — dữ kiện lạ nhất đang có.

**Giả thuyết cần thử:** độ chậm tỉ lệ với **khoảng nghỉ TRƯỚC request**, chứ không phải với tải.
Nếu đúng ⟹ có thứ gì đó **nguội đi khi rảnh** (connection idle-timeout rồi phải bắt tay lại,
cache TTL hết hạn, lazy re-init).

**Dự đoán viết TRƯỚC (R1):**

| Kết quả | Suy ra |
|---|---|
| **Nghỉ càng lâu ⟹ càng chậm** (0s nhanh, 60s chậm) | 🔴 **CHỐT cơ chế "nguội khi rảnh"** ⟹ đi tìm cái gì có TTL/idle-timeout đúng khoảng đó |
| Latency **không phụ thuộc** khoảng nghỉ | ❌ Loại; D5 chỉ là ngẫu nhiên do cỡ mẫu nhỏ ⟹ quay lại Đ6 (MySQL) |

```bash
TOKEN='ragflow-2KB-U6NBJYU62kIUtOhRv-kAL-LbhPmXaPbZfPPEaEw'
URL='http://10.208.137.54:8999/api/v1/retrieval'
BODY='{"question":"quy tắc quy trình quy định về điều lệnh","dataset_ids":["73932b965e5e11f192725fd51894c519"],"similarity_threshold":0.3,"vector_similarity_weight":0.6}'

for gap in 0 0 5 5 15 15 30 30 60 60; do
  sleep $gap
  curl -s -o /dev/null -w "gap=${gap}s total=%{time_total}\n" -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY"
done
```

**Output — ✅ ĐÃ CHẠY 2026-08-18 14:00–14:04, pod `ragflow-b68585df9-2dhbz`** (biến thể có đếm CLOSE_WAIT):

```
gap=0s   latency=9.104s   CLOSE_WAIT_now=269  at=14:00:53
gap=5s   latency=25.921s  CLOSE_WAIT_now=280  at=14:01:24
gap=30s  latency=1.806s   CLOSE_WAIT_now=296  at=14:01:56
gap=60s  latency=15.206s  CLOSE_WAIT_now=322  at=14:03:11
gap=90s  latency=10.188s  CLOSE_WAIT_now=340  at=14:04:51
```

### ❌ KẾT LUẬN Đ9 — phủ định CẢ HAI giả thuyết cùng lúc

1. ❌ **LOẠI "nguội khi rảnh" (D5).** Latency **không** tăng theo `gap`:
   `gap=30s` cho **1.806s** (nhanh nhất toàn phiên) trong khi `gap=5s` cho **25.921s** (chậm nhất).
   Nghỉ 90s lại nhanh hơn nghỉ 5s. **Không có quan hệ đơn điệu nào.**
   ⟹ **D5 ở Đ2 chỉ là ngẫu nhiên do cỡ mẫu nhỏ** — đúng bài học "ảo giác cỡ mẫu nhỏ" đã dính ở 3.20.
   ⟹ ⚠️ **Lần thứ 2 trong phiên một "quy luật" thấy ở 5–10 mẫu tan biến khi kiểm bằng biến khác.**
2. ❌ **LOẠI connection leak LẦN THỨ HAI, bằng biến ĐỘC LẬP với 3.20.**
   `CLOSE_WAIT` tăng đơn điệu 269→280→296→322→340, latency nhảy 9.1→25.9→**1.8**→15.2→10.2.
   Ở CLOSE_WAIT thấp (280) thì **chậm nhất**; ở CLOSE_WAIT cao hơn (296) thì **nhanh nhất**.
   ⟹ 3.20 kết luận đúng. Leak là bug thật nhưng **vô can với latency** — xác nhận 2 lần độc lập.

### 🔴 HỆ QUẢ QUAN TRỌNG NHẤT: đã HẾT biến ngoại sinh để thử

Cùng một query, cùng pod, cùng khung vài phút ⟹ latency **1.806s → 25.921s (14×)**.
**Không biến quan sát được từ ngoài nào dự báo được nó:**

| Biến đã thử | Có dự báo được latency không? |
|---|---|
| Tải đồng thời (1 vs 5 request) | ❌ không (Đ2 — song song 5.78×) |
| Khoảng nghỉ trước request (0–90s) | ❌ không (Đ9) |
| Uptime của pod | ❌ không (Đ2 — pod 13 phút vẫn 23.8s) |
| Số CLOSE_WAIT | ❌ không (3.20 + Đ9, 2 lần độc lập) |
| `topk`, `metadata_condition` | ❌ không (3.9/3.11/3.12) |
| Tải ingest | ❌ chưa loại hẳn, nhưng CPU 10–20% ⟹ không phải tranh CPU |

⟹ **Kết luận phương pháp luận: thứ gây chậm là TRẠNG THÁI BÊN TRONG process, không quan sát
được từ ngoài.** Mọi phép đo từ ngoài — dù thiết kế khéo đến đâu — sẽ tiếp tục cho ra nhiễu.
**PHẢI nhìn từ bên trong (Đ3 — bật DEBUG log).** Đây là việc còn lại duy nhất có khả năng kết thúc
issue, và nó KHÔNG cần cài thêm công cụ (code đã instrument sẵn ở `search.py:590/606`).

---

## Đ10 — ⛔ THỬ NỚI `refresh_interval` 1s → 30s: THẤT BẠI, GÂY SỰ CỐ NGẮN

**Giả thuyết:** `refresh_interval=1000ms` + ingest bulk `refresh=wait_for` ⟹ index bị ép refresh
liên tục ⟹ vô hiệu query cache ⟹ retrieval phải đọc lại. Số liệu hậu thuẫn (`_stats/refresh`):

| Index | refresh total | total_time_in_millis |
|---|---|---|
| `ragflow_doc_meta_22cdb...` | 2,820,748 | **83,171,118 ms ≈ 23 giờ** |
| `ragflow_22cdb...` | 2,447,710 | **46,322,789 ms ≈ 12.9 giờ** |

**Đã làm:** PUT `refresh_interval: "30s"` cho 2 index của KB đang test (2026-08-18 ~14:31).

**Kết quả — ❌ THẤT BẠI VÀ GÂY SỰ CỐ:**

1. Vòng lặp 10 mẫu **treo hoàn toàn**, không in nổi một dòng trong nhiều phút (trước đó mỗi request
   2–25s). Request đơn lẻ cũng không trả về.
2. 🔴 **UI RAGFlow ĐƠ.** Ingest tắc kéo theo API tắc.
3. **Cơ chế gây sự cố:** ingest gọi bulk với `refresh=wait_for` ⟹ khi `refresh_interval=30s`,
   **mỗi bulk phải chờ tới 30 giây** thay vì 1 giây. Hàng đợi bulk dồn ứ ⟹ nghẽn toàn hệ.
4. **Hoàn nguyên** về `1000ms` cho cả 2 index ⟹ `"acknowledged":true`, request trả về **21.493s**
   (chậm như cũ nhưng KHÔNG treo). Hệ thống về trạng thái ban đầu.

⟹ ❌ **LOẠI giả thuyết refresh.** Đây là hướng ES cuối cùng.

**⚠️ SAI LẦM CẦN GHI NHỚ:** đổi `refresh_interval` mà **không tính tới `refresh=wait_for` sẽ khuếch
đại thời gian chờ mỗi bulk lên đúng bằng khoảng đó**. Đáng lẽ phải (a) sửa `wait_for` → `false`
TRƯỚC, hoặc (b) thử trên index nhỏ trước. **Bài học: khi hai setting tương tác nhau, đổi một cái
có thể khuếch đại cái kia — phải rà quan hệ trước khi đụng production.**

---

## 6. 🏁 TỔNG KẾT — GIỚI HẠN CỦA VIỆC ĐO TỪ NGOÀI

### Đã loại trừ trong phiên này (bổ sung cho 15 giả thuyết cũ ở file tracking)

| # | Giả thuyết | Bị loại bởi | Bằng chứng |
|---|---|---|---|
| 16 | Tranh GIL / thread pool dùng chung | Đ2 | Mức song song thực tế **5.78×** — không nối đuôi |
| 17 | Event loop bị block bởi lời gọi sync | Đ2 | Cùng trên; nếu block thì 5 request ≈ 65s, thực tế 11.25s |
| 18 | Thread pool `max_workers` nhỏ | Đ1 + Đ2 | Env không set ⟹ mặc định **128** |
| 19 | Tích tụ theo uptime | Đ2 | Pod mới 13 phút vẫn chậm **23.8s** |
| 20 | "Nguội khi rảnh" (cold connection) | Đ9 | `gap=30s` → **1.806s** (nhanh nhất) vs `gap=5s` → **25.921s** |
| 21 | Connection leak gây chậm (lần 2) | Đ9 | CLOSE_WAIT 269→340 đơn điệu, latency nhảy loạn |
| 22 | TLS handshake mỗi lời gọi ES | log INFO | Mọi lời gọi ES **3–17ms** |
| 23 | `refresh_interval` ép mất cache | Đ10 | Nới lên 30s ⟹ **tệ hơn, gây sự cố** |

### Kết luận trung thực về giới hạn

**Không một biến nào quan sát được từ ngoài dự báo được latency.** Cùng query, cùng pod, cách nhau
vài phút: **1.806s → 25.921s (14×)**. Đã thử: tải đồng thời · khoảng nghỉ · uptime · CLOSE_WAIT ·
`topk` · `metadata_condition` · cường độ ingest · `refresh_interval`.

⟹ **Việc còn lại KHÔNG phải đo thêm từ ngoài.** Phải **chèn instrument vào code retrieval**
để biết đoạn nào nuốt thời gian.

### Cần bàn giao cho anh Cường (người build custom image)

| Việc | Vị trí | Ghi chú |
|---|---|---|
| **1. Chèn timing vào đường retrieval** | `rag/nlp/search.py` — quanh `:56` (`encode_queries`), `:199` (`get_vector`), `:299` (tokenize), `:434/461` (rerank), `:515` (`rerank_mdl.similarity`) | Log mốc thời gian **từng giai đoạn**. Đây là việc DUY NHẤT còn lại có khả năng kết thúc issue |
| **2. `LOG_LEVELS` chứ không phải `LOG_LEVEL`** | `common/log_utils.py:50` `os.environ.get("LOG_LEVELS", "")` | Đã thử `LOG_LEVEL=DEBUG` ⟹ **vô tác dụng**. Định dạng: `pkg:level`, phân tách bằng `,`. `root` mặc định INFO (`:66`) |
| **3. Sửa connection leak** | Client tới LiteLLM gateway | 227–340 CLOSE_WAIT, tăng đơn điệu. **Không gây chậm** (đã chứng minh 2 lần) nhưng là bug thật |
| **4. Cân nhắc bỏ `refresh=wait_for`** ở đường ingest | Lệnh `_bulk` | Mỗi bulk tốn ~1s chỉ để chờ refresh. **KHÔNG phải root cause latency**, nhưng lãng phí rõ. ⚠️ Nếu đổi thì **đừng** đồng thời nới `refresh_interval` (xem Đ10) |

### Nợ kỹ thuật gốc

**RAGFlow không instrument tầng retrieval** — không có field duration ở access log, `logging.debug`
có sẵn nhưng bật không lên bằng env thông dụng. Đây là lý do gốc khiến **5 phiên debug** phải đo
tách tầng thủ công từ ngoài và vẫn không kết luận được.
