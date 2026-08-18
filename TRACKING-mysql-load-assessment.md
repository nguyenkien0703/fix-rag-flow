# TRACKING — Đánh giá tải MySQL của RagFlow

**Phiên:** 05/08/2026 (chẩn đoán ban đầu) + 06-07/08/2026 (bổ sung: node06/08, đối tác báo chậm, đánh giá hướng xử lý)
**Đối tượng:** pod `ragflow-mysql-0`, namespace `ragflow`, node `vrp-kubeengine07`
**Trạng thái phiên:** 🔶 ĐANG DỞ — đã hoàn tất chẩn đoán + đánh giá hướng xử lý + lên plan migrate chi tiết, **chưa thực thi bất kỳ thay đổi nào**.
**Lệnh tham khảo (kèm giải nghĩa cờ):** `commands/mysql-load-assessment.md`
**Plan thực thi ngắn hạn (đã duyệt, chưa chạy):** `PLAN-mysql-migrate-node06.md`

---

## 1. Mục tiêu

Kiểm tra tải của pod MySQL phục vụ RagFlow, xác định xem MySQL có phải nút thắt hiệu năng hay không, và nếu có thì do đâu.

### Bối cảnh hạ tầng

| Hạng mục | Giá trị | Nguồn |
|---|---|---|
| Chart | `helm_ragflow_v0.26.4` (đã deploy thành công 02/08) | phiên trước |
| MySQL replicas | 1 | chart |
| StorageClass | `local-mysql` (`kubernetes.io/no-provisioner`, Retain, không cho expand) | `kubectl get storageclass` |
| PV | `pv-ragflow-mysql` — **hostPath** `/data/ragflow/mysql` | `local-pv.yaml` |
| PV capacity khai báo | 5Gi (**không được enforce** — xem Issue 3) | `local-pv.yaml` |
| Dung lượng thật | `/dev/vda1` 99G, đã dùng 70G (74%) | `df -h` trong pod |
| Node đặt MySQL | `vrp-kubeengine07` (label `ragflow-target=true`) | `values.yaml` nodeSelector |
| DB schema | `rag_flow` | |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Query list document 11.1s, quét 953,020 dòng cho `LIMIT 50` | 🔴 Cao | ✅ FIXED (07/08) | Đã tạo `idx_document_kb_create`; đo thực tế 0.02s (giảm ~500 lần). Nợ nhỏ: optimizer mặc định vẫn không tự chọn index này, xem chi tiết Issue 1 |
| 1b | `duplicate_name(kb_id, name)` — nghi ngờ ban đầu (07/08) là thiếu index, đã `EXPLAIN` xác minh và **bác bỏ** | ⚪ Không phải issue | ✅ ĐÃ XÁC MINH KHÔNG CÓ VẤN ĐỀ (07/08) | Không cần làm gì — xem chi tiết bên dưới |
| 2 | `innodb_buffer_pool_size`=128MB / working set 1.85GB → 6,200 lần đọc đĩa/giây | 🔴 Cao | 🔶 OPEN | Tăng lên 3G, cần restart pod |
| 3 | PV `hostPath` khai báo 5Gi nhưng thực tế ghi vào `/dev/vda1` 99G đã dùng 74%, chung với MinIO/Redis/containerd | 🔴 Cao | 🔶 OPEN | Dọn image + PV rác; dài hạn tách đĩa riêng |
| 4 | Pod MySQL `resources: {}` → QoS BestEffort | 🟡 TB | 🔶 OPEN | Đặt requests/limits |
| 4b | 18 pod bị **Evicted** trên node07 (tuổi 25h/33h) — hệ quả trực tiếp của Issue 4 đang **thực sự xảy ra**, không còn là rủi ro lý thuyết | 🔴 Cao | 🔶 OPEN — mới phát hiện 06/08 | Cùng lượt xử lý Issue 4 (đặt resources); dọn pod Evicted rác |
| 5 | `slow_query_log` OFF + `long_query_time`=10s → mù quan sát | 🟡 TB | ⚠️ WORKAROUND | Đã bật bằng `SET GLOBAL` (mất khi restart) → cần đưa vào ConfigMap |
| 6 | Chưa có metrics-server → `kubectl top` không dùng được | 🟡 TB | 🔶 OPEN | Cài metrics-server |
| 7 | `get_filter_by_kb_id()` (API filter panel) kéo TOÀN BỘ document của KB về Python để đếm tay thay vì `GROUP BY` SQL — 39s với KB 394k doc | 🔴 Cao | 🔶 OPEN — phát hiện 07/08, root cause **là code RagFlow**, không phải DB | Ngoài phạm vi dự án (chỉ sửa qua values.yaml/helm) — cần báo đội phát triển app/team quản lý source RagFlow |

**Kết luận chung (phiên 05/08):** tải thực tế **không lớn** (~93 QPS, 184/1000 connection). Nút thắt đến từ việc **toàn bộ tham số MySQL để nguyên mặc định của chart demo**, chưa tune cho dữ liệu thật 239k document.

**Cập nhật 06-07/08 (đối tác báo chậm 55s/vb khi upload document):**
- node06, node08 xác nhận **gần như rảnh** (CPU 2-3% và 0.4%, load avg ~1 và ~0.2) — loại trừ khả năng cả cụm quá tải, khoanh đúng vào node07/MySQL
- node07 tại thời điểm đo: CPU 80% user, `mysqld` chiếm 666.7% (~6.7/8 core), load avg 19.52 trên node 8 core — **CPU-bound, không phải I/O-bound** (`wa`=0.0%, xem điều chỉnh Issue 2 bên dưới)
- Bước "Upload document" (25s trong 55s/vb đối tác báo) khớp với kiến trúc code: mỗi upload có **≥4 round-trip MySQL tuần tự + 3 round-trip MinIO tuần tự + 1 tác vụ CPU** (thumbnail), không cái nào chạy song song → một bước chậm (query thiếu index) kéo dài cả chuỗi (xem Issue 1b)
- Đã đánh giá feasibility 4 hướng xử lý (xem mục 9) — **chốt ngắn hạn: đánh index + chuyển MySQL sang node06**, KHÔNG dùng read replica (bị chặn cứng bởi chart, xem mục 9)

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

⚠️ **Lưu ý (bổ sung 11/08)**: con số **8 core / 16GB** này là của **node07** — nơi MySQL chạy tại
thời điểm đo. **node06 (nơi MySQL chạy sau khi migrate) có 16 core / 32GB** — cấu hình khác hẳn.
Bằng chứng: `top` trên node06 ghi `KiB Mem: 32778180 total` ≈ 32GB.
Đừng mang số 8 core sang node06 khi tính `load average ÷ số core` (đã mắc lỗi này một lần).

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

3. ✅ **Đã đo thực tế (07/08)**: `CREATE INDEX` mất **8.77 giây** trên bảng ~1GB/239k dòng — không đáng lo như ước tính ban đầu.

**✅ ĐÃ THỰC HIỆN (07/08/2026, trong `PLAN-mysql-migrate-node06.md` Bước 1)**

```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
-- Query OK, 0 rows affected (8.77 sec)
```

Xác minh bằng `EXPLAIN` + đo thời gian thật:
- Đo thời gian thực tế của đúng query gây chậm (chỉ `SELECT t1.id` để tránh tốn công truyền dữ liệu, giữ nguyên WHERE/JOIN/ORDER BY): **50 rows in set (0.02 sec)** — so với baseline 11.1s, giảm **~500 lần**.
- ⚠️ **Phát hiện phụ, chưa giải quyết**: `EXPLAIN` mặc định (không ép index) **vẫn chọn** `key: document_kb_id` (không phải `idx_document_kb_create`) dù đã `ANALYZE TABLE` cập nhật thống kê — optimizer đang đánh giá sai chi phí, không tự nhận ra index mới tốt hơn.
- Dùng `FORCE INDEX (idx_document_kb_create)` để xác nhận dứt khoát index hoạt động đúng: `Extra` từ `Using temporary; Using filesort` (khi dùng key sai) chuyển thành **trống hoàn toàn** — bằng chứng rõ ràng index đã loại bỏ đúng cả filesort lẫn temporary table.
- **Quyết định (đã hỏi ý kiến, chốt "không sửa"):** không sửa code RagFlow để thêm `FORCE INDEX` — nằm ngoài phạm vi (dự án chỉ deploy qua values.yaml/helm, không sửa code app), và 0.02s đã đủ nhanh cho mục tiêu thực tế. Giữ nguyên là **nợ kỹ thuật nhỏ**, xem mục 6.

**Trạng thái cuối: ✅ FIXED** — root cause (thiếu composite index) đã xử lý, có bằng chứng đo thực tế. Không còn là 🔶 OPEN.

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

PV `pv-ragflow-mysql` là **`hostPath`** trỏ vào `/data/ragflow/mysql` — một thư mục thường trên root filesystem `/dev/vda1` của node07, dùng chung với containerd image store và log.

StorageClass `local-mysql` dùng `provisioner: kubernetes.io/no-provisioner` — **không có provisioner nghĩa là không ai tạo volume riêng**. Không có LVM, không có partition, không có quota. `capacity: 5Gi` chỉ là metadata cho scheduler tính toán, **không giới hạn gì về mặt vật lý**. MySQL ghi thoải mái cho tới khi đầy cả đĩa node.

**Bằng chứng**

1) Định nghĩa PV — `local-pv.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-ragflow-mysql
spec:
  storageClassName: "local-mysql"
  capacity: { storage: 5Gi }
  accessModes: [ ReadWriteOnce ]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /data/ragflow/mysql }
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: ragflow-target
              operator: In
              values: [ "true" ]
```

2) StorageClass — `kubectl get storageclass`:
```
NAME                 PROVISIONER                    RECLAIMPOLICY  VOLUMEBINDINGMODE     ALLOWVOLUMEEXPANSION
local-minio          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
local-mysql          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
local-path (default) rancher.io/local-path          Delete         WaitForFirstConsumer  false
local-redis          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
```

3) Dung lượng thật bên trong pod:
```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```
```
Filesystem   Size  Used Avail Use% Mounted on
/dev/vda1     99G   70G   25G  74% /var/lib/mysql
```

Đối chiếu: PV khai báo `5Gi`, nhưng mount point báo 99G tổng / 70G đã dùng — **đó là toàn bộ `/dev/vda1` của node**. Hai con số không liên quan gì đến nhau. `hostPath` + `no-provisioner` giải thích chính xác vì sao.

**Phát hiện thêm — cả 3 service RagFlow dùng chung một gốc đĩa**

Từ cùng file `local-pv.yaml`, ba PV cùng gốc `/data/ragflow/`:

| PV | hostPath | StorageClass | Trạng thái |
|---|---|---|---|
| `pv-ragflow-mysql` | `/data/ragflow/mysql` | local-mysql | Bound → `ragflow/ragflow-mysql` |
| `pv-ragflow-minio` | `/data/ragflow/minio` | local-minio | Bound → `ragflow/ragflow-minio` |
| `pv-ragflow-redis` | (❓ chưa thấy trong ảnh, suy ra `/data/ragflow/redis`) | local-redis | Bound → `ragflow/redis-data-ragflow-redis-0` |

→ MySQL, MinIO, Redis **và** containerd image store đều nằm trên `/dev/vda1`. Không có cách ly nào giữa chúng — bất kỳ thành phần nào làm đầy đĩa thì cả ba service chết theo.

**Đo thực tế mức chiếm đĩa** (`du -sh /data/ragflow/* /var/lib/containerd` trên node07):

```
3.3M    /data/ragflow/elasticsearch
3.2G    /data/ragflow/minio
2.5G    /data/ragflow/mysql
37M     /data/ragflow/redis
27G     /var/lib/containerd
```

| Thành phần | Dung lượng | Ghi chú |
|---|---|---|
| `/var/lib/containerd` | **27 G** | 🔴 **Thủ phạm chính** — gấp ~4.7 lần toàn bộ dữ liệu RagFlow |
| minio | 3.2 G | |
| mysql | 2.5 G | Đã dùng 50% của "5Gi" khai báo |
| redis | 37 M | |
| elasticsearch | 3.3 M | Rác — đã tắt ES nội bộ |
| **Tổng `/data/ragflow`** | **~5.8 G** | |

⚠️ **Điều chỉnh giả định trước đó**: ban đầu suy đoán MinIO là thứ ăn đĩa nhiều nhất (vì lưu file gốc 239k document). **Sai** — MinIO chỉ 3.2G. Image store containerd mới là nguyên nhân, khớp với sự cố `disk-pressure` 31/07 do image 7.2GB.

❓ **Chưa lý giải được**: `df` báo đã dùng **70G**, nhưng hai đường dẫn trên chỉ đếm được **32.8G**. Còn ~37G nằm ở chỗ khác trên `/dev/vda1` — cần tìm (log hệ thống, `/var/lib/kubelet`, hoặc workload khác của node07).

**Ghi chú về ngưỡng 5Gi của MySQL**: hiện 2.5G, tức 50% con số khai báo. Vì `hostPath` không enforce, khi vượt 5Gi sẽ **không có cảnh báo nào** — nó chỉ âm thầm lấn sang phần đĩa còn lại. Đây chính là cái nguy hiểm của việc khai báo capacity ảo.

**Phát hiện thêm — 2 bộ PV song song, bộ cũ có thể là rác**

`kubectl get pv` cho thấy:

| PV | Capacity | Age | Claim |
|---|---|---|---|
| `pv-ragflow-mysql` / `-minio` / `-redis` | 5Gi mỗi cái | 92d | ns `ragflow` (đang dùng) |
| `pv-ragflow-custom-mysql` / `-minio` / `-redis` | 5Gi mỗi cái | 8d | ns `ragflow-custom` (từ lần test 31/07) |

Cả 6 PV đều `Retain` + `Bound`, **cùng nằm trên node07**. Bộ `-custom` sinh ra khi test image v2 ở namespace `ragflow-custom`; nếu namespace đó không còn cần thì đây là dung lượng chiếm vô ích trên chính cái đĩa đang 74%.

❓ **Chưa xác minh**: namespace `ragflow-custom` còn dùng hay không, và bộ PV custom đang chiếm bao nhiêu GB. Cần kiểm tra trước khi xoá — `Retain` nghĩa là xoá PV **không** tự xoá dữ liệu, phải xoá thư mục thủ công.

**Phát hiện thêm — rác PVC**

`ragflow-es-data` ở trạng thái **Pending 69 ngày** (storageClass `local-elasticsearch`). Khớp với việc đã tắt `elasticsearch.enabled=false` để dùng ES ngoài. Không gây hại, nhưng là rác nên dọn.

**Hệ quả kép**

1. **Đã xảy ra (31/07)** — image `infiniflow/ragflow:v0.24.0` (7.2GB) đẩy đĩa node07 vượt ngưỡng → kubelet gắn taint `disk-pressure` `NoSchedule` → pod mysql/minio/redis không schedule được, `Pending` gián đoạn. MySQL bị hạ gục bởi **một image không liên quan**, vì dùng chung đĩa. (Chi tiết ở `TRACKING-ragflow-v0.26.4-upgrade.md` Issue 7)

2. **Rủi ro còn lại** — còn 25GB trống. Nếu đĩa đầy, MySQL không ghi được → **hỏng dữ liệu**, không chỉ là chậm. Kết hợp với Issue 4 (BestEffort), pod này là ứng viên bị evict đầu tiên.

**Đây là bằng chứng cứng nhất cho nhận định "triển khai sơ sài"**: con số 5Gi trong PV không phản ánh gì về thực tế và tạo cảm giác an toàn giả — người vận hành nhìn PVC tưởng DB chỉ chiếm 5GB, trong khi thực tế là cả 3 service dùng chung 99GB với containerd, đã hết 74%.

**Đã thử / cân nhắc**

| Phương án | Kết quả |
|---|---|
| Tin vào `capacity: 5Gi` của PVC | ❌ **Sai** — chỉ là metadata. Phải `df -h` bên trong pod mới biết thực tế |
| `crictl rmi --prune` dọn image (đã làm 31/07) | ✅ Gỡ được `disk-pressure` lần đó — nhưng là **workaround**, root cause (dùng chung đĩa) còn nguyên |
| Mở rộng PV để lấy thêm dung lượng | ❌ **Loại** — `ALLOWVOLUMEEXPANSION: false` trên cả 3 storageclass; hơn nữa với `hostPath` thì "mở rộng" vô nghĩa vì vốn đã dùng cả đĩa |

**Hướng xử lý tiếp**

1. **Ngay** — dọn image cũ trên node07:
```
crictl rmi --prune
```
2. **Ngay** — đo xem thư mục nào đang ăn đĩa nhiều nhất trên node07:
```
du -sh /data/ragflow/* /var/lib/containerd
```
3. **Ngay** — thiết lập cảnh báo dung lượng `/dev/vda1` node07 ở ngưỡng 80%.
4. **Ngắn hạn** — xác minh namespace `ragflow-custom` còn dùng không; nếu không thì xoá deployment + PV + **thư mục dữ liệu** (vì `Retain` không tự xoá).
5. **Ngắn hạn** — xoá PVC rác `ragflow-es-data`.
6. **Dài hạn** — tách `/data/ragflow` sang đĩa/LVM riêng, hoặc ít nhất tách MySQL khỏi MinIO. Việc này **quan trọng hơn cả HA**: hiện tại một image lớn hoặc một đợt upload file bất kỳ có thể hạ gục DB.

**Rủi ro này KHÔNG biến mất sau khi migrate sang node06 (07-08/08/2026)** — PV mới
`pv-ragflow-mysql-node06.yaml` giữ nguyên y hệt cơ chế `hostPath` + `storageClassName: local-mysql`
(no-provisioner) + `capacity: 5Gi` như PV cũ, cố ý để nhất quán với ràng buộc "chỉ deploy qua
values.yaml/helm" của dự án. Node06 hiện có 75G trống (61% used, dư dả hơn node07 lúc chỉ còn
25G/74% used) nên rủi ro ngắn hạn thấp hơn, nhưng bản chất vấn đề — MySQL có thể ghi vượt xa 5Gi
tới khi hết cả đĩa node — vẫn y nguyên, chỉ là chuyển từ node07 sang node06. Xem Q&A chi tiết ngay
bên dưới.

---

#### ❓ Hỏi & Đáp — `capacity: 5Gi` trong PV nghĩa là gì, tại sao MySQL lại ghi gần hết cả đĩa node?

> **Kiên hỏi (08/08/2026)**: PV cho MySQL khai `capacity: 5Gi` — vậy dung lượng lưu trữ chỉ tối
> đa 5GB, không thể hơn được à? Và tại sao trước đó khi MySQL ở node07, PV cũng khai 5GB nhưng
> sau đó lại lưu gần hết cả đĩa?

**Trả lời:**

`capacity: 5Gi` trong PV này **không phải giới hạn thật** — MySQL có thể ghi vượt xa con số này,
cho tới khi hết sạch dung lượng của **toàn bộ ổ đĩa node**, không phải 5Gi. Bằng chứng cụ thể đã
đo được trên node07: `df -h /var/lib/mysql` bên trong pod ra `99G total, 70G used` — đó là dung
lượng cả ổ đĩa `/dev/vda1` của node, không liên quan gì tới số `5Gi` khai trong PV.

Có 2 loại PersistentVolume trong Kubernetes, khác nhau về việc `capacity` có được enforce hay không:

| Loại | Ví dụ | `capacity` có phải giới hạn thật không? |
|---|---|---|
| Có provisioner thật | Cloud disk (EBS, PD), LVM, Ceph | **Có** — hệ thống lưu trữ tạo ra 1 volume đúng kích thước khai báo, ghi vượt sẽ bị chặn/báo lỗi |
| `hostPath` + `no-provisioner` (trường hợp của MySQL ở đây) | `local-mysql`, `local-minio`, `local-redis` | **Không** — chỉ là con số khai báo, không có cơ chế vật lý nào chặn |

Với `hostPath`, PV thực chất chỉ là **1 thư mục thường** (`/data/ragflow/mysql`) nằm trên
filesystem gốc của node — không có "kho chứa ảo" riêng biệt như ổ đĩa cloud. MySQL ghi vào thư
mục đó cũng giống như ghi vào bất kỳ thư mục nào khác trên node, dùng chung dung lượng với mọi
thứ khác (containerd, log hệ thống, MinIO, Redis...). `capacity: 5Gi` chỉ tồn tại để Kubernetes
scheduler **so khớp lúc PVC bind vào PV** (kiểm tra PV có đủ điều kiện logic cho PVC yêu cầu hay
không) — sau bước bind đó, vai trò của con số này kết thúc, không ai theo dõi hay chặn ghi thêm.

> **Kiên hỏi tiếp**: chỗ "PVC yêu cầu 5GB thì PV đã có 5GB nên khớp" — vậy sau đó ứng dụng ghi
> nhiều hơn 5GB cũng không sao, lý do là vì PV này là loại `hostPath` + `no-provisioner`. Nhưng
> nhìn vào file YAML của PV thì làm sao biết được `storageClassName` là `no-provisioner`? Trong
> PV chỉ ghi `storageClassName: local-mysql`, không thấy chữ `no-provisioner` ở đâu cả.

**Trả lời**: Đúng — bản thân file YAML của **PV** không ghi trực tiếp chữ `no-provisioner`.
`storageClassName: local-mysql` trong PV chỉ là **cái tên**, giống như biến tham chiếu — nó
**trỏ tới** một object khác trong cluster tên là `StorageClass`, và chính object `StorageClass`
đó (không phải PV) mới là nơi khai báo `provisioner: kubernetes.io/no-provisioner`. Phải tra
riêng object `StorageClass` mới biết được cơ chế thật:

```
kubectl get storageclass
```
```
NAME                 PROVISIONER                    RECLAIMPOLICY  VOLUMEBINDINGMODE     ALLOWVOLUMEEXPANSION
local-minio          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
local-mysql          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
local-path (default) rancher.io/local-path          Delete         WaitForFirstConsumer  false
local-redis          kubernetes.io/no-provisioner   Retain         WaitForFirstConsumer  false
```

Cột `PROVISIONER` của dòng `local-mysql` chính là bằng chứng — `kubernetes.io/no-provisioner`.
Đây là lệnh đã chạy thật trong phiên chẩn đoán 05/08 (ghi ở mục "Bằng chứng" của Issue 3, gần đầu
mục này) — không phải suy đoán từ nhìn PV, mà từ việc tra thêm object `StorageClass` liên kết.

**Cách nhớ ngắn gọn**: PV nói "tôi thuộc nhóm `local-mysql`" — muốn biết nhóm đó có "luật enforce
dung lượng" hay không, phải hỏi riêng định nghĩa của nhóm (`kubectl get storageclass`), không thể
biết chỉ từ nhìn cái tên trong PV.

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

### 🔴 Issue 7 — API filter panel kéo toàn bộ document của KB về Python để đếm tay — 🔶 OPEN (root cause ở code app, không phải DB)

**Triệu chứng**

Phát hiện trong lúc Bước 4 (xác minh sau migrate) của `PLAN-mysql-migrate-node06.md`: test upload 1 document qua UI xong, quan sát tab Network thấy request `documents?type=filter` và `documents?page=1&page_size=...` mất **39.14s** và **39.11s** — chậm hơn nhiều so với ngưỡng chấp nhận được, dù MySQL vừa migrate xong và Issue 1 (composite index) đã fix.

**Điều tra**

Bật lại `slow_query_log` (giống cách đã làm ở Issue 5), trigger lại request, soi `mysql.slow_log`:

```sql
SELECT start_time, query_time, rows_examined, rows_sent, CONVERT(sql_text USING utf8) AS query
FROM mysql.slow_log ORDER BY start_time DESC LIMIT 5;
```

Bắt được 2 dạng câu chậm, cùng KB (`kb_id='73932b965e5e11f192725fd51894c519'`, KB lớn nhất, giờ có ~153,268-394,310 document — đã tăng nhiều so với ~141k lúc chẩn đoán 05/08):

| query_time | rows_examined | Query |
|---|---|---|
| 19.86s | 1,182,930 | `SELECT COUNT(1) FROM (SELECT 1 FROM document t1 JOIN file2document t2 ... JOIN file t3 ... WHERE t1.kb_id = ?) AS _wrapped` |
| 9.40s | 1,182,930 | `SELECT t1.run, t1.suffix, t1.id FROM document t1 JOIN file2document t2 ... JOIN file t3 ... WHERE t1.kb_id = ?` (không LIMIT) |

`EXPLAIN` câu thứ 2 cho thấy **mỗi bảng đều dùng đúng index** (`document_kb_id`, `file2document_document_id`, PRIMARY trên `file`), không có `Using temporary`/`Using filesort` — **không phải vấn đề thiếu index**. `SHOW INDEX` trên `file2document` và `file` cũng xác nhận đầy đủ index cho path JOIN này. Vấn đề nằm ở việc `t1: rows 153,268` — query đang cố JOIN và trả về **toàn bộ document của KB cùng lúc, không giới hạn**.

**Root cause (xác nhận bằng đọc trực tiếp source code RagFlow, không suy đoán)**

`ragflow-0.24.0/api/db/services/document_service.py`, hàm `get_filter_by_kb_id()` (dòng 187-273):

```python
query = cls.model.select(*fields).join(File2Document, ...).join(File, ...).where(cls.model.kb_id == kb_id)
...
rows = query.select(cls.model.run, cls.model.suffix, cls.model.id)   # dòng 229 — KHÔNG có .limit()
total = rows.count()                                                  # dòng 230 — khớp câu COUNT(1) chậm ở trên
...
doc_ids = [row.id for row in rows]                                    # dòng 237 — duyệt TOÀN BỘ ORM object
...
for row in rows:                                                      # dòng 245 — đếm suffix/run_status THỦ CÔNG trong Python
    suffix_counter[row.suffix] = suffix_counter.get(row.suffix, 0) + 1
    run_status_counter[str(row.run)] = run_status_counter.get(str(row.run), 0) + 1
    ...
```

Gọi từ `ragflow-0.24.0/api/apps/document_app.py:390`:
```python
filter, total = DocumentService.get_filter_by_kb_id(kb_id, keywords, run_status, types, suffix)
return get_json_result(data={"total": total, "filter": filter})
```

→ Đây chính là API đứng sau request `documents?type=filter` — dùng để tính bộ đếm hiển thị ở filter panel (theo suffix, run_status, metadata) trên UI. Thiết kế hiện tại: **mỗi lần cần con số thống kê, code kéo hết danh sách document của cả KB về tầng ứng dụng rồi đếm tay bằng vòng lặp Python**, thay vì để MySQL `GROUP BY`/`COUNT` làm việc đó ở tầng SQL. Với KB nhỏ thì không sao, nhưng ở quy mô 394k document, đây là nghẽn cổ chai thực sự — và sẽ **ngày càng chậm hơn** khi KB tiếp tục phình to, không có ngưỡng chặn nào.

⚠️ Lưu ý version: source code tra được là `ragflow-0.24.0` (có sẵn trong repo), trong khi production đang chạy chart `helm_ragflow_v0.26.4` — **chưa xác minh** hàm `get_filter_by_kb_id` có đổi giữa 2 version hay không, nhưng hành vi quan sát được qua slow log trên production hoàn toàn khớp với logic đọc được ở bản 0.24.0.

**Kết luận: đây là bug/giới hạn thiết kế trong code RagFlow (backend), không phải vấn đề MySQL/database.** MySQL đã trả lời đúng và nhanh nhất có thể cho query được yêu cầu (mỗi JOIN đều dùng đúng index) — cái chậm là do query yêu cầu quá nhiều dữ liệu không cần thiết. **Đánh thêm index không giải quyết được** — không có index nào giúp giảm được việc phải đọc/truyền hết 150k-390k dòng.

**Phạm vi xử lý**

Ngoài phạm vi dự án hiện tại (ràng buộc: chỉ deploy/sửa qua `values.yaml` + Helm, không sửa code app — xem memory `ragflow-deploy-constraints.md`). Không xử lý trong đợt migrate MySQL này.

**Hướng xử lý tiếp**

1. Báo lại cho đội phát triển RagFlow / team quản lý source — đây là việc sửa code, không phải vận hành hạ tầng.
2. Đề xuất kỹ thuật (để tham khảo khi báo, không tự làm): thay đếm thủ công trong Python bằng SQL `GROUP BY suffix`/`GROUP BY run` trực tiếp trên DB — MySQL tính aggregate nhanh hơn nhiều so với kéo hết dữ liệu về rồi đếm tay, và tránh phải truyền 150k-390k dòng qua network.
3. Ngắn hạn (tạm thời, không sửa gốc): nếu team dev chưa xử lý kịp, có thể cân nhắc ẩn/tắt tính năng filter panel cho các KB quá lớn (ví dụ >50k document) từ phía UI, để tránh trigger query này — nhưng đây vẫn là thay đổi code, không phải việc hạ tầng.

---

### ⚪ Issue 1b — `duplicate_name(kb_id, name)` — nghi ngờ thiếu index đã bị BÁC BỎ bằng EXPLAIN — ✅ ĐÃ XÁC MINH

**Nghi ngờ ban đầu (07/08, trước khi đo)**

Từ phân tích flow upload (`file_service.py:514-604`), mỗi file đi qua tuần tự:

1. `get_root_folder` / `init_knowledgebase_docs` / `get_kb_folder` — mỗi cái 1 SELECT trên bảng `file`
2. `duplicate_name(DocumentService.query, name=..., kb_id=...)` — query `document` theo `(kb_id, name)` — **nghi ngờ ban đầu**: cùng lớp vấn đề với Issue 1, có index đơn `kb_id` nhưng không có composite `(kb_id, name)`
3. `STORAGE_IMPL.obj_exist(...)` — 1 HEAD request MinIO
4. `STORAGE_IMPL.put(...)` — PUT file gốc lên MinIO
5. `thumbnail_img(...)` — CPU-bound, nặng với PDF
6. `STORAGE_IMPL.put(...)` lần 2 — PUT thumbnail
7. `DocumentService.insert(doc)` — INSERT MySQL

→ Giả thuyết ban đầu: ≥4 round-trip MySQL + 3 round-trip MinIO + 1 tác vụ CPU, không cái nào song song, cộng dồn thành 25s bước Upload đối tác báo (55s/vb: check 6s, LLM tóm tắt 10s, upload 25s, update metadata 8s, parse chunk 6s).

**Đã `EXPLAIN` trực tiếp (07/08, trong lúc thực thi Bước 1 của `PLAN-mysql-migrate-node06.md`) — kết quả BÁC BỎ nghi ngờ**

```sql
EXPLAIN SELECT * FROM document WHERE kb_id = '73932b965e5e11f192725fd51894c519' AND name = 'test.pdf';
```
```
key: document_name | rows: 1 | filtered: 50.00 | Extra: Using where
```

Không có `Using temporary`, không có `Using filesort`, `rows` ước tính chỉ **1** — hoàn toàn không giống bệnh của Issue 1.

**Root cause thật (khác với nghi ngờ ban đầu)**

`SHOW INDEX FROM rag_flow.document WHERE Key_name = 'document_name'` cho thấy đây là index **đơn cột** trên `name` (không phải composite `(kb_id, name)` như suy luận ban đầu), nhưng `Cardinality = 347,033` trên tổng ~239k dòng — tên file gần như **duy nhất** (độ chọn lọc cực cao). Vì vậy MySQL tra `name` trước là đủ để thu hẹp gần như về 1 dòng ngay lập tức, sau đó check `kb_id` trên phần còn lại gần như miễn phí.

Khác với Issue 1, nơi cột lọc chính (`kb_id`, chỉ 18 giá trị phân biệt) có độ chọn lọc **thấp** nên buộc phải kết hợp với sort mới hiệu quả — đây chính là lý do 2 query cùng dạng `WHERE kb_id = ? AND ...` lại có 2 kết cục khác hẳn nhau.

**Bài học**: suy luận "cùng shape query = cùng bệnh" từ đọc code là **không đủ** — độ chọn lọc (cardinality) của từng cột quyết định index nào thật sự cần, phải `EXPLAIN` trực tiếp mới kết luận được, không suy diễn từ cấu trúc SQL.

**Kết luận**: không cần tạo thêm index cho `duplicate_name`. 25s ở bước Upload trong báo cáo đối tác **không** đến từ query này — nguyên nhân thật (nếu còn tồn tại sau khi đánh index Issue 1 + migrate node) nhiều khả năng nằm ở các bước MinIO/CPU thumbnail hoặc cộng dồn độ trễ khi nhiều pod cùng lúc đập vào MySQL/MinIO trên node07 quá tải — chưa đo lại sau khi xử lý Issue 1, cần đo lại 55s/vb sau khi hoàn tất migrate để biết còn treo ở đâu.

---

### 🟡 Issue 4b — 18 pod Evicted trên node07 (hệ quả thực tế của Issue 4) — 🔶 OPEN

**Triệu chứng**

`kubectl get pods -n ragflow` cho thấy 18 pod ở trạng thái **Evicted** (tuổi 25h và 33h), 2 pod `ContainerStatusUnknown`, 1 `Init:ImagePullBackOff`. `ragflow-minio-0`, `ragflow-mysql-0`, `ragflow-redis-0` vẫn `Running`.

**Root cause**

Chính là Issue 4 (`resources: {}` → QoS BestEffort) nhưng **đã xảy ra thật**, không còn là rủi ro lý thuyết — khi node07 gặp áp lực tài nguyên (khớp với giai đoạn CPU 80%/load 19.5), kubelet evict các pod BestEffort trước.

**Bằng chứng**

Lệnh tra `.status.message`/`.status.reason` của 1 pod tuổi 33h — xem `commands/mysql-load-assessment.md` mục 3.

**Còn tồn đọng**

18 pod Evicted vẫn tồn tại trong `kubectl get pods` cho tới khi bị xoá thủ công (Kubernetes không tự dọn) — gây nhiễu khi đọc trạng thái cluster, và là bằng chứng cho thấy node07 đã thực sự chạm ngưỡng resource pressure ít nhất 1 lần trong 25-33h qua.

**Hướng xử lý tiếp**

1. Dọn 18 pod Evicted rác (không ảnh hưởng dữ liệu, chỉ là pod object cũ):
```
kubectl get pods -n ragflow --field-selector=status.phase=Failed -o name | xargs kubectl delete -n ragflow
```
2. Xử lý gốc: đặt `resources` cho **toàn bộ** pod RagFlow đang BestEffort, không chỉ MySQL — cần rà lại `values.yaml` xem còn service nào bỏ trống `resources`.
3. Việc chuyển MySQL sang node06 (mục 9) sẽ giảm áp lực trực tiếp lên node07, gián tiếp giảm khả năng evict tái diễn — nhưng không thay thế được việc đặt resources.

---

### 🔵 Điều chỉnh Issue 2 — cơ chế là CPU-bound, không phải I/O-bound (kết luận không đổi)

**Bằng chứng mới (06/08)**

`top -bn1 -o %CPU` trên node07 lúc `mysqld` chiếm 666.7% CPU: `%Cpu(s): 80.0 us, 4.0 sy, 16.0 id, 0.0 wa` — iowait = 0%, và `buff/cache` ~8.6GB dù `innodb_buffer_pool_size` chỉ 128MB.

**Diễn giải**

Phần lớn trong 2.6 tỷ lần "đọc đĩa" của InnoDB (Issue 2) thực chất được **OS page cache hấp thụ** — không phải chờ đĩa vật lý thật. Chi phí thật nằm ở **CPU overhead**: syscall, copy trang nhớ từ page cache vào buffer pool, decode InnoDB — không phải iowait.

**Kết luận**: hướng xử lý **không đổi** (vẫn phải tăng `innodb_buffer_pool_size` lên 3G) — nhưng cơ chế lợi ích thì khác: tăng buffer pool sẽ **giảm CPU** (bớt việc copy/decode lặp lại), không phải giảm chờ I/O như suy đoán ban đầu.

---

## 9. Đánh giá feasibility các hướng xử lý (06-07/08/2026)

Bối cảnh: sếp hỏi có thể tận dụng node06/node08 đang rảnh để tăng tốc RagFlow/MySQL không. Đã đọc trực tiếp `helm_ragflow_v0.26.4/templates/mysql.yaml` và `mysql-config.yaml` trước khi kết luận (không suy đoán).

| # | Hướng | Feasibility | Bằng chứng |
|---|---|---|---|
| A | Đánh composite index (Issue 1, 1b) | ✅ Khả thi cao, không downtime | `ALGORITHM=INPLACE` MySQL 8.0 |
| B | Chuyển MySQL sang node06 (đổi node chạy, giữ MinIO/Redis ở node07) | ✅ Khả thi, cần downtime ngắn để migrate data | `nodeSelector` (dòng 49-52 `mysql.yaml`) **đã templated** từ `.Values.mysql.deployment.nodeSelector` — đúng cơ chế deploy-qua-values.yaml hiện tại. **Nhưng** PV là `hostPath` + `nodeAffinity` gắn cứng vào node07 (`ragflow-target=true`, xem `local-pv.yaml` Issue 3) → đổi `nodeSelector` của pod **không tự di chuyển dữ liệu** — bắt buộc phải tạo PV mới trên node06 + copy/migrate data thủ công |
| C | Tách MySQL ra server riêng hoàn toàn | ✅ Khả thi, là việc dài hạn | Xử lý gốc: hiện MySQL đang dùng chung `/dev/vda1` với MinIO/Redis/containerd (Issue 3) |
| D | Dùng node06/08 làm MySQL read replica | ❌ **KHÔNG khả thi ngắn hạn** | 2 rào cản cứng: (1) `mysql.yaml` dòng 31 `replicas: 1` **hardcode**, không đọc từ values — chart không hỗ trợ multi-replica; (2) dòng 82 `args: --disable-log-bin` **hardcode** — binlog là điều kiện bắt buộc để replication chạy, đang bị tắt cứng. Ngoài ra RagFlow dùng Peewee ORM với 1 connection string duy nhất (`service_conf.yaml`), chưa có cơ chế route read/write — phải sửa cả code ứng dụng. Đây là dự án riêng, không làm trong đợt này. |

**Đã chốt — Ngắn hạn (plan chi tiết đã duyệt: `PLAN-mysql-migrate-node06.md`):**
1. Đánh composite index `idx_document_kb_create` (Issue 1) — và đánh giá thêm cho `duplicate_name` (Issue 1b)
2. Chuyển MySQL từ node07 sang node06, **giữ nguyên MinIO/Redis ở node07** để giảm tải node07 mà không dồn hết sang node06

**Dài hạn (chưa lên plan):**
- Tách MySQL ra server/đĩa riêng hoàn toàn (Issue 3, hướng C)
- Đánh giá MySQL HA (cần sửa chart bỏ `--disable-log-bin` + `replicas`, và sửa code app để route read/write — không làm trong đợt ngắn hạn)

**Ý kiến sếp (Nguyễn Chí Đông, 07/08 08:34, qua chat) — ràng buộc bắt buộc cho plan migrate node06:**
> "Ủa, tác động thì báo thôi" — chỉ cần báo trước khi tác động, không cần xin duyệt từng bước.
> "thế phải lên plan chi tiết từ sáng, chuyển mysql liên quan đến migrate dữ liệu, mà migrate thì có 2 kiểu, 1 là copy data rồi mount lại, 2 là dump DB rồi restore. Tạm thế"
> "nếu làm dc cách 1 thì anh nghĩ là nhàn" — ưu tiên cách 1 (copy hostPath data + mount lại PV mới) nếu khả thi, vì đỡ việc hơn cách 2 (mysqldump/restore).
> "tránh sai sót về user/pass, các constrain,..." — lưu ý rủi ro cụ thể cần kiểm tra kỹ khi migrate.

→ Plan chi tiết đã soạn và duyệt tại `PLAN-mysql-migrate-node06.md`, ưu tiên **Cách 1 (copy hostPath + mount lại PV qua rsync)**, giữ Cách 2 (dump/restore) làm fallback bằng văn bản nếu Cách 1 vướng lỗi giữa chừng.

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
| **`capacity` của local PV là metadata, không phải giới hạn.** PV ghi 5Gi nhưng thực tế dùng chung 99G — không có cơ chế enforce | Luôn `kubectl exec <pod> -- df -h <mountpath>` để biết dung lượng **thật**, không tin PVC |
| **`provisioner: kubernetes.io/no-provisioner` = không ai tạo volume.** PV chỉ là thư mục thường trên node; không LVM, không partition, không quota | `kubectl get storageclass` — thấy `no-provisioner` thì `capacity` chắc chắn là số ảo |
| **`hostPath` là cờ đỏ mạnh hơn cả `local`.** `local` volume ít ra còn có thể trỏ vào block device riêng; `hostPath` thì luôn là thư mục trên filesystem sẵn có | `kubectl get pv <name> -o yaml \| grep -A2 hostPath` |
| **Local PV trên root filesystem = DB dùng chung đĩa với containerd.** Một image 7.2GB có thể gây `disk-pressure` và hạ gục DB không liên quan | `df -h` bên trong pod — nếu mount point báo cùng size với `/` của node thì đang dùng chung |
| **Nhiều PV cùng gốc thư mục = không có cách ly giữa các service.** `/data/ragflow/{mysql,minio,redis}` — MinIO ngốn đĩa thì MySQL chết theo | Đọc file định nghĩa PV, so các `hostPath` xem có chung parent không |
| **`Retain` + xoá PV ≠ giải phóng đĩa.** Dữ liệu vẫn nằm nguyên trong thư mục hostPath, phải xoá tay | Sau khi xoá PV `Retain`, kiểm tra `du -sh` thư mục tương ứng trên node |
| **Image store thường ăn đĩa nhiều hơn dữ liệu ứng dụng.** Ở đây containerd 27G vs toàn bộ RagFlow 5.8G — đoán "MinIO lưu file nên nặng nhất" là **sai** | `du -sh` **trước** khi kết luận thành phần nào ngốn đĩa, đừng suy từ bản chất service |
| **`df` và `du` lệch nhau là bình thường và đáng điều tra.** 70G vs 32.8G đếm được → còn 37G ở chỗ chưa biết | `du -sh /var/* \| sort -h` quét rộng thay vì chỉ đo thư mục nghi ngờ |
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
| MySQL + MinIO + Redis + containerd dùng chung `/dev/vda1` node07 | Issue 3 — `hostPath` cùng gốc `/data/ragflow/` | Đĩa đầy → MySQL không ghi được → **hỏng dữ liệu**. MinIO ngốn đĩa thì MySQL chết theo |
| PV 5Gi không phản ánh thực tế 70G (`no-provisioner` + `hostPath`) | Issue 3 | Người vận hành nhìn PVC tưởng an toàn, không ai theo dõi dung lượng thật |
| Bộ PV `pv-ragflow-custom-*` (8d) từ lần test, `Retain` + `Bound`, cùng node07 | Phiên 31/07 | Chiếm đĩa vô ích trên chính đĩa đang 74%; `Retain` nên xoá PV không tự giải phóng |
| PVC `ragflow-es-data` Pending 69 ngày | Tắt `elasticsearch.enabled` để dùng ES ngoài | Rác, gây nhiễu khi đọc trạng thái cluster |
| Không có backup MySQL ❓ | chưa kiểm tra trong phiên | Kết hợp với 3 dòng trên → mất dữ liệu không khôi phục được |
| Optimizer không tự chọn `idx_document_kb_create` dù đã tạo + ANALYZE TABLE, chỉ dùng đúng khi `FORCE INDEX` | Issue 1 — xác nhận 07/08 sau khi tạo index | Hiện tại đủ nhanh (167k rows filtered vẫn nhanh hơn baseline nhiều) nhưng khi KB tiếp tục phình to hơn nữa, khoảng cách hiệu năng giữa 2 key sẽ ngày càng lớn — cần theo dõi, có thể phải `FORCE INDEX` trong code hoặc `ANALYZE TABLE` định kỳ về sau |
| Chưa có metrics-server / giám sát MySQL | Issue 6 | Không phát hiện được suy thoái, chỉ biết khi user kêu |

❓ **Chưa xác minh**: có backup MySQL hay không — không kiểm tra trong phiên này. **Nên kiểm tra sớm**, vì đây là nợ nguy hiểm nhất trong bảng.

---

## 7. Việc tiếp theo

### Ngay lập tức (không downtime)

- [x] ~~Tạo composite index~~ → ✅ **Đã làm 07/08**, mất 8.77s, xem Issue 1
```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
```
- [x] ~~Chạy lại `EXPLAIN` query cũ~~ → ✅ Đã xác minh bằng `FORCE INDEX`: `Extra` sạch, không còn filesort/temporary
- [x] ~~Đo lại thời gian query thực tế sau khi có index~~ → ✅ **0.02s** (từ 11.1s, giảm ~500 lần)
- [x] ~~Dọn image cũ trên node07~~ → đã làm tương đương trên **node06** (07/08, gỡ ~28G rác gồm image RagFlow cũ, xem `PLAN-mysql-migrate-node06.md` Bước 0.5). Node07 vẫn **chưa dọn**, còn trong danh sách việc tiếp theo.
```
crictl rmi --prune
```
- [x] ~~Xem thư mục nào ăn đĩa nhiều nhất trên node07~~ → **containerd 27G**, `/data/ragflow` chỉ 5.8G
- [ ] Truy ~37G còn lại chưa xác định trên **node07** (70G `df` − 32.8G đã đếm) — lưu ý: đã làm việc tương tự trên **node06** (07/08) và tìm ra `/var/lib/containerd`=63G là thủ phạm, nên rất có thể node07 cũng cùng nguyên nhân, nhưng **chưa đo lại trên chính node07** để xác nhận:
```
du -sh /var/* 2>/dev/null | sort -h | tail -10
```
- [ ] Xem containerd đang giữ image gì trên **node07** (đã làm trên node06/node08 07/08, chưa làm trên node07):
```
crictl images
```
- [ ] Kiểm tra lại dung lượng sau khi dọn:
```
kubectl -n ragflow exec ragflow-mysql-0 -- df -h /var/lib/mysql
```
- [ ] Kiểm tra xem có backup MySQL không
- [x] ~~Xác minh namespace `ragflow-custom` còn dùng không~~ → ✅ Xác nhận là môi trường test cũ, không còn dùng — đã `helm uninstall` (07/08). PV/PVC vẫn còn (giữ theo resource-policy), **chưa xoá hẳn**, xem `PLAN-mysql-migrate-node06.md` Bước 0.5 mục "còn treo"

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

- [ ] Dọn bộ PV `pv-ragflow-custom-*` + **thư mục dữ liệu** nếu ns `ragflow-custom` không còn dùng (`Retain` không tự xoá)
- [ ] Xoá PVC rác `ragflow-es-data` (Pending 69 ngày)
- [ ] Tách `/data/ragflow` sang đĩa/LVM riêng, không dùng chung `/dev/vda1` với containerd; ít nhất tách MySQL khỏi MinIO
- [ ] Cài metrics-server
- [ ] Thêm mysqld_exporter + dashboard Grafana (buffer pool hit ratio, slow query rate, connection, dung lượng)
- [ ] Cảnh báo dung lượng `/dev/vda1` node07 ở ngưỡng 80%
- [ ] Đánh giá phương án MySQL HA (MySQL Operator / Patroni-like)
- [ ] Thiết lập backup định kỳ + kiểm thử restore

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Đĩa `/dev/vda1` node07 đầy (còn 25G/99G) → MySQL không ghi được → **hỏng dữ liệu** | 🔴 Cao | Dọn image + PV custom ngay; cảnh báo 80%; dài hạn tách đĩa riêng |
| **Image store containerd (27G) ăn đĩa kéo cả 3 service chết theo** — gấp 4.7 lần toàn bộ dữ liệu RagFlow (5.8G) | 🔴 Cao | `crictl rmi --prune` định kỳ; đặt `imageGCHighThresholdPercent` cho kubelet |
| **~37G trên `/dev/vda1` chưa xác định nằm ở đâu** ❓ | 🟡 TB | `du -sh /var/*` để truy; có thể là log hoặc workload khác của node07 |
| MySQL đang 2.5G / "5Gi" khai báo — khi vượt sẽ **không có cảnh báo** | 🟡 TB | Giám sát dung lượng thư mục `/data/ragflow/mysql`, không dựa vào PVC |
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

PVC / PV / StorageClass:
```
kubectl get pvc -n ragflow
```
```
kubectl get pv -n ragflow
```
```
kubectl get storageclass
```

Resources của pod:
```
kubectl -n ragflow get pod ragflow-mysql-0 -o jsonpath='{.spec.containers[0].resources}'
```

Tài nguyên node:
```
kubectl describe node vrp-kubeengine07
```
