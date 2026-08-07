# PLAN — Đánh index + chuyển MySQL từ node07 sang node06

**Task chính**: `TRACKING-mysql-load-assessment.md` (mục 9) — root cause, bằng chứng, feasibility 4 hướng.
**Lệnh tham khảo (kèm giải nghĩa cờ)**: `commands/mysql-load-assessment.md`
**Trạng thái**: 🔶 Đã duyệt plan, **chưa thực thi**. Còn 3 câu hỏi mở ở cuối file cần xác nhận trước khi vào cửa sổ bảo trì.

---

## Context

RagFlow đang chậm (đối tác báo 55s/vb khi upload document), đã xác định nút thắt là MySQL trên
node07 (CPU 80%, `mysqld` 666.7%, load avg 19.52/8 core) trong khi node06/node08 gần như rảnh.
Đã đánh giá 4 hướng xử lý (xem `TRACKING-mysql-load-assessment.md` mục 9) và chốt ngắn hạn gồm
đúng 2 việc: **(1) đánh composite index** cho query chậm nhất, **(2) chuyển MySQL sang node06**,
**giữ nguyên MinIO/Redis ở node07** để giảm tải mà không dồn hết một node.

Đây là tác động lớn lên database đã có dữ liệu thật (239k document), nên cần plan rõ ràng từng
bước trước khi làm gì trên production. Sếp (Nguyễn Chí Đông) đã cho ý kiến qua chat:
- "tác động thì báo thôi" — chỉ cần báo trước, không cần xin duyệt từng bước nhỏ
- Migrate data có 2 cách: (1) copy data rồi mount lại PV, (2) dump DB rồi restore — **ưu tiên cách 1
  nếu làm được, vì đỡ việc hơn**
- Lưu ý tránh sai sót **user/pass, các constraint**

## Bằng chứng đã xác minh (đọc trực tiếp chart, không suy đoán)

- `helm_ragflow_v0.26.4/values.yaml` dòng 310-333: MinIO, MySQL, Redis **dùng chung 1 label**
  `nodeSelector: {ragflow-target: "true"}`. Nếu chỉ đổi giá trị này, cả 3 service sẽ di chuyển
  theo (hoặc bị schedule tùy ý) — **không đạt được yêu cầu "chỉ chuyển MySQL"**.
  → Cần label **mới, riêng cho MySQL** (đề xuất `ragflow-mysql-target=true`), gắn lên node06, và
  chỉ sửa `mysql.deployment.nodeSelector` trong values.yaml — không đụng `minio`/`redis`.
- `templates/mysql.yaml` dòng 13-14: `storageClassName` được set từ `mysql.storage.className`
  (hiện là `local-mysql`). Comment trong values.yaml dòng 325 cảnh báo: **"storageClassName của
  PVC là IMMUTABLE, đổi giá trị sẽ làm helm upgrade fail"** → không được đổi tên StorageClass của
  PVC hiện có, phải giữ nguyên `local-mysql`.
- StorageClass `local-mysql`: `provisioner: kubernetes.io/no-provisioner`,
  `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Retain` (đã xác nhận ở
  TRACKING file mục Issue 3). PVC không có `volumeName` tường minh trong template → bind theo
  StorageClass + PV còn `Available` khi pod schedule.
- PV hiện tại (`pv-ragflow-mysql`, ngoài phạm vi chart — quản lý thủ công, không nằm trong repo
  Git) là `hostPath: /data/ragflow/mysql` + `nodeAffinity: ragflow-target=true`.
- `templates/env.yaml` dòng 27: `MYSQL_HOST` là **Service DNS** (`ragflow-mysql.ragflow.svc`),
  không phải IP/node → **RagFlow app không cần biết MySQL chạy trên node nào**, chỉ cần Service
  vẫn trỏ đúng pod. Đổi node không cần sửa `service_conf.yaml`/connection string.
- MySQL image: `mysql:8.0.39` — có sẵn `mysqldump`/`mysql` client trong image, dùng được cho
  Cách 2 nếu cần fallback.
- `--disable-log-bin` đang bật cứng (đã ghi trong TRACKING) — không ảnh hưởng đến việc migrate
  bằng copy file, chỉ ảnh hưởng đến hướng replica (đã loại).

## Quyết định thiết kế

**Dùng Cách 1 (copy hostPath data + tạo PV mới trỏ vào node06)**, đúng ưu tiên sếp đã chọn.
Cách 2 (mysqldump/restore) giữ làm **fallback bằng văn bản** trong plan, chỉ dùng nếu Cách 1 gặp
lỗi thực thi giữa chừng (dữ liệu ghi dở, checksum lệch...).

Lý do Cách 1 khả thi và "nhàn" như sếp nhận định:
- `hostPath` là thư mục thường trên node, `cp`/`rsync` là đủ, không cần hiểu schema MySQL
- Vì `--disable-log-bin`, không có binlog cần đồng bộ riêng — toàn bộ state nằm trong
  `/var/lib/mysql` (datadir), copy nguyên thư mục là đủ, không mất giao dịch dở dang miễn
  MySQL đã tắt sạch trước khi copy (InnoDB cần clean shutdown để không phải crash-recovery)

## Các bước thực hiện

### Bước 0 — Chuẩn bị, không tác động production
1. Báo sếp trước cửa sổ bảo trì cụ thể (ngày/giờ) — theo đúng "tác động thì báo thôi"
2. Xác nhận label trên node06 hiện tại: `kubectl get node vrp-kubeengine06 --show-labels`
3. Backup an toàn trước khi động vào bất cứ thứ gì:
   - `mysqldump` toàn bộ `rag_flow` ra file, lưu ngoài cluster (dù chọn Cách 1, vẫn cần bản dump
     làm lưới an toàn cuối cùng — đây chính là điều sếp nhắc "tránh sai sót")
   - Ghi lại nguyên văn `MYSQL_USER`/`MYSQL_PASSWORD`/`MYSQL_ROOT_PASSWORD` đang dùng (từ Secret
     `ragflow-env-config`) để đối chiếu sau migrate — đây là root cause phổ biến nhất của lỗi
     "mất user/pass" mà sếp lo: **secret không đổi, chỉ có pod di chuyển**, nên rủi ro thực chỉ
     xảy ra nếu ai đó vô tình sinh lại secret hoặc đổi `values.yaml` env trong lúc thao tác
   - Ghi lại `SHOW GRANTS` cho user hiện dùng, để đối chiếu quyền không bị mất

### Bước 1 — Đánh composite index (làm trước, độc lập với việc chuyển node)
```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
```
- Không downtime (`ALGORITHM=INPLACE`), làm trước để tách rủi ro — nếu có vấn đề gì thì biết
  ngay là do index hay do migrate node, không lẫn lộn
- Xác minh bằng `EXPLAIN` lại query cũ (kỳ vọng đổi key + giảm rows, theo TRACKING Issue 1)
- Đánh giá thêm `duplicate_name(kb_id, name)` (Issue 1b) — cần `EXPLAIN` trước khi quyết có tạo
  thêm index hay không, chưa chắc chắn 100% như Issue 1

### Bước 2 — Chuẩn bị hạ tầng trên node06 (chưa động vào pod đang chạy)
1. Gắn label mới lên node06: `ragflow-mysql-target=true`
2. Tạo sẵn thư mục đích trên node06 (`/data/ragflow/mysql`, cùng path để giảm khác biệt)
3. Soạn sẵn manifest PV mới (`pv-ragflow-mysql-node06` hoặc tên rõ ràng khác), cùng
   `storageClassName: local-mysql`, `hostPath` trỏ thư mục trên, `nodeAffinity: ragflow-mysql-target=true`
   — **chưa apply**, chỉ chuẩn bị

### Bước 3 — Cửa sổ bảo trì (có downtime, cần báo trước theo yêu cầu sếp)
1. Báo đối tác/team liên quan tạm dừng ghi dữ liệu (giống cách đã làm 31/07: "báo bên họ ngừng
   đẩy dữ liệu")
2. Scale MySQL StatefulSet về 0 (đảm bảo clean shutdown, không copy file đang mở/dở dang)
3. Copy dữ liệu từ node07 sang node06:
   - Ưu tiên `rsync` qua SSH giữa 2 node (giữ nguyên permission/ownership) thay vì `cp` thô, vì
     MySQL rất nhạy với UID/GID của thư mục datadir — sai owner là nguyên nhân phổ biến khiến
     mysqld không start lại được
   - Đối chiếu dung lượng nguồn/đích bằng `du -sh` trước và sau copy — khớp mới tiếp tục
4. Xoá PVC cũ (giữ nguyên PV cũ ở trạng thái `Retain`, **không xoá PV cũ và không xoá thư mục
   gốc trên node07** cho tới khi xác nhận node06 chạy ổn — đây là lưới an toàn thứ hai)
5. Apply PV mới (đã soạn ở Bước 2)
6. Sửa `values.yaml`: chỉ đổi `mysql.deployment.nodeSelector` thành
   `ragflow-mysql-target: "true"` — **không đụng** `minio.deployment.nodeSelector` /
   `redis.deployment.nodeSelector`
7. `helm upgrade` — PVC mới (cùng tên, cùng StorageClass `local-mysql`) sẽ bind vào PV mới nhờ
   `WaitForFirstConsumer` khi pod schedule lên node06
8. Xác nhận pod `ragflow-mysql-0` chạy trên node06: `kubectl get pod -o wide`

### Bước 4 — Xác minh sau migrate (trước khi cho ghi dữ liệu trở lại)
1. `SHOW GRANTS` cho user — đối chiếu với bản ghi ở Bước 0, đảm bảo không mất quyền
2. Đăng nhập bằng đúng `MYSQL_USER`/`MYSQL_PASSWORD` hiện có trong Secret — xác nhận không cần đổi
3. `SELECT COUNT(*) FROM document` — đối chiếu với con số đã biết (239,395) để chắc dữ liệu
   nguyên vẹn, không thiếu
4. Kiểm tra `EXPLAIN` lại query composite index (Bước 1) vẫn hoạt động đúng sau khi đổi node
5. Test thử 1 luồng upload document thật (không phải chỉ query) để xác nhận toàn bộ chuỗi
   app → MySQL → MinIO hoạt động bình thường
6. Theo dõi CPU node06/node07 qua `top`/SigNoz trong ít nhất 30-60 phút đầu

### Bước 5 — Dọn dẹp (chỉ làm sau khi Bước 4 ổn định, có thể để riêng 24-48h quan sát)
1. Xoá PV cũ trên node07 + thư mục dữ liệu cũ (`Retain` không tự xoá, phải làm tay)
2. Cập nhật `TRACKING-mysql-load-assessment.md`: đánh dấu Issue 1, phần "chuyển node" trong
   mục 9 thành ✅ FIXED kèm bằng chứng thực tế đo được

## Fallback — nếu Cách 1 gặp lỗi giữa chừng

Nếu copy xong mà `mysqld` không start được trên node06 (lỗi phổ biến: sai owner/permission,
thiếu file `ib_logfile`, corrupt do copy khi chưa clean shutdown):
1. Không sửa chữa datadir đã copy — quay lại pod cũ trên node07 ngay (PV cũ vẫn còn nguyên vì
   chưa xoá ở Bước 5) để không kéo dài downtime
2. Chuyển sang Cách 2: `mysqldump` từ bản backup đã lấy ở Bước 0, restore vào MySQL mới khởi tạo
   sạch trên node06 (init từ đầu, không copy file datadir)

## Rủi ro & giảm thiểu

| Rủi ro | Giảm thiểu |
|---|---|
| Copy khi MySQL chưa tắt sạch → datadir corrupt | Scale về 0, đợi pod Terminated hẳn mới copy |
| Sai owner/permission khi copy giữa 2 node | Dùng `rsync -a` giữ permission, kiểm tra `ls -la` đối chiếu trước khi start lại |
| Nhầm label khiến MinIO/Redis cũng bị di chuyển | Dùng label riêng `ragflow-mysql-target`, chỉ sửa đúng 1 block trong values.yaml, review diff trước khi apply |
| Mất user/pass sau migrate | Secret không đổi trong toàn bộ quy trình — chỉ đối chiếu, không tạo lại; `SHOW GRANTS` trước/sau |
| Dữ liệu thiếu/lệch sau copy | Đối chiếu `du -sh` (dung lượng) + `COUNT(*)` (số dòng) trước/sau |
| Downtime kéo dài ngoài dự kiến | Có sẵn PV cũ + backup dump làm 2 lớp fallback, không xoá gì cho tới khi xác minh xong |
| PVC không bind đúng PV mới (do `WaitForFirstConsumer` chọn sai) | Xoá hẳn PV cũ khỏi trạng thái `Available` (đã làm ở bước xoá PVC) trước khi apply PV mới, tránh 2 PV cùng match StorageClass gây nhầm lẫn |

## Việc KHÔNG nằm trong plan này (đã chốt loại ở mục 9 TRACKING file)

- Không dùng MySQL read replica (chart chặn cứng bởi `replicas:1` + `--disable-log-bin`, ngoài
  ra app chưa tách read/write)
- Không tách MySQL ra server hoàn toàn riêng (là việc dài hạn, không phải đợt này)
- Không đổi `innodb_buffer_pool_size`, `resources`, hay các Issue khác trong TRACKING file — đó
  là các hạng mục "Ngắn hạn — cần restart" khác, làm riêng đợt sau để tách rủi ro

## Câu hỏi cần xác nhận trước khi thực thi

1. Cửa sổ bảo trì dự kiến làm khi nào (giờ thấp điểm)? Cần báo đối tác trước bao lâu?
2. node06 hiện có đang chạy service nào khác không (ngoài LiteLLM/MinIO đã thấy trong `top`) cần
   tránh xung đột resource khi thêm MySQL vào?
3. Có quyền SSH trực tiếp giữa node07 và node06 để chạy `rsync` không, hay phải qua một bước
   trung gian (ví dụ tạm chép qua một máy khác)?
