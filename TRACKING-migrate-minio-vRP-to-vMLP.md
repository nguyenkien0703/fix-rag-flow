# TRACKING — Migrate MinIO từ cụm vRP sang cụm vMLP

> Phiên bắt đầu: **26/08/2026**
> Issue cha: `TRACKING-minio-can-inode.md` (Issue #1 + #4 + #5)
> Trạng thái: 🔶 **ĐANG KHẢO SÁT** — chưa thao tác ghi trên cụm nào
> Phương án đã chốt: **B — copy offline** (Kiên chốt 26/08)

---

## 0. Quy ước phân biệt 2 cụm (Kiên chốt 26/08)

Từ phiên này trở đi **bắt buộc** dùng prefix khi nhắc tên node, tránh nhầm cụm.

| Prefix | Cụm | Node gõ `kubectl` | Ghi chú |
|---|---|---|---|
| `vrp-` | vRP (nguồn) | **vrp-04** = `10.208.137.51` | ⚠️ cũng là node chạy n8n bằng `nerdctl` |
| `vmlp-` | vMLP (đích) | **vmlp-08** = `10.208.137.42` | |

Kiên **ssh trực tiếp được vào từng node của cả 2 cụm**.

---

## 1. Mục tiêu & phạm vi

| Hạng mục | Quyết định |
|---|---|
| Cái gì di chuyển | **CHỈ MinIO** (workload + data) |
| Cái gì ở lại vRP | RAGFlow, MySQL, Redis, ES — **không đụng** |
| Namespace đích | `ragflow` trên vMLP (tạo mới, không xung đột — ns là object cục bộ từng cụm) |
| Ổ đĩa | ❌ **KHÔNG được cấp block device mới** — Kiên chốt: *"có gì dùng nấy"* ⟹ chạy trên `/dev/vda1` sẵn có |
| Phương án copy | **B — copy offline** (chi tiết mục 5) |

### Hệ quả kiến trúc bắt buộc chấp nhận

RAGFlow ở vRP + MinIO ở vMLP ⟹ **cross-cluster**.
Service DNS `ragflow-minio.ragflow.svc.cluster.local` **sẽ không resolve được** từ vRP nữa.
⟹ Phải đổi endpoint MinIO trong config RAGFlow sang dạng **`IP:NodePort`**.
MinIO từ *in-cluster service* trở thành *external dependency*: mất DNS nội cụm,
mất NetworkPolicy chung, mọi lỗi mạng giữa 2 cụm sẽ biểu hiện thành RAGFlow 0/1.
Đổi lại: cách ly hoàn toàn khỏi disk-pressure của vRP.

---

## 2. Cụm vMLP — topology đo được (26/08)

Nguồn: `kubectl get nodes -o wide` trên vmlp-08.
10 node, dải `10.208.137.35–.44`. **Cùng CentOS 7 / k8s v1.23.2 / containerd 1.5.8 như vRP.**

⭐ Hai cụm **cùng dải mạng** `10.208.137.0/24` (vRP `.48–.55`) ⟹ thông nhau L2, không cần NAT.

| Node | IP | Role | Ghi chú |
|---|---|---|---|
| vmlp-kubeengine01/02/03 | .35 / .36 / .37 | control-plane, master | |
| vmlp-kubeengine04 | .38 | worker | ⛔ **SchedulingDisabled** (cordon) — loại khỏi mọi phương án |
| vmlp-kubeengine05 | .39 | worker | |
| vmlp-kubeengine06 | .40 | worker | |
| vmlp-kubeengine07 | .41 | worker | |
| **vmlp-kubeengine08** | **.42** | worker | **jump box `kubectl`** |
| vmlp-kubeengine09 | .43 | worker | |
| vmlp-kubeengine10 | .44 | worker | |

### Tài nguyên CPU/RAM (từ `kubectl describe node`)

Không node nào có taint (`Taints: <none>` toàn bộ 05, 06, 07, 09, 10).

| Node | CPU request | CPU limit | Mem request | Mem limit |
|---|---|---|---|---|
| vmlp-05 | 880m (5%) | 2200m (13%) | 872520Ki (2%) | 1762632960 (5%) |
| vmlp-06 | 12850m (**80%**) | 12850m (**80%**) | 13597732Ki (41%) | 14303454464 (43%) |
| vmlp-07 | 1800m (11%) | 2325m (14%) | 1989668Ki (6%) | 2915919104 (8%) |
| vmlp-09 | 2050m (12%) | 7500m (47%) | 4553764Ki (14%) | 14995514624 (45%) |
| vmlp-10 | 11450m (**72%**) | 11600m (**72%**) | 11951140Ki (36%) | 12713813248 (38%) |

⟹ **vmlp-06 và vmlp-10 gần kín CPU**, tránh đặt workload nặng vào.

### Namespace đang có trên vMLP

`app-test`, `argocd`, `banking-academy-97`, `bkhn-organization-99`, `cert-manager`,
`data-tools`, `default`, `fluentd`, `ingress-controller`, `kserve`, `kube-*`,
`langfuse`, `litellm-space`, `local-path-storage`, **`minio-operator`**, `mlflow`,
`mlflow-artifact-storage`, `monitoring`, `organization-2004-95`, `resource-monitor`,
`storage`, `vcc`, `vcc-x`, `vic`, `viettel-telecom`, `vmlp`, `vmlp-operator`,
`vmlp-operator-db`, `zeppelin-test`.

⟹ **chưa có ns `ragflow`** — tạo mới, không xung đột.

### StorageClass trên vMLP

| Name | Provisioner | Reclaim | BindingMode | Expansion |
|---|---|---|---|---|
| `local-path` (default) | `rancher.io/local-path` | Delete | WaitForFirstConsumer | false |
| `local-storage` | `kubernetes.io/no-provisioner` | Delete | WaitForFirstConsumer | false |
| `nfs-delete` | `cluster.local/nfs-storage-delete-nfs-subdir-external-provisioner` | Delete | Immediate | true |
| `nfs-retain` | `cluster.local/nfs-storage-retain-nfs-subdir-external-provisioner` | Retain | Immediate | true |

⚠️ Các PV `minio-pv-*` khai storageClass **`host-storage`** — **KHÔNG nằm trong `get sc`**
⟹ đây là **PV tạo tay**, không có provisioner. Tenant mới cũng sẽ phải tạo PV thủ công.
*(cần xác nhận ở đợt khảo sát 2)*

---

## 3. ⭐ Ba phát hiện làm thay đổi phương án

### Phát hiện 1 — vMLP ĐÃ CÓ SẴN MinIO Operator

`kubectl get ns` có `minio-operator` (**2y259d**), và `kubectl get pv` cho thấy
**~40 PV `minio-pv-*` 20Gi**, storageClass `host-storage`, bound vào các StatefulSet dạng:

```
viettel-telecom/data{0..3}-viettel-telecom-viettel-telecom-pool-0-{0..3}   16 PV × 20Gi, 2y227d
vcc/data{0..3}-viettel-construction-viettel-construction-pool-0-{0..3}     16 PV × 20Gi, 2y70d
vic/data{0..3}-viettel-information-viettel-information-pool-0-0            4 PV × 5Gi,  490d
```

Ngoài ra ns `minio-operator` có service `console` **NodePort** `9090:8080/TCP, 9443:8682/TCP`.

Đây là **MinIO Tenant chạy erasure coding 4 disk/pool, đã vận hành 2 năm**.

⭐ **Nghĩa là Issue #4 của sếp** (*"dài hạn phải cài lại minio theo hướng cluster để chia nhỏ dữ liệu"*)
**không cần dựng từ đầu** — vMLP đã có Operator, chỉ cần **tạo thêm một Tenant `ragflow`**.
Đây là đường đúng, và nó **xử lý luôn Issue #4 mà không phải migrate hai lần**.

### Phát hiện 2 — dung lượng thật chỉ **37G**, không phải 61G

Chạy trên vrp-kubeengine07 (`.54`, root):

```
du -sh minio/   →   37G
```

Và gần như **toàn bộ nằm trong MỘT bucket duy nhất**:

```
37G     /data/ragflow/minio/73932b965e5e11f192725fd51894c519   ← ~100% dữ liệu thực
34M     /data/ragflow/minio/a2a98a4a65fe11f19513b68e586af3e
22M     /data/ragflow/minio/aa8bdff27c2d11f98e53d33b00035ba
7.9M    /data/ragflow/minio/1f5b090e5f3011f1a22d4f88f6ea65d6
7.3M    /data/ragflow/minio/9faa56fe7c2d11f98e53d33b00035ba
1.9M    /data/ragflow/minio/b651020e7c2d11f98e53d33b00035ba
836K    /data/ragflow/minio/8b1c260e75e811f198e53d33b00035ba-downloads
(còn lại đều < 700K)
```

⭐ Con số **61G** trong tracking cũ là **suy từ `df -h` toàn ổ — SAI**.
Số đúng là **37G**. ⟹ node đích rộng cửa hơn nhiều, thời gian copy ngắn hơn nhiều.

<details>
<summary>Giải nghĩa lệnh đo dung lượng (bấm để mở)</summary>

```
du -sh /data/ragflow/minio
│ ├─ -s  summarize: chỉ in TỔNG của thư mục, không liệt kê từng thư mục con
│ └─ -h  human-readable: đổi ra G/M thay vì block thô
│
du -sh /data/ragflow/minio/* | sort -h | tail -20
  ├─ /*        bung ra từng thư mục con ⟹ mỗi bucket 1 dòng
  ├─ sort -h   -h = human-numeric-sort: hiểu hậu tố K/M/G để sắp đúng thứ tự.
  │            ⚠️ Dùng `sort -n` ở đây là SAI — nó đọc "9.9M" và "37G"
  │            thành 9.9 và 37 rồi so sánh, bỏ qua đơn vị
  └─ tail -20  lấy 20 dòng cuối = 20 bucket TO NHẤT (vì đã sort tăng dần)

⚠️ Lệnh này KHÔNG có -x. Ở đây chấp nhận được vì /data/ragflow/minio
   là thư mục thường trên /dev/vda1, không phải mount point PV/NFS.
   Trong /var/lib/kubelet thì BẮT BUỘC phải có -x (bài học phiên trước).
```
</details>

### Phát hiện 3 — inode trên vMLP: node nào cũng dư, nhưng có node đã ăn nửa quỹ

Đọc từng `df -i`. **Mọi node đều `/dev/vda1` ext4, 13.107.200 inode, đĩa 197G**
— tức **cùng mật độ 1 inode / 15,8KB y hệt vRP**.

| Node | IP | Disk dùng | IUsed | IFree | IUse% | Ghi chú |
|---|---|---|---|---|---|---|
| vmlp-05 | .39 | 36G/197G (19%) | 5.816.680 | 7.290.520 | **45%** | đã ăn nhiều |
| vmlp-06 | .40 | 95G/197G (51%) | 5.196.020 | 7.911.180 | **40%** | CPU 80% — bận |
| vmlp-07 | .41 | 97G/197G (52%) | 1.405.955 | 11.701.245 | **11%** | |
| vmlp-08 | .42 | 125G/197G (66%) | 1.085.380 | 12.021.820 | **9%** | jump box |
| vmlp-09 | .43 | 51G/197G (27%) | 455.408 | 12.651.792 | **4%** | ⭐ thoáng nhất |
| vmlp-10 | .44 | 82G/197G (44%) | 1.212.747 | 11.894.453 | **10%** | CPU 72% |

⚠️ **Không node nào có `/data`, không có ổ rời** — `lsblk -f` chỉ thấy
`vda → vda1 ext4 (UUID 4b443dbb-9e19-4bca-8e27-333646affa05) /` trên **mọi** node.

### ⭐ Insight rút ra từ 3 phát hiện

- **vMLP dùng đúng cùng mật độ inode với vRP** (13,1M inode / 197G = 1 inode/15,8KB).
  Nếu chỉ **bê nguyên MinIO single-node hostPath sang**, MinIO **5,66M inode**
  sẽ chiếm **43% quỹ của một node** ngay ngày đầu — cộng với 5,8M inode node đó đã dùng
  (vmlp-05) là **chạm ngưỡng luôn**. Đây là **bằng chứng số học** cho thấy
  *"migrate 1-1"* là phương án tệ.
- Ngược lại, **chia 4 disk qua MinIO Tenant** ⟹ mỗi node chỉ gánh **~1,4M inode**.
  Đó là khác biệt giữa *"mua thêm 6 tháng"* và *"xử lý dứt điểm"*.
- `minio-pv-*` bound theo pattern `dataN-...-pool-0-M`: `data0..data3` × `pool-0-0..0-3`
  = **4 disk × 4 server**. Đây chính là **erasure set EC:4** — mất 1 node vẫn đọc ghi được,
  thứ mà hostPath hiện tại **hoàn toàn không có**.

<details>
<summary>Giải nghĩa lệnh khảo sát node (bấm để mở)</summary>

```
hostname; df -h; df -i; lsblk -f; ls /data 2>/dev/null
```

```
hostname                    → in tên node, để CHẮC CHẮN không đọc nhầm phiên ssh
│
df -h                       → dung lượng theo BYTE
│ └─ -h  human-readable: đổi byte thô sang G/M cho dễ đọc
│
df -i                       → dung lượng theo INODE (trục thứ 2 của disk-pressure)
│ └─ -i  inodes: đổi cột từ block sang inode. KHÔNG có -h ⟹ số nguyên đầy đủ,
│        dễ đối chiếu chính xác hơn dạng rút gọn "6.5M"
│
lsblk -f                    → liệt kê block device dạng cây + filesystem
│ └─ -f  fs: thêm cột FSTYPE/LABEL/UUID/MOUNTPOINT.
│        Dùng để trả lời "có ổ rời nào không" và "đang là ext4 hay xfs"
│
ls /data 2>/dev/null        → xem có sẵn thư mục /data không (vRP dùng /data/ragflow)
  └─ 2>/dev/null  nuốt stderr: nếu không tồn tại thì im lặng, không rác output
```

⚠️ Vì sao phải chạy **cả** `df -h` lẫn `df -i`: kubelet đánh giá disk-pressure trên
**hai trục độc lập** — `nodefs.available` (byte) và `nodefs.inodesFree` (inode).
Chỉ cần **một** trục vượt ngưỡng là bật taint. `df -h` xanh **không** loại trừ disk-pressure.
</details>

<details>
<summary>Giải nghĩa lệnh khảo sát cụm trên vmlp-08 (bấm để mở)</summary>

```
kubectl get sc
kubectl get pv
kubectl get svc -A | grep -iE 'LoadBalancer|NodePort'
kubectl get ns
kubectl get pod -A -o wide | grep -vE 'kube-system|Running.*1/1' | head -40
kubectl describe node vmlp-kubeengine05 ... | grep -E '^Name:|Taints:|  cpu |  memory |  pods '
```

```
kubectl get sc              → StorageClass: cách cụm cấp phát ổ. Trả lời "có Longhorn/Ceph không"
kubectl get pv              → PersistentVolume toàn cụm. Chính lệnh này lộ ra ~40 PV minio-pv-*
│
kubectl get svc -A          → Service mọi namespace
│ ├─ -A   all-namespaces: không giới hạn 1 ns
│ └─ grep -iE 'LoadBalancer|NodePort'
│     ├─ -i  ignore-case: khớp cả 'nodeport' lẫn 'NodePort'
│     └─ -E  extended regex: cho phép dùng | làm "hoặc"
│     ⟹ lọc ra service ĐÃ expose ra ngoài cụm — cần cho bài toán cross-cluster
│
kubectl get ns              → liệt kê namespace. Lộ ra ns 'minio-operator'
│
kubectl get pod -A -o wide  → pod mọi ns
│ ├─ -o wide  thêm cột IP + NODE: biết pod nằm node nào
│ └─ grep -vE 'kube-system|Running.*1/1'
│     ├─ -v  invert: LOẠI BỎ dòng khớp, giữ lại phần còn lại
│     └─ ⟹ giấu pod hệ thống + pod đang khoẻ, chỉ còn pod CÓ VẤN ĐỀ
│ └─ head -40  cắt 40 dòng đầu, tránh tràn màn hình
│
kubectl describe node <a> <b> ...   → mô tả chi tiết, nhận NHIỀU tên node một lượt
  └─ grep -E '^Name:|Taints:|  cpu |  memory |  pods '
      ├─ ^Name:      dấu ^ neo đầu dòng ⟹ chỉ lấy dòng tên node,
      │              không dính 'Name:' thụt lề trong phần con
      └─ '  cpu '    CỐ Ý có 2 space đầu + 1 space cuối ⟹ chỉ khớp dòng
                     trong bảng Allocated resources, không khớp 'cpu:' ở Capacity
```
</details>

### Ghi chú phụ — pod đang lỗi sẵn trên vMLP (không liên quan migrate, nhưng cần biết)

```
app-test/vmlp-fe-f54c5bdf9-khsmh              0/1  ImagePullBackOff  543d
argocd/argocd-redis-6cc6f55c7b-ks7sm          0/1  ImagePullBackOff   11d
default/litellm-migrations-84977              0/1  ImagePullBackOff  106d
default/litellm-space-migrations-qkx4c        0/1  ImagePullBackOff  106d
ingress-controller/nginx-...-blwb2            0/1  ImagePullBackOff    8d
```

⚠️ `ImagePullBackOff` trên vMLP ⟹ **cụm này cũng airgap / registry hạn chế**.
Trước khi deploy Tenant phải **xác nhận image MinIO đã có sẵn trên node đích**,
nếu không sẽ dính đúng lỗi này.

---

## 4. Cấu hình MinIO hiện tại trên vRP (nguồn)

Đọc từ `kubectl -n ragflow get sts ragflow-minio -o yaml` trên vrp-04.

| Thuộc tính | Giá trị |
|---|---|
| Kind | StatefulSet, `replicas: 1`, `serviceName: ragflow-minio-headless` |
| Image | `minio/minio:RELEASE.2025-06-13T11-33-47Z` |
| Args | `server`, `--console-address=:9001`, `/data` |
| Ports | `9000` (s3), `9001` (console) |
| Env | `envFrom.secretRef: ragflow-env-config` |
| nodeSelector | `ragflow-target: "true"` ← **cơ chế pin node** |
| Volume | PVC `ragflow-minio` → mount `/data` |
| resources | `{}` — **không đặt request/limit** |
| Chart | `ragflow-0.1.1`, release `ragflow`, tạo `2026-05-15T02:49:03Z`, generation 3 |
| Status | `availableReplicas: 0`, `replicas: 1` ⟹ **đang Pending, không chạy** |

PV tương ứng (`local-pv.yaml` trên vrp-04, thư mục `ragflow-0.24.0`):

```yaml
kind: PersistentVolume
metadata: { name: pv-ragflow-minio }
spec:
  storageClassName: "local-minio"
  capacity: { storage: 5Gi }          # ⚠️ SỐ ẢO — thực tế chứa 37G
  accessModes: [ ReadWriteOnce ]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /data/ragflow/minio }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: ragflow-target
          operator: In
          values: [ "true" ]
```

⭐ `capacity: 5Gi` với hostPath **chỉ là con số khai báo**, không cấp phát và không giới hạn gì —
đó là lý do thư mục phình tới 37G mà k8s không hề báo. (Đã ghi ở Issue #4 tracking cũ.)

*(File `local-pv.yaml` cùng khai `pv-ragflow-mysql` → `/data/ragflow/mysql`
và `pv-ragflow-redis` — cùng cơ chế `nodeAffinity: ragflow-target`.)*

---

## 5. ⭐ Phương án copy — đã chốt B

### Điểm chặn kỹ thuật lớn nhất

**Single-node MinIO và Tenant erasure-coded có layout đĩa KHÁC NHAU HOÀN TOÀN.**
Không thể `rsync` thư mục `/data/ragflow/minio` sang PV của Tenant rồi mong nó đọc được —
Tenant chia object thành các shard erasure + `xl.meta` phân tán trên 4 disk.

⟹ **Bắt buộc copy ở tầng S3** (`mc mirror`), tức MinIO nguồn phải **sống lại để đọc**.
Mà nó đang `Pending` vì node vrp-07 dính taint disk-pressure.

### Hai đường đã cân nhắc

| | A. Gỡ tạm để đọc | **B. Copy offline** ✅ |
|---|---|---|
| Cách | Cordon/tolerate cho `ragflow-minio-0` chạy lại **read-only** trên vrp-07 vừa đủ để `mc mirror` sang vMLP | `rsync` 37G thư mục thô sang một node vMLP, dựng **MinIO single-node tạm** đọc thư mục đó, rồi `mc mirror` từ nó vào Tenant |
| Rủi ro | vrp-07 còn **0,33M inode**; MinIO chạy có thể **ghi thêm → cạn hẳn**, nguy cơ hỏng object | **Không đụng gì vào vrp-07 khi đang chạy** |
| Downtime | Ngắn hơn | Dài hơn (copy 2 chặng) |

**Kiên chốt: B.** Lý do: luật cứng trong `CLAUDE.md` + tình trạng 95% inode nói rằng
**đừng để vrp-07 ghi thêm bất cứ gì**. Chậm hơn nhưng **không có đường mất dữ liệu**.

### Sơ đồ luồng B

```
vrp-07 (.54)                    vmlp-XX (.4?)                  vMLP Tenant
/data/ragflow/minio  ──rsync──> /data/minio-import  ──mc mirror──> tenant ragflow
   37G, chỉ ĐỌC                 MinIO single-node tạm            erasure EC:4
   pod vẫn Pending              (đọc layout single-node)          4 disk × 4 node
```

⚠️ **Chặng 1 (`rsync`) chỉ ĐỌC trên vrp-07** — không ghi, không xoá, không start pod.
⚠️ Node trung chuyển cần **≥ 37G trống + ~5,7M inode trống** ⟹ theo bảng mục 3,
ứng viên là **vmlp-09** (`.43`: 139G trống, 12,65M inode trống) — chờ xác nhận ở đợt khảo sát 2.

⚠️ **Chưa chốt**: sau khi chạy Tenant thì node trung chuyển giữ thêm 37G + 5,7M inode
của bản copy trung gian ⟹ **phải xoá sau khi verify xong**, nếu không lại thành
dữ liệu mồ côi đúng như bài học phiên trước.

---

## 6. Trạng thái khảo sát — còn thiếu gì

### ✅ Đã có

- [x] Topology vMLP + role từng node
- [x] CPU/RAM allocated từng worker
- [x] `df -h`, `df -i`, `lsblk -f` cả 6 worker vMLP
- [x] Dung lượng thật của MinIO: **37G**, tập trung 1 bucket
- [x] StatefulSet + PV của MinIO trên vRP
- [x] Xác nhận vMLP có sẵn MinIO Operator + ~40 PV minio
- [x] Danh sách StorageClass + namespace trên vMLP
- [x] Chốt phương án copy: **B**
- [x] Chốt: **không có ổ rời**, dùng `/dev/vda1`

### ❓ Còn thiếu (đợt khảo sát 2)

- [ ] Tenant hiện có trên vMLP: spec ra sao, EC bao nhiêu, đặt trên node nào
- [ ] `host-storage` là PV tạo tay hay có provisioner ẩn
- [ ] PV `minio-pv-*` trỏ vào **đường dẫn nào** trên node → biết chỗ đặt PV mới
- [ ] Node label liên quan minio/storage
- [ ] Endpoint + credential MinIO mà RAGFlow đang dùng (trong `ragflow-env-config`)
- [ ] Service MinIO trên vRP đang là ClusterIP hay NodePort
- [ ] Image MinIO đã có sẵn trên node vMLP chưa (vì cụm dính ImagePullBackOff)
- [ ] ⭐ **Kiểm mạng 2 chiều `.51` ↔ `.42`** — nếu chặn thì cả phương án đổ

---

## 7. Lệnh cần chạy — ĐỢT KHẢO SÁT 2

### 7.1 ⭐ Kiểm mạng 2 chiều — **CHẠY TRƯỚC TIÊN, chặn là đổ cả phương án**

Từ **vrp-04** (`10.208.137.51`, user `app`):
```
ping -c2 10.208.137.42
curl -sv --max-time 5 http://10.208.137.42:9000/minio/health/live 2>&1 | tail -5
```

Từ **vmlp-08** (`10.208.137.42`, user `app`):
```
ping -c2 10.208.137.54
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
ping -c2 <ip>
│ └─ -c2  count 2: gửi ĐÚNG 2 gói rồi thoát.
│         Không có -c thì ping chạy vô tận, phải Ctrl-C
│   ⟹ chỉ trả lời "2 máy có thấy nhau ở tầng IP không"
│
curl -sv --max-time 5 http://10.208.137.42:9000/minio/health/live 2>&1 | tail -5
  ├─ -s          silent: tắt thanh tiến trình, tránh rác output
  ├─ -v          verbose: NGƯỢC LẠI, bật log chi tiết bắt tay TCP/TLS.
  │              ⚠️ -s và -v đi CÙNG NHAU là cố ý: tắt progress bar
  │              nhưng vẫn giữ log kết nối — đây mới là thứ cần đọc
  ├─ --max-time 5  trần TỔNG thời gian 5 giây. Không có nó, nếu firewall
  │                DROP (không REJECT) thì curl treo rất lâu
  ├─ 2>&1        gộp stderr vào stdout — log của -v đi ra STDERR,
  │              không gộp thì pipe sang tail sẽ mất sạch
  └─ tail -5     lấy 5 dòng cuối = phần kết luận

  ⚠️ Đường /minio/health/live có thể trả 404 vì chưa có MinIO nghe cổng 9000
     trên .42 — KHÔNG SAO. Cái cần đọc là dòng kết nối:
       Connected to ...      ⟹ mạng THÔNG, chỉ là chưa có service
       Connection refused    ⟹ mạng THÔNG, cổng đóng (vẫn ổn, sẽ mở NodePort sau)
       Connection timed out  ⟹ ⛔ FIREWALL CHẶN — phương án phải xem lại
```
</details>

### 7.2 Trên **vmlp-08** (`10.208.137.42`, user `app`)

```
kubectl get tenant -A
kubectl -n minio-operator get pod -o wide
kubectl get sc host-storage -o yaml
kubectl get pv minio-pv-1 -o yaml
kubectl -n viettel-telecom get sts -o wide
kubectl get nodes --show-labels | tr ',' '\n' | grep -iE 'minio|storage|node-role'
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
kubectl get tenant -A       → CRD của MinIO Operator. Cho biết đang có mấy Tenant,
│ └─ -A  all-namespaces      ns nào, trạng thái ra sao. Đây là "bản đồ" MinIO của vMLP
│
kubectl -n minio-operator get pod -o wide
│ ├─ -n <ns>   giới hạn 1 namespace
│ └─ -o wide   thêm cột IP/NODE ⟹ biết operator đang chạy node nào, có khoẻ không
│
kubectl get sc host-storage -o yaml
│ └─ -o yaml   in FULL spec dạng YAML thay vì bảng rút gọn.
│              Cần để biết provisioner là gì: có tự cấp PV không hay phải tạo tay.
│              ⚠️ Nếu lệnh báo NotFound ⟹ ĐÚNG NHƯ DỰ ĐOÁN: PV tạo tay,
│              storageClassName chỉ là NHÃN để ghép PV↔PVC, không có sc thật
│
kubectl get pv minio-pv-1 -o yaml
│              ⭐ QUAN TRỌNG NHẤT ĐỢT NÀY: lộ ra hostPath/local path thật
│              mà Tenant đang dùng ⟹ biết phải tạo thư mục ở đâu cho Tenant mới,
│              và nodeAffinity pin vào node nào
│
kubectl -n viettel-telecom get sts -o wide
│              xem StatefulSet của Tenant đang chạy: mấy replica, image gì
│              ⟹ bắt chước đúng layout + BIẾT TÊN IMAGE để kiểm tra airgap
│
kubectl get nodes --show-labels | tr ',' '\n' | grep -iE 'minio|storage|node-role'
  ├─ --show-labels  thêm cột LABELS (mặc định bị ẩn)
  ├─ tr ',' '\n'    tr = translate: đổi KÝ TỰ ',' thành xuống dòng.
  │                 Label in ra dính liền nhau bằng dấu phẩy, không xuống dòng
  │                 ⟹ không grep từng cái được. tr tách ra mỗi label 1 dòng
  └─ grep -iE 'minio|storage|node-role'
      ⟹ tìm xem Tenant được pin vào node bằng label nào
```
</details>

### 7.3 Trên **vrp-04** (`10.208.137.51`, user `app`)

```
kubectl -n ragflow get svc
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data}' | tr ',' '\n' | grep -i minio
kubectl -n ragflow get cm -o yaml | grep -iE 'minio|s3|endpoint' -A2 -B2
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
kubectl -n ragflow get svc  → xem MinIO đang expose kiểu gì.
│                             Nếu là ClusterIP ⟹ CHẮC CHẮN phải đổi sang NodePort
│                             thì RAGFlow ở vRP mới gọi sang vMLP được
│
kubectl -n ragflow get secret ragflow-env-config -o jsonpath='{.data}' | tr ',' '\n' | grep -i minio
│ ├─ -o jsonpath='{.data}'  trích ĐÚNG nhánh .data trong JSON trả về,
│ │                         thay vì in cả object khổng lồ
│ ├─ tr ',' '\n'            tách từng cặp key:value ra 1 dòng để grep được
│ └─ grep -i minio          -i ignore-case: bắt cả MINIO_ lẫn minio_
│    ⚠️ Giá trị in ra là BASE64, CHƯA decode. Mục đích chỉ là biết
│       CÓ NHỮNG KEY NÀO (MINIO_HOST, MINIO_USER, MINIO_PASSWORD...),
│       không cần biết giá trị.
│    ⛔ KHÔNG decode rồi paste vào repo — CLAUDE.md cấm commit secret,
│       và repo này ĐANG CÓ NỢ rotate token chưa trả
│
kubectl -n ragflow get cm -o yaml | grep -iE 'minio|s3|endpoint' -A2 -B2
  ├─ -A2  after: in thêm 2 dòng SAU dòng khớp
  └─ -B2  before: in thêm 2 dòng TRƯỚC dòng khớp
     ⟹ thấy được ngữ cảnh YAML xung quanh, vì bản thân dòng khớp
        thường chỉ là 'endpoint:' mà giá trị nằm dòng kế
```
</details>

---

## 8. Rủi ro đang theo dõi

| # | Rủi ro | Mức | Ghi chú |
|---|---|---|---|
| R1 | Firewall chặn giữa 2 cụm | 🔴 CAO | Chặn ⟹ đổ toàn bộ phương án. Kiểm ở **7.1 trước mọi thứ khác** |
| R2 | vMLP dùng **cùng mật độ inode** với vRP | 🟠 | Bê nguyên single-node sang ⟹ 5,66M inode = 43% quỹ 1 node ⟹ lặp lại sự cố. **Bắt buộc dùng Tenant chia 4 disk** |
| R3 | Không có ổ rời ⟹ MinIO dùng chung `/dev/vda1` với OS | 🟠 | Cạn inode sẽ kéo sập cả node, không chỉ MinIO. **Cần alert `df -i`** |
| R4 | Cross-cluster: MinIO thành external dependency | 🟠 | RAGFlow probe deep-check ⟹ mạng chập là pod 0/1 ngay |
| R5 | vrp-07 vẫn còn 0,33M inode và **RAGFlow vẫn đang ghi** | 🔴 CAO | Cân nhắc **tạm dừng upload tài liệu mới** trong lúc migrate |
| R6 | Bucket 37G nằm trong **1 bucket duy nhất** | 🟡 | `mc mirror` 1 bucket lớn — không có checkpoint tự nhiên, cần theo dõi tiến độ |
| R7 | vMLP cũng dính `ImagePullBackOff` ⟹ airgap | 🟠 | Phải xác nhận image MinIO có sẵn trên node đích **trước khi** apply Tenant |
| R8 | Bản copy trung gian 37G trên node trung chuyển | 🟡 | Phải **xoá sau khi verify**, nếu không thành dữ liệu mồ côi ăn inode |

---

## 9. Việc tiếp theo

- [ ] **Kiên chạy đợt khảo sát 2** (mục 7) — ưu tiên **7.1 kiểm mạng trước**
- [ ] Chốt node trung chuyển cho `rsync` (ứng viên: **vmlp-09** `.43`)
- [ ] Chốt 4 node đặt Tenant `ragflow` (tránh vmlp-06/10 vì CPU cao, tránh vmlp-04 vì cordon)
- [ ] Thiết kế Tenant: số pool, số disk, dung lượng mỗi PV, đường dẫn hostPath
- [ ] Xác nhận image MinIO có sẵn trên node đích (airgap)
- [ ] Lên kịch bản downtime + rollback
- [ ] Kế hoạch verify sau migrate (đối chiếu số object, checksum, test kết nối RAGFlow→MinIO)
- [ ] Sau khi verify xong: xoá `/data/ragflow/minio` trên vrp-07, **thu hồi 5,66M inode**
- [ ] Xoá bản copy trung gian trên node trung chuyển

---

## 10. Nhật ký phiên

| Thời điểm | Việc | Kết quả |
|---|---|---|
| 26/08 | Nhận ảnh topology vMLP | 10 node, .35–.44, vmlp-04 cordon |
| 26/08 | Chốt phạm vi | Chỉ MinIO đi, RAGFlow ở lại vRP |
| 26/08 | Khảo sát đợt 1 (sc/pv/svc/ns/pod/node + df từng node) | Ra 3 phát hiện mục 3 |
| 26/08 | Đọc sts + PV MinIO trên vRP | Xác nhận hostPath, capacity 5Gi là số ảo |
| 26/08 | `du -sh` trên vrp-07 | **37G**, không phải 61G — sửa lại số sai của tracking cũ |
| 26/08 | Kiên chốt phương án | **B — copy offline** |
| 26/08 | Kiên chốt ổ đĩa | **Không có ổ rời**, dùng `/dev/vda1` |
