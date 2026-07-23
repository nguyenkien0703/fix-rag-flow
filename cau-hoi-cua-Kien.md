# Câu hỏi của Kiên — Giải thích dive-deep (RagFlow 502)

> 3 nhóm câu hỏi phát sinh khi đọc lại báo cáo sự cố RagFlow KB Voffice 502.
> Trả lời theo phong cách "người chưa biết gì cũng hiểu": bài toán gốc → ví von → có/không nó → tóm tắt.
> Ngày: 2026-07-23.

---

# CÂU 1 — Process, Thread, và chuyện "1 pod / N pod / N process"

> Câu hỏi gốc: *"Tôi cần hiểu 1 pod 1 process, 1 pod n process, n pod mỗi pod n process. Và process với thread ở đây là gì? App RagFlow chạy Python + Flask + 1 process 1 thread đúng không? Và task executor là gì?"*

---

## PHẦN 0 — Bài toán gốc: "làm sao 1 máy phục vụ nhiều người cùng lúc?"

Quên máy tính đi một chút. Hình dung một **quán phở**.

- Khách vào → gọi món → bếp nấu → bưng ra. Đó là "1 request".
- Nếu quán chỉ có **1 đầu bếp** và ông ấy nấu xong **hẳn 1 tô** mới quay ra nhận khách tiếp theo → khách thứ 2, 3, 4 phải **xếp hàng đứng chờ**.

Bài toán muôn thuở của mọi phần mềm server: **rất nhiều người gọi cùng lúc, làm sao đừng để người này chờ người kia?**

Máy tính giải bài này bằng 2 khái niệm: **process** và **thread**. Hiểu 2 cái này là hiểu toàn bộ vụ 502.

---

## PHẦN 1 — Process là gì? (cái "quán" riêng biệt)

**Process = một chương trình đang chạy, có vùng nhớ (RAM) RIÊNG của nó.**

Ví von: mỗi process là **một quán phở riêng, có bếp riêng, kho riêng, tiền riêng.** Hai quán không dùng chung gì cả. Quán A cháy thì quán B vẫn bán bình thường.

Cụ thể với máy tính:
- Bạn mở Chrome → đó là 1 process. Mở Word → process khác. Hai cái này **độc lập**: Word treo, Chrome vẫn chạy.
- Mỗi process có **RAM riêng**. Chrome không đọc được biến trong RAM của Word (đây là tính năng bảo vệ, không phải hạn chế).

```
   PROCESS A (Chrome)          PROCESS B (Word)
   ┌──────────────────┐        ┌──────────────────┐
   │  code Chrome     │        │  code Word       │
   │  RAM riêng (2GB) │        │  RAM riêng (1GB) │
   └──────────────────┘        └──────────────────┘
        độc lập hoàn toàn — 1 cái chết, cái kia sống
```

---

## PHẦN 2 — Thread là gì? (nhiều "đầu bếp" TRONG cùng 1 quán)

**Thread = một luồng thực thi BÊN TRONG một process. Nhiều thread trong cùng process DÙNG CHUNG vùng nhớ (RAM) của process đó.**

Ví von: trong **cùng 1 quán phở**, thay vì 1 đầu bếp, thuê **3 đầu bếp**. Cả 3 dùng chung 1 bếp, 1 kho, 1 nồi nước lèo. Trong khi bếp A đang nấu tô của khách 1, bếp B đã có thể nhận và nấu tô của khách 2 → **không ai phải chờ lâu.**

```
   PROCESS (quán phở RagFlow)
   ┌────────────────────────────────────────┐
   │  RAM dùng chung                         │
   │                                         │
   │   THREAD 1 ──► phục vụ khách A          │
   │   THREAD 2 ──► phục vụ khách B  (song song)
   │   THREAD 3 ──► phục vụ khách C          │
   └────────────────────────────────────────┘
```

**So sánh nhanh:**

| | Process | Thread |
|---|---------|--------|
| Vùng nhớ RAM | Riêng biệt | Dùng chung (trong 1 process) |
| Ví von | Quán riêng | Đầu bếp trong cùng quán |
| Nặng/nhẹ | Nặng (tốn RAM, tạo chậm) | Nhẹ (tạo nhanh) |
| 1 cái chết thì... | Cái khác sống | Có thể kéo cả process chết |

---

## PHẦN 3 — CHỐT: RagFlow đang chạy KIỂU NÀO?

Bạn hỏi: *"App RagFlow chạy Python + Flask + 1 process 1 thread đúng không?"*

**Gần đúng — chính xác là: 1 process, và MỖI LÚC chỉ xử lý 1 request (tuần tự).** Đây là gốc rễ của vụ 502.

Bằng chứng từ chính source code (`api/ragflow_server.py:151`):
```python
app.run(host=..., port=...)       # ← chạy Flask "development server"
```

Có 2 điều cực kỳ quan trọng ở dòng này:

1. **`app.run()` là "development server" của Flask** — bản thân Flask cảnh báo *"không dùng cho production"*. Nó sinh ra để lập trình viên test trên máy mình, không phải để chịu tải thật.

2. **KHÔNG có tham số `threaded=True`** → mặc định nó xử lý **tuần tự từng request một**. Tức là: **quán phở RagFlow chỉ có 1 đầu bếp, nấu xong hẳn 1 tô mới nhận khách tiếp.**

> ⚠️ Làm rõ chỗ "thread": Python có một thứ tên là **GIL** (Global Interpreter Lock) — hiểu nôm na: kể cả có nhiều thread thì tại một thời điểm chỉ 1 thread chạy code Python. NHƯNG với web (phần lớn thời gian là **chờ** ES/mạng trả về, chứ không phải tính toán), thread vẫn giúp RẤT nhiều: trong lúc thread 1 **ngồi chờ ES**, thread 2 được chạy phục vụ người khác. Nên bật `threaded=True` vẫn cứu được vụ 502 này, dù không phải giải pháp production hoàn hảo.

### Vì sao chuyện này gây ra 502

```
1 đầu bếp (1 process, tuần tự):

  Khách mở KB Voffice ──► đầu bếp ôm 142k hồ sơ, nấu MẤT 40 GIÂY
                           │
     trong 40 giây đó:     │
       khách /filter    ───┤  ← đứng chờ, nginx đợi mãi không tới lượt → trả 502
       khách /knowledge ───┤  ← 502
       khách ở KB KHÁC  ───┘  ← 502  (oan, chẳng liên quan KB Voffice)
```

→ Đây là lý do **1 người mở KB nặng = cả team sập**. Không phải KB kia có vấn đề, mà là **chung 1 đầu bếp.**

---

## PHẦN 4 — Bây giờ hiểu "1 pod / N pod / N process" (đây là câu bạn hỏi)

Giờ nâng 1 tầng. Ở trên là chuyện **bên trong 1 process**. Còn đây là chuyện **nhân bản process/pod** — cách phổ biến để chịu tải lớn.

Nhắc lại 1 thuật ngữ K8s: **pod = "hộp" chứa (thường là) 1 container đang chạy app.** Bạn cứ tạm hiểu **1 pod ≈ 1 máy ảo nhỏ chạy 1 bản RagFlow.**

Bốn kịch bản, từ yếu tới mạnh:

### (a) 1 pod, 1 process, 1 request-tại-1-thời-điểm ← RAGFLOW HIỆN TẠI
```
   POD ragflow-xxx
   └── PROCESS (1 đầu bếp, tuần tự)
```
1 quán, 1 đầu bếp. Đúng tình trạng đang gây 502. Yếu nhất.

### (b) 1 pod, 1 process, N thread ← ĐÂY LÀ "VIỆC A" (bật đa luồng)
```
   POD ragflow-xxx
   └── PROCESS
        ├── thread 1
        ├── thread 2   (N đầu bếp trong CÙNG 1 quán, chung RAM)
        └── thread 3
```
1 quán, nhiều đầu bếp. **Chỉ cần thêm `threaded=True`** — không tạo pod mới, không tốn thêm RAM nhiều. Người mở KB nặng vẫn chờ, nhưng người khác được phục vụ. **Đây chính là fix A, rẻ và nhanh nhất.**

### (c) 1 pod, N process (ví dụ gunicorn 4 workers)
```
   POD ragflow-xxx
   ├── PROCESS 1 (đầu bếp + bếp riêng)
   ├── PROCESS 2
   ├── PROCESS 3
   └── PROCESS 4
```
1 quán nhưng **4 bếp riêng biệt**. Mạnh hơn (b) vì né được GIL của Python (4 process = 4 GIL độc lập, tính toán thật sự song song). Đây là cách **production chuẩn**: chạy RagFlow sau **gunicorn/uvicorn** với nhiều worker. Tốn RAM gấp ~số worker.

### (d) N pod, mỗi pod N process ← quy mô lớn thật
```
   POD 1 (4 process)     POD 2 (4 process)     POD 3 (4 process)
        │                     │                     │
        └─────────── nginx / load balancer chia khách ─────────┘
```
Nhiều quán, mỗi quán nhiều bếp. K8s tự động thêm/bớt pod theo tải (autoscale). Chịu tải cực lớn + chịu lỗi (1 pod chết, pod khác gánh). Đây là đích đến khi RagFlow thành service thật cho nhiều bên.

### Bảng tổng

| Kịch bản | Ví von | Song song? | Chi phí | Khi nào dùng |
|---|---|---|---|---|
| (a) 1 pod 1 process tuần tự | 1 quán 1 bếp, nấu xong mới nhận khách | ❌ Không | Rẻ nhất | **← đang bị, gây 502** |
| (b) 1 pod 1 process N thread | 1 quán N đầu bếp chung bếp | ✅ (cho việc chờ I/O) | Rất rẻ | **← Fix A, làm ngay** |
| (c) 1 pod N process | 1 quán N bếp riêng | ✅✅ (thật sự) | Vừa (×RAM) | Production chuẩn |
| (d) N pod × N process | N quán, mỗi quán N bếp | ✅✅✅ | Cao | Quy mô lớn, cần chịu lỗi |

---

## PHẦN 5 — Task Executor là gì? (ĐỪNG nhầm với web server!)

Đây là chỗ **rất dễ hiểu nhầm**, tôi tách riêng.

RagFlow thực ra có **HAI loại tiến trình hoàn toàn khác nhau**, chạy song song:

```
   ┌─────────────────────────────────────────────────────────┐
   │  POD ragflow                                             │
   │                                                          │
   │  ① WEB SERVER  (api/ragflow_server.py — app.run)         │
   │     → tiếp NGƯỜI DÙNG: mở KB, list file, gọi API         │
   │     → 1 process, tuần tự  ← CHỖ BỊ 502                    │
   │                                                          │
   │  ② TASK EXECUTOR (rag/svr/task_executor.py)              │
   │     → xử lý NỀN: khi upload file → cắt chunk, tạo         │
   │       embedding, đẩy vào ES. Chạy ngầm, không ai đợi.     │
   │     → CÓ THỂ chạy N cái (cờ --workers=N)                  │
   └─────────────────────────────────────────────────────────┘
```

**Phân biệt bằng ví von quán phở:**
- **Web server** = nhân viên **tiếp khách ở quầy** (khách đứng đợi câu trả lời ngay).
- **Task executor** = nhân viên **trong kho, sơ chế nguyên liệu** (thái thịt, ninh xương cho ngày mai — không khách nào đứng đợi trực tiếp).

**Cái bẫy khiến bạn dễ nhầm:** Trong file cấu hình `docker/entrypoint.sh` CÓ tham số `--workers=N`. Nhìn thấy "workers" dễ tưởng "à web có nhiều worker rồi, sao còn 502?". **KHÔNG.** Cái `--workers` đó chỉ nhân bản **task executor (②)** — nhân viên trong kho. **Web server (①) vĩnh viễn chỉ 1 process.** Đó là lý do dù có nhiều task executor, web vẫn sập.

Bằng chứng source (`docker/entrypoint.sh`):
```bash
# ① Web — chạy ĐÚNG 1 cái, không dính --workers:
"$PY" api/ragflow_server.py &

# ② Task executor — CÁI NÀY mới nhân theo --workers:
for (( i=0; i<WORKERS; i++ )); do
    "$PY" rag/svr/task_executor.py ...
done
```

**Liên hệ với sự cố C (up file chờ 10')** trong báo cáo: đó là vì task executor xử lý nền chậm/ít worker → file nằm trong hàng đợi lâu mới tới lượt. Khác hẳn vụ 502 (web server). Hai vấn đề, hai loại tiến trình.

---

## Tóm tắt CÂU 1 trong 1 phút

- **Process** = quán riêng, RAM riêng, chết độc lập. **Thread** = đầu bếp trong cùng quán, chung RAM.
- **RagFlow web = 1 process, xử lý tuần tự 1 request/lúc** (`app.run` không `threaded`). → 1 KB nặng chiếm 40s = cả team bị 502.
- **Fix A = bật thread** (1 quán nhiều bếp) — rẻ, nhanh, cứu 502 ngay. Production chuẩn thì dùng N process (gunicorn) hoặc N pod.
- **Task executor ≠ web server.** `--workers` chỉ nhân task executor (xử lý nền), KHÔNG cứu web. Đừng nhầm.

---
---

# CÂU 2 — "Facet" là cái gì?

> Câu hỏi gốc: *"facet là cái gì thế? tôi chưa hiểu luôn."*

---

## PHẦN 0 — Bài toán gốc: "cho tôi xem nhanh bộ lọc có những lựa chọn nào"

Bạn mua hàng trên **Shopee/Tiki**. Bên trái màn hình có bảng lọc:

```
  Thương hiệu
    ☐ Samsung (1.234)
    ☐ Apple    (987)
    ☐ Xiaomi   (2.001)

  Giá
    ☐ Dưới 2 triệu   (543)
    ☐ 2–5 triệu      (1.200)
```

Cái **con số trong ngoặc** — "Samsung có 1.234 sản phẩm" — chính là **facet**. Và bảng lọc đó = **faceted search** (tìm kiếm theo phân mặt).

---

## PHẦN 1 — Định nghĩa

**Facet = một "mặt" để phân loại dữ liệu, kèm SỐ LƯỢNG mỗi giá trị.**

Trong RagFlow, khi bạn mở 1 KB, giao diện có bộ lọc tài liệu:
```
  Trạng thái xử lý:  Xong (1.100)   Đang chạy (35)   Lỗi (12)
  Loại file:         PDF (900)      Word (200)       Excel (47)
  status (metadata): "công văn" (500)   "báo cáo" (300)  ...
```

Mỗi dòng đó là 1 facet. Để hiện được con số "PDF: 900", hệ thống phải **đếm** xem trong KB có bao nhiêu file PDF, bao nhiêu Word...

---

## PHẦN 2 — Vì sao facet gây ra vấn đề (chỗ /filter khó fix)

Đây là mấu chốt tại sao báo cáo nói *"/filter không fix được bằng phân trang"*.

- `/list` (danh sách file) → chỉ cần **50 dòng của trang hiện tại**. Dễ: chỉ lấy 50.
- `/filter` (facet) → phải đếm **"PDF: 900"**. Muốn ra con số 900, về nguyên tắc phải **nhìn qua TOÀN BỘ** tài liệu để đếm. **Không thể chỉ nhìn 50 dòng rồi nói cả KB có 900 PDF.**

→ Đó là lý do `/filter` **bản chất phải quét toàn KB**, không phân trang được.

**Cách RagFlow đang làm (sai):** kéo cả 142k tài liệu về Python rồi đếm bằng tay → nặng.

**Cách đúng:** để **Elasticsearch tự đếm**. ES có sẵn tính năng **aggregation** (gom nhóm + đếm) — giống lệnh `GROUP BY ... COUNT(*)` trong SQL. ES đếm nội bộ rồi chỉ trả về **kết quả gọn** ("PDF: 900, Word: 200"), thay vì trả 142k dòng thô về cho Python đếm.

```
  CÁCH SAI (hiện tại):
    ES ──142k dòng thô──► Python đếm tay ──► "PDF:900"     (nặng, tràn)

  CÁCH ĐÚNG (aggregation):
    ES tự đếm bên trong ──chỉ trả "PDF:900, Word:200"──► Python   (nhẹ)
```

**Vì sao vẫn khó, phải test kỹ:** metadata trong RagFlow là **động** — mỗi KB do người dùng tự định nghĩa field khác nhau (KB này có field `status`, `promulgateDate`; KB kia có `author`, `department`...). Muốn bảo ES "đếm theo field X" thì phải **biết trước tên các field X** — mà nó không cố định. Nên phải: (1) hỏi ES "KB này có những field metadata nào", rồi (2) mới bảo ES đếm theo từng field đó. Hai bước, cần viết cẩn thận → "không phải sửa 1 dòng".

---

## Tóm tắt CÂU 2 trong 1 phút

**Facet = bộ lọc kèm số đếm** (như "Samsung (1.234)" trên Shopee). Để hiện số đếm phải quét toàn KB → không phân trang được. Cách đúng là để ES tự đếm bằng **aggregation** (giống `GROUP BY COUNT` của SQL). Khó vì field metadata mỗi KB một khác (động), phải dò tên field trước khi đếm.

---
---

# CÂU 3 — "Tại sao lại mất data được? Web stateless, data ở ES cơ mà?"

> Câu hỏi gốc: *"Data (doc, metadata) đều ở ES rồi. Web chỉ xử lý + render, app.run chỉ chạy web/UI. Rollout lỗi thì đã sao? Web stateless mà, data vẫn ở ES, sao mất được? Bên tôi đang dựng RagFlow cho các bên cắm API vào thử nghiệm, chưa dùng thật, không có môi trường test."*

---

## Câu trả lời ngắn gọn, thẳng thắn: **BẠN ĐÚNG. Tôi đã dùng từ sai.**

Bạn suy luận hoàn toàn chính xác về mặt kiến trúc. Để tôi công nhận rõ từng ý:

| Bạn nói | Đúng/Sai | Xác nhận |
|---|---|---|
| Data (doc + metadata) lưu ở ES | ✅ ĐÚNG | Đúng. ES là nơi lưu thật. |
| Web RagFlow chỉ đọc + xử lý + render | ✅ ĐÚNG | 3 hàm mình patch (162, 241, 772) **chỉ `search` — chỉ ĐỌC**, không ghi/xóa ES. Đã verify source. |
| Web là stateless | ✅ ĐÚNG | Web không giữ data riêng; restart không mất gì. |
| Rollout web lỗi → data vẫn còn ở ES | ✅ ĐÚNG | Chuẩn. Rollback về image cũ là xong, ES nguyên vẹn. |

→ **Câu "sai tên field → mất metadata mọi doc" trong báo cáo là TỪ NGỮ GÂY HIỂU NHẦM của tôi. Xin đính chính.**

---

## Vậy tôi đã định nói gì? Làm rõ "mất" nghĩa là gì

Có **2 loại "mất" hoàn toàn khác nhau**, tôi đã gộp bậy làm 1:

### Loại 1 — Mất data VĨNH VIỄN khỏi ES (xóa mất thật)
→ **KHÔNG BAO GIỜ xảy ra với patch này.** Vì patch chỉ đọc. Bạn đúng 100%. Data ở ES là bất khả xâm phạm ở đây.

### Loại 2 — "Mất" theo nghĩa HIỂN THỊ SAI (data còn nguyên, nhưng UI/API trả về thiếu)
→ **Cái này CÓ THỂ xảy ra**, và đó mới là điều tôi lo. Giải thích bằng ví dụ:

Nhớ chi tiết kỹ thuật: doc-id nằm ở ES `_id`, **không** có trong `_source`. Nếu patch viết sai — lọc nhầm bằng `terms {id:...}` thay vì `ids {...}` — thì:

```
  Câu lọc SAI gửi xuống ES  ──►  ES tìm không thấy field "id"  ──►  trả về RỖNG
                                                                      │
  ES vẫn còn đủ 142k metadata ✅       nhưng API trả metadata = {} ✗ ─┘
                                                                      │
                     → UI hiện file NHƯNG cột metadata TRỐNG TRƠN ────┘
```

**Data vẫn nằm im ở ES, không mất đi đâu.** Nhưng người dùng mở lên thấy **trống metadata** → tưởng mất. Sửa lại patch cho đúng + restart là hiện lại ngay. Đây là **"mất hiển thị tạm thời", có thể hồi phục 100%**, KHÁC hẳn "mất data".

→ Diễn đạt đúng phải là: *"nếu patch sai tên field → API trả metadata rỗng → UI hiển thị thiếu (dù ES còn nguyên); sửa patch là hồi lại."* Ngắn gọn tôi rút thành "mất metadata" — sai, gây hoảng. Nhận lỗi.

---

## Về bối cảnh của bạn: thử nghiệm, chưa production, không có môi trường test

Bạn cung cấp thêm 3 dữ kiện, và chúng **thay đổi hẳn khẩu vị rủi ro** — theo hướng bạn nói là đúng:

1. **RagFlow đang là service thử nghiệm cho các bên cắm API thử tích hợp**, chưa dùng thật.
2. **Chưa đi vào sử dụng thực sự.**
3. **Không có môi trường test/staging** — chỉ có đúng 1 môi trường này.

→ Với bối cảnh đó, **"phải có staging mới được đụng" là lời khuyên quá cứng, không hợp tình huống của bạn.** Đây là môi trường **thử nghiệm chịu được lỗi** (không có khách thật mất tiền/mất việc khi nó trục trặc 10 phút). Vậy khuyến nghị điều chỉnh lại cho đúng thực tế của bạn:

| Vấn đề | Trước (tôi nói cứng) | Điều chỉnh theo bối cảnh thật của bạn |
|---|---|---|
| Môi trường test | "Bắt buộc có staging" | Không có cũng được. Chính môi trường thử nghiệm này **đóng vai staging.** Miễn là **báo trước cho các bên đang cắm API** về khung giờ có thể gián đoạn. |
| Rủi ro rollout | "Rủi ro cao" | **Thấp** — web stateless, data ở ES an toàn, rollback = đổi lại image cũ + restart (1 lệnh). |
| An toàn tối thiểu cần làm | — | (1) **Backup file gốc** trước khi mount đè (để rollback nhanh). (2) Thử trên **1 KB nhỏ trước**, thấy metadata hiện đúng rồi mới yên tâm. (3) Giữ sẵn lệnh `kubectl rollout undo`. |

**Điều DUY NHẤT vẫn nên giữ:** sau khi deploy, **mở 1 KB có metadata và mắt nhìn xem cột metadata có hiện đúng không** (verify Loại-2 ở trên). Đây không phải vì sợ mất data — mà để chắc patch lọc đúng, API không trả rỗng. Chỉ tốn 1 phút.

---

## Tóm tắt CÂU 3 trong 1 phút

- Bạn **đúng**: data ở ES, web stateless, patch chỉ đọc → **không thể mất data khỏi ES.** Từ "mất metadata" của tôi là sai, gây hiểu nhầm — xin đính chính.
- Cái *có thể* xảy ra chỉ là **hiển thị thiếu tạm thời** nếu patch lọc sai (ES còn nguyên, sửa + restart là hồi) — không phải mất data.
- Bối cảnh thử nghiệm + không có staging của bạn → **rủi ro thực tế THẤP**, rollout thoải mái. Chỉ cần: backup file gốc, thử KB nhỏ trước, và nhìn mắt xem metadata hiện đúng sau khi deploy. Nhớ **báo trước các bên đang cắm API** về khung giờ gián đoạn.

---

## GHI CHÚ — sửa lại báo cáo cho khớp

Câu hỏi #2 và #3 trong artifact báo cáo nên chỉnh lại (khi bạn muốn):
- Bỏ "mất metadata mọi doc" → thay bằng "nếu patch lọc sai → API trả metadata rỗng, UI hiển thị thiếu; sửa patch + restart là hồi (ES luôn nguyên vẹn)".
- Câu hỏi "có staging không" → đổi thành "báo trước các bên đang cắm API về khung giờ deploy" (vì thực tế không có & không cần staging cho môi trường thử nghiệm này).
