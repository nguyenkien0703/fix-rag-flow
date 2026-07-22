# RagFlow — Giải thích: "Chậm rồi tự bình thường" (stale connection tới ES Lakehouse)

> Tài liệu giải thích root cause cho triệu chứng 1/2/3 (UI trống / API chết / up file chờ 10').
> Bối cảnh: RagFlow trên K8s, doc engine = **ES Lakehouse Viettel** `https://10.211.145.107:8051` (ngoài cluster).
> Ngày: 2026-07-22

---

## 1/ Cái "chậm rồi tự bình thường" thực chất là gì?

**Hiện tượng:** Vào UI KB "Voffice doc sum" sau một lúc không dùng → API treo, UI trống → chờ ~10 phút → tự nhiên chạy lại bình thường mà **không ai làm gì cả**.

**Điểm mấu chốt để phân biệt với "query chậm":**

- **Query chậm** (triệu chứng 4) = **lần nào cũng chậm** ~30s, vì ES phải quét 120k chunks. Chậm *ổn định, lặp lại được*.
- **Cái này khác hẳn:** lần đầu sau khi idle thì **chết cứng ~10 phút, sau đó nhanh trở lại**. Chậm *một lần rồi hết*. Đây là dấu hiệu kinh điển của **connection chết**, không phải xử lý chậm.

**Số liệu chứng minh:**

| Trạng thái | Lệnh đo | Kết quả |
|---|---|---|
| Connection **ấm** (vừa dùng) | curl tới ES Lakehouse | `total = 0.021s` (21ms) — **cực nhanh** |
| ES Lakehouse có yếu không? | cùng lệnh | `http=200`, **khỏe mạnh** |

→ ES Lakehouse **không hề chậm**. Nó trả lời trong 21ms. Vậy 10 phút treo kia **không phải do ES xử lý lâu**. Nó là thời gian RagFlow **ngồi chờ một connection đã chết mà nó tưởng còn sống**.

**Issue (một câu):** Connection giữa RagFlow và ES Lakehouse bị **chết trong lúc nhàn rỗi**, nhưng RagFlow không biết nó chết, nên request đầu tiên sau đó phải chờ rất lâu (tới khi hệ điều hành bỏ cuộc) rồi mới mở connection mới.

---

## 2/ Connection pool, idle, và con số 7200 — giải thích từ gốc

### Lớp 1: "Connection" là gì và vì sao phải giữ lại (pool)

Mỗi lần RagFlow muốn hỏi ES Lakehouse, nó phải mở một **kết nối TCP** — như gọi điện thoại: quay số, đổ chuông, bắt máy ("bắt tay 3 bước" — TCP handshake). Tốn thời gian, với HTTPS còn thêm bước mã hóa (TLS handshake).

Nếu mỗi query đều mở connection mới rồi đóng → lãng phí. Nên RagFlow (qua thư viện `elasticsearch-py`) giữ sẵn một **bể connection đã mở** = **connection pool**. Query xong không đóng, giữ lại cho lần sau. Giống giữ cuộc gọi không cúp máy để lần sau nói tiếp, khỏi quay số lại.

```
RagFlow  ──[connection 1: đang giữ mở]──►  ES Lakehouse
         ──[connection 2: đang giữ mở]──►
         ──[connection 3: đang giữ mở]──►   ← đây là "pool"
```

### Lớp 2: Vấn đề — có "người thứ ba" giữa hai đầu

RagFlow ở trong cluster K8s (mạng `10.208.x`). ES Lakehouse ở mạng khác (`10.211.x`), do tập đoàn Viettel quản. Giữa hai mạng có một **firewall / NAT gateway** — cổng kiểm soát mọi traffic đi qua.

```
RagFlow (10.208.x) ──► [ FIREWALL Viettel ] ──► ES Lakehouse (10.211.x)
```

Firewall này có luật phổ biến: **"connection nào không có traffic trong X phút thì xóa khỏi bảng theo dõi"** (idle timeout). Vấn đề chí mạng: khi xóa, firewall thường **KHÔNG báo cho hai đầu biết**. Nó **lặng lẽ cắt**.

```
Bước 1: RagFlow và ES đang giữ connection, nhưng không có query nào (idle)
Bước 2: Sau ~vài phút, firewall âm thầm xóa connection này khỏi bảng
        → RagFlow KHÔNG biết. ES KHÔNG biết. Cả hai vẫn tưởng "đường dây còn thông".
Bước 3: RagFlow có query mới → gửi vào connection cũ (mà nó tưởng còn sống)
        → Gói tin tới firewall → firewall không còn nhớ connection này → gói tin RƠI vào hư không
        → RagFlow không nhận được trả lời...
```

### Lớp 3: Vì sao chết tới ~10 PHÚT chứ không phải chết ngay?

Khi gửi gói tin mà không nhận được trả lời, TCP **không bỏ cuộc ngay** — nó nghĩ "chắc mạng nghẽn tạm thời" và **gửi lại** (retransmit), chờ, gửi lại, chờ lâu hơn... theo cấp số nhân. Thử tới ~15 lần trong khoảng **~10-15 phút** trước khi kết luận "connection chết thật" và báo lỗi. Lúc đó RagFlow mới mở connection mới → mọi thứ bình thường trở lại.

**Đó chính xác là 10 phút bạn thấy.** Không phải ES chậm. Là hệ điều hành đang kiên nhẫn gửi lại gói tin vào một connection đã chết.

### Lớp 4: 7200 là gì và vì sao nó là thủ phạm

TCP có cơ chế **phòng bệnh** = **keepalive**: định kỳ gửi một gói nhỏ "mày còn sống không?" để **giữ connection luôn có traffic** → firewall thấy có traffic thì không cắt.

Con số đo được:
```
keepalive_time = 7200   ← chờ 7200 giây = 2 TIẾNG idle rồi mới gửi gói keepalive đầu tiên
```

**Đây là gốc rễ.** Linux mặc định chỉ bắt đầu "hỏi thăm sức khỏe" sau **2 tiếng** không hoạt động. Nhưng firewall Viettel cắt idle sau **vài phút**:

```
Phút 0:   query xong, connection idle
Phút ~5:  firewall cắt connection (âm thầm)
Phút ~5-120: RagFlow vẫn im lặng, keepalive CHƯA chạy (phải chờ tới phút 120)
            → connection đã chết mà không ai probe để phát hiện
→ Query tiếp theo đâm vào connection chết → treo 10 phút
```

Keepalive sinh ra chính xác để chống bệnh này, nhưng bị hẹn giờ **2 tiếng** — quá muộn, firewall đã cắt từ đời nào. **Fix = kéo con số này xuống** (vd 120s) để RagFlow gửi "mày còn sống không?" mỗi 2 phút → firewall luôn thấy traffic → không bao giờ cắt → connection không bao giờ chết.

### Insight
- **Query chậm** = xử lý lâu (CPU/scan nhiều dữ liệu). **Connection chết** = ngồi chờ mạng. Hai loại "chậm" khác nhau; số liệu 21ms chứng minh triệu chứng 1/2/3 thuộc loại thứ hai.
- Firewall cắt idle **không gửi tín hiệu** là điểm ác nhất — nếu nó gửi RST ("đường dây đã cắt"), RagFlow biết ngay và reconnect trong 1ms. Chính vì cắt *lặng lẽ* nên mới treo 10 phút.
- Keepalive 7200s là mặc định Linux cho use-case thông thường (server nội bộ). Nó **sai** cho use-case "đi xuyên firewall doanh nghiệp" — đây là lỗi **cấu hình môi trường**, không phải lỗi code RagFlow.

---

## 3/ Ba lệnh đọc chart làm gì (đều CHỈ ĐỌC, không sửa)

```bash
cd /home/app/app/ragflow-0.24.0/helm
```
→ Đi vào thư mục chứa Helm chart của RagFlow (có `values.yaml`, `templates/`). `cd` = change directory. Chỉ di chuyển.

```bash
grep -vE '^\s*#|^\s*$' values.yaml
```
→ In `values.yaml` nhưng **lọc bỏ dòng comment (`#`) và dòng trống** cho gọn. `grep -v` = in dòng KHÔNG khớp. Chỉ đọc.

```bash
ls -la templates/
```
→ Liệt kê file trong `templates/` (nơi Helm chứa file mô tả K8s: deployment, service...). Cần biết file nào định nghĩa pod ragflow-server — đó là chỗ thêm cấu hình keepalive. Chỉ đọc.

**Vì sao cần 2 file này:** để biết fix keepalive **đặt vào đâu**. RagFlow deploy bằng Helm → config sống trong `values.yaml` + `templates/`. Muốn hạ `keepalive_time` 7200→120 **bền vững** (không mất khi restart pod), phải sửa đúng file trong chart, không gõ lệnh tạm vào pod. Đọc để biết chart cho set kiểu nào (initContainer? securityContext.sysctls? env client?).
