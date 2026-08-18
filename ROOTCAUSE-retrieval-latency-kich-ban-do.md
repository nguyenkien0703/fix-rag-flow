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
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}')
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
kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}'
│ ├─ -n ragflow        namespace chứa deployment
│ ├─ -l app=ragflow    label selector, lọc đúng pod ragflow (bỏ pod khác trong ns)
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

**Output:**

```
⏳ CHỜ OUTPUT
```

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

**Output:**

```
⏳ CHỜ OUTPUT
```

**Ghi chú thi hành:** nếu SSH qua VDI đứt giữa chừng (bài học 9 — `Connection closed` khi lệnh chạy
lâu), giảm phần A xuống 2 vòng, hoặc bọc `nohup ... > /tmp/d2.log 2>&1 &` rồi đọc file.

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
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}')
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
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}')
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
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}')
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

⚠️ **Có downtime ngắn — phải báo trước các bên đang cắm API.** Chỉ chạy nếu Đ1–Đ3 chưa dứt điểm.
Lần trước (3.20) hỏng vì bấm `^C` giữa rollout ⟹ đo nhầm pod cũ.

```bash
kubectl -n ragflow rollout restart deployment/ragflow
kubectl -n ragflow rollout status deployment/ragflow --timeout=600s   # KHONG bam ^C
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}')
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

| # | Nghi phạm | Khớp D1? | Khớp D2? | Khớp D3? | Trạng thái |
|---|---|---|---|---|---|
| 1 | **Tranh GIL** giữa 128 thread của pool dùng chung | ✅ | ✅ | ✅ | ❓ chờ Đ1+Đ2 |
| 2 | **Event loop bị block** bởi lời gọi sync trong coroutine | ✅ | ✅ | ✅ | ❓ chờ Đ2 |
| 3 | Thread pool `max_workers` **nhỏ** | ✅ | ✅ | ✅ | ⚠️ **yếu đi** — source cho thấy mặc định 128 (mục 1) |
| 4 | **MySQL** chậm/khoá | ✅ | — chưa đo | ✅ | ❓ chờ Đ6 — đích I/O DUY NHẤT chưa đo |
| 5 | MinIO trong đường retrieval | ✅ | — chưa đo | ✅ | ❓ chưa kiểm có nằm trong đường không |
| — | *15 giả thuyết đã bị phủ định* | | | | ❌ xem bảng "đường cụt" ở `TRACKING-api-retrieval-latency.md` mục 4.6 — **KHÔNG lặp lại** |
