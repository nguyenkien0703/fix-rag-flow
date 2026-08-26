# 📕 RUNBOOK — MinIO của RAGFlow trên cụm vMLP

> **Tài liệu VẬN HÀNH.** Đọc file này khi cần biết *"cái gì nằm ở đâu, chạy lệnh nào"*.
> Muốn biết **vì sao** lại làm như vậy ⟹ đọc `TRACKING-migrate-minio-vRP-to-vMLP.md`.
>
> **Ngày migrate**: 26/08/2026 · **Người thực hiện**: KienNV
> **Trạng thái**: ✅ Đã chạy production, RAGFlow (vRP) kết nối được MinIO (vMLP)

---

## 1. ⚡ TÓM TẮT — 30 giây

MinIO của RAGFlow **đã chuyển từ cụm vRP (node 07) sang cụm vMLP (node 09)**
vì node 07 cạn inode. RAGFlow **vẫn ở lại vRP**, gọi sang MinIO qua NodePort.

```
┌─────────────── vRP (airgap) ───────────────┐      ┌────── vMLP ──────┐
│  RAGFlow  deploy/ragflow      ns: ragflow  │      │ ns: ragflow      │
│  Redis    sts/ragflow-redis   (vrp-07)     │─────▶│ sts/ragflow-minio│
│  MySQL    sts/ragflow-mysql                │ S3   │ (vmlp-09)        │
│  MinIO    sts/ragflow-minio → ⛔ replicas=0│ 9000 │ 37G / 5,66M inode│
└────────────────────────────────────────────┘      └──────────────────┘
        ES chạy NGOÀI cụm: https://10.211.145.107:8051
```

| Hạng mục | Giá trị |
|---|---|
| **Node chạy MinIO** | `vmlp-kubeengine09` = **`10.208.137.43`** |
| **Đường dẫn dữ liệu** | **`/home/app/app_data/ragflow/minio`** (hostPath, trên `/dev/vda1`) |
| **Namespace** | `ragflow` (cụm vMLP) |
| **Endpoint RAGFlow gọi** | **`10.208.137.43:9000`** (NodePort) |
| **Console MinIO** | `10.208.137.43:9901` |
| **Image** | `docker.io/minio/minio:RELEASE.2025-06-13T11-33-47Z` |
| **Dung lượng** | 37G on-disk / 20,3 GiB logic / **5.664.048 inode** |

---

## 2. 📁 FILE NẰM Ở ĐÂU

### 2.1 Trên node vmlp-08 (`10.208.137.42`) — nơi gõ `kubectl` của cụm vMLP

Thư mục: **`/home/app/KienNV_DevOps/`** (user `app`)

| File | Nội dung |
|---|---|
| `minio-secret.yaml` | Secret `ragflow-env-config` copy từ vRP (đã lọc metadata) |
| `minio-pv-pvc.yaml` | PersistentVolume + PersistentVolumeClaim |
| `minio-sts.yaml` | StatefulSet MinIO |
| `minio-svc.yaml` | 2 Service: headless + NodePort |

### 2.2 Trong git repo `fix-rag-flow`

| File | Nội dung |
|---|---|
| `manifests-vmlp/minio-vmlp.yaml` | **Bản gộp đầy đủ** cả 6 object trong 1 file, có comment giải nghĩa từng dòng |
| `RUNBOOK-minio-vmlp.md` | ⬅️ file này |
| `TRACKING-migrate-minio-vRP-to-vMLP.md` | Nhật ký điều tra đầy đủ: 14 phát hiện, 26 rủi ro, mọi lệnh + giải nghĩa |

> ✅ Bản trong git **đã đồng bộ** với bản đang chạy (`nodePort: 9000/9901`).
> ⚠️ Nhưng các file trong `/home/app/KienNV_DevOps/` trên vmlp-08 **vẫn còn**
> `nodePort: 9900` ở `minio-svc.yaml` (đã patch trực tiếp bằng `kubectl patch`,
> chưa sửa lại file). **Apply lại file đó sẽ làm hỏng kết nối RAGFlow** — xem 6.1.
> ⟹ Sửa file trên vmlp-08 cho khớp, hoặc copy bản từ git sang.

### 2.3 Dữ liệu

| Nơi | Đường dẫn | Trạng thái |
|---|---|---|
| ✅ **Bản đang dùng** | `vmlp-09:/home/app/app_data/ragflow/minio` | **DUY NHẤT** — không còn bản sao nào khác |
| ❌ Bản gốc | `vrp-07:/data/ragflow/minio` | **ĐÃ XOÁ** 26/08 để thu hồi inode |

> 🔴 **KHÔNG CÒN BẢN SAO.** Mọi thao tác trên `/home/app/app_data/ragflow/minio`
> phải hết sức cẩn thận. Xem mục 7 — chưa có backup.

---

## 3. 🔑 CÁCH ĐĂNG NHẬP (khác nhau giữa 2 cụm!)

| Cụm | Node gõ `kubectl` | User | Cách vào root |
|---|---|---|---|
| **vRP** | `vrp-04` = `10.208.137.51` | `app` | ssh thẳng `root@` **được** |
| **vMLP** | `vmlp-08` = `10.208.137.42` | `app` | ❌ **KHÔNG** ssh thẳng root — phải `ssh vt_admin@` rồi `su -` |

> ⚠️ **Mọi lệnh từ xa vào vMLP** (`ssh`, `scp`, `rsync`) **phải dùng `vt_admin@`**.
> `vt_admin` có sudo nhưng **đòi mật khẩu** ⟹ không dùng được trong phiên không TTY.

> ⚠️ **SSH chiều vMLP → vRP bị CHẶN** (`Connection timed out`).
> Chỉ đi được chiều **vRP → vMLP**. Muốn copy file: luôn **đẩy** từ vRP sang, không **kéo** từ vMLP.

---

## 4. 🔍 KIỂM TRA SỨC KHOẺ — chạy khi nghi có sự cố

### 4.1 Trên vmlp-08 (`app`) — kiểm MinIO
```
kubectl -n ragflow get pod,svc,pvc -o wide
kubectl -n ragflow get endpoints ragflow-minio
kubectl -n ragflow logs ragflow-minio-0 --tail=50
```
<details>
<summary>Kết quả kỳ vọng (bấm để mở)</summary>

```
pod/ragflow-minio-0            1/1 Running   trên vmlp-kubeengine09
svc/ragflow-minio             NodePort  9000:9000/TCP, 9001:9901/TCP
svc/ragflow-minio-headless    ClusterIP None
pvc/pvc-ragflow-minio-vmlp    Bound → pv-ragflow-minio-vmlp
endpoints                     172.16.x.x:9000   ⬅️ KHÔNG được rỗng
```
⚠️ `endpoints` **rỗng** ⟹ sai selector hoặc sai **tên** port (`s3`/`console`).
</details>

### 4.2 Trên vrp-07 hoặc bất kỳ node vRP nào (`root`) — kiểm đường xuyên cụm
```
curl -s -o /dev/null -w "%{http_code}\n" http://10.208.137.43:9000/minio/health/live
curl -s -o /dev/null -w "%{http_code}\n" http://10.208.137.43:9000/
```
<details>
<summary>Cách đọc kết quả (bấm để mở)</summary>

```
/minio/health/live  → 200   MinIO sống
/                   → 403   ⭐ 403 LÀ ĐÚNG, KHÔNG PHẢI LỖI
                            S3 từ chối request không ký (không có AWS signature)
                            ⟹ chứng tỏ tầng S3 API đang hoạt động
                            Nếu ra 000 / timeout ⟹ mạng hoặc Service hỏng
```
</details>

### 4.3 Trên vmlp-09 (`root`) — kiểm inode (⚠️ QUAN TRỌNG, xem mục 7)
```
df -i /home
df -h /home
```
<details>
<summary>Ngưỡng cảnh báo (bấm để mở)</summary>

```
Đo được 26/08 ngay sau migrate:
  Inodes 13.107.200 · IUsed 6.144.243 · IFree 6.962.957 · IUse% 47%
  Size 197G · Used ~87G · Avail ~103G

⚠️ NGƯỠNG:
  IUse% ≥ 80%  → cảnh báo, bắt đầu lên kế hoạch
  IUse% ≥ 90%  → nguy hiểm
  IUse% ≥ 95%  → kubelet bật taint disk-pressure ⟹ pod bị evict / không schedule được

🔴 /home nằm trên `/` (cùng /dev/vda1) ⟹ cạn inode giết CẢ kubelet + containerd,
   không riêng MinIO.
```
</details>

### 4.4 Trên vrp-04 (`app`) — kiểm RAGFlow đọc đúng MinIO không
```
kubectl -n ragflow get pod -o wide
kubectl -n ragflow logs deploy/ragflow -c ragflow --tail=40 | grep -i minio
```
Phải thấy `minio: {... 'host': '10.208.137.43:9000' ...}` và **không** có
`Connection refused`.

---

## 5. 🔄 CÁC THAO TÁC THƯỜNG DÙNG

### 5.1 Restart MinIO
```
kubectl -n ragflow rollout restart sts ragflow-minio
kubectl -n ragflow get pod -w
```
> ⏱️ MinIO quét 2,83 triệu object lúc boot. Lần migrate mất **~30 giây** để Ready,
> nhưng `startupProbe` cho phép tới **10 phút**. Pod `Running` mà chưa `Ready`
> trong vài phút là **BÌNH THƯỜNG** — đừng vội kết luận hỏng.

### 5.2 Restart RAGFlow (trên vrp-04, `app`)
```
kubectl -n ragflow rollout restart deploy ragflow
kubectl -n ragflow get pod -o wide
```

### 5.3 Xem MinIO Console bằng trình duyệt
```
http://10.208.137.43:9901
```
User/password lấy từ secret (mục 5.4).

### 5.4 Đọc credential MinIO
Trên **vmlp-08** hoặc **vrp-04** (`app`):
```
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d; echo
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d; echo
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data.MINIO_HOST}' | base64 -d; echo
```

### 5.5 Đổi endpoint MinIO mà RAGFlow trỏ tới
⚠️ RAGFlow đọc **`/ragflow/conf/service_conf.yaml`** (từ ConfigMap
`ragflow-service-config`), **KHÔNG** đọc trực tiếp `MINIO_PORT` trong secret.

Trên **vrp-04** (`app`):
```
kubectl -n ragflow get cm ragflow-service-config -o yaml | grep -A3 minio
echo -n '<ip-moi>' | base64
kubectl -n ragflow patch secret ragflow-env-config -p '{"data":{"MINIO_HOST":"<base64>"}}'
kubectl -n ragflow rollout restart deploy ragflow
```
> 💡 **Mẹo đã dùng**: thay vì sửa RAGFlow, **đổi NodePort bên vMLP cho khớp** —
> nhanh hơn và ít rủi ro hơn. Xem 6.1.

### 5.6 Đổi NodePort của MinIO
Trên **vmlp-08** (`app`):
```
kubectl -n ragflow patch svc ragflow-minio --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":9000}]'
kubectl -n ragflow get svc ragflow-minio
```
> ⚠️ **Dải NodePort hợp lệ của cụm vMLP là `8000–10000`**, KHÔNG phải mặc định
> 30000–32767. Đặt ngoài dải ⟹ API server từ chối.

### 5.7 Dựng lại toàn bộ từ đầu (dữ liệu vẫn còn trên đĩa)
Trên **vmlp-08** (`app`):
```
kubectl apply -f /home/app/KienNV_DevOps/minio-secret.yaml
kubectl apply -f /home/app/KienNV_DevOps/minio-pv-pvc.yaml
kubectl apply -f /home/app/KienNV_DevOps/minio-sts.yaml
kubectl apply -f /home/app/KienNV_DevOps/minio-svc.yaml
```
> ✅ An toàn: PV để `Retain`, `hostPath.type: Directory` ⟹ xoá PVC/PV **không**
> xoá dữ liệu, và nếu path sai thì **báo lỗi ngay** thay vì tạo thư mục rỗng.

---

## 6. ⚠️ CÁC BẪY ĐÃ GẶP — đọc trước khi sửa gì

### 6.1 🔴 RAGFlow gọi port 9000, không phải port mình đặt

**Triệu chứng**: RAGFlow log lặp vô hạn
```
MinIO health check: HTTPConnectionPool(host='10.208.137.43', port=9000):
Connection refused
```
pod RAGFlow `Running` nhưng `0/1`, startup probe fail `connect: connection refused` tới `:9380`.

**Nguyên nhân**: RAGFlow đọc `service_conf.yaml` (ConfigMap), **không** đọc `MINIO_PORT`
của secret. Vá `MINIO_PORT` trong secret **không có tác dụng**.

**Cách sửa đã dùng** (nhanh nhất, 1 lệnh): đổi NodePort bên vMLP về **9000** —
xem 5.6. Ban đầu đặt `9900`, phải đổi lại.

### 6.2 🔴 NodePort của vMLP chỉ nhận 8000–10000
```
The Service "ragflow-minio" is invalid: spec.ports[0].nodePort:
Invalid value: 30900: provided port is not in the valid range.
The range of valid ports is 8000-10000
```
Cụm vMLP sửa `--service-node-port-range`. **Nhớ khi tạo Service mới bất kỳ.**

### 6.3 🔴 Image thiếu prefix registry ⟹ ImagePullBackOff vĩnh viễn
Image đang chạy là **`docker.io/minio/minio:...`**. Prefix `docker.io` khiến kubelet
đi hỏi Docker Hub — trong airgap là **DNS timeout**. An toàn được nhờ **2 điều kiện**:
1. Image đã import vào **namespace `k8s.io`** của containerd
2. `imagePullPolicy: IfNotPresent`

⚠️ **Sai một trong hai là pod chết.** Đây chính là lỗi đã giết MinIO bên vRP.

Import lại image (nếu cần), trên **vmlp-09** (`root`):
```
ctr -n k8s.io images ls | grep -i minio
ctr -n k8s.io images import /tmp/ragflow-images.tar
```
> ⭐ **`-n k8s.io` BẮT BUỘC.** Thiếu ⟹ image vào namespace `default`,
> `ctr images ls` vẫn thấy nhưng **kubelet KHÔNG thấy** ⟹ tưởng xong mà vô ích.

### 6.4 🔴 Redis của RAGFlow ghim trên vrp-07 — cùng node từng cạn inode
`redis-data-ragflow-redis-0` → PV `pv-ragflow-redis` → **hostPath trên vrp-07**.
Node 07 bị taint `disk-pressure` ⟹ Redis `Pending` ⟹ **RAGFlow không lên được**.

Triệu chứng:
```
0/8 nodes are available: 1 node(s) had taint {node.kubernetes.io/disk-pressure}
```
Đã tự khỏi sau khi xoá `/data/ragflow/minio` thu hồi inode. **Nhưng gốc rễ còn đó**:
Redis vẫn phụ thuộc dung lượng node 07.

### 6.5 ⚠️ Copy file giữa 2 cụm — luôn ĐẨY từ vRP
```
✅ ĐÚNG:  (chạy trên vRP)   scp <file> vt_admin@10.208.137.43:/tmp/
❌ SAI:   (chạy trên vMLP)  scp vt_admin@10.208.137.54:<file> /tmp/
                            → ssh: connect to host 10.208.137.54 port 22:
                              Connection timed out
```

### 6.6 ⚠️ `-a` của rsync cần root BÊN NHẬN
`-a` = `-rlptgoD`, trong đó `-o -g` (giữ owner/group) **cần quyền root ở đích**.
vMLP không cho ssh root ⟹ phải dùng **`-rlptDHAX`** (bỏ `-o -g`) rồi
`chown -R root:root` sau.

---

## 7. 🔴 VIỆC CÒN NỢ — cần làm sớm

| # | Việc | Vì sao gấp |
|---|---|---|
| **0** | 🔴 **Sửa `minio-svc.yaml` trên vmlp-08: `9900` → `9000`** | **Bom hẹn giờ.** NodePort hiện tại được đặt bằng `kubectl patch`, **file YAML chưa sửa**. Ai đó `kubectl apply -f minio-svc.yaml` (kể cả chính mình, lúc dựng lại) ⟹ NodePort quay về `9900` ⟹ **RAGFlow đứt kết nối ngay**, và triệu chứng sẽ rất khó đoán. Lệnh: `sed -i 's/nodePort: 9900/nodePort: 9000/' /home/app/KienNV_DevOps/minio-svc.yaml && grep nodePort /home/app/KienNV_DevOps/minio-svc.yaml` |
| **1** | **Alert `df -i` cho vmlp-09** | 🔴 Chưa có. Inode đã **47%**, và MinIO vẫn ăn ~3 inode/object ⟹ **sẽ bò lên lại**. `/home` nằm trên `/` ⟹ cạn là chết cả node. Đây **đúng kịch bản đã giết vrp-07** |
| **2** | **Backup dữ liệu MinIO** | 🔴 Sau khi xoá nguồn, `/home/app/app_data/ragflow/minio` là **BẢN DUY NHẤT**. Không có snapshot, không có bản sao |
| **3** | Giảm số object của MinIO | 🟠 Nguyên nhân gốc **chưa được sửa**. Migrate chỉ **mua thêm thời gian** (bảng inode 13,1M so với 6,55M). Hướng: gộp file nhỏ / đổi chiến lược lưu / filesystem inode động (XFS) |
| **4** | Đồng bộ manifest git ↔ thực tế | 🟡 `manifests-vmlp/minio-vmlp.yaml` còn ghi `nodePort: 30900/30901`, thực tế là `9000/9901` |
| **5** | Trả quyền `/home/app*` về `0700` | 🟡 Đã `chmod o+x` 3 thư mục cha để rsync đi qua (chỉ cho *đi xuyên*, không cho *liệt kê*). Cân nhắc trả lại nếu chính sách yêu cầu |
| **6** | Dọn `sts/ragflow-minio` cũ ở vRP | 🟡 Đang `replicas=0`. Còn PV/PVC `pv-ragflow-minio` treo ở đó |
| **7** | Rotate token RAGFlow + mật khẩu ES | 🟡 Đã lọt git history từ trước (xem `CLAUDE.md`) |

---

## 8. 📌 SỐ LIỆU THAM CHIẾU (đo 26/08/2026)

```
DỮ LIỆU
├─ Số mục            5.664.048   (2.831.983 file + 2.832.065 thư mục — tỉ lệ ~1:1)
├─ Dung lượng đĩa    37 G        (du -sh)
├─ Dung lượng logic  20,3 GiB    (21.845.814.562 bytes)
└─ Chênh ~17G        = slack space: block 4K làm tròn + 2,83M thư mục × 4K

⭐ Mỗi object MinIO ≈ 3 inode (thư mục + xl.meta + part.1)
   ⟹ chi phí dồn vào METADATA của filesystem, KHÔNG vào dung lượng
   ⟹ đây là nguyên nhân gốc của cả 3 hiện tượng:
      cạn inode · copy chậm · du ≠ kích thước logic

THỜI GIAN (tham chiếu nếu phải làm lại)
├─ rsync 5,66 triệu file    40 phút 10 giây  (8,64 MB/s — metadata-bound)
├─ scp 1 file 838 MB        5 giây          (153 MB/s — bandwidth-bound)
│  ⟹ CHÊNH GẦN 18 LẦN trên cùng đường dây
├─ MinIO khởi động lần đầu  ~30 giây
└─ dry-run rsync            ~13 phút

INODE
├─ vrp-07 (nguồn)  tổng 6.553.600 · trước xoá IUse 95% · sau xoá ~61% và đang giảm
└─ vmlp-09 (đích)  tổng 13.107.200 · trước 4% (IFree 12.629.445)
                                     sau  47% (IFree 6.962.957)
```

---

## 9. 🔁 NẾU PHẢI MIGRATE LẠI (tóm tắt quy trình)

```
1. Tạo thư mục đích + mở quyền           (vmlp-09 root)
   mkdir -p <path> && chown vt_admin:vt_admin <path>
   chmod o+x <các thư mục cha>            ← nếu không sẽ Permission denied
   ⚠️ debug quyền bằng `namei -l <path>`, KHÔNG phải `ls -ld`

2. Dry-run rsync                          (nguồn, root)
   rsync -rlptDHAX --numeric-ids --dry-run --stats <src>/ vt_admin@<dst-ip>:<path>/
   ⚠️ đối chiếu "Number of files" TRƯỚC khi copy thật

3. rsync thật + theo dõi
   rsync -rlptDHAX --numeric-ids --info=progress2 --partial <src>/ vt_admin@<ip>:<path>/
   ⚠️ theo dõi bằng `xfr#`, KHÔNG dùng `%` (rsync 3.x incremental list → % nhảy loạn)
   ⚠️ vrp-07 KHÔNG có screen/tmux. Đứt thì chạy lại — rsync idempotent

4. chown -R root:root <path>              (đích, root) — MinIO chạy uid 0

5. Đối chiếu 2 bên
   du -sh <path>
   find <path> -xdev -printf "." | wc -c   ← phải BẰNG NHAU

6. Import image
   (từ nguồn) scp ragflow-images.tar vt_admin@<ip>:/tmp/
   (ở đích)   ctr -n k8s.io images import /tmp/ragflow-images.tar

7. Apply manifest: secret → pv/pvc → sts → svc

8. Verify: endpoints không rỗng · curl healthz=200 · curl / =403

9. Scale MinIO cũ về 0, ĐỔI TÊN thư mục nguồn (mv) trước, xoá sau
   ⚠️ CHỈ xoá khi đã có đủ 3 bằng chứng: sts cũ 0/0 · find 2 bên khớp · MinIO mới chạy
```

---

*Cập nhật lần cuối: 26/08/2026 — sau khi RAGFlow kết nối thành công MinIO trên vMLP.*
