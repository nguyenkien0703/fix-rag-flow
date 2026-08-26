# TRACKING — MinIO cạn inode trên node 07 (cụm vRP)

> Phiên: **26/08/2026**, 09:14 → 10:45
> Trạng thái tổng: 🔶 **CHƯA XỬ LÝ XONG** — dịch vụ RAGFlow vẫn gián đoạn
> Hướng đã chốt: **move MinIO sang cụm vMLP** (không phải node 08 của vRP)

---

## 1. Mục tiêu

| Hạng mục | Hiện tại | Đích |
|---|---|---|
| MinIO chạy ở | cụm **vRP**, node 07 (`vrp-kubeengine07` / 10.208.137.54) | cụm **vMLP** |
| Đường dẫn dữ liệu | `/data/ragflow/minio` (hostPath, ổ `/dev/vda1`) | ❓ chưa xác định trên vMLP |
| Dung lượng dữ liệu | ~61G ❓ *(suy từ `df -h` toàn ổ, chưa chạy `du -sh` riêng thư mục minio)* | — |
| Inode MinIO chiếm | **5.664.048** | — |
| RAGFlow pod | 0/1, không nhận request | 1/1 Ready |

### Bối cảnh hạ tầng

Cụm vRP: airgap, CentOS 7, k8s v1.23.2, containerd 1.5.8.

| Node | IP | Vai trò | Đĩa | Inode |
|---|---|---|---|---|
| vrp-kubeengine04 | .51 | jump box (kubectl) + n8n nerdctl | — | — |
| vrp-kubeengine06 | .53 | RAGFlow pod + MySQL | 197G, dùng 158G (84%) | 13M, free 12M (8%) |
| **vrp-kubeengine07** | **.54** | **MinIO + Redis** ⚠️ đang sự cố | 99G, dùng 61G (65%) | **6,5M, free 0,33M (95%)** |
| vrp-kubeengine08 | .55 | worker | 197G, dùng 120G (64%) | 13M, free 12M (9%) |

---

## 2. Tổng quan issue

| # | Issue | Trạng thái | Giải pháp |
|---|---|---|---|
| 1 | Node 07 disk-pressure → MinIO/Redis Pending → RAGFlow 0/1 | 🔶 **OPEN** | Move MinIO sang vMLP |
| 2 | Thư mục `elasticsearch` + `mysql` mồ côi trên node 07 | ✅ **FIXED** | Đã xoá, thu hồi 5G |
| 3 | Chẩn đoán nhầm trục: dọn theo dung lượng thay vì inode | ✅ **FIXED** | Xác định đúng trục là inode |
| 4 | MinIO cluster hoá (chia nhỏ dữ liệu) | 🔶 **OPEN** | Sếp chỉ đạo, chưa làm |
| 5 | Ổ `/dev/vda1` format sai mật độ inode cho workload file nhỏ | 🔶 **OPEN** | Cần format lại / đổi XFS |

---

## 3. Issue đã FIXED

### Issue #2 — ✅ Thư mục `elasticsearch` + `mysql` mồ côi

**Triệu chứng** — `/data/ragflow` chứa 4 thư mục trong khi chỉ MinIO + Redis còn chạy trên node 07.

```
drwxr-xr-x  3 vt_admin  4096 May 14 18:41  elasticsearch
drwxr-xr-x 40 root      4096 Jul 20 17:35  minio
drwxr-xr-x  8 polkitd   4096 Aug  7 10:39  mysql
drwxr-xr-x  2 root      4096 Aug 26 09:13  redis
```

**Root cause** — MySQL đã migrate cả workload lẫn dữ liệu sang node 06 (07/08/2026),
ES đã chuyển ra chạy ngoài cụm. Nhưng hostPath **không tự dọn** khi pod rời node,
thư mục dữ liệu cũ nằm lại thành mồ côi.

**Bằng chứng mồ côi**

| Dấu hiệu | Ý nghĩa |
|---|---|
| `mysql.sock` là symlink treo | MySQL không còn tiến trình nào chạy |
| `ibdata1`, `undo_001`, `undo_002` đóng băng `Aug 7 10:39` | Trùng mốc migrate, 19 ngày không ghi mới |
| `elasticsearch/node.lock` size 0, mtime `May 14` | ES tắt hẳn, 3 tháng không đụng |

**Giải pháp cuối**

```
\rm -rf /data/ragflow/elasticsearch
```

```
\rm -rf /data/ragflow/mysql
```

**Kết quả — chỉ giải phóng 227 inode**

```
trước:  IUsed 6.221.793   IFree 331.807   95%
sau:    IUsed 6.221.566   IFree 332.034   95%
byte:   66G → 61G  (70% → 65%)   thu hồi 5G
```

⚠️ Xoá đúng nhưng **không cứu được sự cố** — chính kết quả này xác nhận thủ phạm inode
không nằm ở đây, và dẫn tới việc khoanh vùng đúng sang MinIO.

---

### Issue #3 — ✅ Chẩn đoán nhầm trục: dọn dung lượng thay vì inode

**Triệu chứng** — node 07 báo disk-pressure trong khi `df -h` cho thấy **còn trống 34G (65%)**.

**Root cause** — kubelet đánh giá disk-pressure trên **hai trục độc lập**:
`nodefs.available` (byte) và `nodefs.inodesFree` (inode). Chỉ cần **một** trục vượt là bật taint.
Các đợt dọn trước nhắm vào byte nên `df -h` đẹp lên mà inode gần như không giảm.

**Cơ chế inode** *(dùng để giải thích trong báo cáo sếp)*

Ext4 chia đĩa thành 2 vùng cố định lúc `mkfs`: bảng inode và vùng dữ liệu.
Mỗi file tốn **đúng 1 inode** bất kể lớn nhỏ — file 232 byte và file 1GB tốn như nhau.

```
Giả định lúc format:  6,5 triệu file × 16KB  = 99GB   ✓ cân
Thực tế MinIO:        6,2 triệu file × ~10KB = 61GB   ✗ lệch
→ hết inode khi vùng dữ liệu mới dùng 65%
```

**Bằng chứng** — `stat` một file MinIO thật:

```
File: '/data/ragflow/minio/.minio.sys/format.json'
Size: 232        Blocks: 8        IO Block: 4096   regular file
Inode: 2383940   Links: 1
Inode size: 256
```

File 232 byte vẫn tốn 1 inode y hệt file lớn.

**⭐ Bẫy phát hiện trong phiên** — `tune2fs` và `df -i` cho số vênh nhau:

```
df -i     →  Free inodes:   332.032    (95% used)   ← ĐÚNG
tune2fs   →  Free inodes: 6.446.817    (1,6% used)  ← SAI, số cũ
```

`tune2fs` đọc superblock **trên đĩa** (ext4 chỉ ghi định kỳ ⟹ lỗi thời).
`df` đọc trạng thái kernel qua `statfs()` — **đây mới là nguồn kubelet dùng để quyết định taint**.

---

## 4. Issue chưa xong

### Issue #1 — 🔶 OPEN — MinIO cạn inode làm sập RAGFlow

**Triệu chứng** — RAGFlow pod 0/1, MinIO + Redis `Pending` không gán được node.

```
ragflow-67fcdbbdb7-cpdbs   0/1   Running   0                23h
ragflow-67fcdbbdb7-ns8pd   0/1   Running   0                23h
ragflow-67fcdbbdb7-pl8hd   0/1   Running   3 (5m46s ago)    ← liveness giết pod
ragflow-minio-0            0/1   Pending   0                86s   <none>   ← không có NODE
ragflow-mysql-0            1/1   Running   0                12d
ragflow-redis-0            0/1   Pending   0                82s   <none>   ← không có NODE
```

Lỗi probe **nguyên văn**:

```
Warning  Unhealthy  Readiness probe failed: Get "http://172.16.78.64:9380/api/v1/system/healthz":
context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

⭐ **Phân biệt với lỗi phiên trước**: phiên 21/08 là `connection refused` (chưa bind port —
vấn đề khởi động). Lần này là **timeout** (port đã mở, app không trả headers trong 5s —
vấn đề dependency). Hai lỗi khác nhau, đừng gộp.

**Root cause — chuỗi nhân quả đầy đủ**

```
1. RAGFlow lưu MỖI CHUNK tài liệu = 1 object
   MinIO lưu MỖI OBJECT = 1 thư mục + xl.meta + part.1 ≈ 3 inode
        ↓
2. /data/ragflow/minio chiếm 5.664.048 inode (91% toàn node)
   /dev/vda1: 6.221.566 / 6.553.600 = 95%
        ↓
3. kubelet: nodefs.inodesFree < 5% → bật taint
   node.kubernetes.io/disk-pressure:NoSchedule
        ↓
4. PV của MinIO + Redis là hostPath, PIN CỨNG node 07
   → node có taint → không còn node thay thế → Pending vĩnh viễn
        ↓
5. RAGFlow gọi MinIO/Redis → treo tới hết TCP timeout
        ↓
6. /api/v1/system/healthz là DEEP CHECK (gọi ES + MySQL + Redis + MinIO)
   → không trả headers trong timeoutSeconds: 5
        ↓
7. Readiness timeout → pod 0/1 ; Liveness fail → pod restart
```

**Bằng chứng root cause**

```
find /data/ragflow/minio -xdev -printf "." | wc -c
5664048
```

Đối chiếu tổng: 5.664.048 / 6.221.566 = **91%**.

Phân bố inode toàn node (loại trừ mọi chỗ khác):

```
/var/lib/containerd    107.753
/var/lib/kubelet           115
/var/lib/nerdctl         2.007
/var/log                 2.605
/home/app                   33
/tmp                         9
/data/ragflow/minio  5.664.048   ← thủ phạm
```

**Đánh giá root cause — độ chắc chắn: CAO.** Có số đo trực tiếp, không suy diễn.

**Tiến triển / đã khoanh vùng được gì**

| Đã loại trừ | Bằng chứng |
|---|---|
| Hết dung lượng | `df -h` còn 34G trống (65%) |
| containerd/image ăn inode | 107k inode = 1,7% |
| ES/MySQL mồ côi | Xoá rồi, chỉ được 227 inode |
| **Multipart upload rác** | `.minio.sys/multipart/` = **1 inode** (rỗng) |
| Log ăn inode | `/var/log` = 2.605 inode |

⭐ **Phát hiện quan trọng nhất**: `multipart/` rỗng ⟹ **không tồn tại object rác để dọn**.
5,66 triệu inode là object **thật** RAGFlow chủ động ghi. Không có đường tắt —
muốn giảm inode chỉ còn cách giảm dữ liệu thật hoặc đổi hạ tầng lưu trữ.

**⭐ Bảng đã thử — GỒM CẢ ĐƯỜNG CỤT**

| # | Phương án | Kết quả | Loại rào cản / ghi chú |
|---|---|---|---|
| 1 | Xoá ES + MySQL mồ côi | ⚠️ Được 5G nhưng chỉ **227 inode** | Đúng việc, sai kỳ vọng |
| 2 | Nới ngưỡng `evictionHard` xuống 2–3% | ❌ **SẾP BÁC** | **Không được phép**, không phải chưa biết cách. Sếp: *"cách này ko dc"* |
| 3 | `mc rm --incomplete --older-than 7d` | ❌ **VÔ TÁC DỤNG** | Sếp chỉ đạo. Nhưng `multipart/` rỗng ⟹ thu về 0. `mc` cũng chưa cài trên node |
| 4 | Tăng size PVC → tăng inode | ❌ **KHÔNG ÁP DỤNG ĐƯỢC** | Sếp gợi ý. PV là **hostPath** — `capacity` chỉ là số khai báo, không cấp phát thật |
| 5 | Gỡ taint thủ công | ❌ Loại từ đầu | kubelet re-evaluate, bật lại sau ~10s. Kiên chủ động bác: *"gỡ taint vậy nguy hiểm lắm"* |
| 6 | Migrate sang node 06 (.53) | ❌ Loại | Đĩa chỉ còn **32G**, MinIO cần ~61G — **không đủ chỗ** |
| 7 | Migrate sang node 08 (.55) | ⚠️ Khả thi nhưng đã bỏ | Còn 69G cho 61G ⟹ sau migrate node 08 lên **~92% đĩa**, dính disk-pressure trục byte |
| 8 | **Move sang cụm vMLP** | 🔶 **ĐANG CHỌN** | Tách hẳn khỏi vRP |

**⭐ Kết luận SAI đã từng tin trong phiên**: ban đầu tôi ghi trong báo cáo
"migrate sang node khác là **xử lý dứt điểm**". **Sai.**
Kiên phát hiện: RAGFlow vẫn sinh object với tốc độ cũ ⟹ node đích sẽ cạn lại,
chỉ là muộn hơn. Ước tính node có 13M inode mua thêm được ~6–8 tháng ❓ *(suy từ tốc độ
node 07 đi từ trống tới 95% trong ~3–4 tháng với 6,5M inode — chưa đo tốc độ tăng thực tế)*.
Đã sửa lại trong báo cáo gửi sếp.

**Còn tồn đọng nếu để nguyên**

- RAGFlow gián đoạn hoàn toàn, người dùng không truy cập được
- Node 07 free inode chỉ **0,33 triệu** và MinIO **vẫn đang ghi** ⟹ nếu cạn hẳn:
  container không start được, containerd không unpack image được,
  **có nguy cơ hỏng object MinIO** khi ghi lỗi giữa chừng
- `ragflow-mysql-0` còn `1/1 Running 12d` vì nằm trên node 06 — chưa ảnh hưởng

**Hướng xử lý tiếp** *(việc làm được ngay xếp trước)*

1. Chạy `du -sh /data/ragflow/minio` — biết dung lượng thật cần chuyển (**chưa chạy**)
2. ❓ Khảo sát cụm **vMLP**: node nào, `df -ih /`, `df -h /`, storage class có sẵn
3. ❓ Xác định MinIO trên vMLP dùng hostPath hay storage phân tán
   *(nếu vMLP có Longhorn/Ceph thì tránh được hostPath, xử lý luôn Issue #5)*
4. Lên kế hoạch downtime + phương án copy dữ liệu qua 2 cụm airgap
5. Cập nhật endpoint MinIO trong `values.yaml` RAGFlow trỏ sang vMLP
6. Sau khi chuyển xong: xoá `/data/ragflow/minio` trên node 07, thu hồi 5,66M inode

---

### Issue #4 — 🔶 OPEN — MinIO cluster hoá

**Chỉ đạo của sếp** (26/08, 10:18): *"dài hạn phải cài lại minio theo hướng cluster để chia nhỏ dữ liệu"*

**Đánh giá root cause sơ bộ — độ chắc chắn: CAO.**
MinIO single-node dồn toàn bộ object lên **một** filesystem ⟹ quỹ inode của đúng một ổ
trở thành trần cứng của cả hệ thống. Cluster nhiều node chia object ra ⟹ mỗi node chỉ gánh một phần.

**Tiến triển** — mới ở mức chỉ đạo, chưa khảo sát gì.
Sếp cũng nói *"nếu mình có sẵn node thì ok luôn"* ⟹ rào cản là **tài nguyên**, không phải kỹ thuật.

**Còn tồn đọng** — chưa làm thì mọi phương án migrate chỉ là mua thêm thời gian.

**Hướng xử lý tiếp**

1. Khảo sát số node khả dụng cho MinIO cluster (tối thiểu 4 node cho erasure coding)
2. Đánh giá có gộp luôn vào việc move sang vMLP không — tránh migrate 2 lần

---

### Issue #5 — 🔶 OPEN — Ổ `/dev/vda1` format sai mật độ inode

**Đánh giá root cause — độ chắc chắn: CAO.**
`mkfs.ext4` mặc định cấp 1 inode / 16KB. Workload MinIO nhiều file nhỏ (~10KB)
phá vỡ giả định đó. Bảng inode nằm vị trí cố định sát vùng dữ liệu ⟹ **ext4 không nới được**.

**Bằng chứng — cả 3 node cùng mật độ**

```
node 07:  Inodes 6.553.600   đĩa  99G   → 1 inode / 15,8KB
node 06:  Inodes 13M         đĩa 197G   → 1 inode / 15,8KB
node 08:  Inodes 13M         đĩa 197G   → 1 inode / 15,8KB
```

⚠️ Trả lời câu hỏi của sếp *"check thử 2 node to xem inode là bao nhiêu, có gấp đôi ko"*:
**gấp đôi cả inode lẫn đĩa, nhưng tỉ lệ y hệt** — node 06/08 hơn chỉ vì đĩa to gấp đôi,
**không phải cấu hình tốt hơn**. Chuyển sang đó vẫn gặp lại vấn đề, chỉ muộn hơn.

**Tiến triển** — đã đo được mật độ của cả 3 node, đủ căn cứ kết luận đây là vấn đề hệ thống
chứ không riêng node 07.

**Hướng xử lý tiếp** *(đều cần format lại ⟹ mất dữ liệu ⟹ phải backup/restore)*

| Cách | Ưu | Nhược |
|---|---|---|
| `mkfs.ext4 -i 4096` | Inode gấp 4 (26M) | Vẫn cố định, vẫn có trần |
| Chuyển **XFS** | Cấp phát inode **động**, hết thì cấp thêm | Đổi filesystem, cần test kỹ |
| Ổ riêng cho MinIO | Tách rủi ro khỏi OS node | Cần cấp thêm đĩa |

---

## 5. Bài học

### Filesystem / inode

- ⭐ **Disk-pressure có 2 trục độc lập.** `df -h` xanh **không** loại trừ disk-pressure.
  Luôn chạy **cả** `df -h` **và** `df -i`.
  *Phát hiện sớm*: `df -ih /` — đọc cột `IUse%`.

- ⭐ **File nhỏ và file lớn ăn inode như nhau.** Xoá 1 tarball 3,7G thu hồi nhiều byte
  nhưng **đúng 1 inode**. Dọn theo dung lượng không bao giờ cứu được sự cố inode.
  *Phát hiện sớm*: so `IUse%` với `Use%` — lệch nhiều ⟹ workload nhiều file nhỏ.

- ⭐ **`tune2fs` cho số free inode SAI.** Nó đọc superblock trên đĩa (ghi định kỳ, lỗi thời).
  Chỉ tin `df -i` — cùng nguồn `statfs()` mà kubelet dùng.
  Trong phiên này hai lệnh vênh nhau **6,1 triệu inode**, suýt dẫn tới kết luận "chưa cạn".

- **Inode không nới được trên ext4.** Bảng inode cố định lúc `mkfs`, nằm sát vùng dữ liệu.
  Muốn tăng phải format lại toàn ổ.

### MinIO

- ⭐ **MinIO ăn inode theo SỐ OBJECT, không theo dung lượng.** Mỗi object ≈ 3 inode
  (thư mục + `xl.meta` + `part.1`). RAGFlow đẩy mỗi chunk tài liệu thành 1 object
  ⟹ inode tăng theo **số tài liệu đã parse**, hoàn toàn không tương quan với dung lượng.
  *Phát hiện sớm*: `ls -la` thư mục bucket — cột link count = số thư mục con + 2.

- ⭐ **Kiểm tra `multipart/` TRƯỚC khi định dùng `mc rm --incomplete`.**
  Rỗng ⟹ không có rác ⟹ thu về 0, khỏi mất công cài `mc` trên môi trường airgap.
  *Lệnh*: `find /data/ragflow/minio/.minio.sys/multipart -xdev -printf "." | wc -c`

### Kubernetes

- ⭐ **hostPath PV pin cứng pod vào node.** Node dính taint ⟹ pod `Pending` **vĩnh viễn**,
  không có node dự phòng. Đây chính là lý do sự cố inode leo thang thành sập dịch vụ.
  *Phát hiện sớm*: `kubectl get pod -o wide` — `Pending` mà cột `NODE` là `<none>`.

- ⭐ **Tăng size PVC KHÔNG tăng inode với hostPath.** `capacity` trong PV hostPath
  chỉ là con số khai báo, không có ranh giới thật, không cấp phát gì.
  Chỉ đúng với PVC do storage class cấp ổ riêng (Longhorn / LVM / cloud disk).

- ⭐ **Readiness probe làm ĐÚNG việc khi báo 0/1.** Pod RAGFlow không hỏng — nó báo
  trung thực rằng dependency hỏng. Không có probe này thì k8s đã đánh Ready,
  forward request vào và user ăn 502.
  *(Chính là probe thêm vào ở phiên upgrade chart 21/08 — xem `TRACKING-helm-chart-v0.26.4-improve.md`.)*

- **`connection refused` ≠ `context deadline exceeded`.** Cái đầu = chưa bind port
  (vấn đề khởi động, thường trong startup window). Cái sau = port mở nhưng app treo
  (vấn đề dependency). Đọc nhầm là đi sai hướng cả buổi.

- **Gỡ taint thủ công vô nghĩa** — kubelet re-evaluate và bật lại sau ~10s.

### Vận hành

- ⭐ **hostPath không tự dọn khi pod rời node.** Migrate workload ≠ migrate dữ liệu trên đĩa.
  Sau mỗi lần migrate phải xoá thư mục cũ thủ công, nếu không thành dữ liệu mồ côi ăn inode.
  *Trong phiên này*: MySQL migrate 07/08, tới 26/08 thư mục vẫn nằm nguyên trên node 07.

- ⭐ **Tách "chưa biết cách" khỏi "không được phép".** Phương án nới ngưỡng
  kỹ thuật làm được trong 5 phút, nhưng **sếp bác**. Hai loại rào cản này cần cách gỡ
  hoàn toàn khác nhau — cái đầu cần điều tra, cái sau cần thuyết phục / xin phê duyệt.

- **Thư mục ứng dụng ở root filesystem dễ bị bỏ sót.** `/data` không phải bố cục chuẩn
  của CentOS hay k8s ⟹ các đợt dọn trước chỉ quét `/var/lib/*` nên bỏ qua hoàn toàn.
  *Phát hiện sớm*: quét từ `/` chứ đừng chỉ quét thư mục hệ thống.

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| Không có giám sát `df -i` | Chưa ai đặt alert inode trên Prometheus | Lặp lại y hệt: chỉ biết khi dịch vụ đã chết |
| MinIO single-node | Thiết kế ban đầu | Trần inode của 1 ổ = trần của cả hệ thống |
| PV dùng hostPath | Thiết kế ban đầu | Pod pin cứng node, mất khả năng failover |
| Ổ format mật độ inode mặc định | `mkfs` lúc dựng node | Sai giả định với workload file nhỏ |
| Chưa có tác vụ dọn object mồ côi định kỳ | — | ❓ KB xoá trên UI nhưng object có còn trên đĩa không — **chưa xác minh** |
| ES password + Bearer token trong git history | PR #8, commit trước `b79e701` | **Cần rotate** (kế thừa từ phiên trước) |

---

## 7. Việc tiếp theo

### Ngay lập tức

- [ ] Chạy `du -sh /data/ragflow/minio` — biết dung lượng thật cần chuyển
- [ ] Khảo sát cụm **vMLP**: danh sách node, `df -ih /`, `df -h /`, storage class có sẵn
- [ ] Xác định MinIO trên vMLP sẽ dùng hostPath hay storage phân tán
- [ ] Phản hồi sếp: `mc rm --incomplete` và tăng size PVC **không dùng được**, kèm bằng chứng
- [ ] Cân nhắc **tạm dừng upload tài liệu mới** vào RAGFlow để node 07 không cạn hẳn inode

### Ngắn hạn

- [ ] Lên kế hoạch downtime move MinIO vRP → vMLP
- [ ] ❓ Phương án copy ~61G qua 2 cụm airgap — chưa rõ đường truyền giữa 2 cụm
- [ ] Backup `/data/ragflow/minio` trước khi thao tác
- [ ] Cập nhật endpoint MinIO trong `values.yaml` RAGFlow
- [ ] Sau khi chuyển xong: xoá `/data/ragflow/minio` node 07, thu hồi 5,66M inode
- [ ] Thêm alert Prometheus cho `node_filesystem_files_free` (ngưỡng cảnh báo 20%)

### Dài hạn

- [ ] MinIO cluster hoá theo chỉ đạo sếp (tối thiểu 4 node cho erasure coding)
- [ ] Đánh giá chuyển hostPath → storage phân tán (Longhorn) cho toàn cụm
- [ ] Xem xét format lại ổ MinIO với XFS hoặc `mkfs.ext4 -i 4096`
- [ ] Tác vụ định kỳ dọn object mồ côi (đối chiếu bucket ↔ `knowledgebase` trong MySQL)

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Node 07 cạn hẳn inode trước khi migrate xong | 🔴 **Cao** | Chỉ còn 0,33M inode. Tạm dừng upload tài liệu mới |
| Hỏng object MinIO do ghi lỗi khi hết inode | 🔴 **Cao** | Backup `/data/ragflow/minio` trước khi làm bất cứ gì |
| Copy ~61G qua 2 cụm airgap thất bại giữa chừng | 🟡 Trung bình | Dùng `rsync` có resume, verify checksum sau khi copy |
| Cụm vMLP cũng cạn inode sau vài tháng | 🟡 Trung bình | Chọn node có storage phân tán / XFS ngay từ đầu, đừng lặp lại hostPath |
| Xoá nhầm object thật khi dọn | 🟡 Trung bình | ⚠️ **KHÔNG `rm` trong `/data/ragflow/minio`** — chỉ xoá qua MinIO API/`mc` |
| RAGFlow gián đoạn kéo dài | 🟡 Trung bình | Cân nhắc gỡ **Redis** khỏi node 07 trước (cache, dữ liệu không quan trọng, ít inode) |
| Migrate xong vẫn tái diễn | 🟡 Trung bình | Đây là bước đệm, không phải giải pháp gốc — phải làm Issue #4 |

---

## Phụ lục A — Lệnh đã dùng

### Kiểm tra inode

```
df -ih /
```

<details>
<summary>Giải nghĩa</summary>

```
df -ih /
│  ││ └─ đường dẫn cần kiểm tra (ở đây là root filesystem)
│  │└─── -h : human-readable, rút gọn 13107200 thành 13M
│  └──── -i : hiển thị INODE thay vì dung lượng (mặc định df hiện byte)
└─────── df : disk free
```

Không có `-i` thì `df` chỉ báo byte — **đúng cái bẫy của phiên này**.
Cột cần đọc: **`IUse%`**. Từ 95% trở lên là đã vượt ngưỡng kubelet mặc định (5% free).
</details>

### Đếm inode theo thư mục

```
find /data/ragflow/minio -xdev -printf "." | wc -c
```

<details>
<summary>Giải nghĩa</summary>

```
find /data/ragflow/minio -xdev -printf "." | wc -c
│    │                    │      │            │  └─ -c : đếm KÝ TỰ
│    │                    │      │            └──── wc : word count
│    │                    │      └─── -printf "." : in đúng 1 dấu chấm mỗi file
│    │                    └────────── -xdev : KHÔNG vượt sang mount khác
│    └───────────────────────────── thư mục cần đếm
└────────────────────────────────── find
```

Mỗi file → 1 ký tự → `wc -c` đếm được **số file = số inode**.
Nhanh hơn `du` vì không cần `stat` để lấy kích thước từng file.

⚠️ `-xdev` **bắt buộc** — bài học cũ: không có nó thì bò sang PV/NFS,
số sai và chạy hàng chục phút.
</details>

### Quét từng thư mục con (in dần, không phải chờ hết)

```
for d in /data/ragflow/*; do echo -n "$d "; find "$d" -xdev -printf '.' 2>/dev/null | wc -c; done
```

<details>
<summary>Giải nghĩa</summary>

```
for d in /data/ragflow/*; do echo -n "$d "; find "$d" -xdev ... ; done
│                          │  │       │           │
│                          │  │       │           └─ nháy kép quanh "$d" : an toàn với tên có khoảng trắng
│                          │  │       └─ "$d " : in tên thư mục, dấu cách phân tách với số
│                          │  └───────── -n : KHÔNG xuống dòng, để số nằm cùng dòng tên
│                          └──────────── do ... done : thân vòng lặp
└─────────────────────────────────────── duyệt từng thư mục con
```

`2>/dev/null` nuốt lỗi permission cho output sạch.
In **dần từng dòng** — thư mục nào chạy lâu chính là thư mục nhiều file.
</details>

### Chạy nền khi quét lâu

```
nohup sh -c 'find /data/ragflow/minio -xdev -printf "." | wc -c > /root/minio-inode.txt' &
```

<details>
<summary>Giải nghĩa</summary>

```
nohup sh -c '... > /root/minio-inode.txt' &
│     │  │                                └─ & : chạy nền, trả lại prompt ngay
│     │  └─ -c : chạy chuỗi lệnh truyền vào
│     └──── sh : shell con
└────────── nohup : không chết khi đóng terminal / mất SSH
```

Quét 5,6 triệu inode mất nhiều phút. Chạy nền để không phải giữ session.

| Việc | Lệnh |
|---|---|
| Xem kết quả | `cat /root/minio-inode.txt` — rỗng = chưa xong |
| Xem tiến độ | `jobs` — còn `Running` là chưa xong |
</details>

### Kiểm tra multipart rác

```
find /data/ragflow/minio/.minio.sys/multipart -xdev -printf '.' 2>/dev/null | wc -c
```

Kết quả `1` = thư mục rỗng (chỉ đếm chính nó) ⟹ **không có rác upload dở dang**.

### Kiểm tra thư mục có mồ côi không

```
fuser -vm /data/ragflow/mysql
```

<details>
<summary>Giải nghĩa</summary>

```
fuser -vm /data/ragflow/mysql
│     ││  └─ đường dẫn cần kiểm tra
│     │└─── -m : liệt kê tiến trình đang dùng FILESYSTEM chứa đường dẫn này
│     └──── -v : verbose, hiện bảng có tên tiến trình + user
└────────── fuser : file user — ai đang giữ file này
```

Không tiến trình nào ⟹ mồ côi, an toàn xoá.
</details>

### Xoá (bỏ qua alias `rm -i` của CentOS 7)

```
\rm -rf /data/ragflow/elasticsearch
```

<details>
<summary>Giải nghĩa</summary>

```
\rm -rf /data/ragflow/elasticsearch
││  ││└─ -f : force, không hỏi khi file read-only
││  │└── -r : recursive, xoá cả thư mục con
│└────── rm
└─────── \  : BỎ QUA alias. CentOS 7 đặt alias rm='rm -i' (hỏi từng file)
```

⚠️ Output kết thúc bằng dấu `?` nghĩa là nó **đã hỏi và CHƯA xoá**.
</details>

### Xem metadata một file (chứng minh cơ chế inode)

```
stat /data/ragflow/minio/.minio.sys/format.json
```

<details>
<summary>Giải nghĩa</summary>

Đọc thẳng nội dung **inode** của file. Các trường cần chú ý:

| Trường | Ý nghĩa |
|---|---|
| `Size` | Kích thước thật (byte) |
| `Blocks` | Số block 512-byte đã cấp — file nhỏ vẫn chiếm tối thiểu 1 block 4KB |
| `Inode` | Số hiệu inode — chứng minh mỗi file tốn đúng 1, bất kể lớn nhỏ |
| `Modify` | Lần cuối **nội dung** thay đổi |
| `Change` | Lần cuối **metadata** thay đổi — dùng phát hiện tiến trình còn hoạt động không |
</details>

### Xem cấu hình inode của filesystem

```
tune2fs -l /dev/vda1 | grep -iE "inode count|free inodes|inode size"
```

⚠️ **`Free inodes` ở đây KHÔNG đáng tin** — đọc superblock trên đĩa, lỗi thời.
Chỉ dùng để xem `Inode count` và `Inode size` (giá trị tĩnh, không đổi).
Free inode **phải** lấy từ `df -i`.

### Kiểm tra PV pin vào node nào

```
kubectl get pv -o custom-columns=NAME:.metadata.name,PATH:.spec.hostPath.path,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],CLAIM:.spec.claimRef.name
```

<details>
<summary>Giải nghĩa</summary>

```
kubectl get pv -o custom-columns=NAME:...,PATH:...,NODE:...,CLAIM:...
                │  └─ custom-columns : tự chọn cột thay vì output mặc định
                └──── -o : output format
```

| Cột | Trường | Cho biết |
|---|---|---|
| PATH | `.spec.hostPath.path` | Thư mục thật trên node |
| NODE | `.spec.nodeAffinity...values[0]` | PV pin vào node nào |
| CLAIM | `.spec.claimRef.name` | PVC nào đang dùng |

Cột `PATH` có giá trị ⟹ hostPath ⟹ **pin cứng node, không failover được**.
</details>

### Kiểm tra ngưỡng eviction của kubelet

```
grep -nE "eviction|inodes|nodefs|imagefs" /etc/kubernetes/kubelet-config.yaml
```

Không ra dòng nào ⟹ đang dùng **mặc định**: `nodefs.inodesFree < 5%`.

Đường dẫn config lấy từ:

```
ps -ef | grep kubele[t] | tr ' ' '\n' | grep -E "config|eviction"
```

<details>
<summary>Giải nghĩa</summary>

```
ps -ef | grep kubele[t] | tr ' ' '\n' | grep -E "config|eviction"
│  │      │              │              └─ -E : regex mở rộng, dùng | làm "hoặc"
│  │      │              └─ tr ' ' '\n' : đổi mỗi khoảng trắng thành xuống dòng
│  │      │                               ⟹ mỗi tham số một dòng, dễ đọc
│  │      └─ kubele[t] : ngoặc vuông để grep KHÔNG tự khớp chính nó
│  └─ -e : mọi tiến trình | -f : full command line (cần, để thấy tham số)
└──── ps
```

⭐ Mẹo `kubele[t]`: regex `[t]` khớp ký tự `t` nhưng chuỗi lệnh `grep kubele[t]`
lại không chứa `kubelet` ⟹ tránh dòng rác của chính lệnh grep.
</details>

---

## Phụ lục B — Trao đổi với sếp (26/08/2026)

| Giờ | Người | Nội dung |
|---|---|---|
| 09:25 | Sếp | *"nhưng cái gì làm nó đầy nhanh thế"* |
| 10:08 | Kiên | Báo nguyên nhân: MinIO chiếm 5,66M inode (91% node 07) |
| 10:12 | Kiên | Đề xuất 3 hướng, tự nhận đều không phải lâu dài |
| 10:14 | Sếp | Gợi ý `mc rm --incomplete --older-than 7d` |
| 10:16 | Sếp | *"với check size của PVC nữa"* |
| 10:17 | Sếp | *"tăng size lên cũng tăng inode"* |
| 10:18 | Sếp | *"dài hạn phải cài lại minio theo hướng cluster để chia nhỏ dữ liệu"* |
| 10:21 | Kiên | Giải thích RAGFlow chỉ ready khi ES + MinIO + Redis + MySQL đều OK |
| 10:23 | Sếp | *"ừa, nhưng mà đang giải quyết chỗ minio đã"* |
| 10:35 | Sếp | *"sau đó mới tính cài đa node"* |
| 10:39 | Sếp | *"giờ move minio sang node khác cũng phải tính kìa"* |
| 10:40 | Sếp | *"check thử mấy 2 node to xem inode là bao nhiêu, có gấp đôi ko"* |

### ⚠️ Cần phản hồi lại sếp — 2 gợi ý không dùng được

| Gợi ý | Vì sao không dùng được | Bằng chứng |
|---|---|---|
| `mc rm --incomplete` | `multipart/` **rỗng**, không có rác. Thu về 0 inode | `find .../multipart ... \| wc -c` = `1` |
| Tăng size PVC | PV là **hostPath**, `capacity` chỉ là số khai báo, không cấp phát thật | `kubectl get pv` — cột `PATH` = `/data/ragflow/minio` |

### Trả lời câu hỏi *"2 node to có gấp đôi inode không"*

**Có — gấp đôi cả inode lẫn đĩa, nhưng mật độ y hệt.**

```
node 07:  6.553.600 inode /  99G  → 1 inode / 15,8KB
node 06:        13M inode / 197G  → 1 inode / 15,8KB
node 08:        13M inode / 197G  → 1 inode / 15,8KB
```

Node 06/08 hơn chỉ vì **đĩa to gấp đôi**, không phải cấu hình tốt hơn.
Chuyển sang đó vẫn cạn lại, chỉ muộn hơn ⟹ đúng như sếp lo:
*"giờ move minio sang node khác cũng phải tính kìa"*.
