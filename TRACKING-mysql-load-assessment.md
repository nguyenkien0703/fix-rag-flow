# TRACKING — Đánh giá tải MySQL của RagFlow

**Phiên:** 05/08/2026
**Đối tượng:** pod `ragflow-mysql-0`, namespace `ragflow`, node `vrp-kubeengine07`
**Trạng thái phiên:** 🔶 ĐANG DỞ — đã hoàn tất chẩn đoán, **chưa thực thi bất kỳ thay đổi nào**

---

## 1. Mục tiêu

Kiểm tra tải của pod MySQL phục vụ RagFlow, xác định xem MySQL có phải nút thắt hiệu năng hay không, và nếu có thì do đâu.

### Bối cảnh hạ tầng

| Hạng mục | Giá trị | Nguồn |
|---|---|---|
| Chart | `helm_ragflow_v0.26.4` (đã deploy thành công 02/08) | phiên trước |
| MySQL replicas | 1 | chart |
| StorageClass | `local-mysql` | `values.yaml` |
| PVC capacity khai báo | 5Gi | `values.yaml` |
| Node đặt MySQL | `vrp-kubeengine07` (label `ragflow-target=true`) | `values.yaml` nodeSelector |
| DB schema | `rag_flow` | |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Query list document 11.1s, quét 953,020 dòng cho `LIMIT 50` | 🔴 Cao | 🔶 OPEN | Tạo composite index `(kb_id, create_time DESC)` |
| 2 | `innodb_buffer_pool_size`=128MB / working set 1.85GB → 6,200 lần đọc đĩa/giây | 🔴 Cao | 🔶 OPEN | Tăng lên 3G, cần restart pod |
| 3 | PVC khai báo 5Gi nhưng thực tế ghi vào `/dev/vda1` 99G đã dùng 74% | 🔴 Cao | 🔶 OPEN | Dọn image; dài hạn tách đĩa riêng |
| 4 | Pod MySQL `resources: {}` → QoS BestEffort | 🟡 TB | 🔶 OPEN | Đặt requests/limits |
| 5 | `slow_query_log` OFF + `long_query_time`=10s → mù quan sát | 🟡 TB | ⚠️ WORKAROUND | Đã bật bằng `SET GLOBAL` (mất khi restart) → cần đưa vào ConfigMap |
| 6 | Chưa có metrics-server → `kubectl top` không dùng được | 🟡 TB | 🔶 OPEN | Cài metrics-server |

**Kết luận chung:** tải thực tế **không lớn** (~93 QPS, 184/1000 connection). Nút thắt đến từ việc **toàn bộ tham số MySQL để nguyên mặc định của chart demo**, chưa tune cho dữ liệu thật 239k document.

---

## 3. Số liệu nền đã thu thập

### 3.1 Trạng thái MySQL

| Chỉ số | Giá trị | Đánh giá |
|---|---|---|
| Uptime | 417,754s ≈ 4.83 ngày | |
| Questions (tổng query) | 38,961,290 | ~93 QPS — **bình thường** |
| Threads_connected | 39 | Bình thường |
| Threads_running | 6 | Bình thường |
| Threads_created | 1,732 | |
| Threads_cached | 16 | |
| Max_used_connections | 184 | |
| max_connections | 1,000 | Còn dư 82% — **OK** |
| Slow_queries | 1,691 | Đếm ở ngưỡng `long_query_time`=10s |

### 3.2 Kích thước bảng

```sql
SELECT table_name, ROUND(data_length/1024/1024,1) AS data_mb, ROUND(index_length/1024/1024,1) AS index_mb, ROUND((data_length+index_length)/1024/1024,1) AS total_mb, table_rows FROM information_schema.tables WHERE table_schema='rag_flow' ORDER BY (data_length+index_length) DESC LIMIT 10;
```

| TABLE_NAME | data_mb | index_mb | total_mb | TABLE_ROWS |
|---|---|---|---|---|
| document | 658.5 | 387.3 | **1045.8** | 218,651 |
| file | 98.9 | 229.1 | 328.0 | 246,008 |
| task | 182.5 | 112.0 | 294.5 | 261,393 |
| pipeline_operation_log | 187.0 | 4.6 | 191.7 | 3,115 |
| file2document | 69.3 | 109.5 | 178.8 | 241,794 |
| conversation | 6.3 | 0.1 | 6.4 | 100 |
| canvas_template | 2.0 | 0.1 | 2.1 | 18 |
| llm | 0.1 | 0.5 | 0.6 | 791 |
| knowledgebase | 0.0 | 0.4 | 0.4 | 25 |
| tenant | 0.0 | 0.3 | 0.4 | 9 |

**Tổng working set ≈ 1,850 MB (~1.85 GB)**

> Lưu ý: `table_rows` từ `information_schema` là giá trị **ước lượng** của InnoDB. `SELECT COUNT(*) FROM document` trong phiên cho **239,395**, trong khi bảng trên báo 218,651. Dùng con số 239,395 khi cần chính xác.

### 3.3 Dung lượng đĩa

```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```
```
Filesystem   Size  Used Avail Use% Mounted on
/dev/vda1     99G   70G   25G  74% /var/lib/mysql
```

### 3.4 Tài nguyên node07

```
kubectl -n ragflow get pod ragflow-mysql-0 -o jsonpath='{.spec.containers[0].resources}'
```
```
{}
```

`kubectl describe node vrp-kubeengine07` — Allocated resources:
- cpu: 250m (3%) requests / 300m (3%) limits
- memory: 168857600 (1%) requests / 500M (3%) limits

→ Node ≈ 8 core / 16GB, còn trống ~97%. **Không thiếu tài nguyên node.**

`kubectl -n ragflow top pod ragflow-mysql-0` → `metrics API not available` (chưa cài metrics-server).

---

## 4. Issue chi tiết

### 🔴 Issue 1 — Query list document 11.1s, quét 953,020 dòng — 🔶 OPEN

**Triệu chứng**

Query liệt kê document của một knowledge base mất **11.1 giây**, `rows_examined = 953,020` để trả về 50 dòng.

```sql
SELECT t1.id, t1.thumbnail, t1.kb_id, t1.parser_id, t1.pipeline_id, t1.parser_config,
       t1.source_type, t1.type, t1.created_by, t1.name, t1.location, t1.size,
       t1.token_num, t1.chunk_num, t1.progress, t1.progress_msg, t1.process_begin_at,
       t1.process_duration, t1.suffix, t1.run, t1.status, t1.create_time, t1.create_date,
       t1.update_time, t1.update_date, t2.title AS pipeline_name, t3.nickname
FROM document AS t1
INNER JOIN file2document AS t4 ON t4.document_id = t1.id
LEFT OUTER JOIN user_canvas AS t2 ON t1.pipeline_id = t2.id
INNER JOIN file AS t5 ON t5.id = t4.file_id
LEFT OUTER JOIN user AS t3 ON t1.created_by = t3.id
WHERE t1.kb_id = '73932b965e5e11f192725fd51894c519'
ORDER BY t1.create_time DESC LIMIT 50 OFFSET 0
```

**Root cause**

MySQL chỉ dùng được **một index cho mỗi bảng**. Query cần đồng thời hai việc trên bảng `document`:
1. Lọc `WHERE kb_id = ?`
2. Sắp xếp `ORDER BY create_time DESC`

Hai index đơn cột hiện có đều chỉ phục vụ được một việc:

| Index | Phục vụ được | Chi phí còn lại |
|---|---|---|
| `document_kb_id` | lọc kb_id | phải filesort ~141k dòng |
| `document_create_time` | sắp xếp | phải lọc kb_id từng dòng trên 239k dòng |

Optimizer chọn `document_create_time`. Nó quét ngược index create_time (mới → cũ), mỗi dòng đọc lên rồi mới kiểm tra `kb_id`. Vì KB này chiếm ~60% bảng nhưng phân bố rải theo thời gian, nó phải lết qua gần hết bảng — nhân với 4 JOIN → 953,020 `rows_examined`.

**Bằng chứng**

`EXPLAIN` của query trên, phần bảng `t1`:

```
table: t1 (document)
type:  index                              <- quet TOAN BO index, khong phai range
possible_keys: PRIMARY, document_kb_id    <- CO index kb_id kha dung
key:   document_create_time               <- nhung optimizer CHON create_time
rows:  100                                <- uoc tinh SAI (thuc te ~953,000)
Extra: Using where; Backward index scan
```

Ba điểm trong output này là bằng chứng trực tiếp:
- `possible_keys` **có** `document_kb_id` → index tồn tại, không phải thiếu index hoàn toàn
- `key` lại là `document_create_time` → optimizer chủ động bỏ qua nó
- `Using where` → lọc `kb_id` được làm **sau khi đọc dòng**, không phải bằng index

Độ chọn lọc kém của index kb_id:
```
SHOW INDEX FROM document  ->  document_kb_id: Cardinality = 18
```
239,395 dòng / 18 giá trị kb_id phân biệt → trung bình 13,300 doc/KB; KB đang xét có ~141k doc ≈ 60% bảng.

**Slow query log — bằng chứng đây không phải trường hợp cá biệt**

Sau khi bật log (xem Issue 5), trong khoảng theo dõi ngắn:

| Số lần chạy | avg time | max rows_examined | Query |
|---|---|---|---|
| **1,091** | 1.73s | 238,928 | `SELECT ... FROM document ...` (chính query trên) |
| 238 | 1.34s | 41,010 | `SELECT COUNT(t1.id) FROM task JOIN document` |
| 3 | 5.33s | 239,144 | `SELECT ... FROM document WHERE status/progress` |
| 2 | 7.50s | 952,956 | `SELECT COUNT(1)` với 4 JOIN |
| 1 | **11.00s** | **953,020** | Query liệt kê document ở trên |

1,091 lần chạy với trung bình 1.73s → đây là query nóng nhất của hệ thống, không phải outlier.

**Đã thử / cân nhắc**

| Phương án | Kết quả |
|---|---|
| Đọc `Slow_queries` counter (=1,691) | Chỉ ra có vấn đề nhưng **không biết query nào** — cần bật log chi tiết |
| Bật slow log ngưỡng 1s, `log_output=TABLE` | ✅ Lộ ra query thủ phạm và tần suất |
| `EXPLAIN` query thủ phạm | ✅ Xác định chính xác cơ chế — optimizer chọn sai index |
| Nghi ngờ "tải quá lớn" | ❌ **Loại** — 93 QPS, 184/1000 connection là mức trung bình. Vấn đề là chất lượng query, không phải khối lượng |
| Nghi ngờ thiếu index hoàn toàn | ❌ **Loại** — `possible_keys` cho thấy `document_kb_id` có tồn tại |

**Hướng xử lý tiếp**

1. Tạo composite index (không cần downtime, `ALGORITHM=INPLACE` trong MySQL 8.0 → không khóa bảng):

```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
```

Composite index giải quyết cả hai việc: nhảy thẳng vào vùng của `kb_id`, và trong vùng đó dữ liệu **đã sẵn thứ tự** `create_time` → đọc 50 dòng rồi dừng.

2. Xác minh sau khi tạo — chạy lại `EXPLAIN` query cũ, kỳ vọng:
   - `key` đổi từ `document_create_time` → `idx_document_kb_create`
   - `type` đổi từ `index` → `ref`
   - `rows` giảm mạnh
   - `Extra` **không còn** `Using where` (lọc đã do index đảm nhận)

3. ❓ **Chưa xác minh**: chi phí thời gian và dung lượng của lệnh CREATE INDEX trên bảng 1GB / 239k dòng. Ước tính vài chục giây và ~15-20MB, nhưng **chưa đo thực tế**.

---

### 🔴 Issue 2 — Buffer pool 128MB / working set 1.85GB — 🔶 OPEN

**Triệu chứng**

2.6 tỷ lần đọc đĩa trong 4.83 ngày ≈ **6,200 lần/giây**.

**Root cause**

`innodb_buffer_pool_size` để nguyên **giá trị mặc định của MySQL** (128MB), trong khi working set của schema `rag_flow` là ~1,850MB.

Buffer pool là cache RAM của InnoDB — mọi dữ liệu muốn đọc đều phải nạp vào đây trước. Nằm sẵn → nhanh; không có → đọc đĩa. Với tỉ lệ phủ **6.9%**, 93% dữ liệu nóng nằm ngoài RAM.

Riêng bảng `document` (1,045.8 MB) đã **lớn gấp 8 lần** toàn bộ buffer pool → không có cách nào query chạm bảng này mà không đập đĩa.

**Bằng chứng**

```
innodb_buffer_pool_size          = 134217728        (= 128 MB, mac dinh MySQL)
Innodb_buffer_pool_read_requests = 236,928,826,053  (doc tu RAM)
Innodb_buffer_pool_reads         =   2,595,028,607  (doc PHAI xuong DIA)
```

Tính toán:
- Hit ratio = 1 − (2,595,028,607 / 236,928,826,053) = **98.9%**
- Nhưng con số **tuyệt đối**: 2,595,028,607 / 417,754s ≈ **6,212 lần đọc đĩa/giây**
- Tỉ lệ phủ working set = 128 MB / 1,850 MB = **6.9%**

**Đã thử / cân nhắc**

| Phương án | Kết quả |
|---|---|
| Đánh giá qua hit ratio 98.9% | ❌ **Bẫy** — nghe rất tốt nhưng che giấu 2.6 tỷ lần đọc đĩa. Phải nhìn con số tuyệt đối |
| Đối chiếu buffer pool với tổng data+index | ✅ Cho ra tỉ lệ phủ 6.9% — bằng chứng định lượng, mạnh hơn nhiều so với suy luận từ hit ratio |
| Đo bằng `kubectl top pod` | ❌ **Bị chặn** — metrics-server chưa cài (Issue 6) |

**Hướng xử lý tiếp**

1. Tăng `innodb_buffer_pool_size` lên **3G** (≈1.6× working set, chừa chỗ tăng trưởng). Cần đưa vào ConfigMap của chart + restart pod (~2 phút downtime).
2. Phải làm **cùng lúc** với Issue 4 — nếu đặt limit memory thấp hơn buffer pool, pod sẽ bị OOMKill.
3. ❓ **Chưa xác minh**: chart v0.26.4 mount MySQL config qua cơ chế nào (ConfigMap `my.cnf`? env? command args?). **Cần đọc `helm_ragflow_v0.26.4/templates/mysql.yaml` trước khi làm.**

---

### 🔴 Issue 3 — PVC khai báo 5Gi nhưng thực tế dùng chung đĩa hệ thống 99G, đã 74% — 🔶 OPEN

**Triệu chứng**

Không có triệu chứng trực tiếp trong phiên này — phát hiện khi đi đo dung lượng PV. Nhưng **hậu quả đã xảy ra rồi** ở phiên 31/07.

**Root cause**

StorageClass `local-mysql` dùng local PV trỏ vào một thư mục trên `/dev/vda1` — chính là root filesystem của node07, dùng chung với containerd image store và log.

**Local PV không có cơ chế enforce quota.** `capacity: 5Gi` trong PVC chỉ là metadata cho scheduler tính toán, **không giới hạn gì về mặt vật lý**. MySQL ghi thoải mái cho tới khi đầy cả đĩa node.

**Bằng chứng**

```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```
```
Filesystem   Size  Used Avail Use% Mounted on
/dev/vda1     99G   70G   25G  74% /var/lib/mysql
```

Đối chiếu: PVC khai báo 5Gi, nhưng mount point báo 99G tổng / 70G đã dùng. Hai con số không liên quan gì đến nhau.

**Hệ quả kép**

1. **Đã xảy ra (31/07)** — image `infiniflow/ragflow:v0.24.0` (7.2GB) đẩy đĩa node07 vượt ngưỡng → kubelet gắn taint `disk-pressure` `NoSchedule` → pod mysql/minio/redis không schedule được, `Pending` gián đoạn. MySQL bị hạ gục bởi **một image không liên quan**, vì dùng chung đĩa. (Chi tiết ở `TRACKING-ragflow-v0.26.4-upgrade.md` Issue 7)

2. **Rủi ro còn lại** — còn 25GB trống. Nếu đĩa đầy, MySQL không ghi được → **hỏng dữ liệu**, không chỉ là chậm. Kết hợp với Issue 4 (BestEffort), pod này là ứng viên bị evict đầu tiên.

**Đây là bằng chứng cứng nhất cho nhận định "triển khai sơ sài"**: con số 5Gi trong chart không phản ánh gì về thực tế và tạo cảm giác an toàn giả — người vận hành nhìn PVC tưởng DB chỉ chiếm 5GB.

**Đã thử / cân nhắc**

| Phương án | Kết quả |
|---|---|
| Tin vào `capacity: 5Gi` của PVC | ❌ **Sai** — chỉ là metadata. Phải `df -h` bên trong pod mới biết thực tế |
| `crictl rmi --prune` dọn image (đã làm 31/07) | ✅ Gỡ được `disk-pressure` lần đó — nhưng là **workaround**, root cause (dùng chung đĩa) còn nguyên |

**Hướng xử lý tiếp**

1. **Ngay** — dọn image cũ trên node07 để lấy lại dung lượng:
```
crictl rmi --prune
```
2. **Ngay** — thiết lập cảnh báo dung lượng `/dev/vda1` node07 ở ngưỡng 80%.
3. **Dài hạn** — tách MySQL sang đĩa/volume riêng. Việc này **quan trọng hơn cả HA**: hiện tại một image lớn bất kỳ có thể hạ gục DB.
4. ❓ **Chưa xác minh**: đường dẫn thư mục cụ thể mà PV `local-mysql` trỏ tới trên node07. Cần `kubectl get pv -o yaml` để biết trước khi tính chuyện tách đĩa.

---

### 🟡 Issue 4 — Pod MySQL QoS BestEffort — 🔶 OPEN

**Root cause**

Container MySQL không khai báo `resources` → không có requests/limits → Kubernetes xếp vào QoS class **BestEffort**, mức ưu tiên thấp nhất. Khi node thiếu RAM, kubelet **evict pod này trước tiên**.

**Bằng chứng**

```
kubectl -n ragflow get pod ragflow-mysql-0 -o jsonpath='{.spec.containers[0].resources}'
```
```
{}
```

Node07 hiện còn dư nhiều (Allocated: cpu 250m/3%, memory 168857600/1%) nên chưa xảy ra evict. Nhưng rủi ro là thật — sự cố 31/07 cho thấy node07 đã từng gặp áp lực tài nguyên.

**Hướng xử lý tiếp**

Đặt trong `values.yaml`:
- requests: `cpu: 1`, `memory: 4Gi`
- limits: `cpu: 2`, `memory: 6Gi`

→ QoS chuyển sang **Burstable**.

⚠️ **Ràng buộc**: memory limit phải ≥ `innodb_buffer_pool_size` + overhead của MySQL (connection buffer, temp table…). Với buffer pool 3G thì limit 6Gi là an toàn. **Làm cùng lúc với Issue 2 trong một lần restart.**

---

### 🟡 Issue 5 — Mù quan sát slow query — ⚠️ WORKAROUND

**Triệu chứng**

`Slow_queries = 1,691` nhưng **không có log nào** để biết query nào chậm.

**Root cause**

Hai tham số mặc định của chart:
- `slow_query_log = OFF` → không ghi log
- `long_query_time = 10` (giây) → ngưỡng quá cao, chuẩn nên là 1-2s

Nghĩa là: 1,691 query vượt **10 giây** đã được **đếm** nhưng không được **ghi**. Còn số query vượt 1 giây thì hoàn toàn không biết — hóa ra rất nhiều (1,091 lần chỉ riêng một query).

**Đã làm — WORKAROUND, không phải FIXED**

```sql
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 1;
SET GLOBAL log_output = 'TABLE';
```

✅ Đã lộ ra toàn bộ bằng chứng cho Issue 1.

⚠️ **Tại sao là WORKAROUND**: `SET GLOBAL` chỉ tồn tại trong runtime. Pod restart (mà Issue 2 và 4 đều **cần** restart) → mất hết cấu hình này. State nằm ngoài Git/Helm.

**Hướng xử lý tiếp**

Đưa 3 tham số trên vào ConfigMap MySQL của chart, cùng lượt với `innodb_buffer_pool_size` ở Issue 2. Sau khi làm xong mới được đánh ✅.

**Ghi chú thao tác**: query slow log trong `mysql.slow_log` trả về cột `sql_text` dạng **hex blob**, phải giải mã mới đọc được. Trong phiên đã dùng cách giải mã hex để đọc.

---

### 🟡 Issue 6 — Chưa có metrics-server — 🔶 OPEN

**Triệu chứng**

```
kubectl -n ragflow top pod ragflow-mysql-0
```
```
metrics API not available
```

**Root cause**

Cluster chưa cài metrics-server.

**Còn tồn đọng**

Không đo được CPU/RAM thực tế của pod MySQL. Toàn bộ đánh giá tài nguyên trong phiên này phải suy ra gián tiếp từ:
- `describe node` (chỉ cho biết **requests/limits đã đặt**, không phải mức dùng thực)
- counter nội bộ của MySQL (`Innodb_buffer_pool_reads`, `Threads_*`)

Đây là **rào cản loại "chưa được cài"**, không phải "chưa biết cách" — cài metrics-server là việc rõ ràng, chỉ cần được phép.

**Hướng xử lý tiếp**

1. Cài metrics-server (lưu ý môi trường air-gapped: cần copy image trước).
2. Dài hạn: thêm mysqld_exporter + dashboard Grafana để theo dõi buffer pool hit ratio, slow query rate, connection.

---

## 5. Bài học

### Đọc số liệu MySQL

| Bài học | Cách phát hiện sớm lần sau |
|---|---|
| **Hit ratio cao vẫn có thể là thảm hoạ.** 98.9% nghe tuyệt vời nhưng che giấu 2.6 tỷ lần đọc đĩa. Phải nhìn **con số tuyệt đối chia cho uptime** | `Innodb_buffer_pool_reads / Uptime` → nếu > vài trăm/giây là có vấn đề |
| **Cách đánh giá buffer pool đúng là so với tổng data+index**, không phải nhìn hit ratio | `SELECT SUM(data_length+index_length)/1024/1024 FROM information_schema.tables WHERE table_schema='<db>'` rồi chia cho `innodb_buffer_pool_size` |
| **`Slow_queries` counter vô dụng nếu `long_query_time` quá cao.** Ngưỡng 10s ẩn đi hàng nghìn query 1-3s — chính chúng mới là thứ giết hệ thống | Kiểm tra `SHOW VARIABLES LIKE 'long_query_time'` **trước** khi tin vào `Slow_queries` |
| **`LIMIT` không giới hạn công việc, chỉ giới hạn output.** `LIMIT 50` vẫn có thể quét 953k dòng | Luôn xem `rows_examined` trong slow log, không xem số dòng trả về |
| **`table_rows` trong `information_schema` là ước lượng.** Báo 218,651 trong khi `COUNT(*)` cho 239,395 | Cần chính xác thì `COUNT(*)`; `information_schema` chỉ để ước lượng nhanh |

### Index

| Bài học | Cách phát hiện sớm lần sau |
|---|---|
| **`WHERE a = ? ORDER BY b LIMIT n` cần composite index `(a, b)`.** Hai index đơn cột không thay thế được, vì MySQL chỉ dùng 1 index/bảng | Thấy pattern này trong slow log → kiểm tra ngay có composite index chưa |
| **`possible_keys` có index nhưng `key` chọn cái khác = optimizer đang đánh đổi.** Không phải "thiếu index", mà là "index hiện có không đủ tốt để vừa lọc vừa sort" | Đọc `EXPLAIN`: `possible_keys` ≠ `key` + `Extra: Using where` → dấu hiệu cần composite index |
| **Cardinality thấp làm optimizer bỏ qua index.** `document_kb_id` Cardinality=18 trên 239k dòng → mỗi giá trị khớp ~13k dòng, optimizer thấy không lợi | `SHOW INDEX FROM <table>` — so Cardinality với tổng số dòng |
| **`rows` trong EXPLAIN có thể sai rất xa.** Báo 100, thực tế 953,020 | Đừng tin `rows` của EXPLAIN; đối chiếu với `rows_examined` trong slow log |

### Kubernetes / storage

| Bài học | Cách phát hiện sớm lần sau |
|---|---|
| **`capacity` của local PV là metadata, không phải giới hạn.** PVC ghi 5Gi nhưng thực tế dùng 99G — không có cơ chế enforce | Luôn `kubectl exec <pod> -- df -h <mountpath>` để biết dung lượng **thật**, không tin PVC |
| **Local PV trên root filesystem = DB dùng chung đĩa với containerd.** Một image 7.2GB có thể gây `disk-pressure` và hạ gục DB không liên quan | `df -h` bên trong pod — nếu mount point báo cùng size với `/` của node thì đang dùng chung |
| **`resources: {}` = BestEffort = evict đầu tiên.** Chart demo thường bỏ trống mục này | `kubectl get pod X -o jsonpath='{.spec.containers[0].resources}'` — ra `{}` là cờ đỏ |
| **`describe node` cho biết requests/limits, KHÔNG cho biết mức dùng thực.** Node báo "1% memory" chỉ nghĩa là các pod **khai báo** ít, không nghĩa là RAM đang rảnh | Cần mức dùng thực → phải có metrics-server |

### Phương pháp

| Bài học | Cách phát hiện sớm lần sau |
|---|---|
| **"Chậm" không đồng nghĩa "tải cao".** Ở đây 93 QPS là mức trung bình — vấn đề nằm ở chất lượng query và config, không phải khối lượng | Đo QPS (`Questions/Uptime`) và connection headroom **trước** khi kết luận quá tải |
| **Chart Helm upstream tối ưu cho demo, không cho production.** Mọi tham số MySQL trong phiên này đều là giá trị mặc định chưa ai chạm vào | Khi tiếp nhận một deploy bằng chart upstream: rà `resources`, `buffer_pool`, PV thật, probe, log — mặc định là chưa tune |

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| `SET GLOBAL slow_query_log/long_query_time` chỉ nằm trong runtime | Issue 5 — workaround trong phiên này | Restart pod (mà Issue 2, 4 đều cần) → mất cấu hình, mù quan sát trở lại |
| MySQL 1 replica, không HA | Chart mặc định | Mất pod = mất toàn bộ metadata RagFlow (KB, document, user, model config) |
| MySQL dùng chung đĩa với containerd trên node07 | Issue 3 | Đĩa đầy → MySQL không ghi được → **hỏng dữ liệu** |
| PVC 5Gi không phản ánh thực tế 70G | Issue 3 | Người vận hành nhìn PVC tưởng an toàn, không ai theo dõi dung lượng thật |
| Không có backup MySQL ❓ | chưa kiểm tra trong phiên | Kết hợp với 3 dòng trên → mất dữ liệu không khôi phục được |
| Chưa có metrics-server / giám sát MySQL | Issue 6 | Không phát hiện được suy thoái, chỉ biết khi user kêu |

❓ **Chưa xác minh**: có backup MySQL hay không — không kiểm tra trong phiên này. **Nên kiểm tra sớm**, vì đây là nợ nguy hiểm nhất trong bảng.

---

## 7. Việc tiếp theo

### Ngay lập tức (không downtime)

- [ ] Tạo composite index:
```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
```
- [ ] Chạy lại `EXPLAIN` query cũ, xác nhận `key` = `idx_document_kb_create` và `rows` giảm mạnh
- [ ] Đo lại thời gian query thực tế sau khi có index
- [ ] Dọn image cũ trên node07:
```
crictl rmi --prune
```
- [ ] Kiểm tra lại dung lượng sau khi dọn:
```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```
- [ ] Kiểm tra xem có backup MySQL không

### Ngắn hạn (cần 1 lần restart pod, ~2 phút)

Gộp chung một lần restart:

- [ ] Đọc `helm_ragflow_v0.26.4/templates/mysql.yaml` để biết cơ chế truyền config MySQL
- [ ] Đặt `innodb_buffer_pool_size = 3G`
- [ ] Đặt `slow_query_log=ON`, `long_query_time=1`, `log_output=TABLE` vào ConfigMap (xoá nợ kỹ thuật ở Issue 5)
- [ ] Đặt `resources` cho MySQL: requests `cpu:1/memory:4Gi`, limits `cpu:2/memory:6Gi`
- [ ] Sau restart, xác minh:
```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
```
```sql
SHOW VARIABLES LIKE 'slow_query_log';
```
- [ ] Theo dõi `Innodb_buffer_pool_reads` sau 24h, so với mức 6,212/giây hiện tại

### Dài hạn

- [ ] Tách MySQL sang đĩa/volume riêng, không dùng chung `/dev/vda1` với containerd
- [ ] Cài metrics-server
- [ ] Thêm mysqld_exporter + dashboard Grafana (buffer pool hit ratio, slow query rate, connection, dung lượng)
- [ ] Cảnh báo dung lượng `/dev/vda1` node07 ở ngưỡng 80%
- [ ] Đánh giá phương án MySQL HA (MySQL Operator / Patroni-like)
- [ ] Thiết lập backup định kỳ + kiểm thử restore

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Đĩa `/dev/vda1` node07 đầy (còn 25G/99G) → MySQL không ghi được → **hỏng dữ liệu** | 🔴 Cao | Dọn image ngay; cảnh báo 80%; dài hạn tách đĩa riêng |
| Mất pod MySQL = mất toàn bộ metadata (1 replica, backup ❓) | 🔴 Cao | Kiểm tra backup ngay; đánh giá HA |
| Pod MySQL bị evict do BestEffort khi node gặp áp lực | 🟡 TB | Đặt resources (Ngắn hạn) |
| Restart pod làm mất cấu hình slow log đang có | 🟡 TB | Đưa vào ConfigMap **trong cùng lần restart** |
| Tăng buffer pool 3G nhưng đặt memory limit thấp → OOMKill | 🟡 TB | Limit 6Gi ≥ buffer pool + overhead; làm 2 thay đổi cùng lúc |
| `CREATE INDEX` trên bảng 1GB gây tải đột biến ❓ | 🟢 Thấp | MySQL 8.0 dùng INPLACE, không khoá bảng; nên chạy giờ thấp điểm để chắc |
| Dữ liệu tiếp tục tăng (239k doc và đang lên) làm working set vượt 3G | 🟢 Thấp | Theo dõi qua Grafana sau khi có monitoring |

---

## Phụ lục — Lệnh đã dùng trong phiên

Lấy password MySQL:
```
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d
```

Trạng thái tổng quan:
```sql
SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Questions','Threads_connected','Threads_running','Threads_created','Threads_cached','Max_used_connections','Slow_queries','Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads');
```

Buffer pool:
```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
```

Bật slow log:
```sql
SET GLOBAL slow_query_log = 'ON';
```
```sql
SET GLOBAL long_query_time = 1;
```
```sql
SET GLOBAL log_output = 'TABLE';
```

Kích thước bảng:
```sql
SELECT table_name, ROUND(data_length/1024/1024,1) AS data_mb, ROUND(index_length/1024/1024,1) AS index_mb, ROUND((data_length+index_length)/1024/1024,1) AS total_mb, table_rows FROM information_schema.tables WHERE table_schema='rag_flow' ORDER BY (data_length+index_length) DESC LIMIT 10;
```

Index của bảng document:
```sql
SHOW INDEX FROM rag_flow.document;
```

Dung lượng đĩa thật:
```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```

Resources của pod:
```
kubectl -n ragflow get pod ragflow-mysql-0 -o jsonpath='{.spec.containers[0].resources}'
```

Tài nguyên node:
```
kubectl describe node vrp-kubeengine07
```
