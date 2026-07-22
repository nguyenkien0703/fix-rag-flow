# RagFlow — Kế hoạch Debug & Kiểm chứng

> KB "Voffice doc sum" (~120k chunks). UI: http://10.208.137.54:8999/
> Doc engine: **ES Lakehouse Viettel (NGOÀI cluster)** `https://10.211.145.107:8051` — user `aihub_prod`
> Debug từ node `10.208.137.51`, Helm chart tại `/home/app/app/ragflow-0.24.0/helm`
> K8s namespace: `ragflow` | Pod app: `ragflow-78dd4c855-shdq8`
> Ngày: 2026-07-22

---

## 0. Bức tranh cluster (ĐÃ THU THẬP)

| Pod | Trạng thái | Ghi chú |
|-----|-----------|---------|
| ragflow-78dd4c855-shdq8 | 1/1 Running, 48d, 0 restart | App server (API + web) |
| ragflow-es-0 | **0/1 Pending, 55d** | ES nội bộ — **KHÔNG dùng**, vô hại. RagFlow trỏ ES Lakehouse ngoài |
| ragflow-minio-0 | 1/1 Running, 68d | Lưu file |
| ragflow-mysql-0 | 1/1 Running, 55d | Metadata (dataset, document, folder) |
| ragflow-redis-0 | 1/1 Running, 55d | Cache + task queue |

**Kết luận sớm:** Không pod nào restart/OOM → "idle 10 phút" KHÔNG do pod chết → thuộc tầng **network/connection**.

---

## 1. Bốn triệu chứng & phân loại root cause

| # | Triệu chứng | Nhóm root cause |
|---|-------------|-----------------|
| 1 | Click KB nhiều tài liệu+metadata → API chết, UI trống, vài phút sau tự hồi | **A: stale connection** |
| 2 | Lâu không vào UI → vào lại bị (1), ~10' sau bình thường | **A: stale connection** |
| 3 | Lâu không up file → up vào queue, ~10' sau mới xử lý | **A: stale connection** |
| 4 | Retrieval query 120k chunks ~30s; dataset 500 chunks ~40ms | **B: query nặng thật** (tách riêng, làm sau) |

**Ưu tiên đã chốt: Fix nhóm A (1/2/3) trước.**

---

## 2. Root cause nhóm A — GIẢ THUYẾT

**Chuỗi nhân quả:**
1. RagFlow giữ **connection pool** (elasticsearch-py/urllib3) tới ES Lakehouse để tái dùng, khỏi bắt tay TCP/TLS mỗi query.
2. Giữa cluster (`10.208.x`) và ES Lakehouse (`10.211.x`) có **firewall/NAT Viettel** → cắt **idle connection** sau vài phút, **KHÔNG gửi RST** (cắt lặng).
3. Kernel keepalive của pod: `tcp_keepalive_time = 7200` (2h) → keepalive không kịp probe trước khi firewall cắt.
4. Request đầu sau idle → gửi vào socket "zombie" → TCP retransmit ~10-15' rồi mới bỏ cuộc, reconnect → "tự bình thường".

**Trick workaround hiện tại của anh Cường** (call API mỗi 3-5') = tạo traffic giả để firewall không cắt → che triệu chứng, KHÔNG phải fix.

---

## 3. CHECKLIST giả thuyết & kiểm chứng

| ID | Giả thuyết | Cách kiểm chứng | Kỳ vọng nếu ĐÚNG | KẾT QUẢ THỰC TẾ |
|----|-----------|-----------------|------------------|-----------------|
| H1 | ES Lakehouse KHỎE khi connection ấm (loại "ES tự chậm") | `curl -w` health check lúc vừa dùng | total < 1s, http 200 | ✅ **21ms, http=200** (connect=1.2ms, ttfb=20ms) |
| H2 | keepalive quá muộn (7200s) | đọc `/proc/sys/net/ipv4/tcp_keepalive_time` | = 7200 | ✅ **7200** (intvl=75, probes=9) |
| H3 | **Idle làm connection chết** (mấu chốt) | ⚠️ curl KHÔNG dùng được — curl mở conn MỚI mỗi lần, không đụng pool cũ. Phải **tái hiện qua app** | request đầu qua app treo vài phút→10', các request sau nhanh | ⏳ **ĐO QUA APP** (xem dưới) |
| H4 | App pool tái dùng socket zombie (khác curl mở conn mới) | = chính là H3 đo qua app | request đầu ~10' rồi mới xong | ⏳ gộp vào H3 |
| H5 | Firewall Viettel thật sự có idle-timeout | Hỏi team hạ tầng Viettel timeout NAT là bao nhiêu phút | có 1 giá trị (vd 5-15') | ⏳ cần hỏi |

### ⚠️ Vì sao curl KHÔNG chứng minh được H3
`curl` là tiến trình mới mỗi lần → **mở connection TCP mới toanh** (thấy `connect=0.0018s`). Connection mới thì luôn nhanh vì firewall chưa kịp cắt. Nhưng bug nằm ở **connection CŨ trong pool app** (đã idle, đã bị firewall cắt lặng). curl không đụng pool đó → không tái hiện được.
- Baseline curl ấm: `total=0.021s` http=200 ✅ (chứng minh H1: ES khỏe)
- curl sau ~15' (lần 2): `total=0.015s` http=200 — **KHÔNG hợp lệ cho H3** (conn mới, không phải pool cũ)

### Cách đo H3 ĐÚNG — tái hiện qua app
1. Để RagFlow **idle thật 15-20'** (không ai vào UI, không query).
2. Vào UI **KB "Voffice doc sum"** hoặc gọi 1 retrieval query qua app → **bấm giờ request đầu**.
3. Ghi kết quả:
   - Request đầu tiên mất: `__________` (kỳ vọng nếu ĐÚNG: treo vài phút → ~10')
   - Các request ngay sau đó: `__________` (kỳ vọng: nhanh trở lại)

**Kết quả H3:** ❌ **BÁC BỎ giả thuyết stale-connection cho triệu chứng 1.**
Tái hiện qua app (click KB Voffice, xem Network tab):
- Các request `detail`, `list?kb_id`, `knowledge_graph`, `filter` → **Pending ~8.7s → tất cả trả 502**.
- **KHÔNG treo 10 phút.** 502 sau **8.71s** đều tăm tắp = **timeout gateway cấu hình cứng (~8-9s)**, không phải TCP retransmit của stale connection.
- ⟹ Root cause triệu chứng 1 = **backend API xử lý >8.7s → gateway bỏ cuộc 502**. Cùng họ với triệu chứng 4 (query nặng), KHÔNG phải họ stale-connection.

---

## 3b. KHÚC NGOẶT — giả thuyết mới (H6, H7)

| ID | Giả thuyết | Cách kiểm chứng | KẾT QUẢ |
|----|-----------|-----------------|---------|
| H6 | API `list/detail/filter/knowledge_graph` trên KB nhiều metadata xử lý >8.7s | Log ragflow-server lúc 502 + đo query nào chậm | ⏳ đo cụm 7 |
| H7 | Gateway (nginx trong pod?) có `proxy_read_timeout ~8-9s` cắt request | Đọc nginx conf trong pod + ps process | ⏳ đo cụm 7 |
| H8 | Query chậm ở tầng MySQL (list document metadata) HAY ES? | Log slow query / EXPLAIN | ⏳ chưa đo |

**Lưu ý:** stale-connection (7200 keepalive) VẪN có thể đúng cho **triệu chứng 3** (up file chờ 10') — cần tách bạch. Nhưng triệu chứng 1 giờ chuyển sang họ "query/timeout nặng".

---

## 4. GIẢI PHÁP (theo thứ tự ưu tiên, chưa áp)

| Ưu tiên | Giải pháp | Cơ chế | Rủi ro | Bền vững? |
|---------|-----------|--------|--------|-----------|
| **P1** | Hạ kernel keepalive trong pod: `tcp_keepalive_time` 7200→120, `intvl` 75→30, `probes` 9→5 | Pod tự gửi keepalive mỗi ~2' → firewall luôn thấy traffic → không cắt | Thấp (chỉ đổi hành vi TCP của pod) | Cần đặt trong Helm để không mất khi restart |
| P2 | Bật ES client retry/timeout ngắn (env RagFlow) | Request đầu fail nhanh + auto reconnect thay vì treo 10' | Thấp-TB (đụng config app) | Có |
| P3 | Cấu hình firewall Viettel tăng idle-timeout | Chữa từ phía gateway | Phụ thuộc team ngoài | Có nhưng ngoài tầm |
| ❌ | Trick call-API mỗi 3' (hiện tại) | Traffic giả | Che triệu chứng, tốn tài nguyên, không bền | Không |

**Cách áp P1 (3 lựa chọn kỹ thuật — chọn sau khi đọc chart):**
- (a) `securityContext.sysctls` trong pod spec (cần allowlist `net.ipv4.tcp_keepalive_*` ở kubelet — có thể bị chặn)
- (b) `initContainer` privileged chạy `sysctl -w` (chắc ăn hơn nhưng cần privileged)
- (c) Set socket keepalive **ở tầng ES client** trong RagFlow (không đụng kernel — sạch nhất nếu code hỗ trợ)

→ Cần đọc `values.yaml` + `templates/` để chọn (a)/(b)/(c).

---

## 5. VERIFY sau khi áp fix

| Bước | Cách làm | Đạt nếu |
|------|----------|---------|
| V1 | Sau khi áp P1, `kubectl exec` đọc lại `tcp_keepalive_time` | = 120 |
| V2 | Chạy lại curl 6a **sau 15-20' idle** | total vẫn < 1s (không còn treo) |
| V3 | Vào UI KB "Voffice doc sum" sau khi idle qua đêm | UI hiện folder ngay, API không chết |
| V4 | Up 1 file sau khi idle lâu | Vào queue & xử lý ngay, không chờ 10' |
| V5 | Quan sát 24-48h, tắt trick call-API-mỗi-3' của anh Cường | Không tái phát |

**Nguyên tắc:** chỉ áp **MỘT** fix (P1) → verify → rồi mới cân nhắc P2. Không gộp nhiều fix.

---

## 6. Nhật ký thao tác (điền khi làm)

| Thời gian | Việc | Kết quả |
|-----------|------|---------|
| | H1,H2 đã đo | ES khỏe 21ms; keepalive=7200 |
| | | |

---

## 3c. THÔNG TIN MỚI (người vận hành): "bị như ảnh 2 (502) tầm 10-15' là lại view bình thường"

→ Ghép "502-mỗi-request-sau-8.7s" + "10-15' tự khỏi" = **KHÔNG mâu thuẫn**, mà là 2 giai đoạn 1 chuỗi:
- 502 = hành vi **tức thời** mỗi request (gateway cắt ở 8.7s).
- "10-15' tự khỏi" = hành vi **hồi phục hệ thống** → có tài nguyên bị cạn/tắc rồi tự giải phóng.

**STALE-CONNECTION SỐNG LẠI (mạnh hơn):** request đầu sau idle → nhiều worker đâm vào socket zombie
→ **pool cạn** → mọi request 502 (gateway che cái treo TCP dài sau 8.7s) → chờ từng socket zombie
chết dần (~vài phút/cái) → sau 10-15' pool sạch → hồi phục. Khớp CẢ 502 LẪN 10-15'.

**⟸ RÚT LẠI việc bác bỏ ở mục 3b.** 502-8.7s chỉ là gateway che cái treo TCP, KHÔNG loại được stale-connection.

### Phép phân biệt DỨT ĐIỂM (cụm 7 — log lúc đang 502)
| Nếu log cho thấy... | ⟹ Root cause | Fix |
|---------------------|--------------|-----|
| ConnectionTimeout / ConnectionError / reset tới ES 10.211.145.107 | **Stale-connection** | P1: hạ keepalive |
| Query chạy XONG nhưng mất 20-30s, KHÔNG lỗi connection | **Query nặng** | Tối ưu query/index |

| H | Giả thuyết | KẾT QUẢ |
|---|-----------|---------|
| H9 | Log ragflow-server lúc 502 = lỗi connection tới ES | CHỜ đo cụm 7a |
| H10 | Có gateway (nginx/gunicorn) timeout ~8.7s trong pod | CHỜ đo cụm 7b |

---

## 3d. ROOT CAUSE THẬT (xác định từ log cụm 7) — KHÁC cả stale-connection LẪN query nặng thuần

### Bằng chứng log:
- Mọi request ES: `duration:0.003s`~`0.005s` → **ES KHỎE, connection KHỎE** → BÁC BỎ stale-connection (H9 ❌).
- 1 search nặng: `POST ragflow_doc_meta/_search [status:200 duration:5.097s]` với query `size:10000` (kéo 10k doc metadata/lần, không phân trang).
- **Bão lỗi metadata (thủ phạm chính):**
  - `ERROR ES partial update failed ... NotFoundError(404,'document_missing_exception')`
  - `ERROR Failed to insert metadata ... document_parsing_exception: failed to parse field [meta_fields.promulgateDate] of type [date] ... value '15/07/2026 00:00:00' ... format [strict_date_optional_time||epoch_millis]`
- ps aux: `python3 api/ragflow_server.py` chiếm **77.5% CPU, 12.8% mem** → server đang nghẽn CPU.
- Gateway 502: pod có **nginx master + workers** → chính nó cắt request >8.7s.

### Cơ chế root cause:
1. Mở KB Voffice → RagFlow search metadata `size:10000` (~5s) rồi loop update metadata TỪNG document.
2. Field `promulgateDate` = `dd/MM/yyyy` (`15/07/2026`) nhưng ES map kiểu `date` format `yyyy-MM-dd` → ES từ chối `document_parsing_exception`.
3. Hàng nghìn document lỗi → retry + log + xử lý exception → nghẽn CPU ragflow_server (77.5%).
4. Tổng > 8.7s → nginx timeout → **502**.
5. "10-15' tự khỏi" = thời gian loop metadata chạy hết/bỏ qua đống lỗi.

### Bác bỏ:
- ❌ Stale-connection (keepalive 7200): ES duration 3-5ms, KHÔNG timeout. Fix P1 KHÔNG cần cho triệu chứng 1.
- ❌ Query nặng thuần ES: search 5s là do `size:10000` + loop, không phải ES yếu.

### Root cause 1 câu:
**Metadata `promulgateDate` sai format ngày (`dd/MM/yyyy` vs ES `date yyyy-MM-dd`) → mỗi lần mở KB, RagFlow loop update metadata hàng nghìn doc, tất cả fail parse → nghẽn CPU ragflow_server > timeout nginx 8.7s → 502; loop chạy xong (~10-15') thì tự khỏi.**

### Hướng fix mới (cần xác minh thêm):
- F1: Sửa format `promulgateDate` trong metadata (hoặc mapping ES) để ES parse được → hết vòng lặp lỗi.
- F2: RagFlow không nên loop update metadata mỗi lần mở KB — cần tìm code path gây ra (register-server list/detail).
- F3: Tăng nginx `proxy_read_timeout` chỉ là giảm 502, KHÔNG chữa gốc (vẫn nghẽn CPU).

| H | Giả thuyết mới | Cách kiểm chứng | KẾT QUẢ |
|---|----------------|-----------------|---------|
| H11 | promulgateDate sai format gây parse fail hàng loạt | Đã thấy trong log | ✅ XÁC NHẬN |
| H12 | Vòng lặp update metadata chạy mỗi lần mở KB (không chỉ khi upload) | Đọc code path list?kb_id / detail | ⏳ cần đọc code |
| H13 | Số document lỗi lớn (hàng nghìn) → mới đủ nghẽn >8.7s | Đếm doc trong KB + đếm doc lỗi | ⏳ cần đo |

---

## 3e. CHỈNH HƯỚNG (feedback người vận hành): metadata lỗi KHÔNG phải root cause

**Feedback:** upload tài liệu vẫn thành công, metadata lỗi chỉ khiến doc đó thiếu metadata, request vẫn OK.

**Verify bằng log — feedback ĐÚNG:**
- Đường GHI (upload): `PUT .../_bulk?refresh=false [status:200 duration:0.005s]` → upload OK, metadata parse fail chỉ log ERROR rồi bỏ qua. Không hỏng upload.
- Mấy dòng `ERROR ES partial update failed` / `document_parsing_exception (promulgateDate)` = NHIỄU, đến từ tiến trình nền `sync_data_source.py`, KHÔNG liên quan việc mở KB 502.

**⟹ RÚT LẠI H11/H12/H13 (đổ lỗi vòng lặp update metadata).** Đó không phải nguyên nhân 502.

### Nghi phạm còn lại cho 502 = đường ĐỌC khi mở KB:
- `POST ragflow_doc_meta/_search [status:200 duration:5.097s]` với `size:10000` — 1 search đọc metadata mất 5s.
- NHƯNG 5.097s < 8.7s (nginx timeout) → 1 search CHƯA đủ 502. Trang mở KB gọi nhiều API song song (list/detail/knowledge_graph/filter).
- ⟹ CHƯA chốt root cause. Cần đo API nào trong đường đọc thực sự chậm/gây 502.

| H | Giả thuyết | Cách kiểm chứng | KẾT QUẢ |
|---|-----------|-----------------|---------|
| H14 | `_search size:10000` (không phân trang) là điểm chậm chính đường đọc | Đo lại từng API list/detail/kg/filter khi mở KB | ⏳ |
| H15 | knowledge_graph API mới là cái chậm nhất (>8.7s) | Xem duration của knowledge_graph trong log | ⏳ |
| H16 | Nhiều API đọc song song cộng dồn nghẽn CPU ragflow_server (77.5%) | Đo CPU + thời gian từng API lúc mở KB | ⏳ |

---

## 3f. ROOT CAUSE CHỐT (có bằng chứng số, cụm 9) — API list documents chậm ở tầng APP

### Bằng chứng (log mở KB Voffice, 16:16-16:17):
```
POST ragflow_doc_meta/_search           [status:200 duration:4.865s]   ← ES: 4.8s
POST /api/v1/datasets/{kb}/documents 200 1391 38864185   ← API: 38.86s
POST /api/v1/datasets/{kb}/documents 200 1390 40437134   ← API: 40.44s
GET  /api/v1/datasets/{kb}/documents 200 2027 44368792   ← API: 44.37s
POST /api/v1/datasets/{kb}/documents 200 1390  1400008   ← API: 1.40s
```
(số cuối access log = micro-giây)

### Phân tích:
- ES search: **4.8s** (kéo size:10000 doc metadata) — nhanh tương đối, KHÔNG phải thủ phạm chính.
- API `/documents`: **38-44s** — chênh ~40s so với ES → **RagFlow tiêu ~40s xử lý/serialize 10k bản ghi trong PYTHON**, không phải ở ES.
- Tất cả `status:200` = request THÀNH CÔNG nhưng QUÁ CHẬM. 44s >> 8.7s nginx timeout → browser 502, backend vẫn chạy tiếp cho xong.

### ROOT CAUSE 1 câu:
**API list documents (`/api/v1/datasets/{kb}/documents`) load toàn bộ ~10k document metadata (ES `size:10000` không phân trang) rồi xử lý trong Python ~40s → tổng 44s >> nginx timeout 8.7s → browser nhận 502. KB ít doc (500) thì nhanh 40ms nên không lỗi.**

### Khớp mọi triệu chứng:
- TC1 (click KB nhiều tài liệu → 502): ✅ list 10k doc = 44s.
- TC4 (KB 500 chunks nhanh 40ms): ✅ ít doc → Python xử lý nhoáng.
- "10-15' tự khỏi": cần verify (nghi request chồng chất + CPU nghẽn giãn dần).

### BÁC BỎ các giả thuyết trước:
- ❌ Stale-connection (keepalive 7200): ES duration 3-5ms.
- ❌ Metadata parse error: chỉ là nhiễu từ sync nền, upload vẫn 200.
- ❌ ES query nặng thuần: ES chỉ 4.8s, 40s còn lại ở tầng Python.

| H | Giả thuyết | KẾT QUẢ |
|---|-----------|---------|
| H14 | API list documents chậm ~40s ở tầng Python (không phải ES) | ✅ XÁC NHẬN (44s API vs 4.8s ES) |
| H17 | Nguyên nhân Python chậm: xử lý/serialize 10k doc, hoặc N+1 query, hoặc đếm chunks per doc | ⏳ cần đọc code documents API |

### HƯỚNG FIX (chốt sau khi đọc code):
- F1: Phân trang API list documents (page/size) thay vì load 10k/lần — fix gốc.
- F2: Tối ưu code xử lý Python (bỏ N+1, bỏ đếm chunks per-doc nếu có, cache).
- F3 (giảm đau tạm): tăng nginx proxy_read_timeout > 45s để hết 502 (KHÔNG chữa gốc, vẫn chậm 44s).

---

## 3g. ROOT CAUSE KHẲNG ĐỊNH (bằng chứng CODE) — fetch-all-metadata sau lưng pagination

### Code path (RagFlow 0.24.0):
- Web UI mở KB → `POST /v1/document/list` (`api/apps/document_app.py:224`) → `DocumentService.get_by_kb_id()` (`document_service.py:132`).
- `get_by_kb_id` phân trang SQL ĐÚNG: `docs.paginate(page, size)` (dòng 173) → chỉ 30 doc từ MySQL. ✅
- NHƯNG gắn metadata: gọi `DocMetadataService.get_metadata_for_documents()` (`doc_metadata_service.py:759`).
- Dòng 771: `results = cls._search_metadata(kb_id, condition={"kb_id": kb_id})` → **LUÔN kéo TOÀN BỘ ~10k metadata của KB từ ES** (= `_search size:10000`, 4.8s trong log).
- Dòng 782-789: lặp qua 10k kết quả, mỗi cái `_extract_metadata` (parse JSON) → **~40s Python**. `doc_ids` filter chỉ áp SAU KHI đã kéo hết + parse hết → 99.7% công sức bị vứt.

### Vì sao khớp mọi triệu chứng:
- KB Voffice ~10k doc → kéo+parse 10k metadata = ~40s → 502.
- KB 500 chunks → 500 metadata = vài chục ms → nhanh (khớp TC4: 40ms).
- Chậm TUYẾN TÍNH theo số doc trong KB.

### FIX (chốt):
- **F1 (fix gốc, đúng nhất):** Sửa `get_by_kb_id`/`get_list` truyền **doc_ids của trang hiện tại** vào `get_metadata_for_documents`, VÀ sửa hàm này để `_search_metadata` lọc theo doc_ids ngay ở query ES (`terms doc_id`) thay vì kéo full rồi lọc Python. → chỉ kéo 30 metadata/trang.
- **F2 (giảm đau nhanh, không sửa code):** Tăng nginx `proxy_read_timeout` > 60s để hết 502 (UI vẫn chậm ~44s nhưng không trắng). Tạm thời.
- **F3 (bổ trợ):** cân nhắc cache metadata_map theo KB (TTL ngắn) nếu F1 khó vá nóng.

### Trạng thái: ROOT CAUSE XÁC ĐỊNH XONG. Chuyển sang bàn phương án fix với người vận hành.

---

## 3h. LOẠI TRỪ tầng gateway — 8.7s KHÔNG phải timeout proxy

### Bằng chứng (cụm 10):
- `kubectl get ingress -A` → **No resources found**. KHÔNG có ingress.
- svc ragflow = **NodePort 80:8999** → 8999 chỉ forward TCP (L4), không có HTTP read-timeout.
- nginx pod: `proxy_read_timeout 3600s`, `proxy_send_timeout 3600s` → 1 tiếng, KHÔNG cắt 8.7s.

### Đường request thật:
`browser → 10.208.137.54:8999 (NodePort L4) → nginx pod:80 (3600s) → Flask localhost:9380`

### Phát hiện: RagFlow dùng **Werkzeug dev server** (`app.run()`), KHÔNG phải gunicorn
- `api/ragflow_server.py:151`: `app.run(host, port)` — không set `threaded=`.
- `ps aux`: chỉ 1 process `ragflow_server.py` (PID 29473), không có worker pool.
- Nếu threaded=False → xử lý TUẦN TỰ 1 request/lúc → request 44s BLOCK toàn server → giải thích "click 1 KB cả UI chết".

### ⚠️ CHƯA GIẢI THÍCH DỨT ĐIỂM con số 8.7s:
- Đã loại: nginx pod (3600s), NodePort (L4), ingress (không có).
- 502 đều tăm tắp 8.7s = dấu hiệu 1 timeout CẤU HÌNH, không phải nghẽn ngẫu nhiên.
- Còn nghi: (a) timeout Flask/werkzeug, (b) client axios timeout ở frontend (nhưng client timeout → "canceled" chứ không "502").
- CẦN: đọc nginx access.log trong pod (11a), cmdline process (11b), env timeout (11c), + Timing tab của request 502.

| H | Giả thuyết | KẾT QUẢ |
|---|-----------|---------|
| H18 | 8.7s = timeout gateway/proxy ngoài | ❌ BÁC BỎ (no ingress, NodePort L4, nginx 3600s) |
| H19 | Werkzeug threaded=False → block tuần tự khi 1 request chậm | ⏳ verify threaded default |
| H20 | 8.7s = 1 timeout cấu hình chưa tìm ra (flask/client) | ⏳ đo cụm 11 + Timing tab |
