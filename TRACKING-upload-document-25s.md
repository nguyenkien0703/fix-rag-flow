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
| Source code tra cứu | `ragflow-0.26.4/` — ✅ **đúng version production**, đã clone và đối chiếu 10/08 | `git clone --depth 1 --branch v0.26.4 https://github.com/infiniflow/ragflow.git` |
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

### 3.5 Kiểm chứng giả định của phương án fix — tìm root folder bằng `name` thay vì `parent_id = id`

*(Kiên yêu cầu 10/08: "muốn dùng query để tìm root folder `/` và `.knowledgebase`, cần xác nhận
nó có tồn tại". Thực chất câu hỏi này kiểm chứng luôn giả định nền của phương án sửa code.)*

Cả 3 câu chỉ `SELECT`, không đụng dữ liệu — chạy được ngay cả khi đối tác đang đẩy dữ liệu.
Chạy trên **node04** qua `kubectl -n ragflow exec -it ragflow-mysql-0 -- mysql -uroot -p... rag_flow`.

**a) Root folder có tồn tại không, tìm bằng `name` có ra không?**

```sql
SELECT id, name, parent_id, tenant_id, type, create_date FROM file WHERE tenant_id = '22cdb01e486a11f1ac9749e86cfe939a' AND name = '/'\G
```

| Thành phần | Ý nghĩa |
|---|---|
| `AND name = '/'` | Tìm theo **tên** — so cột với **hằng số**, dùng được index. Đối lập với `parent_id = id` của code hiện tại |
| `\G` thay `;` | Hiển thị dọc, mỗi cột 1 dòng — tránh tràn màn hình VDI. `\G` **cũng là ký tự kết thúc câu** nên không cần thêm `;` |

**Output:**

```
*************************** 1. row ***************************
         id: 22cdb226486a11f1ac9749e86cfe939a
       name: /
  parent_id: 22cdb226486a11f1ac9749e86cfe939a
  tenant_id: 22cdb01e486a11f1ac9749e86cfe939a
       type: folder
create_date: 2026-05-05 18:06:51
1 row in set (0.00 sec)
```

**Đọc được gì:**
- ✅ `parent_id` = `id` (cùng `22cdb226...`) — xác nhận đúng phân tích: root folder trỏ về chính nó
- ✅ `id` (`22cdb226...`) **khác** `tenant_id` (`22cdb01e...`) — chỉ trùng 4 ký tự đầu do sinh UUID
  cùng thời điểm. Dễ nhìn nhầm thành một nếu đọc lướt
- 🔴 **`0.00 sec`** — con số quan trọng nhất. Cùng bảng, cùng 1 dòng kết quả, nhưng
  `name = '/'` mất **0.00s** trong khi `parent_id = id` mất **18s** (mục 3.4). Chênh **>1000 lần**
- ✅ Bảng `file` **có index dùng được cho cột `name`** (suy ra từ 0.00s trên bảng 631k dòng)

**b) `.knowledgebase` có tồn tại và nối đúng vào root không?**

```sql
SELECT c.id, c.name, c.parent_id, p.name AS parent_name FROM file c JOIN file p ON c.parent_id = p.id WHERE c.tenant_id = '22cdb01e486a11f1ac9749e86cfe939a' AND c.name = '.knowledgebase'\G
```

| Thành phần | Ý nghĩa |
|---|---|
| `file c JOIN file p` | **Self-join** — nối bảng `file` với chính nó. `c` = child, `p` = parent |
| `ON c.parent_id = p.id` | So cột giữa **2 dòng khác nhau** → **dùng được index**. Khác hẳn `parent_id = id` so 2 cột **cùng 1 dòng** |
| `p.name AS parent_name` | Lấy tên thư mục cha ra đối chiếu — kỳ vọng phải là `/` |

**Output:**

```
*************************** 1. row ***************************
         id: 4b2289be4a8011f1ac9749e86cfe939a
       name: .knowledgebase
  parent_id: 22cdb226486a11f1ac9749e86cfe939a
parent_name: /
1 row in set (0.00 sec)
```

**Đọc được gì:**
- ✅ Cây thư mục nối **đúng**: `parent_id` của `.knowledgebase` = `22cdb226...` = đúng `id` của `/`
- ✅ Sơ đồ `/` → `.knowledgebase` → `<KB>` được xác nhận bằng **dữ liệu thật**, không chỉ bằng đọc code
- ✅ **0.00 sec** dù là self-join trên bảng 631k dòng → chứng minh trực tiếp: so cột giữa 2 dòng
  khác nhau thì index hoạt động bình thường. Vấn đề **chỉ** nằm ở so 2 cột cùng 1 dòng

**c) ⭐ Có dòng trùng không? — câu quyết định phương án fix**

```sql
SELECT name, COUNT(*) AS so_dong FROM file WHERE tenant_id = '22cdb01e486a11f1ac9749e86cfe939a' AND name IN ('/', '.knowledgebase') GROUP BY name;
```

| Thành phần | Ý nghĩa |
|---|---|
| `COUNT(*) ... GROUP BY name` | Đếm số dòng theo từng tên — lộ ra ngay nếu có bản ghi trùng |
| `IN ('/', '.knowledgebase')` | Kiểm tra cả 2 tầng trong một câu |
| `;` (không phải `\G`) | Trả nhiều dòng ngắn → bảng ngang dễ đọc hơn. **Lần đầu chạy bị treo ở prompt `->` do soạn lệnh thiếu `;`** |

**Output:**

```
+----------------+---------+
| name           | so_dong |
+----------------+---------+
| .knowledgebase |       1 |
| /              |       1 |
+----------------+---------+
2 rows in set (0.00 sec)
```

**Đọc được gì:**
- ✅ **Không có dòng trùng** — mỗi tên đúng 1 dòng
- ✅ Loại trừ được rủi ro đã nêu trước đó: "nếu có 2 dòng cùng `name = '/'` thì sửa thành
  `name = '/'` sẽ lấy nhầm". Giả thuyết này **sai với dữ liệu thực tế**
- ➡️ **Kết luận**: thay `parent_id = id` bằng `name = '/'` cho **kết quả tương đương**, nhưng
  nhanh hơn >1000 lần. Đây là căn cứ để hạ mức rủi ro của phương án vá code (xem mục 4)

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

---

#### 📖 Giải thích dễ hiểu — câu SQL này đang tìm cái gì?

*(Ghi lại theo yêu cầu của Kiên 10/08 — phần Root cause ở trên dùng thuật ngữ, phần này giải
thích lại từ đầu cho dễ đọc lại sau này)*

**Bảng `file` lưu cây thư mục.** Mỗi dòng có 2 cột quan trọng: `id` (mã của chính nó) và
`parent_id` (mã thư mục cha chứa nó).

Cây thư mục thực tế của 1 tài khoản RagFlow:

```
/                          ← root folder      - 1 cái duy nhất cho cả tenant
└── .knowledgebase/        ← kb_root folder   - 1 cái duy nhất, chứa mọi KB
    ├── Voffice-doc-sum/   ← kb folder        - mỗi KB một thư mục
    ├── KB-2/
    └── ... (các KB khác)
```

✅ **Đã xác minh sơ đồ này là đúng, không phải ví dụ minh hoạ** (Kiên hỏi 10/08):

| Thành phần | Bằng chứng trong code v0.26.4 |
|---|---|
| Tên `/` của root folder | `file_service.py:253` → `"name": "/"` — chuỗi ký tự thật ghi vào DB |
| Tên `.knowledgebase` | `api/db/__init__.py:91` → `KNOWLEDGEBASE_FOLDER_NAME = ".knowledgebase"` |
| kb_root nằm dưới root | `file_service.py:271` → `parent_id == root_id` |
| Thư mục KB nằm dưới kb_root | `upload_document()` → `new_a_file_from_kb(kb.tenant_id, kb.name, kb_root_folder["id"])` |

⚠️ **Một đính chính**: phạm vi là **tenant**, không hẳn là "tài khoản". Query lọc theo
`tenant_id`, mà mặc định mỗi user là một tenant riêng — nên với trường hợp của Kiên thì hai
khái niệm này trùng nhau. Nhưng nếu về sau bật tính năng team/chia sẻ tenant thì nhiều user
sẽ **dùng chung một cây thư mục** và cùng chịu chung một bảng `file` phình to.

Lưu trong bảng `file` thành:

| id | name | parent_id | Ý nghĩa |
|---|---|---|---|
| `AAA` | `/` | **`AAA`** | Thư mục gốc — **cha của nó chính là nó** |
| `BBB` | `.knowledgebase` | `AAA` | Cha là `/` |
| `CCC` | `Voffice-doc-sum` | `BBB` | Cha là `.knowledgebase` |
| `DDD` | `file1.txt` | `CCC` | Cha là `Voffice-doc-sum` |

**Vì sao thư mục gốc có `parent_id = id`?** Vì nó không có cha (đã trên cùng rồi), nhưng cột
`parent_id` bắt buộc phải điền gì đó — nên code cho nó **trỏ về chính nó**:

```python
file_id = get_uuid()          # sinh mã mới, ví dụ "AAA"
file = {
    "id": file_id,            # id        = "AAA"
    "parent_id": file_id,     # parent_id = "AAA"  ← cùng giá trị!
    "name": "/",
}
```

**Vậy câu SQL đang tìm gì?**

```sql
WHERE (tenant_id = '22cdb01e...')     ← của tài khoản này
  AND (parent_id = id)                ← dòng nào có "cha = chính nó"
```

Dịch sang tiếng Việt: **"Tìm thư mục gốc `/` của tài khoản này"** — chỉ trả về đúng **1 dòng**.

**Vì sao chậm?**

| Loại điều kiện | MySQL làm gì | Tốc độ |
|---|---|---|
| `WHERE name = '/'` (so với **giá trị cố định**) | Tra "mục lục" (index) — giống tra từ điển, lật thẳng tới vần cần tìm, không đọc cả quyển | Nhanh |
| `WHERE parent_id = id` (so **2 cột với nhau**) | Không có "mục lục" nào sắp xếp theo "dòng có 2 cột bằng nhau" — vì giá trị cần tìm **đổi theo từng dòng** (dòng `AAA` so với `AAA`, dòng `BBB` so với `BBB`...). Buộc phải **đọc từng dòng** trong 631,585 dòng | **18 giây** |

Ví von: thay vì tra mục lục, phải **lật từng trang trong 631,585 trang** để tìm đúng 1 trang có
"số ghi ở đầu bằng số ghi ở cuối" → mất 18 giây chỉ để lấy về **1 dòng**.

**Vì sao đánh index không cứu được?** Index chỉ giúp khi biết trước **giá trị cụ thể** cần tìm.
`parent_id = id` không có giá trị cụ thể nào — nó là quan hệ giữa 2 cột, index không mô tả được
kiểu này. Đây là khác biệt căn bản với Issue 1 của `TRACKING-mysql-load-assessment.md` — Issue 1
fix được bằng index vì điều kiện là `kb_id = '<giá trị cụ thể>'`.

---

#### ❓ Giải đáp — lần nào upload cũng full scan? Root folder khác KB folder thế nào?

*(Câu hỏi của Kiên 10/08, đã xác minh trực tiếp trên code v0.26.4 — đúng version production)*

**1. Có, lần nào cũng chạy — và 2 lần mỗi lượt upload.**

4 dòng đầu của `upload_document()` chạy mỗi lần gọi hàm, không cache, không điều kiện bỏ qua
(`ragflow-0.26.4/api/db/services/file_service.py:515-519`):

```python
root_folder = self.get_root_folder(user_id)        # ← full scan lần 1
pf_id = root_folder["id"]
self.init_knowledgebase_docs(pf_id, user_id)       # (không full scan — nhận root_id truyền sẵn)
kb_root_folder = self.get_kb_folder(user_id)       # ← bên trong gọi lại get_root_folder = full scan lần 2
kb_folder = self.new_a_file_from_kb(kb.tenant_id, kb.name, kb_root_folder["id"])
```

**1b. Tìm root folder ra để LÀM GÌ?** *(Kiên hỏi 10/08)*

Không phải để ghi file vào đó. Root folder chỉ được dùng làm **điểm bắt đầu để lần xuống**
đúng thư mục KB cần ghi. Đọc lại 5 dòng code trên theo trình tự:

```
get_root_folder(user_id)        → ra id của "/"            (gọi nó là AAA)
   ↓ dùng AAA làm mốc
get_kb_folder(user_id)          → tìm ".knowledgebase" có parent_id = AAA   → ra BBB
   ↓ dùng BBB làm mốc
new_a_file_from_kb(..., BBB)    → tìm/tạo "<tên KB>" có parent_id = BBB     → ra CCC
   ↓
File mới được ghi vào với parent_id = CCC   ← đây mới là chỗ file thực sự nằm
```

Nói cách khác: mỗi tầng cần biết `id` của tầng cha để tìm mình, và root là tầng trên cùng
nên phải lấy nó trước. Vấn đề nằm ở chỗ **cách lấy tầng trên cùng đó lại là cách tệ nhất** —
quét cả bảng, trong khi 2 tầng dưới đều tra bằng giá trị cụ thể nên rất nhanh.

➡️ **Đây chính là lý do vấn đề này đáng lẽ rất dễ sửa**: root folder của một tenant là **bất
biến** — tạo một lần rồi không bao giờ đổi. Đúng ra chỉ cần cache lại `id` đó (hoặc đánh dấu
bằng một cột riêng), thay vì đi quét 631,585 dòng lặp đi lặp lại 2 lần cho **mỗi** file upload.

**2. Root folder và KB folder là 3 tầng thư mục KHÁC NHAU** (hay bị nhầm là một):

| Thư mục | Hàm lấy | Điều kiện `WHERE` | Có full scan? |
|---|---|---|---|
| `/` (root folder) | `get_root_folder()` | `parent_id = id` — **so 2 cột** | 🔴 **CÓ** — 18s |
| `.knowledgebase` (kb_root folder) | `get_kb_folder()` | `parent_id = '<id của root>'` — giá trị cụ thể | ✅ Không, dùng được index |
| `<tên KB>` (kb folder) | `new_a_file_from_kb()` | `parent_id = '<id kb_root>'` + `name = '<tên KB>'` | ✅ Không |

⚠️ Nhưng `get_kb_folder()` **gọi lại `get_root_folder()` ngay dòng đầu** (dòng 269) → vẫn dính
full scan lần 2, dù bản thân query tìm `.knowledgebase` là nhanh.

**3. Số lượng KB KHÔNG ảnh hưởng — tổng số file trong tài khoản mới ảnh hưởng.**

Full scan quét **toàn bộ bảng `file`** (631,585 dòng, gộp chung mọi KB), không quét riêng KB nào.
Hệ quả thực tế trên tài khoản đang dùng (6 KB, trong đó `Voffice-doc-sum` chiếm ~394k document):

- Upload vào KB **nhỏ nhất** (chỉ vài file) **vẫn mất đúng 18 giây** — vì vẫn phải lật hết 631,585 dòng
- KB `Voffice-doc-sum` làm bảng `file` phình to → **làm chậm luôn cả 5 KB còn lại**
- Bảng `file` càng lớn → càng chậm tuyến tính, không phụ thuộc KB đích là cái nào

**4. Chỉ có 2 lần/upload, không phải 3** (đã tra hết mọi nơi gọi `get_root_folder` trong v0.26.4):

| Vị trí | Có trong flow upload? |
|---|---|
| `file_service.py:515` — `upload_document()` gọi trực tiếp | ✅ Lần 1 |
| `file_service.py:269` — `get_kb_folder()` gọi lại | ✅ Lần 2 |
| `file_service.py:678` — `delete_docs()` | ❌ Không — thuộc flow xoá document |

→ Câu thứ 3 bắt được trong slow log lúc 12:29:08 đến từ **request khác chạy song song** (UI đang
mở, hoặc upload nhiều file cùng lúc), không phải từ cùng 1 lần gọi `upload_document`.

---

**Bằng chứng — nguồn code**

`ragflow-0.26.4/api/db/services/file_service.py` dòng 237-246 (**đúng version production**):

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

**Tệ hơn: chạy đúng 2 lần mỗi upload.** `get_kb_folder()` (dòng 262-274) gọi lại `get_root_folder()`:

```python
def get_kb_folder(cls, tenant_id):
    root_folder = cls.get_root_folder(tenant_id)    # <-- gọi lại lần 2
    root_id = root_folder["id"]
    ...
```

Và `upload_document()` (dòng 513-519) gọi cả hai:

```python
def upload_document(self, kb, file_objs, user_id, src="local", parent_path=None, parser_config_override=None):
    root_folder = self.get_root_folder(user_id)      # lần 1  (dòng 515)
    pf_id = root_folder["id"]
    self.init_knowledgebase_docs(pf_id, user_id)     # KHÔNG gọi get_root_folder (nhận root_id truyền sẵn)
    kb_root_folder = self.get_kb_folder(user_id)     # lần 2, bên trong lại gọi get_root_folder (dòng 518)
```

✅ **Đã xác minh (10/08, trên code v0.26.4)**: `init_knowledgebase_docs()` (dòng 360) **không**
gọi `get_root_folder` — nó nhận `root_id` truyền sẵn làm tham số, chỉ query theo giá trị cụ thể.
Tra toàn bộ nơi gọi `get_root_folder` trong v0.26.4 cho ra đúng 3 vị trí: dòng 515
(`upload_document`), dòng 269 (`get_kb_folder`), dòng 678 (`delete_docs` — **không** thuộc flow
upload).

→ Vậy 1 lần upload gây **2 lần** full scan (~36s nếu mỗi lần 18s). Câu thứ 3 bắt được trong slow
log lúc 12:29:08 đến từ **request khác chạy song song**, không phải từ cùng 1 lần `upload_document`.

**Bằng chứng — đã có issue upstream nào chưa? (tra 10/08 theo yêu cầu của Kiên)**

🔶 **Chưa tìm thấy issue nào mô tả đúng vấn đề này.** Đã tra:

| Nguồn tra | Kết quả |
|---|---|
| GitHub issues, keyword `get_root_folder` | Không có issue nào về hiệu năng. Chỉ ra 3 issue Feature không liên quan (#14736, #15240, #12313) + 1 PR đã merge (#14345 "Refa: unify document create flows") |
| GitHub issues, keyword `file table slow query index` | Không liên quan (#15049 onnxruntime, #14628 s3 connector, #3022 hanging at parsing) |
| Web search "ragflow upload slow MySQL large knowledge base" | Chỉ ra các issue về **parsing chậm** (#7576, #11142, #4673) — khác hẳn: đó là tầng embedding/task executor, không phải MySQL |

⚠️ **Quan trọng — đã kiểm tra branch `main` mới nhất** (không chỉ v0.26.4):
`get_root_folder()` trên `main` **vẫn còn nguyên** `parent_id == id`, **vẫn không có cache**.

→ Nghĩa là: **nâng version RagFlow sẽ KHÔNG tự khỏi.** Đây không phải bug đã fix ở bản mới mà
mình đang chạy bản cũ — nó vẫn đang tồn tại ở bản mới nhất upstream.

→ Vì sao chưa ai báo? Nhiều khả năng vì vấn đề chỉ lộ ra khi bảng `file` đủ lớn (mình có
631,585 dòng), còn đa số người dùng chỉ có vài trăm/vài nghìn dòng — quét hết cũng chỉ mất
vài ms nên không ai nhận ra.

➡️ **Hệ quả cho hướng xử lý**: mình là bên đầu tiên chạm vào giới hạn này, nên **không có bản
vá sẵn để chờ**. Muốn xử lý thì phải tự mở issue/PR lên upstream, hoặc tự vá tại chỗ.

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
   `upload_document()` vẫn gọi riêng thêm 1 lần ở dòng 515 → truyền kết quả xuống thay vì gọi lại.
   Riêng cách này **giảm được một nửa** (2 lần → 1 lần) mà không đụng schema.
4. ✅ **Đã xác minh (10/08)**: hàm `get_root_folder()` ở v0.26.4 (production) **giống hệt** bản
   0.24.0 — cùng dòng `where((tenant_id == tenant_id), (parent_id == cls.model.id))`. Kết luận
   root cause áp dụng đúng cho production, không cần dè dặt vì lệch version nữa.

#### ⭐ Phương án (d) — thay điều kiện tìm: `parent_id = id` → `name = '/'`

**Đã kiểm chứng bằng dữ liệu thật production (mục 3.5, 10/08)** — đây là phương án gọn nhất:

| Tiêu chí | Bằng chứng |
|---|---|
| Có tìm ra đúng root folder không? | ✅ Ra đúng 1 dòng, `id = 22cdb226...`, `parent_id = id` |
| Có bị trùng dòng không? | ✅ `COUNT(*)` = **1** cho `/`, = **1** cho `.knowledgebase` |
| Nhanh hơn bao nhiêu? | 🚀 **18s → 0.00s** (>1000 lần) |
| Sửa bao nhiêu dòng code? | **1 dòng** (`file_service.py:244`) |

Sửa cụ thể — chỉ đổi vế điều kiện thứ 2:

```python
# HIỆN TẠI (dòng 244) — so 2 cột cùng dòng, không dùng được index
.where((cls.model.tenant_id == tenant_id), (cls.model.parent_id == cls.model.id))

# SỬA THÀNH — so cột với hằng số, dùng được index
.where((cls.model.tenant_id == tenant_id), (cls.model.name == "/"))
```

⚠️ **Đánh giá trước đó của tôi cần điều chỉnh.** Trước khi có mục 3.5, tôi xếp phương án vá code
bằng `sed` vào nhóm "không khuyến nghị", lý do: *"nếu có 2 dòng cùng `name = '/'` thì kết quả sẽ
khác bản gốc"*. Dữ liệu thật cho thấy **không có dòng trùng** → giả thuyết đó **sai**, và mức rủi
ro của phương án (d) thấp hơn hẳn so với đánh giá ban đầu:

- Đây là **thay 1 chuỗi trong 1 dòng** — đúng loại việc mà 2 patch `codePatch` hiện có đang làm
- Không thêm dòng mới, không đụng indent Python (khác phương án (b) cache — cần thêm biến/decorator)
- ✅ Vẫn nên **test ở non-prod trước**: rủi ro giảm ≠ rủi ro bằng 0

**Rủi ro còn lại của (d)** — cần ghi rõ, không được bỏ qua:

| Rủi ro | Mức | Ghi chú |
|---|---|---|
| Tenant **mới** chưa có root folder → `name = '/'` không ra dòng nào | Thấp | Code có sẵn nhánh tự tạo khi không tìm thấy (`file_service.py:246-259`) — hành vi giữ nguyên |
| Về sau xuất hiện dòng trùng `name = '/'` do race condition | Thấp | Hiện `COUNT(*)` = 1. Code v0.26.4 đã có logic dedup cho `.knowledgebase` (dòng 79) → chuyện trùng là có thật với thư mục khác, nên vẫn cần theo dõi |
| ❓ Chưa xác minh: có index cụ thể nào trên cột `file.name` | Thấp | Suy ra từ `0.00 sec` trên bảng 631k dòng. Chưa chạy `SHOW INDEX FROM file` để xem tên index |

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
| **Số lần query trong slow log ≠ số lần 1 request gọi.** Ban đầu thấy 3 câu cùng lúc → tưởng 1 lần upload gọi 3 lần. Tra code mới biết chỉ 2 lần, câu thứ 3 từ request song song khác | Đếm số lời gọi bằng cách `grep` toàn bộ codebase (`grep -rn "get_root_folder"`), đừng suy từ số dòng trong slow log |
| **Tra code phải đúng version đang chạy production.** Repo có sẵn 0.24.0 nhưng production chạy 0.26.4 — may là code giống nhau, nhưng nếu khác thì kết luận sai hoàn toàn | `git clone --depth 1 --branch <tag>` bản đúng version rồi đối chiếu, trước khi báo dev |
| **"Chưa có ai báo issue" không có nghĩa là mình sai** — có nghĩa là mình chạm giới hạn trước người khác. Bug này chỉ lộ ra khi bảng `file` đủ lớn; đa số user chỉ có vài nghìn dòng nên quét hết vẫn mất vài ms | Tra issue upstream mà không ra → **kiểm tra thêm branch `main`** xem code còn lỗi không, thay vì kết luận "chắc mình hiểu nhầm" |
| **Kiểm tra `main` chứ không chỉ version đang chạy.** Nếu `main` đã fix thì hướng xử lý là nâng version; nếu `main` còn lỗi thì phải tự vá — hai hướng hoàn toàn khác nhau | `curl raw.githubusercontent.com/<repo>/main/<file>` đọc thẳng bản mới nhất, nhanh hơn clone |
| **Đánh giá rủi ro dựa trên giả thuyết phải đi đo, đừng để nguyên.** Đã xếp phương án vá code vào nhóm "rủi ro cao" vì lo `name = '/'` có dòng trùng — chạy `COUNT(*)` 10 giây thì thấy **không trùng**, rủi ro thấp hơn hẳn | Mỗi khi viết "nếu X xảy ra thì nguy hiểm" → hỏi ngay **"X có thật không, đo bằng câu nào?"**. Giả thuyết chưa đo mà đem đi ra quyết định thì dễ chọn sai hướng |
| **Cùng một bảng, đổi cách hỏi thì nhanh gấp 1000 lần.** `parent_id = id` mất 18s, `name = '/'` mất 0.00s — cùng bảng 631k dòng, cùng trả 1 dòng | Nghi query chậm do "bảng to" → thử viết lại điều kiện theo hằng số rồi đo. Bảng to chỉ là điều kiện cần, cách hỏi mới quyết định |
| **`\G` cũng là ký tự kết thúc câu, `;` thì không thay thế được nó.** Câu dùng `\G` chạy được dù không có `;`; câu dùng bảng ngang mà quên `;` sẽ treo ở prompt `->` | Thấy MySQL hiện `->` thay vì `mysql>` → câu chưa kết thúc, gõ `;` rồi Enter là xong (không cần `^C` chạy lại) |
| **Bảng dùng chung nghĩa là 1 KB lớn làm chậm mọi KB.** Bảng `file` gộp chung mọi KB của tài khoản → full scan quét hết 631k dòng bất kể upload vào KB nào | Khi thấy query full scan trên bảng dùng chung, đừng chỉ nhìn KB/tenant đang thao tác — nhìn tổng số dòng cả bảng |

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| `slow_query_log` bật bằng `SET GLOBAL`, mất khi pod restart | Mục 3.1 phiên này (đã mất 2 lần trước đó) | Restart pod → mù quan sát trở lại, phải bật lại thủ công mỗi lần cần debug |
| Bảng `mysql.slow_log` đang tích luỹ rất lớn (783,945 dòng chỉ riêng 1 loại query) | Hệ quả của việc bật log ngưỡng 0.1s | Chiếm dung lượng MySQL; nên `TRUNCATE mysql.slow_log` sau khi debug xong ❓ chưa làm |
| ~~Source code tra cứu là `0.24.0`, production chạy `0.26.4`~~ | ~~Repo chỉ có sẵn bản 0.24.0~~ | ✅ **Đã xử lý 10/08** — clone bản v0.26.4 về đối chiếu, code `get_root_folder()` giống hệt, kết luận vẫn đúng |
| Source v0.26.4 hiện nằm ở `/Users/macboook/.claude/jobs/feb3bf0f/tmp/ragflow-0.26.4/` (thư mục tạm của job) | Clone 10/08 để đối chiếu | Thư mục tạm có thể bị dọn khi job kết thúc → lần sau cần tra lại phải clone lại. Cân nhắc copy vào repo nếu còn dùng nhiều |

---

## 7. Việc tiếp theo

### Ngay lập tức (không cần downtime)

- [x] ~~Đọc `init_knowledgebase_docs()` để giải thích vì sao có 3 câu full scan~~ → ✅ **Xong
      10/08**: hàm này **không** gọi `get_root_folder` (nhận `root_id` truyền sẵn). 1 lần upload
      chỉ gây **2** lần full scan; câu thứ 3 đến từ request khác chạy song song
- [x] ~~Xác minh hàm `get_root_folder()` ở version 0.26.4 có giống 0.24.0 không~~ → ✅ **Xong
      10/08**: giống hệt, kết luận root cause áp dụng đúng cho production
- [ ] `TRUNCATE mysql.slow_log` sau khi debug xong để giải phóng dung lượng ❓ cân nhắc thời điểm
- [ ] Đo `SELECT COUNT(*) FROM file` để biết chính xác kích thước bảng (hiện chỉ suy từ
      `rows_examined` = 631,585)
- [x] ~~Xác nhận root folder `/` và `.knowledgebase` có tồn tại, có bị trùng không~~ → ✅ **Xong
      10/08 (mục 3.5)**: cả 2 tồn tại, nối đúng cây, **mỗi cái đúng 1 dòng, không trùng**.
      `name = '/'` chạy **0.00s** vs `parent_id = id` **18s** → chốt được phương án (d)
- [ ] Chạy `SHOW INDEX FROM file` để biết tên index đang phục vụ cột `name` (hiện chỉ suy ra từ
      thời gian 0.00s, chưa xem trực tiếp) ❓

### Ngắn hạn

- [x] ~~Tra xem upstream đã có issue nào cho vấn đề này chưa~~ → 🔶 **Xong 10/08: CHƯA CÓ.**
      Tra GitHub issues (`get_root_folder`, `file table slow query index`) + web search đều không
      ra issue nào đúng vấn đề. Quan trọng hơn: **branch `main` mới nhất vẫn còn nguyên lỗi**
      (`parent_id == id`, không cache) → **nâng version sẽ không tự khỏi**
- [ ] Báo đội phát triển RagFlow về Issue U1 kèm bằng chứng (mục 3-4 file này) — **là bên đầu
      tiên báo**, nên cần kèm số liệu đầy đủ: 631,585 dòng, 18s/lần, 2 lần/upload, 783,945 lần
      chạy tích luỹ 838h59m
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
| ~~Kết luận dựa trên code 0.24.0 có thể không đúng với 0.26.4 đang chạy~~ | ✅ Đã loại bỏ | Đã clone v0.26.4 đối chiếu 10/08 — code giống hệt, không còn rủi ro này |
| Bảng `mysql.slow_log` phình to do log ngưỡng 0.1s | 🟢 Thấp | Tắt slow log hoặc truncate sau khi debug xong |
