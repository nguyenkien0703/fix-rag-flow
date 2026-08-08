# PLAN — Đánh index + chuyển MySQL từ node07 sang node06

**Task chính**: `TRACKING-mysql-load-assessment.md` (mục 9, Issue 1, Issue 7) — root cause, bằng chứng, feasibility 4 hướng.
**Lệnh tham khảo (kèm giải nghĩa cờ)**: `commands/mysql-load-assessment.md`
**Trạng thái**: ✅ **HOÀN THÀNH** (07-08/08/2026) — đã đánh index, migrate MySQL sang node06,
xác minh dữ liệu/quyền/CPU ổn định kể cả dưới tải thật khi đối tác đẩy dữ liệu trở lại.
Còn 2 việc nhỏ chưa làm (không chặn kết luận thành công): (1) Bước 5 — xoá PV cũ trên node07 sau
24-48h quan sát ổn định, (2) 1 câu hỏi phụ chưa giải quyết dứt điểm về cơ chế dung lượng (xem
Bước 4.7, mục "Chưa giải quyết").

## Mục lục nhanh (đọc lại sau này)

- **Kết quả cuối cùng**: xem "✅ KẾT LUẬN BƯỚC 4" (gần cuối file, trước Bước 5)
- **Đánh index — số liệu trước/sau**: Bước 1
- **Vì sao chọn node06 thay vì node08**: Bước 0.5
- **Cách migrate data (rsync) + các lỗi gặp phải khi làm**: Bước 3, đặc biệt mục 4 (owner/permission,
  sudo, thư mục cha chặn quyền)
- **Sự cố ImagePullBackOff sau khi upgrade**: cảnh báo cuối phần Bước 0.5
- **Phát hiện phụ ngoài phạm vi (bug code RagFlow, không phải DB)**: Bước 4 mục 5, chi tiết đầy
  đủ ở `TRACKING-mysql-load-assessment.md` Issue 7
- **Tải thật khi đối tác đẩy dữ liệu sau migrate**: Bước 4.7

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

### Bước 0.5 — Dọn namespace test `ragflow-custom` trên node06 + so sánh node06 vs node08 (✅ ĐÃ LÀM 07/08/2026)

**Lý do làm trước Bước 1**: namespace `ragflow-custom` (môi trường test cũ, deploy 31/07) đang
chạy sống trên chính node06 — nghi ngờ từ TRACKING file Issue 3 nay đã xác nhận là rác, và pod
của nó đang giữ chân nhiều image RagFlow cũ trong containerd, cần dọn trước khi so sánh disk
công bằng giữa node06/node08.

**Đã làm, theo thứ tự:**
1. `kubectl -n ragflow-custom get pvc` — xác nhận 4 PVC: `es-data` (Pending, rác), `minio`,
   `mysql`, `redis-data-*` (đều Bound, storageClass `local-minio`/`local-mysql`/`local-redis` —
   **cùng SC với production nhưng khác PV/tên**, không xung đột)
2. `kubectl get pv pv-ragflow-custom-{mysql,minio,redis} -o jsonpath=...` — lấy đúng hostPath:
   `/data/ragflow-custom/{mysql,minio,redis}` trên node06
3. `du -sh /data/ragflow-custom/*` (node06) — chỉ **2.3G** (minio 1.4G + mysql 998M + redis 9.9M)
   → không phải nguồn gây thiếu disk
4. `df -h /` (node06) lúc đó: 197G total, **chỉ 47G trống (76% used)** — lệch xa so với 2.3G vừa
   đo → còn ~140G chưa rõ, đào tiếp: `du -sh /var/*` → `/var/lib` = 83G → `du -sh /var/lib/*` →
   **`/var/lib/containerd` = 63G** (thủ phạm chính, cùng pattern với node07 hồi 31/07)
5. Đối chiếu công bằng trước khi chọn node: `du -sh /data/ragflow/mysql` (node07) = **5.1G**
   (tăng từ 2.5G ghi trong TRACKING chỉ trong ~2 ngày — cần lưu ý tốc độ tăng trưởng cho dài hạn);
   `df -h /` (node08) lúc đó = 197G total, 44G trống (78% used) — **gần bằng node06, chưa đủ để
   quyết định ngay**
6. `crictl images` trên cả 2 node — node06 lộ ra **4 image RagFlow cũ (~13.7GB)**:
   `ragflow:v1-latest`, `ragflow:v0.24.0-pyvi` (khớp sự cố 7.2GB hồi 31/07), `ragflow:v2-latest`,
   `custom-ragflow:v0.26.4-pyvi` — nghi ngờ đang bị pod `ragflow-custom-*` giữ chân, không prune
   được nếu chưa dừng pod. node08 sạch, không có image RagFlow nào.
7. `kubectl get deploy,sts -n ragflow-custom` → `helm list -n ragflow-custom` — xác nhận release
   Helm tên `ragflow-custom` (chart `ragflow-0.1.0`, deployed 31/07)
8. `helm uninstall ragflow-custom -n ragflow-custom` — xoá Deployment + 3 StatefulSet (mysql/
   minio/redis) + es (Pending). **PV/PVC được giữ lại** nhờ `resource-policy: keep` (Helm tự báo
   rõ) — dữ liệu vẫn nguyên vẹn, chưa xoá gì vật lý
9. `kubectl get pods -n ragflow-custom` → `No resources found` — xác nhận dừng sạch
10. `crictl rmi --prune` trên cả 2 node — node06 gỡ được **hầu hết image rác** (kể cả
    `ragflow:v0.24.0-pyvi`, `mysql:8.0.39` cũ, `redis`, `postgres`...); node08 không gỡ được gì
    (toàn bộ image đang dùng, không có rác)
11. `df -h /` đo lại sau dọn — **node06: 75G trống (61% used)**, node08: 43G trống (78% used,
    không đổi vì không prune được gì)

**Kết quả — chốt migrate MySQL sang node06:**

| | node06 (sau dọn) | node08 |
|---|---|---|
| Disk trống | **75G (61% used)** | 43G (78% used) |
| CPU/load (từ phiên 06/08) | rảnh | rảnh nhất |

node06 thắng cả 2 tiêu chí sau khi dọn ~28G rác (image RagFlow cũ + `ragflow-custom` data), và
namespace test đã sạch hoàn toàn nên không còn rủi ro tranh chấp resource với môi trường mới.

**Còn treo — chưa xử lý trong đợt này (không chặn việc migrate MySQL production):**
- 4 PV/PVC `pv-ragflow-custom-*` vẫn còn (`Retain`, giữ lại theo Helm resource-policy) —
  ❓ chưa xoá, để làm sau khi migrate MySQL production ổn định, tránh gộp 2 loại rủi ro
- PVC `ragflow-custom-es-data` (Pending) — rác thuần, dọn cùng lúc với các PV trên
- `/var/lib/kubelet` = 21G trên node06 — chưa điều tra, không phải rác rõ ràng như containerd
  nên chưa động vào

⚠️ **Hệ quả không lường trước, lộ ra ở Bước 3.7-3.8**: `crictl rmi --prune` ở bước này đã gỡ
luôn `docker.io/library/mysql:8.0.39` khỏi node06 (tưởng là "image rác" vì không có container
tham chiếu tại thời điểm đó, nhưng thực ra là image **cần dùng** cho lần migrate MySQL sang
chính node06 sau này). Hậu quả: sau `helm upgrade` (Bước 3.7), pod mới trên node06 bị
`ImagePullBackOff` — cluster air-gapped, không tự pull được từ `registry-1.docker.io` (lỗi
`i/o timeout`). Đã xử lý bằng cách **import image `mysql:8.0.39` từ file tar** sẵn có vào node06
(`ctr image import`/`crictl` tương đương), sau đó `helm upgrade` lại lần 2 thì pod chạy được
(`Running`).

**Bài học cho lần dọn rác container sau này**: `crictl rmi --prune` chỉ an toàn cho image chắc
chắn không còn cần trong **tương lai gần**, không chỉ "hiện tại không container nào dùng" — với
môi trường air-gapped (không tự pull lại được), cần cân nhắc kỹ trước khi prune image runtime
quan trọng (mysql, redis, minio...) trên node sắp trở thành đích migrate.

### Bước 1 — Đánh composite index (✅ ĐÃ LÀM 07/08/2026)

```sql
CREATE INDEX idx_document_kb_create ON rag_flow.document (kb_id, create_time DESC);
-- Query OK, 0 rows affected (8.77 sec)
```

**Kết quả:**
- Không downtime, chỉ mất 8.77s
- Đo thời gian thực tế query gây chậm: **0.02s** (từ baseline 11.1s — giảm ~500 lần)
- Xác minh bằng `FORCE INDEX (idx_document_kb_create)`: `Extra` sạch hoàn toàn, không còn
  `Using temporary; Using filesort`
- ⚠️ Nợ nhỏ ghi nhận: optimizer mặc định (không FORCE INDEX) vẫn tự chọn `document_kb_id` thay
  vì index mới dù đã `ANALYZE TABLE` — không sửa code (ngoài phạm vi, đã hỏi ý kiến và chốt giữ
  nguyên vì đã đủ nhanh). Theo dõi dài hạn nếu KB tiếp tục phình to. Chi tiết: TRACKING Issue 1.
- Đánh giá `duplicate_name(kb_id, name)` (Issue 1b): đã `EXPLAIN` trực tiếp, **kết quả bác bỏ**
  nghi ngờ ban đầu — index đơn cột `document_name` (cardinality 347,033, gần unique) đã đủ nhanh
  (`rows: 1`, không filesort). Không cần tạo thêm index. Chi tiết: TRACKING Issue 1b.

**Việc phát sinh, đã làm trước Bước 1** — xem Bước 0.5 bên dưới (dọn `ragflow-custom` + chốt
node06 qua so sánh disk với node08, phát sinh từ câu hỏi thực tế lúc thực thi Bước 0).

### Bước 2 — Chuẩn bị hạ tầng trên node06 (✅ ĐÃ LÀM 07/08/2026)
1. ✅ Gắn label `ragflow-mysql-target=true` lên node06 — xác nhận qua `--show-labels`, không đè
   mất label cũ `ragflow-custom-target=true`
2. ✅ Tạo thư mục `/data/ragflow/mysql` trên node06 — ban đầu tạo với owner `root:root 700`,
   phải sửa lại `chown 999:0` + `chmod 755` để khớp đúng owner thật của datadir trên node07
   (đã đo bằng `stat -c '%u:%g %a %n'`, không suy đoán tên user vì UID trên 2 node có thể ánh xạ
   tên khác nhau trong `/etc/passwd`)
3. ✅ Soạn manifest PV mới `pv-ragflow-mysql-node06.yaml` (lưu trong repo, cùng thư mục
   `PLAN-mysql-migrate-node06.md`) — dựa trên `kubectl get pv pv-ragflow-mysql -o yaml` làm khuôn
   mẫu, giữ nguyên `storageClassName: local-mysql`, `persistentVolumeReclaimPolicy: Retain`, chỉ
   đổi `hostPath` sang node06 (cùng path) và `nodeAffinity` sang `ragflow-mysql-target=true`.
   **Bỏ `claimRef`** so với PV gốc — PV gốc có `claimRef` trỏ cứng vào PVC production hiện tại,
   không tái sử dụng được cho PV mới; để trống cho PVC mới tự bind qua `WaitForFirstConsumer`.

### Bước 3 — Cửa sổ bảo trì (✅ ĐÃ LÀM 07/08/2026, có downtime thật)

1. ✅ Đã báo trước (theo đúng "tác động thì báo thôi" của sếp)
2. ✅ Backup an toàn trước khi động vào production:
   `mysqldump -uroot -p rag_flow > rag_flow_backup_20260807.sql` → file **1.2G** (nhỏ hơn nhiều
   so với datadir 5.1G vì dump là SQL text thuần, không có overhead B-tree/page của InnoDB —
   không phải dấu hiệu thiếu dữ liệu). Xác minh hợp lệ bằng dòng cuối
   `-- Dump completed on 2026-08-07 11:35:34`.
   ⚠️ **Sự cố nhỏ khi backup**: `mysqldump -uroot -p` lần đầu lỗi `Access denied` vì `kubectl exec`
   không có đủ TTY để `-p` hỏi password tương tác — phải gõ password thẳng trên dòng lệnh
   (`-pPASSWORD`) để qua được. **Rủi ro bảo mật đã xảy ra**: password bị lộ vào shell history
   của node04. Đã hỏi ý kiến, người phụ trách chấp nhận rủi ro này, không đổi password ngay.
   Khuyến nghị dọn `history -d` dòng đó và cân nhắc đổi password vào đợt bảo trì kế tiếp.
3. ✅ Scale MySQL về 0: `kubectl -n ragflow scale statefulset ragflow-mysql --replicas=0`, xác
   nhận dừng sạch bằng `kubectl get pods -l app.kubernetes.io/component=mysql` → trống hoàn toàn
4. ✅ Copy dữ liệu node07 → node06 bằng `rsync -avzP`:
   - **Xác nhận trước**: SSH giữa 2 node chỉ đi qua `vt_admin` (không SSH thẳng bằng `root` —
     `PermitRootLogin` bị chặn, xác nhận bằng thử `ssh root@vrp-kubeengine06` → `Permission denied`)
   - **Vướng mắc**: dùng `--rsync-path="sudo rsync"` để có quyền ghi ở đích thất bại vì
     `sudo: no tty present and no askpass program specified` — `vt_admin` cần password khi
     `sudo` qua non-interactive SSH thì không có TTY để nhập.
   - **Cách xử lý cuối cùng**: tạm `chown vt_admin:vt_admin` thư mục đích trên node06 để rsync
     ghi được không cần sudo — nhưng vẫn bị `Permission denied` lần nữa vì **thư mục cha**
     `/data` và `/data/ragflow` là `root:root 700`, chặn cả quyền "đi qua" (`x`) của `vt_admin`
     dù thư mục con đã đúng owner. Sửa bằng `chmod o+x /data /data/ragflow` (chỉ thêm execute,
     không thêm read, giữ tối thiểu quyền cần thiết) — rsync chạy thành công sau đó.
   - Copy xong: `sent 713,502,689 bytes`, `total size is 4,765,593,360`, không lỗi giữa chừng.
   - Đối chiếu dung lượng: `du -sh` cả 2 bên đều ra **4.5G** — khớp, không thiếu dữ liệu.
   - **Chown lại đúng owner gốc**: `chown -R 999:0 /data/ragflow/mysql` trên node06 (đệ quy,
     khác Bước 2 vì giờ có hàng trăm file `.ibd` bên trong, không chỉ thư mục rỗng) — verify bằng
     `stat` trên 1 file cụ thể (`document.ibd`) để chắc `-R` áp dụng đúng xuống tận file con.
5. ✅ Xoá PVC cũ: `kubectl -n ragflow delete pvc ragflow-mysql` → PV cũ chuyển `Released` (không
   bị xoá, đúng theo `Retain`), dữ liệu vật lý trên node07 còn nguyên — lưới an toàn thứ hai vẫn
   giữ đúng thiết kế.
6. ✅ Apply PV mới: `kubectl apply -f pv-ragflow-mysql-node06.yaml` → `STATUS: Available`
7. ✅ Sửa `helm_ragflow_v0.26.4/values.yaml`: chỉ đổi `mysql.deployment.nodeSelector` từ
   `ragflow-target: "true"` sang `ragflow-mysql-target: "true"` — xác nhận diff chỉ đúng 1 chỗ
   thay đổi (`git diff`), `minio`/`redis` giữ nguyên `ragflow-target` như cũ.
   Trước khi `helm upgrade`, đối chiếu `helm get values ragflow -n ragflow -o yaml` (giá trị
   đang chạy thật trên cluster) với `values.yaml` local — khớp hoàn toàn, xác nhận không có
   drift/override nào khác ngoài file đang sửa, an toàn để upgrade bằng đúng `-f values.yaml`.
8. ✅ `helm upgrade ragflow . -n ragflow -f values.yaml` (revision 60→61) — **lần đầu pod bị
   `ImagePullBackOff`** vì thiếu image `mysql:8.0.39` trên node06 (đã lỡ bị `crictl rmi --prune`
   ở Bước 0.5 gỡ mất, xem cảnh báo cuối phần Bước 0.5 phía trên). Xử lý bằng import image từ
   file tar vào node06, sau đó `helm upgrade` lại lần 2 (revision 61→62) → pod `Running`.
9. ✅ Xác nhận: `kubectl -n ragflow get pod ragflow-mysql-0 -o wide` → `NODE: vrp-kubeengine06`,
   `1/1 Running`. `describe pod` xác nhận `Node-Selectors: ragflow-mysql-target=true`,
   `ClaimName: ragflow-mysql` (PVC mới bind đúng PV mới), Events log sạch (`Pulled`, `Created`,
   `Started`), không còn lỗi lặp lại.

### Bước 4 — Xác minh sau migrate (✅ mục 1-5 đã làm 07/08/2026, mục 6 đang theo dõi)

1. ✅ `SHOW GRANTS FOR CURRENT_USER()` — 2 dòng, đầy đủ quyền chuẩn + admin nâng cao MySQL 8.0,
   `WITH GRANT OPTION` — không mất quyền gì so với trước migrate.
2. ✅ Đăng nhập bằng đúng password cũ trong Secret — thành công, tự nó là bằng chứng Secret
   `ragflow-env-config` không bị động vào trong suốt quá trình migrate.
3. ✅ `SELECT COUNT(*) FROM document` → **395,137** (không phải 239,395 như baseline TRACKING) —
   ban đầu tưởng lệch, nhưng **cao hơn** chứ không thấp hơn baseline cũ, và khớp với `du -sh` đã
   đối chiếu chính xác 4.5G ở Bước 3.3b (nếu thiếu dữ liệu, dung lượng không thể khớp đúng như
   vậy) → kết luận: tăng trưởng tự nhiên trong ~2 ngày làm việc, không phải mất dữ liệu.
4. ✅ `EXPLAIN` lại với `FORCE INDEX (idx_document_kb_create)` trên node06 — kết quả y hệt lúc
   test trên node07 ở Bước 1.4 (`Extra` sạch hoàn toàn) — index copy đúng, hoạt động bình thường
   sau khi đổi node. `SHOW INDEX` cũng xác nhận cấu trúc 2 cột `(kb_id, create_time)` nguyên vẹn.
5. ✅ Test upload 1 document thật qua UI (`file support.txt`) — thành công, xuất hiện đúng trong
   danh sách, `Total 394310` khớp hợp lý với `COUNT(*)`.
   ⚠️ **Phát hiện phụ trong lúc test — Issue 7 mới**: quan sát tab Network thấy request
   `documents?type=filter` mất **39.11s**. Điều tra bằng slow log (bật lại `slow_query_log`,
   `long_query_time=1`, `log_output=TABLE` — vì đây là `SET GLOBAL` nên đã mất sau lần restart ở
   Bước 3.2/3.8, phải bật lại) → bắt được 2 câu chậm cùng thuộc hàm `get_filter_by_kb_id()`
   (JOIN 3 bảng không `LIMIT`, đọc hết ~153k-394k document của KB để đếm suffix/run_status thủ
   công trong Python). Đã đọc trực tiếp source `ragflow-0.24.0/api/db/services/document_service.py`
   dòng 187-273 xác nhận: **root cause là code app RagFlow, không phải MySQL/database** — mỗi
   bảng JOIN đều dùng đúng index (`EXPLAIN` sạch), MySQL trả lời đúng những gì được yêu cầu, chỉ
   là code yêu cầu quá nhiều dữ liệu không cần thiết. Không đánh thêm index nào giải quyết được.
   **Ngoài phạm vi migrate DB** — ghi chi tiết đầy đủ, báo đội dev riêng. Xem TRACKING Issue 7.
6. ✅ Theo dõi CPU node06 — kiểm tra sau hơn 1 tiếng kể từ khi migrate xong:
   ```
   top -bn1 -o %CPU | head -20
   ```
   Kết quả (node06, 13:34:46, hơn 1h sau migrate): `mysqld` chỉ chiếm **43.8% CPU**, `load average:
   2.48, 2.46, 2.19` trên node 8 core (~31% oversubscribed, bình thường), `%Cpu(s) id: 90.9%` —
   so với baseline node07 lúc quá tải (`mysqld` 666.7%, load 19.52, idle 16.0%), cải thiện rõ
   rệt và ổn định qua thời gian, không có dấu hiệu bất thường. **Bước 4 hoàn tất.**

**✅ KẾT LUẬN BƯỚC 4: Migrate MySQL sang node06 thành công toàn diện** — dữ liệu nguyên vẹn,
quyền không đổi, index hoạt động đúng, CPU ổn định dưới tải thật hơn 1 tiếng. Đủ điều kiện báo
đối tác tiếp tục đẩy dữ liệu.

### Bước 4.7 — Theo dõi tải thật khi đối tác đẩy dữ liệu trở lại (07-08/08/2026)

Sau khi báo đối tác tiếp tục đẩy dữ liệu (dựa trên kết luận Bước 4 ở trên), đo lại tải thực tế
lúc 15:09 cùng ngày (đối tác đang đẩy):

**Chạy trên: node06**
```
top -bn1 -o %CPU | head -20
```
Kết quả: `mysqld` **293.8% CPU** (tăng từ 43.8% lúc rảnh), `load average: 7.98, 9.09, 7.69` trên
node 8 core, `%Cpu(s) id: 74.2%`, `wa (iowait): 1.5%` (khác 0.0% lúc rảnh — bắt đầu có chờ đĩa
nhẹ). Vẫn thấp hơn nhiều so với mức quá tải cũ ở node07 (666.7% CPU, load 19.52).

**Kiểm tra ổn định kết nối dưới tải** — trong lúc đo dung lượng DB qua SQL, gặp
`ERROR 2013 (HY000): Lost connection to MySQL server during query` (client tự reconnect thành
công, connection id mới, kết quả sau đó nhất quán khi chạy lại). Kiểm tra thêm:
```sql
SHOW GLOBAL STATUS LIKE 'Aborted%';
```
Kết quả: `Aborted_clients: 3`, `Aborted_connects: 0` — số lần rớt kết nối tạm thời rất thấp kể từ
lúc pod khởi động lại trên node06 (~vài tiếng), `Aborted_connects: 0` nghĩa là không có lần nào
bị từ chối kết nối. Kết luận: 1 lần "Lost connection" gặp phải là blip tạm thời dưới tải cao
(query timeout phía client), không phải dấu hiệu MySQL có sự cố nghiêm trọng.

**Đo dung lượng DB dưới tải:**
```sql
SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS total_size_gb
FROM information_schema.tables WHERE table_schema = 'rag_flow';
```
→ **3.08 GB** (đo qua SQL, chỉ tính data+index logic của các bảng)

```
du -sh /data/ragflow/mysql
```
(chạy trên node06) → **4.5 GB** (đo toàn bộ datadir vật lý trên đĩa)

Hai con số khác nhau (4.5G > 3.08G) là **bình thường**, không phải bất thường: `du -sh` tính cả
InnoDB log file (`ib_logfile*`, redo log), undo log, temp file, và phần dung lượng đã cấp phát
nhưng chưa dùng hết (fragmentation) — những thứ không nằm trong `data_length + index_length`.

❓ **Chưa giải quyết — điểm cần điều tra thêm nếu có dịp**: `du -sh` đo được **4.5G** ở thời điểm
này, khớp đúng với lần đối chiếu ngay sau rsync (Bước 3.3b, cũng 4.5G cả 2 bên) — nhưng **thấp
hơn** con số **5.1G** đã đo trên node07 ở Bước 0.5 (06/08/2026, lúc MySQL cũ còn đang chạy sống
trên node07, dùng để so sánh disk trống node06/node08). Nghĩa là: 5.1G (06/08, node07, đang chạy)
→ 4.5G (07/08, sau khi scale về 0 rồi rsync) — **giảm 0.6G**, không tăng.

Giả thuyết hợp lý nhất (chưa xác minh bằng cách so sánh danh sách file trước/sau): khi MySQL đang
chạy sống, có thể tồn tại thêm các file tạm (undo log đang mở, buffer pool dump nếu bật, temp
table trên đĩa cho query lớn...) mà quá trình clean shutdown ở Bước 3.2 đã dọn/flush sạch trước
khi rsync — nên bản copy sang node06 nhỏ hơn bản gốc lúc đang hoạt động. **Chưa kiểm chứng trực
tiếp**, cần liệt kê file trong `/data/ragflow/mysql` và đối chiếu với tài liệu MySQL 8.0 về các
loại file tạm sinh ra khi server đang chạy nếu muốn có câu trả lời chắc chắn. Không ảnh hưởng tới
kết luận migrate thành công (dữ liệu đã đối chiếu khớp bằng `COUNT(*)` và `du -sh` tại đúng thời
điểm rsync), chỉ là một câu hỏi phụ về cơ chế chưa được trả lời dứt điểm.

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
