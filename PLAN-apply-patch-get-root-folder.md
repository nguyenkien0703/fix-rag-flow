# PLAN — Áp dụng patch `get_root_folder()` (Issue U1)

> **Trạng thái**: 🔶 Đã sửa chart, **chưa deploy**
> **Ngày soạn**: 10/08/2026
> **Issue gốc**: xem `TRACKING-upload-document-25s.md` (root cause + số liệu đo)
> **Phạm vi**: sửa **1 dòng** code RagFlow qua cơ chế `codePatch` có sẵn trong chart

---

## 0. Tóm tắt — đọc 30 giây

| Hạng mục | Nội dung |
|---|---|
| Sửa gì | `file_service.py:244` — đổi `parent_id == id` thành `name == "/"` |
| Vì sao | So 2 cột cùng dòng không dùng được index → full-scan 631.585 dòng → **18s/lần**, chạy **2 lần/upload** |
| Nhanh hơn bao nhiêu | **18.02s → 0.00s** (đo thật trên production, mục 3.5 TRACKING) |
| Cách áp dụng | `initContainer` + `sed` (cơ chế `codePatch` chart đã có sẵn, **không phải postStart**) |
| Tác động DB | ❌ **Không** — không đổi schema, không sửa dữ liệu, không đánh index |
| Đối tác có cần dừng đẩy dữ liệu? | ❌ **Không cần** |
| Downtime | Restart pod ragflow, ~1-2 phút |
| Rollback | Sửa `values.yaml` bỏ block patch → `helm upgrade`. Image gốc không bị đụng |

---

## 1. Vì sao chọn `initContainer`, KHÔNG chọn `postStart`

*(Kiên hỏi 10/08: "chọn hướng là sed trong postStart hay initContainer?")*

Chart **đã chốt `initContainer` từ trước**, lý do ghi tại `values.yaml:187-190`. Đây là lựa
chọn đúng, giữ nguyên:

| Tiêu chí | `postStart` | `initContainer` ✅ |
|---|---|---|
| Thứ tự chạy | **Song song** với ENTRYPOINT — K8s không đảm bảo cái nào trước | Chạy xong (**exit 0**) mới tới container chính |
| Rủi ro chí mạng | Python có thể **đã import xong file cũ** trước khi sed kịp sửa → patch vô tác dụng nhưng pod vẫn `Running` | Không thể xảy ra — file đã patch chắc chắn có trên đĩa trước khi Python khởi động |
| Patch lỗi thì sao | Pod vẫn `Running` với code chưa patch, **không ai biết** | Pod dừng ở `Init:Error`, thấy ngay |

➡️ Với patch này, `postStart` đặc biệt nguy hiểm: nếu trượt âm thầm thì mình sẽ tưởng đã fix,
báo cáo là xong, trong khi upload vẫn 25s.

### Cơ chế `codePatch` hoạt động thế nào

Đọc từ `templates/ragflow.yaml:46-69` và `109-115`:

```
initContainer "ragflow-code-patch"           (dùng CHÍNH image ragflow)
  ├─ mkdir -p /patched/api/db/services/
  ├─ cp /ragflow/<file>  →  /patched/<file>     ← copy ra chỗ khác, KHÔNG sửa image gốc
  ├─ sed -i '<expr>' /patched/<file>            ← patch trên bản copy
  └─ grep -q '<verify>' /patched/<file>         ← không khớp → exit 1 → Init:Error
         │
         ▼  (emptyDir volume: code-patch-volume)
container chính "ragflow"
  └─ mountPath: /ragflow/<file>  subPath: <file>   ← mount đè bản đã patch lên file gốc
```

Ba điểm thiết kế đáng chú ý:

1. **Không sửa image gốc** — sed chạy trên bản copy trong `emptyDir`, rồi mount đè. Rollback chỉ
   cần bỏ block patch khỏi values, không cần build lại gì
2. **`verify` là lớp an toàn quan trọng nhất** — `sed` **không khớp vẫn trả exit 0**. Không có
   verify thì patch trượt âm thầm. Có verify thì `Init:Error`
3. **Dùng chính image ragflow làm initContainer** — không cần kéo thêm image nào (quan trọng vì
   cluster air-gapped, đã từng dính `ImagePullBackOff` khi migrate MySQL)

---

## 2. Nội dung đã sửa trong chart

**File**: `helm_ragflow_v0.26.4/values.yaml`, mục `ragflow.codePatch.patches`

```yaml
- file: api/db/services/file_service.py
  expr: 's|(cls.model.parent_id == cls.model.id)|(cls.model.name == "/")|'
  verify: 'cls.model.name == "/"'
```

| Thành phần | Ý nghĩa |
|---|---|
| `file` | Đường dẫn tương đối từ `/ragflow/` trong container |
| `expr` | Biểu thức `sed`. Dùng dấu phân cách **`\|`** thay vì `/` vì chuỗi thay thế có chứa `"/"` — dùng `/` sẽ phải escape thành `\/`, dễ sai |
| `verify` | Chuỗi `grep` tìm sau khi patch. Chọn chuỗi **chưa tồn tại** trong file gốc |

Code trước/sau:

```python
# TRƯỚC (dòng 244) — so 2 cột CÙNG 1 DÒNG → không dùng được index → 18s
for file in cls.model.select().where((cls.model.tenant_id == tenant_id), (cls.model.parent_id == cls.model.id)):

# SAU — so cột với HẰNG SỐ → dùng được index → 0.00s
for file in cls.model.select().where((cls.model.tenant_id == tenant_id), (cls.model.name == "/")):
```

---

## 3. Đã kiểm chứng gì TRƯỚC khi sửa chart

Không sửa chart rồi mới thử — 4 việc dưới đây làm trước, tất cả đều pass:

| # | Kiểm chứng | Lệnh | Kết quả |
|---|---|---|---|
| 1 | `name = '/'` có trả đúng 1 dòng không (không trùng) | `SELECT name, COUNT(*) ... GROUP BY name` trên production | ✅ `/` = **1**, `.knowledgebase` = **1** |
| 2 | Nhanh hơn thật không | So `parent_id = id` vs `name = '/'` | ✅ **18.02s → 0.00s** |
| 3 | Chuỗi cần thay có duy nhất không | `grep -c "cls.model.parent_id == cls.model.id"` | ✅ **1** — sed không sửa nhầm chỗ khác |
| 4 | Chuỗi `verify` đã tồn tại sẵn chưa | `grep -c 'cls.model.name == "/"'` | ✅ **0** — verify thực sự có tác dụng |
| 5 | Cú pháp Python còn hợp lệ sau patch | `python3 -c "ast.parse(...)"` trên bản đã sed | ✅ **OK** |
| 6 | Chart render hợp lệ | `helm template` | ✅ Không lỗi YAML, script initContainer đúng |

⭐ **Điểm 4 hay bị bỏ qua**: nếu chuỗi verify đã có sẵn trong file gốc thì `grep -q` **luôn pass**,
kể cả khi `sed` trượt → lớp an toàn thành vô dụng. Chart đã dính đúng lỗi này một lần: comment
`values.yaml:198-200` ghi patch `minimum_should_match` **có thể đã thừa** vì code v0.26 có sẵn.

---

## 4. Các bước triển khai

### Bước 1 — Xem lại diff trước khi apply (node04)

```
git -C /path/to/repo diff helm_ragflow_v0.26.4/values.yaml
```

Kỳ vọng: chỉ thêm 1 block patch mới + comment, **không đụng** gì khác (đặc biệt không đụng
`nodeSelector` của mysql/minio/redis).

### Bước 2 — Ghi lại thời gian upload TRƯỚC khi patch (để đối chiếu)

Bật slow log nếu đã tắt (mất sau mỗi lần restart pod):

```
kubectl -n ragflow exec -it ragflow-mysql-0 -- mysql -uroot -pfini_rag_flow_helm -e "SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 0.1; SET GLOBAL log_output = 'TABLE';"
```

| Thành phần | Ý nghĩa |
|---|---|
| `slow_query_log = 'ON'` | Bật ghi query chậm |
| `long_query_time = 0.1` | Ngưỡng 0.1s — thấp, để bắt cả query nhỏ cộng dồn (mặc định 10s sẽ bỏ sót) |
| `log_output = 'TABLE'` | Ghi vào bảng `mysql.slow_log` để query được bằng SQL, thay vì ghi ra file |

⚠️ `SET GLOBAL` **mất khi pod restart** — mà bước 4 sẽ restart pod ragflow (không phải mysql),
nên setting này vẫn giữ. Nhưng nếu pod mysql restart thì phải bật lại.

### Bước 3 — Apply chart (node04)

```
helm upgrade ragflow /path/to/helm_ragflow_v0.26.4 -n ragflow -f /path/to/helm_ragflow_v0.26.4/values.yaml
```

| Cờ | Ý nghĩa |
|---|---|
| `upgrade ragflow` | Nâng cấp release tên `ragflow` (không tạo mới) |
| `-n ragflow` | Namespace |
| `-f <file>` | Chỉ định values.yaml dùng cho lần upgrade này |

### Bước 4 — Theo dõi initContainer chạy (node04)

⭐ **Đây là bước quan trọng nhất** — nếu patch trượt, pod dừng ở đây:

```
kubectl -n ragflow get pod -l app=ragflow -w
```

| Cờ | Ý nghĩa |
|---|---|
| `-l app=ragflow` | Lọc theo label, tránh liệt kê cả mysql/minio/redis |
| `-w` | `--watch` — theo dõi realtime, Ctrl+C để thoát |

| Trạng thái thấy được | Nghĩa |
|---|---|
| `Init:0/1` → `PodInitializing` → `Running` | ✅ Patch thành công |
| `Init:Error` / `Init:CrashLoopBackOff` | 🔴 **Patch trượt** — sang Bước 4b |

### Bước 4b — Nếu Init:Error, đọc log initContainer (node04)

```
kubectl -n ragflow logs <tên-pod> -c ragflow-code-patch
```

| Cờ | Ý nghĩa |
|---|---|
| `-c ragflow-code-patch` | Chỉ định **container nào** trong pod. Không có cờ này sẽ đọc log container chính (chưa chạy) |

Kỳ vọng thấy dòng: `PATCH FAILED: api/db/services/file_service.py khong khop pattern`

→ Nghĩa là chuỗi trong image thật khác với bản v0.26.4 đã đối chiếu. **Rollback ngay** (mục 6),
không sửa mò.

### Bước 5 — Xác minh patch đã thật sự vào code (node04)

Không tin pod `Running` là đủ — kiểm tra trực tiếp file trong container:

```
kubectl -n ragflow exec -it <tên-pod> -c ragflow -- grep -n 'cls.model.name == "/"' /ragflow/api/db/services/file_service.py
```

Kỳ vọng: ra **1 dòng**, số dòng khoảng 244.

Kiểm tra chuỗi cũ đã biến mất:

```
kubectl -n ragflow exec -it <tên-pod> -c ragflow -- grep -c "cls.model.parent_id == cls.model.id" /ragflow/api/db/services/file_service.py
```

Kỳ vọng: **0**.

### Bước 6 — Đo kết quả thật: upload 1 file qua UI

Upload 1 file test qua giao diện, bấm giờ. Sau đó kiểm tra slow log:

```
kubectl -n ragflow exec -it ragflow-mysql-0 -- mysql -uroot -pfini_rag_flow_helm -e "SELECT start_time, query_time, rows_examined FROM mysql.slow_log WHERE rows_examined > 600000 ORDER BY start_time DESC LIMIT 5;"
```

| Kết quả | Nghĩa |
|---|---|
| **Không có dòng mới** sau thời điểm upload | ✅ Patch có tác dụng — không còn full-scan 631k dòng |
| Vẫn có dòng mới `rows_examined ~631585` | 🔴 Patch không tác dụng dù grep thấy — điều tra tiếp |

---

## 5. Kỳ vọng kết quả

| Chỉ số | Trước | Sau (kỳ vọng) |
|---|---|---|
| `get_root_folder` mỗi lần | 18.02s | ~0.00s |
| Số lần chạy mỗi upload | 2 | 2 (**không đổi** — chưa làm phương án bỏ lời gọi thừa) |
| Tổng thời gian tìm thư mục gốc | ~36s | ~0s |
| Bước "Upload document" khách hàng báo | 25s | ❓ **chưa đo được** — cần đo lại thực tế |

⚠️ **Không hứa trước con số cuối.** Bước upload 25s còn gồm MinIO PUT, sinh thumbnail, ghi
`document`/`file2document`. Patch này chỉ gỡ phần MySQL full-scan. Phải đo lại rồi mới báo.

⚠️ **Tổng 55s sẽ KHÔNG giảm hết** — 4 bước còn lại (LLM tóm tắt 10s, Update metadata 8s, Parse
chunk 6s, Check tồn tại 6s) chưa được trace, là việc riêng.

---

## 6. Rollback

Nhanh, không mất dữ liệu, vì image gốc không bị sửa:

**Cách 1 — bỏ đúng patch này** (giữ patch `minimum_should_match`): xoá block
`- file: api/db/services/file_service.py` khỏi `values.yaml` → `helm upgrade` lại.

**Cách 2 — tắt toàn bộ cơ chế patch**: `codePatch.enabled: false` → `helm upgrade`.
⚠️ Cách này bỏ luôn patch `minimum_should_match` đang chạy — chỉ dùng khi nghi ngờ chính cơ chế.

Sau rollback, pod restart và dùng lại code gốc trong image. **Không cần đụng database.**

---

## 7. Rủi ro còn lại

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Chuỗi trong image production khác bản v0.26.4 đã đối chiếu | Thấp | `verify` bắt được → `Init:Error`, không chạy sai âm thầm |
| Về sau xuất hiện dòng trùng `name = '/'` do race condition | Thấp | Hiện `COUNT(*)` = 1. Code v0.26.4 có logic dedup cho `.knowledgebase` (dòng 79) → chuyện trùng **có thật** với thư mục khác, cần theo dõi định kỳ |
| Tenant mới chưa có root folder | Rất thấp | Code có sẵn nhánh tự tạo khi không tìm thấy (dòng 246-259), hành vi giữ nguyên |
| ❓ Chưa xác minh tên index cụ thể trên `file.name` | Thấp | Suy từ `0.00 sec` trên bảng 631k dòng. Chạy `SHOW INDEX FROM file` nếu muốn chắc |
| Chưa test ở non-prod | **Trung bình** | Môi trường hiện không có non-prod tương đương. Bù lại bằng: verify + rollback nhanh + đo lại sau khi apply |

---

## 8. Việc chưa làm (cố ý)

- [ ] **Phương án (a) — bỏ lời gọi trùng lặp** (2 lần → 1 lần): Kiên chốt 10/08 **chưa làm**, vì
      sau patch này mỗi lần chỉ còn ~0.00s nên gọi 2 lần cũng không đáng kể. Giữ lại làm việc
      tối ưu về sau nếu cần
- [ ] **Phương án (b) — cache id thư mục gốc**: không cần nữa sau khi có (d)
- [ ] Báo issue lên upstream RagFlow (branch `main` vẫn còn lỗi này)
- [ ] Trace 4 bước còn lại của flow 55s
