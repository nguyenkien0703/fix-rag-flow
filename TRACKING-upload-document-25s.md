# TRACKING — Fix issue upload document 25s (flow 55s/văn bản của đối tác)

**Phiên:** 10/08/2026
**Đối tượng:** flow `upload_document` của RagFlow, MySQL trên node06 (đã migrate 07/08)
**Trạng thái phiên:** 🔶 ĐANG DỞ — **đã tìm ra root cause có bằng chứng đo thực tế**, chưa thực thi fix
**Task liên quan:** `TRACKING-mysql-load-assessment.md` (Issue 1, Issue 7), `PLAN-mysql-migrate-node06.md`

---

## 1. Mục tiêu

Tìm root cause và hướng xử lý cho bước "Upload document 25s" trong feedback của đối tác:

| Bước | Thời gian đối tác đo |
|---|---|
| 1. Check tồn tại | 6s |
| 2. Gọi LLM tóm tắt | 10s |
| 3. **Upload document** | **25s** ← mục tiêu phiên này |
| 4. Update metadata | 8s |
| 5. Parse chunk | 6s |
| **Tổng** | **55s/vb** |

### Bối cảnh

| Hạng mục | Giá trị | Nguồn |
|---|---|---|
| MySQL | `ragflow-mysql-0`, node06 (`vrp-kubeengine06`) | đã migrate 07/08 |
| Source code tra cứu | `ragflow-0.24.0/` (có sẵn trong repo) | ⚠️ production chạy chart `v0.26.4` — chưa xác minh code có đổi giữa 2 version |
| Bảng `file` | ~631,585 dòng (theo `rows_examined` của full scan) | slow log 10/08 |
| Bảng `document` | ~395,137 dòng | `COUNT(*)` đo 07/08 |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| U1 | `get_root_folder()` dùng `WHERE parent_id = id` (so cột với cột) → MySQL **không dùng được index** → full scan 631,585 dòng, **18s/lần**, chạy **≥2 lần mỗi upload** | 🔴 Rất cao | 🔶 OPEN — root cause đã xác nhận | Root cause ở **code app**, ngoài phạm vi (chỉ sửa qua values.yaml/helm) → báo đội dev. Xem mục 4 để biết các hướng khả dĩ |
| U2 | Query này đã chạy **783,945 lần**, tích luỹ **838 giờ 59 phút** CPU MySQL | 🔴 Rất cao | 🔶 OPEN | Hệ quả trực tiếp của U1 |

**Kết luận chung:** 25s của bước "Upload document" **không phải** do MinIO/thumbnail/INSERT như suy
luận ban đầu, mà do **1 câu SELECT full-scan bảng `file` chạy lặp lại**. Đây là bug thiết kế query
trong code RagFlow, không phải vấn đề cấu hình MySQL hay hạ tầng.

---

## 3. Lệnh đã chạy + output (bằng chứng)

### 3.1 Bật slow log ngưỡng thấp để bắt cả query nhỏ

```sql
SET GLOBAL slow_query_log = 'ON';
```
```sql
SET GLOBAL long_query_time = 0.1;
```
```sql
SET GLOBAL log_output = 'TABLE';
```

| Tham số | Ý nghĩa |
|---|---|
| `long_query_time = 0.1` | Ngưỡng 0.1s thay vì 1s như các phiên trước — vì flow upload có 13 bước tuần tự, mỗi bước có thể chỉ vài trăm ms nhưng **cộng dồn** mới thành 25s. Ngưỡng cao sẽ bỏ sót |
| `log_output = 'TABLE'` | Ghi vào bảng `mysql.slow_log` để query được bằng SQL |

⚠️ **Đây là `SET GLOBAL` → mất khi pod restart** (đã bị mất 2 lần trước: sau scale về 0 ở migrate,
và sau `helm upgrade`). Cùng nợ kỹ thuật với Issue 5 của `TRACKING-mysql-load-assessment.md`.

### 3.2 Xem 20 query gần nhất (cắt ngắn để không tràn màn hình)

```sql
SELECT start_time, query_time, rows_examined, LEFT(CONVERT(sql_text USING utf8), 80) AS query_short FROM mysql.slow_log ORDER BY start_time DESC LIMIT 20;
```

| Thành phần | Ý nghĩa |
|---|---|
| `LEFT(..., 80)` | Chỉ lấy 80 ký tự đầu — **bắt buộc**, vì có câu `DELETE ... NOT IN (hàng nghìn id)` dài hàng chục nghìn ký tự làm tràn màn hình (đã gặp ở lần chạy đầu) |
| `CONVERT(sql_text USING utf8)` | `sql_text` lưu dạng hex blob, không convert thì không đọc được |

**Output (trích, lúc 12:29 ngày 10/08 — đúng thời điểm upload file test):**

```
| start_time          | query_time | rows_examined | query_short                                    |
| 2026-08-10 12:29:08 | 00:00:17.083502 |    630,774 | SELECT t1.id, t1.create_time, t1.create_date... |
| 2026-08-10 12:29:08 | 00:00:19.414252 |    630,769 | SELECT t1.id, t1.create_time, t1.create_date... |
| 2026-08-10 12:29:08 | 00:00:19.138855 |    630,773 | SELECT t1.id, t1.create_time, t1.create_date... |
| 2026-08-10 12:29:09 | 00:00:00.118184 |          1 | UPDATE document SET update_time = ...           |
| 2026-08-10 12:29:08 | 00:00:00.172380 |          1 | SELECT GET_LOCK('update_progress', -1)          |
| 2026-08-10 12:29:07 | 00:00:00.529593 |      2,001 | SELECT t1.id FROM pipeline_operation_log ...     |
| 2026-08-10 12:29:06 | 00:00:00.102054 |          0 | INSERT INTO file2document ...                    |
| 2026-08-10 12:29:06 | 00:00:00.170363 |          0 | INSERT INTO file ...                             |
```

**Đọc được gì:** 3 câu 17-19s với `rows_examined` ~630,770 xuất hiện **cùng lúc** (12:29:08) — đây
là thủ phạm. Các câu còn lại (INSERT `file`, INSERT `file2document`, UPDATE `document`) đều **rất
nhanh** (0.1-0.2s, `rows_examined` 0-1) → loại trừ khả năng INSERT/UPDATE là nút thắt.

### 3.3 Gom nhóm để thấy quy mô tích luỹ

```sql
SELECT COUNT(*) AS so_lan, SEC_TO_TIME(SUM(TIME_TO_SEC(query_time))) AS tong_thoi_gian, MAX(query_time) AS lau_nhat, LEFT(CONVERT(sql_text USING utf8), 60) AS query_short FROM mysql.slow_log GROUP BY query_short ORDER BY SUM(TIME_TO_SEC(query_time)) DESC LIMIT 15;
```

| Thành phần | Ý nghĩa |
|---|---|
| `GROUP BY query_short` | Gom câu giống nhau thành 1 dòng — thay vì đọc hàng trăm nghìn dòng riêng lẻ |
| `SUM(TIME_TO_SEC(query_time))` | **Tổng** thời gian tích luỹ — quan trọng hơn thời gian 1 lần: query 0.5s chạy 100 lần (50s) tệ hơn query 5s chạy 1 lần |
| `SEC_TO_TIME(...)` | Đổi tổng số giây về dạng `HH:MM:SS` cho dễ đọc |
| `ORDER BY SUM(...) DESC` | Thủ phạm ngốn nhiều thời gian nhất nằm đầu |

**Output (trích 8 dòng đầu):**

```
| so_lan  | tong_thoi_gian | lau_nhat        | query_short                                      |
| 783,945 | 838:59:59      | 00:01:25.264007 | SELECT t1.id, t1.create_time, t1.create_date, t  |
| 106,995 | 196:05:16      | 00:01:48.664407 | SELECT COUNT(t1.id) FROM task AS t1 INNER JOIN   |
|  77,747 | 60:59:09       | 00:01:21.137074 | DELETE FROM pipeline_operation_log WHERE ((pipe  |
|  14,192 | 09:46:39       | 00:00:43.817487 | INSERT INTO pipeline_operation_log (id, create_  |
|     311 | 01:27:16       | 00:01:08.671231 | SELECT t1.id, t1.process_begin_at, t1.parser_conf|
|     159 | 00:37:47       | 00:05:36.502796 | SELECT COUNT(1) FROM (SELECT 1 FROM document ... |
|      82 | 00:29:00       | 00:02:10.624483 | SELECT t1.id, t1.thumbnail, t1.kb_id, t1.pars    |
|      67 | 00:15:12       | 00:01:07.389314 | SELECT t1.run, t1.suffix, t1.id FROM document    |
```

**Đọc được gì:**
- Dòng 1 (**783,945 lần / 838 giờ**) là cùng câu với 3 dòng 17-19s ở mục 3.2 → đây là query ngốn
  nhiều thời gian nhất toàn hệ thống, bỏ xa mọi thứ khác
- `lau_nhat: 1 phút 25 giây` — có lần chạy lên tới 85 giây
- Dòng 6 (`SELECT COUNT(1) FROM (SELECT 1 FROM document...`) chính là **Issue 7** đã ghi ở
  `TRACKING-mysql-load-assessment.md` (`get_filter_by_kb_id`) — vẫn còn đó, chưa fix
- Dòng 7 (`SELECT t1.id, t1.thumbnail, t1.kb_id, t1.pars...`) là query list document đã fix bằng
  index ở Issue 1 — giờ chỉ còn 82 lần/29 phút, không còn nằm top

### 3.4 Lấy full text câu SQL thủ phạm

```sql
SELECT query_time, rows_examined, CONVERT(sql_text USING utf8) AS query FROM mysql.slow_log WHERE rows_examined > 600000 ORDER BY start_time DESC LIMIT 1\G
```

| Thành phần | Ý nghĩa |
|---|---|
| `WHERE rows_examined > 600000` | Lọc đúng nhóm query 630k dòng, bỏ qua query nhỏ |
| `\G` thay `;` | Hiển thị **dọc** (mỗi cột 1 dòng) thay vì bảng ngang — cách duy nhất đọc được câu SQL dài mà không bị cắt |

**Output:**

```
query_time: 00:00:18.028771
rows_examined: 631585
query: SELECT `t1`.`id`, `t1`.`create_time`, `t1`.`create_date`, `t1`.`update_time`,
       `t1`.`update_date`, `t1`.`parent_id`, `t1`.`tenant_id`, `t1`.`created_by`,
       `t1`.`name`, `t1`.`location`, `t1`.`size`, `t1`.`type`, `t1`.`source_type`
       FROM `file` AS `t1`
       WHERE ((`t1`.`tenant_id` = '22cdb01e486a11flac9749e86cfe939a')
          AND (`t1`.`parent_id` = `t1`.`id`))
```

---

## 4. Issue chi tiết

### 🔴 Issue U1 — `get_root_folder()` full-scan bảng `file` do so sánh cột với cột — 🔶 OPEN

**Triệu chứng**

Bước "Upload document" mất 25s (đối tác báo). Slow log bắt được 3 câu SELECT trên bảng `file`,
mỗi câu **17-19 giây**, `rows_examined` ~630,770, xảy ra cùng thời điểm upload.

**Root cause (đã xác nhận bằng cả slow log lẫn đọc source code)**

Câu SQL có điều kiện:
```sql
WHERE (t1.tenant_id = '22cdb01e...') AND (t1.parent_id = t1.id)
```

`t1.parent_id = t1.id` là **so sánh 2 cột của cùng một dòng**. MySQL **không thể dùng index** cho
kiểu so sánh này — index B-tree chỉ tra được khi so cột với **giá trị hằng** (`WHERE col = 'abc'`),
không so được cột với cột. Hệ quả: MySQL buộc phải đọc từng dòng của bảng `file` (631,585 dòng)
rồi tự kiểm tra `parent_id == id` trên mỗi dòng → full table scan, không có cách nào tránh được
bằng đánh index.

**Bằng chứng — nguồn code**

`ragflow-0.24.0/api/db/services/file_service.py` dòng 222-231:

```python
@classmethod
@DB.connection_context()
def get_root_folder(cls, tenant_id):
    # Get or create root folder for tenant
    for file in cls.model.select().where(
        (cls.model.tenant_id == tenant_id),
        (cls.model.parent_id == cls.model.id)      # <-- so cột với cột, không dùng được index
    ):
        return file.to_dict()
    ...
```

**Tệ hơn: chạy ≥2 lần mỗi upload.** `get_kb_folder()` (dòng 249-261) gọi lại `get_root_folder()`:

```python
def get_kb_folder(cls, tenant_id):
    root_folder = cls.get_root_folder(tenant_id)    # <-- gọi lại lần 2
    root_id = root_folder["id"]
    ...
```

Và `upload_document()` (dòng 431-435) gọi cả hai:

```python
def upload_document(self, kb, file_objs, user_id, src="local", parent_path=None):
    root_folder = self.get_root_folder(user_id)      # lần 1  (dòng 432)
    pf_id = root_folder["id"]
    self.init_knowledgebase_docs(pf_id, user_id)     # (cần tra thêm — có thể gọi tiếp)
    kb_root_folder = self.get_kb_folder(user_id)     # lần 2, bên trong lại gọi get_root_folder (dòng 435)
```

→ Khớp chính xác với việc slow log bắt được **3 câu cùng lúc 12:29:08** (không phải 1) — nghĩa là
thực tế còn nhiều hơn 2 lần. ❓ **Chưa xác minh**: `init_knowledgebase_docs()` (dòng 294) có gọi
tiếp `get_root_folder` hay không — chưa đọc hàm này, cần đọc để giải thích đủ 3 lần.

**Bằng chứng — quy mô tích luỹ**

Từ query gom nhóm (mục 3.3): query này chạy **783,945 lần**, tổng **838 giờ 59 phút** — gấp hơn 4
lần query đứng thứ hai. Đây là nguồn tải MySQL lớn nhất của toàn hệ thống.

**Đã thử / cân nhắc**

| Phương án | Kết quả |
|---|---|
| Suy luận "25s là do MinIO PUT + thumbnail CPU" (từ đọc code flow, trước khi đo) | ❌ **Sai** — slow log cho thấy 3 câu MySQL 17-19s chiếm gần hết 25s. INSERT `file`/`file2document` chỉ 0.1-0.2s |
| Nghi ngờ `duplicate_name(kb_id, name)` (Issue 1b của tracking cũ) | ❌ **Đã loại từ trước** — `EXPLAIN` cho `rows: 1`, dùng index `document_name`, không phải nút thắt |
| Đánh composite index để fix | ❌ **Không khả thi** — `parent_id = id` là so cột với cột, **không index nào dùng được**. Đây là điểm khác biệt căn bản so với Issue 1 (fix được bằng index) |
| Bật slow log `long_query_time = 1` (như các phiên trước) | ⚠️ Không đủ — nhiều bước nhỏ dưới 1s bị bỏ sót. Phải hạ xuống `0.1` mới thấy toàn cảnh |
| Đọc slow log bằng `SELECT ... sql_text` không cắt ngắn | ❌ Tràn màn hình vì câu `DELETE ... NOT IN (nghìn id)`. Phải dùng `LEFT(..., 80)` hoặc `\G` |

**Còn tồn đọng nếu để nguyên**

- Mỗi lần upload 1 văn bản tốn ≥2 lần full-scan 631k dòng → 25s/văn bản không giảm được
- Bảng `file` càng lớn thì càng chậm tuyến tính — đối tác đẩy càng nhiều dữ liệu, càng tệ
- Chiếm CPU MySQL liên tục (838 giờ tích luỹ), ảnh hưởng cả các query khác trên cùng instance

**Hướng xử lý tiếp**

Root cause nằm ở **code app RagFlow**, ngoài phạm vi dự án hiện tại (ràng buộc: chỉ sửa qua
`values.yaml` + Helm, không sửa code app — xem memory `ragflow-deploy-constraints.md`). Cần báo
đội phát triển RagFlow / team quản lý source.

Các hướng khả dĩ (để tham khảo khi báo, **chưa đánh giá khả thi trên production**):

1. **Sửa query để dùng được index** — root folder là dòng có `parent_id = id`; có thể thay bằng
   điều kiện dùng hằng số, ví dụ đánh dấu bằng cột riêng (`is_root = 1`) hoặc quy ước `parent_id
   IS NULL` thay vì trỏ về chính nó. Cần đội dev quyết định vì ảnh hưởng schema.
2. **Cache kết quả `get_root_folder(tenant_id)`** — root folder của 1 tenant gần như không đổi,
   không cần query lại mỗi lần upload. Đây là fix rẻ nhất về mặt schema.
3. **Bỏ lời gọi trùng lặp** — `get_kb_folder()` đã gọi `get_root_folder()` bên trong, nhưng
   `upload_document()` vẫn gọi riêng thêm 1 lần ở dòng 432 → truyền kết quả xuống thay vì gọi lại.
4. ❓ **Cần xác minh trước khi đề xuất**: hàm này có đổi ở version 0.26.4 (production) so với
   0.24.0 (bản đọc được) hay không.

---

## 5. Bài học

| Bài học | Cách phát hiện sớm lần sau |
|---|---|
| **`WHERE col_a = col_b` (2 cột cùng bảng) không bao giờ dùng được index** — khác hẳn `WHERE col = 'hằng'`. Đánh bao nhiêu index cũng vô ích | Đọc `WHERE` trong slow log: thấy vế phải là **tên cột** chứ không phải giá trị → biết ngay là full scan, không cần `EXPLAIN` |
| **Suy luận từ đọc code flow có thể sai hoàn toàn.** Đã đoán "25s là MinIO + thumbnail CPU" dựa trên đọc `upload_document()`, nhưng đo thật thì 3 câu MySQL chiếm gần hết | Luôn đo bằng slow log **trước** khi kết luận bước nào chậm, đừng suy từ cấu trúc code |
| **`long_query_time` phải khớp với thứ đang tìm.** Ngưỡng 1s hợp lý để tìm query đơn lẻ chậm, nhưng bỏ sót flow gồm nhiều bước nhỏ cộng dồn | Đang debug 1 flow nhiều bước → hạ xuống `0.1`; đang tìm query nặng đơn lẻ → giữ `1` |
| **Đọc slow log phải gom nhóm, không đọc từng dòng.** `GROUP BY` + `SUM(query_time)` lộ ra thủ phạm 783,945 lần/838 giờ mà đọc 20 dòng gần nhất không thấy được quy mô | Luôn chạy query gom nhóm **trước**, rồi mới soi chi tiết dòng cụ thể |
| **Câu SQL dài làm tràn màn hình VDI.** `DELETE ... NOT IN (nghìn id)` khiến output không đọc nổi | Dùng `LEFT(CONVERT(sql_text USING utf8), 80)` để liệt kê, `\G` khi cần đọc full 1 câu |
| **Một lời gọi hàm trong code có thể thành nhiều query.** `get_kb_folder()` gọi lại `get_root_folder()` → 1 dòng code thành 2 lần full scan | Khi thấy query lặp bất thường trong slow log, tra ngược xem hàm nào gọi hàm nào |

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| `slow_query_log` bật bằng `SET GLOBAL`, mất khi pod restart | Mục 3.1 phiên này (đã mất 2 lần trước đó) | Restart pod → mù quan sát trở lại, phải bật lại thủ công mỗi lần cần debug |
| Bảng `mysql.slow_log` đang tích luỹ rất lớn (783,945 dòng chỉ riêng 1 loại query) | Hệ quả của việc bật log ngưỡng 0.1s | Chiếm dung lượng MySQL; nên `TRUNCATE mysql.slow_log` sau khi debug xong ❓ chưa làm |
| Source code tra cứu là `0.24.0`, production chạy `0.26.4` | Repo chỉ có sẵn bản 0.24.0 | Kết luận có thể lệch nếu code đã đổi giữa 2 version — cần xác minh trước khi báo dev |

---

## 7. Việc tiếp theo

### Ngay lập tức (không cần downtime)

- [ ] Đọc `init_knowledgebase_docs()` (`file_service.py:294`) để giải thích đủ vì sao có **3** câu
      full scan trong 1 lần upload, không phải 2
- [ ] Xác minh hàm `get_root_folder()` ở version 0.26.4 (production) có giống 0.24.0 không
- [ ] `TRUNCATE mysql.slow_log` sau khi debug xong để giải phóng dung lượng ❓ cân nhắc thời điểm
- [ ] Đo `SELECT COUNT(*) FROM file` để biết chính xác kích thước bảng (hiện chỉ suy từ
      `rows_examined` = 631,585)

### Ngắn hạn

- [ ] Báo đội phát triển RagFlow về Issue U1 kèm bằng chứng (mục 3-4 file này)
- [ ] Báo luôn Issue 7 (`get_filter_by_kb_id`) — vẫn còn trong top slow query, cùng nhóm nguyên
      nhân "code app query không tối ưu"
- [ ] Trace nốt 4 bước còn lại của flow 55s (LLM tóm tắt 10s, Update metadata 8s, Parse chunk 6s,
      Check tồn tại 6s) — hiện mới xong đúng bước Upload document

### Dài hạn

- [ ] Đưa `slow_query_log` + `long_query_time` vào ConfigMap của chart (xoá nợ kỹ thuật, dùng
      chung với Issue 5 của `TRACKING-mysql-load-assessment.md`)
- [ ] Cân nhắc bổ sung mysqld_exporter + Grafana để không phải bật/tắt slow log thủ công mỗi lần

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Đối tác tiếp tục đẩy dữ liệu → bảng `file` lớn thêm → full scan càng chậm tuyến tính | 🔴 Cao | Chưa có cách giảm thiểu ở tầng hạ tầng; phụ thuộc hoàn toàn vào việc đội dev sửa code |
| Query 838 giờ tích luỹ vẫn đang chạy liên tục, chiếm CPU MySQL ảnh hưởng query khác | 🔴 Cao | Đã migrate sang node06 (CPU rảnh hơn) nên chịu tải tốt hơn, nhưng không giải quyết gốc |
| Kết luận dựa trên code 0.24.0 có thể không đúng với 0.26.4 đang chạy | 🟡 TB | Xác minh trước khi báo dev (đã đưa vào Việc tiếp theo) |
| Bảng `mysql.slow_log` phình to do log ngưỡng 0.1s | 🟢 Thấp | Tắt slow log hoặc truncate sau khi debug xong |
