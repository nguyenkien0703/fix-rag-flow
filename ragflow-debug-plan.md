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

**Kết quả H3:** `__________`

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
