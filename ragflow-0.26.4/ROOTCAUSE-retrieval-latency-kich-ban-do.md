
---

# 10. ✅ BẢN VÁ — phương án (b), đã kiểm chứng trên MySQL production

Kiên chốt phương án **(b)** + yêu cầu **hướng fix lâu dài** (2026-08-18).

## 10.1. File sửa

`ragflow-0.26.4/api/db/services/pipeline_operation_log_service.py` — 49 thêm / 7 xoá.

Tách phần trim ra khỏi `create()` thành `_trim_logs()`, cộng 2 helper advisory lock.

## 10.2. Bốn thay đổi — mỗi cái khử đúng một khiếm khuyết ở §9.3

| # | Khiếm khuyết (§9.3) | Thay đổi trong patch |
|---|---|---|
| 1 | `DB.atomic()` bọc COUNT+SELECT+DELETE | `DB.atomic()` giờ **chỉ bọc INSERT**; trim gọi sau khi transaction đã đóng |
| 2 | `id NOT IN (1000 ids)` không dùng được index | Thay bằng `create_time < cutoff`, với `cutoff` = `create_time` của hàng thứ `limit` (`.limit(1).offset(limit-1)`) — **range predicate trên index** |
| 3 | `COUNT(*)` mỗi document | Vẫn giữ (query rẻ, có index `kb_id`) nhưng **thoát sớm** khi `total <= limit*slack` |
| 4 | N worker song song cùng `kb_id` | `GET_LOCK(name, 0)` — timeout **0**: worker không lấy được lock thì `return` ngay, **không xếp hàng chờ** |

**Biến môi trường mới:** `PIPELINE_OPERATION_LOG_TRIM_SLACK` (mặc định `1.5`)
⟹ chỉ trim khi vượt 1500 thay vì 1000; mỗi lần xoá ~500 dòng
⟹ **tần suất giảm ~500 lần**: từ *mỗi document* xuống *mỗi ~500 document*.

> 💡 Vì sao `GET_LOCK` timeout = **0** chứ không phải > 0: trim là việc **cơ hội**,
> bỏ lỡ một lượt hoàn toàn vô hại vì lượt sau sẽ dọn. Nếu dùng timeout > 0 thì ta chỉ
> **đổi deadlock lấy lock-wait** — đúng thứ đang cần khử.

> 💡 `_try_advisory_lock` trả `True` khi `GET_LOCK` không tồn tại — RAGFlow hỗ trợ cả
> PostgreSQL và OceanBase, patch không được vỡ trên các backend đó.

## 10.3. Kiểm chứng — chạy trên MySQL production, KHÔNG xoá dữ liệu

```
CUTOFF SQL | SELECT `t1`.`create_time` FROM `pipeline_operation_log` AS `t1`
             WHERE (`t1`.`kb_id` = %s) ORDER BY `t1`.`create_time` DESC LIMIT %s OFFSET %s
             args: ['73932b965e5e11f192725fd51894c519', 1, 999]
CUTOFF VAL | 1787044397447
SE XOA     | 0   GIU LAI | 1000   (ky vong giu = 1000)
EXPLAIN    | (1, 'SIMPLE', 'pipeline_operation_log', None, 'ref',
              'pipelineoperationlog_create_time,pipelineoperationlog_kb_id',
              'pipelineoperationlog_kb_id', '130', 'const', 1008, 49.99, 'Using where')
GET_LOCK   | (1,)
RELEASE    | (1,)
```

| Điểm kiểm chứng | Kết quả | Ý nghĩa |
|---|---|---|
| `GIU LAI = 1000` | ✅ | Ngữ nghĩa cũ giữ nguyên, không mất log |
| `SE XOA = 0` | ✅ | **Off-by-one test tự nhiên**: bảng đang đúng 1000 dòng, cutoff = hàng thứ 1000 ⟹ không hàng nào cũ hơn. Khác 0 nghĩa là logic offset lệch |
| `EXPLAIN type=ref, key=...kb_id` | ✅ | **Dùng được index** — khác biệt cốt lõi so với `NOT IN`, vốn phải materialize 1000 phần tử rồi lọc sau khi đã đọc & khoá từng hàng |
| `GET_LOCK → 1` | ✅ | Advisory lock khả dụng trên MySQL này |

> Bảng đã có sẵn index `pipelineoperationlog_create_time` và `pipelineoperationlog_kb_id`.
> MySQL chọn `kb_id` vì lọc theo dataset hẹp hơn. **Không cần thêm composite index.**

## 10.4. Tuỳ chọn chưa đưa vào patch (ghi lại để anh Cường cân nhắc sau)

`SELECT COUNT(*) WHERE kb_id=X` vẫn chạy mỗi document. Query rẻ (bảng nhỏ, có index)
nhưng vẫn là một round-trip DB trên đường nóng của ingest 1.9M docs.
Có thể chỉ chạy COUNT theo xác suất (~12% số lần).

**Cố ý KHÔNG đưa vào patch:** làm code khó hiểu, lợi ích nhỏ so với rủi ro.
Nguyên tắc **không tối ưu thứ chưa đo** — đúng bài học rút suốt 6 phiên.
Chỉ làm nếu sau này COUNT trở thành vấn đề **đo được**.

## 10.5. Triển khai

**Bước 1 — mitigation ngay (không cần build image):**
```bash
kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT=100000000
```
Rollback: `kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT-`
(Kiên xác nhận có thể rollout ngay. Gây rolling restart 3 replica.)

**Bước 2 — build image với patch §10.1, rồi trả `PIPELINE_OPERATION_LOG_LIMIT` về `1000`.**

**Bước 3 — xác nhận đã fix:** chạy lại phép đo Đ17
```bash
kubectl -n ragflow logs -l app.kubernetes.io/component=ragflow -c ragflow -f --tail=0 --max-log-requests=6 > /tmp/db.log 2>&1 &
# ... chạy 5 request retrieval ...
grep -icE "Deadlock found" /tmp/db.log     # kỳ vọng: 0
```
Tiêu chí đạt: **0 dòng deadlock** và latency retrieval ổn định quanh 2-3s (thay vì 2-22s).

---

# 11. ⚠️ CAN THIỆP THỰC TẾ — deadlock KHÔNG phải root cause chính

**Ngày 2026-08-18, sau khi rollout mitigation.**

## 11.1. Can thiệp

```bash
kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT=100000000
kubectl -n ragflow rollout status deployment/ragflow
```
Rollout thành công, 3 pod mới. Xác nhận env đã vào pod:
```
kubectl -n ragflow exec $POD -c ragflow -- printenv PIPELINE_OPERATION_LOG_LIMIT
100000000
```

## 11.2. Kết quả đo sau can thiệp (10 request)

```
Deadlock found:       0        <-- nguyên nhân đã tắt HOÀN TOÀN
Cleaned ... old logs: 0        <-- trim không còn chạy
DB execution failure: (không dòng nào)

10 request: 9.526 8.118 9.974 8.130 11.391 7.887 8.236 5.828 4.989 3.170
```

## 11.3. So sánh trước/sau

| | Trước (10 mẫu, §7) | Sau (10 mẫu) |
|---|---|---|
| min | 3.328 | 3.170 |
| max | **22.290** | **11.391** |
| trung bình | ~10.0 | 7.7 |
| biên độ | **6.7×** | **3.6×** |

## 11.4. 🔴 Kết luận phải sửa

**Deadlock là bug thật, đã fix đúng — nhưng KHÔNG phải root cause chính.**

- Deadlock **có** đóng góp: nó tạo ra các cực trị 20s+. Gỡ đi → đuôi dài bị cắt 22s → 11s,
  biên độ giảm gần một nửa.
- Nhưng **nền ~8s vẫn nguyên vẹn** ⟹ bên dưới còn một nguồn chậm khác,
  **ổn định hơn và lớn hơn**.

> 💡 Giá trị phương pháp: suốt 6 phiên, deadlock đã **làm nhiễu mọi phép đo** — các cực trị
> 20s ngẫu nhiên chen vào khiến không thể nhìn thấy nền 8s ổn định bên dưới. Giờ đo trong
> môi trường đã **bớt một biến nhiễu**, tín hiệu sẽ sạch hơn nhiều.

> ⚠️ **Bài học 0g — "khớp mọi dấu vân tay" KHÔNG đồng nghĩa "là nguyên nhân duy nhất".**
> Ở §9.6 tôi lập bảng cho thấy deadlock khớp cả 7 dấu vân tay đã đo, và kết luận đã tìm ra
> root cause. Bảng đó **không sai** — deadlock thật sự khớp cả 7. Nhưng một nguyên nhân thứ hai
> **cùng bản chất** (chờ I/O, không tốn CPU, không sinh log HTTP) sẽ khớp **y hệt** bộ dấu vân tay đó.
> Dấu vân tay chỉ thu hẹp được **loại** nguyên nhân, không đếm được **số lượng** nguyên nhân.
> Chỉ có **can thiệp** (tắt nguyên nhân, đo lại) mới phân biệt được.

## 11.5. Trạng thái mitigation

**GIỮ NGUYÊN** `PIPELINE_OPERATION_LOG_LIMIT=100000000` để tiếp tục điều tra
trong môi trường không nhiễu. Patch §10 vẫn đúng và vẫn cần build — nhưng
**không được bàn giao như "fix xong issue"**, mà là "fix một trong các nguyên nhân".
