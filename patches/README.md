# Patches — RAGFlow v0.26.4

## 0001-fix-pipeline-log-deadlock.patch

**Vấn đề:** MySQL deadlock liên tục từ khối trim `pipeline_operation_log`,
góp phần gây latency không ổn định cho `/api/v1/retrieval` (cực trị 20s+).

**File sửa:** `api/db/services/pipeline_operation_log_service.py` (1 file, +49/-7)

### Áp patch

```bash
cd <thu-muc-source-ragflow-v0.26.4>
git apply --check patches/0001-fix-pipeline-log-deadlock.patch   # thử trước, không ghi gì
git apply         patches/0001-fix-pipeline-log-deadlock.patch   # áp thật
```

Nếu `--check` báo lỗi (source đã bị sửa khác đi), dùng:
```bash
git apply --3way patches/0001-fix-pipeline-log-deadlock.patch
```

### Nội dung sửa

| # | Trước | Sau |
|---|---|---|
| 1 | `DB.atomic()` bọc cả `COUNT` + `SELECT` + `DELETE` | `DB.atomic()` chỉ bọc `INSERT`; trim chạy sau khi transaction đã đóng |
| 2 | `WHERE id NOT IN (1000 ids)` — không dùng được index, khoá toàn range `kb_id` | `WHERE create_time < cutoff` — range predicate **dùng index**; `cutoff` = `create_time` của hàng thứ `limit` |
| 3 | Trim chạy **mỗi document** parse xong | Chỉ trim khi `total > limit * slack` (mặc định 1.5) → tần suất giảm ~500 lần |
| 4 | N worker song song cùng chạy DELETE trên cùng `kb_id` | `GET_LOCK(name, 0)` — worker không lấy được lock thì `return` ngay, **không xếp hàng chờ** |

Giữ **nguyên ngữ nghĩa** "keep latest N logs per dataset".

### Biến môi trường

| Biến | Mặc định | Ghi chú |
|---|---|---|
| `PIPELINE_OPERATION_LOG_LIMIT` | `1000` | Đã có sẵn, không đổi |
| `PIPELINE_OPERATION_LOG_TRIM_SLACK` | `1.5` | **MỚI** — chỉ trim khi vượt `limit × slack` |

### Tương thích

`_try_advisory_lock()` trả `True` khi `GET_LOCK` không tồn tại
⟹ không vỡ trên PostgreSQL / OceanBase.

### Đã kiểm chứng trên MySQL production (không xoá dữ liệu)

```
GIU LAI  = 1000    -> ngữ nghĩa cũ giữ nguyên
SE XOA   = 0       -> off-by-one test pass (bảng đang đúng 1000 dòng)
EXPLAIN  -> type=ref, key=pipelineoperationlog_kb_id   -> DÙNG INDEX
GET_LOCK -> 1      -> advisory lock khả dụng
```

### Verify sau khi deploy image mới

```bash
# 1. Trả biến về mặc định (gỡ workaround)
kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT=1000

# 2. Bắt log + chạy request
kubectl -n ragflow logs -l app.kubernetes.io/component=ragflow -c ragflow -f --tail=0 --max-log-requests=6 > /tmp/verify.log 2>&1 &
LOGPID=$!
sleep 2
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "$i http=%{http_code} TONG=%{time_total}\n" -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY_ON"
done
sleep 3; kill $LOGPID

# 3. Tiêu chí đạt
grep -icE "Deadlock found" /tmp/verify.log     # kỳ vọng: 0
grep -icE "Cleaned .* old logs" /tmp/verify.log # > 0 là bình thường (trim vẫn hoạt động, chỉ thưa hơn)
```

> ⚠️ **Patch này KHÔNG giải quyết hết issue latency.**
> Can thiệp thực tế (đặt `PIPELINE_OPERATION_LOG_LIMIT=100000000`) cho thấy:
> deadlock về 0 nhưng latency vẫn 3.2–11.4s. Deadlock chỉ tạo **cực trị 20s+**;
> còn một nguyên nhân thứ hai gây **nền ~8s**.
> Xem `ROOTCAUSE-retrieval-latency-kich-ban-do.md` §11 và §12.

## Workaround tạm thời (không cần build image)

```bash
kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT=100000000
```
Vô hiệu hoá khối trim ⟹ hết deadlock ngay.
**Đánh đổi:** bảng `pipeline_operation_log` phình ra không được dọn.
Gỡ bỏ: `kubectl -n ragflow set env deployment/ragflow PIPELINE_OPERATION_LOG_LIMIT-`

**Hiện trạng:** đang BẬT trên production (rollout 2026-08-18) để điều tra
nguyên nhân #2 trong môi trường không nhiễu.
