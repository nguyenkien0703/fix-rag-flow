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
| Phương án copy | **B — copy offline**, nguồn chỉ ĐỌC (mục 5) |
| **Kiến trúc đích** | ✅ **SINGLE-NODE** — Kiên chốt 26/08. Bỏ MinIO tạm + `mc mirror`. **Chi tiết & luồng chốt: mục 5d** |
| Issue #4 (cluster hoá) | ⏸️ **Tách ra làm sau**, không gộp vào lần migrate này |
| Cứu RAGFlow sống lại | ❌ **Không làm** — Kiên chốt *"kệ nó, đã chết từ lâu"* |

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

## 5. Phương án copy — bàn A vs B *(⚠️ ĐÃ LỖI THỜI — xem 5d)*

> ⚠️ **ĐỌC 5d TRƯỚC.** Mục này ghi lại quá trình cân nhắc A vs B khi còn **giả định
> kiến trúc đích là Tenant erasure-coded**. Kiên đã chốt **single-node** (5d)
> ⟹ **không còn MinIO tạm, không còn `mc mirror`**. Giữ lại để tra cứu lý do,
> **đừng làm theo các bước trong mục này**.

### Điểm chặn kỹ thuật lớn nhất *(chỉ đúng khi đích là Tenant)*

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

## 5b. ⭐ KHẢO SÁT ĐỢT 2 — kết quả (26/08)

### 5b.1 ✅ R1 ĐÓNG — mạng 2 cụm THÔNG cả 2 chiều

Từ **vrp-04 (`.51`)** → vmlp-08 (`.42`):

```
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 0.309/0.727/1.146/0.419 ms

$ curl -sv --max-time 5 http://10.208.137.42:9000/minio/health/live 2>&1 | tail -5
< X-Content-Type-Options: nosniff
< X-Xss-Protection: 1; mode=block
< Date: Wed, 26 Aug 2026 06:28:55 GMT
<
* Connection #0 to host 10.208.137.42 left intact
```

Từ **vmlp-08 (`.42`)** → vrp-07 (`.54`):

```
2 packets transmitted, 2 received, 0% packet loss, time 1000ms
rtt min/avg/max/mdev = 0.492/0.611/0.731/0.122 ms
```

⭐ **Đọc kết quả curl**: trả về được **HTTP response header** (`X-Content-Type-Options`,
`Date`) và `Connection ... left intact` ⟹ **không chỉ thông IP mà bắt tay HTTP thành công**,
tức **đã có service nghe cổng 9000 sẵn trên vmlp-08**. Đây là kết quả tốt hơn kỳ vọng
(kỳ vọng ban đầu chỉ là `Connection refused` cũng đủ dùng).

⟹ **Rủi ro R1 (firewall chặn) — LOẠI BỎ.** Phương án B đi tiếp được.

---

### 5b.2 ⭐ Phát hiện 4 — Tenant dùng hostPath dưới `/home/app/app_data`, KHÔNG phải `/data`

`kubectl get sc host-storage -o yaml`:

```
Error from server (NotFound): storageclasses.storage.k8s.io "host-storage" not found
```

✅ **Đúng như dự đoán ở đợt 1**: `host-storage` **không tồn tại thật**.
Nó chỉ là **nhãn** để ghép PV ↔ PVC. Toàn bộ PV `minio-pv-*` là **PV tạo tay**.
⟹ Tenant `ragflow` mới cũng **phải tạo PV thủ công**, không có provisioner tự cấp.

`kubectl get pv minio-pv-1 -o yaml` (rút gọn):

```yaml
spec:
  accessModes: [ ReadWriteOnce ]
  capacity: { storage: 20Gi }
  claimRef:
    name: data1-viettel-telecom-viettel-telecom-pool-0-0
    namespace: viettel-telecom
  hostPath:
    path: /home/app/app_data/viettel-telecom/minio/data-1
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [ vmlp-kubeengine08 ]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: host-storage
  volumeMode: Filesystem
status: { phase: Bound }
```

Tạo từ `2024-01-11T11:10:33Z`.

**Quy ước đường dẫn đọc ra được**: `/home/app/app_data/<tên-tenant>/minio/data-<N>`
⟹ Tenant ragflow sẽ là `/home/app/app_data/ragflow/minio/data-{1..4}`.

⚠️ `type: DirectoryOrCreate` ⟹ kubelet **tự tạo thư mục nếu chưa có**. Tiện, nhưng
**gõ sai đường dẫn sẽ âm thầm tạo thư mục rỗng thay vì báo lỗi**. Phải `ls` xác nhận
trước khi apply, đừng tin vào việc "pod chạy được là đúng đường dẫn".

⚠️⚠️ **`/home/app/app_data` nằm trên `/dev/vda1`** — cùng ổ với OS, vì `lsblk` đã xác nhận
mọi node chỉ có 1 partition. ⟹ **Rủi ro R3 vẫn nguyên**: inode MinIO và inode OS chung quỹ.

### 🔴 SỬA LẠI KẾT LUẬN SAI CỦA ĐỢT 1

Ở đợt 1 tôi ghi: *"chia 4 disk qua Tenant ⟹ mỗi node chỉ gánh ~1,4M inode"* — **lý do SAI.**

Sự thật đọc từ `minio-pv-1`: PV `data-1` của `pool-0-0` nodeAffinity về **vmlp-kubeengine08**.
Tức `data1..data4` của **cùng một** `pool-0-0` đều nằm trên **CÙNG MỘT NODE**,
là **4 thư mục trên cùng `/dev/vda1`** — không phải 4 ổ vật lý.

| | Chia được | Không chia được |
|---|---|---|
| Erasure coding chia qua | **4 server** (`pool-0-0` … `pool-0-3`) | |
| 4 "disk" mỗi server | | chỉ là **4 thư mục cùng 1 ổ** |

⟹ **Con số ~1,4M inode/node vẫn ĐÚNG** (5,66M ÷ 4 server), nhưng:
- Chia được **4 lần**, không phải 16 lần.
- ⭐ **4 thư mục cùng ổ KHÔNG cho thêm chút chịu lỗi ổ đĩa nào** — chỉ chịu lỗi **node**.
  Nếu `/dev/vda1` của 1 node hỏng thì mất cả 4 disk của node đó cùng lúc.
  EC vẫn cứu được (mất 1/4 server), nhưng đừng nhầm là "có 16 disk nên rất an toàn".

### 5b.3 ⭐ Phát hiện 5 — registry khác nhau + image MinIO trên vMLP CŨ HƠN 2 NĂM

`kubectl -n viettel-telecom get sts -o wide`:

```
NAME                                READY  AGE     CONTAINERS      IMAGES
viettel-telecom-viettel-telecom-pool-0  4/4  2y227d  minio,sidecar
  10.208.137.65:8890/vmlp/minio/minio:RELEASE.2023-06-23T20-26-00Z
  10.208.137.65:8890/vmlp/minio/operator:v5.0.6
```

| | vRP (nguồn) | vMLP (đích) |
|---|---|---|
| Registry | `10.60.170.184:8083` | **`10.208.137.65:8890`** ← khác hẳn |
| Image MinIO | `minio/minio:RELEASE.**2025-06**-13T11-33-47Z` | `.../minio:RELEASE.**2023-06**-23T20-26-00Z` |
| Operator | — | `operator:v5.0.6` |

⭐ **Lệch 2 năm — đây là rủi ro THẬT, không phải chi tiết vụn:**

MinIO **2023-06 KHÔNG đọc được** dữ liệu do MinIO **2025-06** ghi, nếu format version
của backend đã nâng giữa 2 bản. Chiều ngược lại (bản mới đọc bản cũ) thì được.

⟹ **MinIO single-node TẠM ở chặng 2 của phương án B bắt buộc dùng ĐÚNG image
`RELEASE.2025-06-13T11-33-47Z` của vRP**, không được xài image 2023-06 sẵn có trên vMLP.

⟹ Mà image đó **chưa có trên registry vMLP** ⟹ phải đưa image sang.

### ✅ 5b.3b — ĐÃ CÓ SẴN FILE TAR IMAGE (Kiên báo 26/08)

Kiên xác nhận: **image MinIO có sẵn ở `/tmp/ragflow-images.tar` trên vrp-07 (`.54`)**.

⟹ **Không cần đụng tới registry airgap.** Đường đi ngắn hơn nhiều:

```
vrp-07:/tmp/ragflow-images.tar  ──scp──>  vmlp-XX  ──ctr -n k8s.io images import──>  containerd
```

✅ **Kiên xác nhận 26/08**: tar chứa **chính xác 100% cả image lẫn tag** của MinIO
đang định migrate ⟹ **không cần xác minh thêm**, dùng thẳng.

⟹ **R9 (lệch version image) — ĐÓNG.**

⚠️ Import xong **image nằm ở containerd cục bộ của node đó**, không nằm ở registry
⟹ **phải import trên TỪNG node** sẽ chạy MinIO, và pod phải để
`imagePullPolicy: IfNotPresent` (StatefulSet vRP vốn đã dùng đúng policy này).

⚠️⚠️ **LUẬT CỨNG**: khi `ctr` trên node vMLP phải **luôn ghi rõ `-n k8s.io`**.
Không ghi namespace thì image vào `default`, **kubelet sẽ không thấy** ⟹ vẫn `ImagePullBackOff`
mà tưởng đã import xong. (Cùng loại bẫy với luật `.51`/nerdctl bên vRP.)

### 5b.4 Phát hiện 6 — không có node label minio/storage

```
$ kubectl get nodes --show-labels | tr ',' '\n' | grep -iE 'minio|storage|node-role'
node-role.kubernetes.io/control-plane=
node-role.kubernetes.io/master=
node-role.kubernetes.io/control-plane=
node-role.kubernetes.io/master=
node-role.kubernetes.io/control-plane=
node-role.kubernetes.io/master=
```

Chỉ có label của 3 control-plane, **không có label tuỳ biến nào liên quan minio/storage**.

⟹ Tenant **pin node bằng `nodeAffinity` viết trong từng PV** (`kubernetes.io/hostname`),
**không** bằng nodeSelector/label như cách vRP làm (`ragflow-target: "true"`).
Tenant ragflow phải theo đúng cơ chế này của vMLP.

### 5b.5 Trạng thái MinIO Operator trên vMLP

```
NAME                              READY  STATUS             RESTARTS      AGE    NODE
console-6b6d4f4f6b-zjjdj          1/1    Running            0             257d   vmlp-kubeengine08
minio-operator-69cb755bf-kbw4l    1/1    Running            3 (494d ago)  2y258d vmlp-kubeengine06
minio-operator-69cb755bf-zsqpz    0/1    ImagePullBackOff   0             11d    vmlp-kubeengine07
```

⚠️ Operator có **2 replica nhưng 1 con đang `ImagePullBackOff` 11 ngày** trên vmlp-07.
Con còn lại vẫn `Running` nên Operator hoạt động, nhưng **mất HA**.
Đây là **bằng chứng cụ thể cho R7**: registry vMLP đang có vấn đề kéo image —
phải xử lý trước khi apply Tenant mới, nếu không Tenant sẽ chết đúng lỗi này.

Tenant hiện có:

```
NAMESPACE        NAME                   STATE         AGE
vcc              viettel-construction   Initialized   2y70d
vic              viettel-information    Initialized   490d
viettel-telecom  viettel-telecom        Initialized   2y227d
```

### 5b.6 Cấu hình phía RAGFlow trên vRP (bước 3)

`kubectl -n ragflow get svc`:

| NAME | TYPE | CLUSTER-IP | PORT(S) | AGE |
|---|---|---|---|---|
| ragflow | **NodePort** | 172.16.151.109 | 80:8999/TCP | 95d |
| ragflow-admin | ClusterIP | 172.16.150.194 | 9381/TCP | 25d |
| ragflow-api | ClusterIP | 172.16.239.79 | 80/TCP | 103d |
| **ragflow-minio** | **ClusterIP** | 172.16.213.63 | **9000/TCP, 9001/TCP** | 103d |
| ragflow-mysql | ClusterIP | 172.16.138.99 | 3306/TCP | 103d |
| ragflow-redis | ClusterIP | None (headless) | 6379/TCP | 103d |
| ragflow-redis-svc | ClusterIP | 172.16.134.105 | 6379/TCP | 103d |

⟹ ✅ Đúng như dự đoán: `ragflow-minio` là **ClusterIP** ⟹ **bắt buộc phải đổi**
sang endpoint `IP:NodePort` của vMLP sau khi migrate.

Secret `ragflow-env-config` có **đúng 5 key** liên quan MinIO:

```
MINIO_HOST            (base64)
MINIO_PORT            (base64)
MINIO_USER            (base64)
MINIO_PASSWORD        (base64)
MINIO_ROOT_PASSWORD   (base64)
```

⟹ Sau migrate cần sửa **`MINIO_HOST`** và **`MINIO_PORT`**.
Ba key credential giữ nguyên **nếu** Tenant mới được tạo với cùng user/password.

### 5b.7 Ghi chú về credential

Output bước 3 hiển thị giá trị base64 của `MINIO_PASSWORD` / `MINIO_ROOT_PASSWORD`.

**Kiên đánh giá 26/08: không thành vấn đề** — môi trường VDI nội bộ, phạm vi xem được
hạn chế. ⟹ **Không đưa rotate vào danh sách việc phải làm** của phiên này.

| Việc | Trạng thái |
|---|---|
| Giá trị secret có bị ghi vào repo này không | ❌ **KHÔNG** — và **giữ nguyên nguyên tắc này** |
| Lý do vẫn không ghi vào repo | Repo push lên GitHub — **phạm vi khác hẳn** screenshot nội bộ. Repo đang có nợ Bearer token trong git history, đừng thêm |

⟹ Khi tạo Tenant mới **vẫn nên đặt credential riêng cho Tenant ragflow**
(không bê nguyên giá trị cũ) — không phải vì bảo mật, mà vì **tách bạch quyền**:
Tenant trên vMLP nằm cạnh 3 Tenant của đơn vị khác (`vcc`, `vic`, `viettel-telecom`).

### 5b.8 Trạng thái pod RAGFlow đã ĐỔI so với tracking cũ

```
NAME                        READY  STATUS             RESTARTS      AGE
ragflow-67fcdbbdb7-cpdbs    0/1    Running            0             27h
ragflow-67fcdbbdb7-ns8pd    0/1    Running            0             27h
ragflow-67fcdbbdb7-pl8hd    0/1    Running            46 (114s ago) 27h
ragflow-minio-0             0/1    ImagePullBackOff   0             3h45m
ragflow-mysql-0             1/1    Running            0             12d
ragflow-redis-0             0/1    ImagePullBackOff   0             3h45m
```

⭐ **Thay đổi quan trọng**: `ragflow-minio-0` và `ragflow-redis-0` **không còn `Pending`**
mà chuyển thành **`ImagePullBackOff`**, tuổi pod chỉ **3h45m** (trước là 86s lúc 26/08 sáng).

Nghĩa là pod **ĐÃ được scheduler gán node** (taint disk-pressure có thể đã hạ),
nhưng giờ chết vì **không kéo được image** từ registry vRP.
⟹ Trục sự cố đã **dịch từ inode sang registry/image**. Cần kiểm lại
`kubectl describe pod ragflow-minio-0` để biết node nào và lỗi pull cụ thể.

⚠️ `ragflow-...-pl8hd` đã **restart 46 lần** — liveness vẫn đang giết pod liên tục.

---

## 5c. 🔴 KHẢO SÁT ĐỢT 3 — KẾT QUẢ LẬT NGƯỢC CHẨN ĐOÁN (26/08)

### 5c.1 🔴 Phát hiện 7 — taint ĐÃ HẠ, sự cố KHÔNG CÒN là inode

```
$ kubectl get node vrp-kubeengine07 -o jsonpath='{.spec.taints}'
(in ra RỖNG — không còn taint nào)
```

```
NAME                       READY  STATUS            RESTARTS     AGE    IP             NODE
ragflow-67fcdbbdb7-cpdbs   0/1    Running           0            27h    172.16.78.64   vrp-kubeengine05
ragflow-67fcdbbdb7-ns8pd   0/1    Running           0            27h    172.16.83.83   vrp-kubeengine06
ragflow-67fcdbbdb7-pl8hd   0/1    Running           48 (4m27s)   27h    172.16.83.72   vrp-kubeengine06
ragflow-minio-0            0/1    ImagePullBackOff  0            3h59m  172.16.93.112  vrp-kubeengine07
ragflow-mysql-0            1/1    Running           0            12d    172.16.83.7    vrp-kubeengine06
ragflow-redis-0            0/1    ImagePullBackOff  0            3h59m  172.16.93.108  vrp-kubeengine07
```

`describe pod` xác nhận: `PodScheduled: True`, pod **đã được gán vrp-kubeengine07**, đã có IP.

⟹ **Scheduling KHÔNG còn là vấn đề.** Chuỗi nhân quả cũ
(inode → taint → Pending → RAGFlow chết) **đã đứt ở mắt xích thứ 3**.

### 5c.2 🔴 Phát hiện 8 — lỗi THẬT là kéo image từ Docker Hub Internet

Events nguyên văn từ `describe pod ragflow-minio-0`:

```
Normal   BackOff  6m58s (x910 over 3h51m)  kubelet
  Back-off pulling image "minio/minio:RELEASE.2025-06-13T11-33-47Z"

Warning  Failed   118s (x58 over 3h32m)    kubelet
  Failed to pull image "minio/minio:RELEASE.2025-06-13T11-33-47Z":
  rpc error: code = Unknown desc = failed to pull and unpack image
  "docker.io/minio/minio:RELEASE.2025-06-13T11-33-47Z":
  failed to resolve reference "docker.io/minio/minio:RELEASE.2025-06-13T11-33-47Z":
  failed to do request:
  Head "https://registry-1.docker.io/v2/minio/minio/manifests/RELEASE.2025-06-13T11-33-47Z":
  dial tcp: lookup registry-1.docker.io on 10.30.3.39:53:
  read udp 10.208.137.54:39761->10.30.3.39:53: i/o timeout
```

Đã thử **910 lần** trong 3h51m.

**Root cause — độ chắc chắn: RẤT CAO** (log nguyên văn, không suy diễn):

```
StatefulSet ghi image: "minio/minio:RELEASE.2025-06-13T11-33-47Z"
                        └─ KHÔNG CÓ PREFIX REGISTRY
        ↓
containerd mặc định điền "docker.io/" vào đầu
        ↓
cụm AIRGAP → DNS 10.30.3.39 không hồi đáp → i/o timeout
        ↓
ImagePullBackOff vĩnh viễn
```

⭐ **Phân biệt `i/o timeout` với `no such host`**:
- `i/o timeout` = gói DNS gửi đi **không có hồi đáp** ⟹ firewall **DROP im lặng**
- `no such host` = DNS **trả lời** "không tồn tại" ⟹ sai tên miền

Ở đây là **timeout** ⟹ bị chặn, không phải gõ sai. Đọc nhầm 2 cái này là đi sai hướng.

### 5c.3 ⭐ Vì sao taint hạ mà inode KHÔNG hề giảm

`df` mới nhất trên vrp-07:

```
$ df -i /
/dev/vda1  Inodes 6553600  IUsed 6221631  IFree 331969  IUse% 95%

$ df -h /
/dev/vda1  Size 99G  Used 61G  Avail 34G  Use% 65%
```

| Thời điểm | IUsed | IFree | IUse% |
|---|---|---|---|
| 26/08 sáng (tracking cũ) | 6.221.566 | 332.034 | 95% |
| 26/08 chiều (đợt 3) | 6.221.631 | 331.969 | 95% |

⟹ **Inode gần như KHÔNG đổi** (chênh 65 inode). Vậy tại sao taint hạ?

**Giải thích**: ngưỡng mặc định của kubelet là `nodefs.inodesFree < 5%`.
Node đang ở **331.969 / 6.553.600 = 5,06% free** — **dao động NGAY SÁT MÉP ngưỡng**.

⚠️ ⟹ Taint đang **bật/tắt quanh lằn ranh**. Đây **KHÔNG PHẢI đã khỏi** —
chỉ cần MinIO ghi thêm vài nghìn object là taint bật lại. Trạng thái này **nguy hiểm hơn**
bị taint cố định, vì nó tạo cảm giác an toàn giả.

❓ *Cần xác minh*: ngưỡng `evictionHard` thực tế trên cụm này có đúng mặc định 5% không
(`ps -ef | grep kubelet` hoặc đọc `/var/lib/kubelet/config.yaml`).

### 5c.4 ⭐⭐ HỆ QUẢ: có còn cần migrate không?

**Sự cố ĐANG diễn ra fix được trong ~10 phút, KHÔNG cần migrate gì:**

```
1. ctr -n k8s.io images import /tmp/ragflow-images.tar   (trên vrp-07)
2. Sửa image reference trong values/sts → registry nội bộ 10.60.170.184:8083
3. Pod chạy → RAGFlow sống lại
```

**Nhưng nguyên nhân gốc còn nguyên**: inode 95%, free 331.969, node dao động sát ngưỡng,
và RAGFlow vẫn đang ghi object mới.

⟹ **Migrate vẫn CẦN**, nhưng đổi tính chất:
- Trước: việc **cứu hoả**, làm gấp trong lúc dịch vụ đang chết
- Giờ: việc **xử lý nợ kỹ thuật**, làm có kế hoạch, có downtime chủ động

### ✅ QUYẾT ĐỊNH — Kiên chốt 26/08

> **"vẫn migrate chứ"** + **"ko cần ragflow sống lại, kệ nó, vì nó đã chết từ lâu rồi,
> tập trung hoàn thành chỗ migrate minIO này trước"**

| Việc | Quyết định |
|---|---|
| Cứu RAGFlow sống lại ngay | ❌ **BỎ** — đã chết lâu, không phải việc gấp |
| Migrate MinIO sang vMLP | ✅ **LÀM, ưu tiên số 1** |

### ⭐ Điều này ĐƠN GIẢN HOÁ bài toán rất nhiều

| Ràng buộc trước đây | Giờ |
|---|---|
| Phải tính downtime, xin cửa sổ bảo trì | ✅ **Bỏ** — dịch vụ đã down sẵn |
| Lo MinIO ghi thêm object khi đang copy | ✅ **Bỏ** — MinIO không chạy, dữ liệu **ĐỨNG YÊN** |
| Lo inode vrp-07 tụt tiếp trong lúc làm | ✅ **Bỏ** — không có gì ghi vào |
| R5 (RAGFlow vẫn đang ghi) | ✅ **ĐÓNG** |
| R6 (`mc mirror` bucket lớn không checkpoint) | 🟢 hạ mức — không có sức ép thời gian |

⭐ **Dữ liệu nguồn ở trạng thái ĐỨNG YÊN là điều kiện lý tưởng để copy** —
không cần lo tính nhất quán, không cần quiesce, copy xong là chắc chắn đủ.

---

## 5d. ✅ CHỐT KIẾN TRÚC ĐÍCH: **SINGLE-NODE** (Kiên chốt 26/08)

### Bối cảnh câu hỏi

Kiên hỏi lại: *"ủa mà bạn đang bảo dựng tạm là dựng cái gì thế? tưởng chỉ cần migrate
data của minIO từ node 07 sang, rồi tạo các PV PVC, rồi migrate cả workload dành cho
minIO nữa, rồi check kết nối giữa các thành phần với minIO xem ok chưa"*

⭐ **Câu hỏi đúng chỗ.** Tôi đã **lẳng lặng nhét thêm một quyết định Kiên chưa hề chốt**:
mặc định MinIO đích sẽ là **Tenant erasure-coded** (vì vMLP có sẵn Operator).
**Chính giả định đó — chứ không phải bản thân việc migrate — mới đẻ ra "MinIO tạm".**

### Vì sao Tenant thì cần MinIO tạm, single-node thì không

| Hướng | Layout đĩa | Copy được bằng | MinIO tạm? |
|---|---|---|---|
| single-node → **single-node** | **Y HỆT** | `rsync` thư mục thô, trỏ PV vào là đọc thẳng | ❌ **KHÔNG cần** |
| single-node → **Tenant EC** | **KHÁC HẲN** (object chẻ thành shard rải nhiều drive + `xl.meta` riêng) | bắt buộc qua **tầng S3** (`mc mirror`) | ✅ Cần — để parse layout cũ |

⟹ **"MinIO tạm" KHÔNG phải yêu cầu bắt buộc của việc migrate.**
Nó là **cái giá của việc đổi kiến trúc sang Tenant**. Bỏ Tenant ⟹ cái giá đó biến mất.

### Trade-off đã trình bày để Kiên chọn

| | **1. Single-node** ✅ chọn | 2. Tenant EC |
|---|---|---|
| Các bước | rsync → PV/PVC → deploy STS → check | rsync → MinIO tạm → mc mirror → Tenant → check |
| Độ phức tạp | **Thấp** — bê nguyên config vRP sang | Cao — viết Tenant mới, học Operator v5.0.6 |
| Rủi ro hỏng | **Thấp** — layout không đổi | Trung bình — nhiều bước mới, chưa từng làm |
| Inode | vẫn dồn 5,66M vào 1 node | chia 4 node (~1,4M/node) — **chỉ nếu** cấu hình đúng |
| Giải quyết gốc? | ❌ mua thêm thời gian | ✅ nếu trải được qua nhiều node |
| Issue #4 của sếp | ❌ chưa | ✅ xong luôn |

⭐ **Điểm quyết định**: node đích **vmlp-09 có 12,65M inode free**, còn vrp-07
chỉ có **6,55M inode TỔNG**. ⟹ Ngay cả single-node cũng cho **gấp đôi quỹ inode**
so với hiện tại — **không phải "y như cũ"**.

⭐ Và **R15 làm lựa chọn 2 kém hấp dẫn hơn tưởng**: Tenant mẫu trên vMLP pin cả pool
vào 1 node, muốn chia thật phải làm **khác mẫu** trên Operator đời **2023**
⟹ rủi ro cao hơn, mà **lợi ích không còn tự động có**.

### ✅ Quyết định

**Single-node.** Issue #4 (cluster hoá) tách thành **việc riêng làm sau** — khi đó
dữ liệu đã nằm sẵn trên vMLP, việc dựng MinIO tạm + `mc mirror` sang Tenant
diễn ra **trong nội bộ một cụm**, dễ và an toàn hơn nhiều so với làm ngay bây giờ.

### 📐 Luồng migrate CHỐT

```
[1] rsync 37G     vrp-07:/data/ragflow/minio  ──>  vmlp-09:/home/app/app_data/ragflow/minio
                     (đứng yên, chỉ ĐỌC)
[2] tạo PV (hostPath + nodeAffinity vmlp-09) + PVC        trên vMLP, ns ragflow
[3] import image từ tar + deploy StatefulSet MinIO        image 2025-06
[4] tạo Service NodePort                                  vì cross-cluster
[5] sửa MINIO_HOST + MINIO_PORT trong ragflow-env-config   trên vRP
[6] check kết nối + đối chiếu số object / dung lượng
[7] dọn: xoá /data/ragflow/minio trên vrp-07 → thu hồi 5,66M inode
```

⚠️ **Bước [3] BẮT BUỘC dùng image `RELEASE.2025-06-13T11-33-47Z`** từ
`/tmp/ragflow-images.tar` — **KHÔNG** dùng image 2023-06 sẵn có trên vMLP,
vì bản cũ không đọc được backend do bản mới ghi (5b.3).

⚠️ Phải khai **đủ FQDN registry** hoặc import sẵn vào containerd + `IfNotPresent` —
đừng lặp lại đúng lỗi thiếu prefix đã làm chết pod nguồn (5c.2).

⚠️ **Không còn bản copy trung gian** ⟹ **R8 đóng**. Bản rsync sang chính là bản dùng thật.

⭐ **Bài học**: nếu không chạy `describe pod` mà lao vào migrate ngay,
ta đã **migrate 37G để chữa một bệnh đã tự khỏi**, trong khi bệnh thật
(image reference thiếu registry prefix) vẫn còn nguyên và sẽ tái phát ở cụm mới.

### 5c.5 File tar image

```
$ ls -lh /tmp/ragflow-images.tar
-rw-r--r-- 1 root root 838M Aug 14 09:08 /tmp/ragflow-images.tar
```

**838 MB**, tạo 14/08. scp sang vMLP trong mạng nội bộ (~0,3–1ms RTT) ⟹ rất nhanh.

### 5c.6 ⭐ Tenant mẫu `viettel-telecom` — BẢN MẪU để viết Tenant ragflow

```yaml
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: viettel-telecom
  namespace: viettel-telecom
  labels: { app: minio, app.kubernetes.io/managed-by: Helm }
  annotations:
    meta.helm.sh/release-name: minio          # ⟹ quản lý bằng Helm
    meta.helm.sh/release-namespace: viettel-telecom
  creationTimestamp: "2024-01-11T11:11:23Z"
spec:
  buckets:                                     # ⭐ Tenant TỰ TẠO bucket
  - { name: mlflow, objectLock: false }
  - { name: vmlp,   objectLock: false }
  configuration: { name: myminio-env-configuration }   # ⟸ Secret chứa credential
  features: { bucketDNS: false, enableSFTP: false }
  image: 10.208.137.65:8890/vmlp/minio/minio:RELEASE.2023-06-23T20-26-00Z
  imagePullPolicy: IfNotPresent
  imagePullSecret: { name: harbor-secret }     # ⚠️ CẦN secret này trong ns
  mountPath: /export                           # ⚠️ KHÔNG phải /data
  subPath: /data
  podManagementPolicy: Parallel
  pools:
  - name: viettel-telecom-pool-0
    servers: 4
    volumesPerServer: 4
    nodeSelector:
      kubernetes.io/hostname: vmlp-kubeengine08     # ⚠️⚠️ XEM 5c.7
    containerSecurityContext: { runAsUser: 0, runAsGroup: 0, runAsNonRoot: false }
    securityContext:
      { fsGroup: 0, fsGroupChangePolicy: OnRootMismatch,
        runAsUser: 0, runAsGroup: 0, runAsNonRoot: false }
    volumeClaimTemplate:
      metadata: { name: data }
      spec:
        accessModes: [ ReadWriteOnce ]
        resources: { requests: { storage: 20Gi } }
        storageClassName: host-storage
  prometheusOperator: false
  requestAutoCert: false
status:
  currentState: Initialized
  healthStatus: green
  availableReplicas: 4
  drivesOnline: 16
  writeQuorum: 12
  usage: { rawCapacity: 343597383680, rawUsage: 2133630582784 }
  pools: [ { ssName: viettel-telecom-viettel-telecom-pool-0, state: PoolInitialized } ]
  provisionedBuckets: true
```

Operator: `10.208.137.65:8890/vmlp/minio/operator:v5.0.6`

**Ghi chú đọc từ mẫu:**
- `mountPath: /export` + `subPath: /data` — **khác** vRP (`/data`). Phải theo mẫu vMLP.
- `imagePullSecret: harbor-secret` — Tenant ragflow cũng cần secret này (hoặc import image sẵn).
- `configuration: myminio-env-configuration` — credential nằm trong Secret riêng,
  **không** nhét thẳng vào Tenant. Đây là chỗ đặt user/password cho Tenant ragflow.
- `buckets:` — khai báo sẵn ⟹ có thể **khai luôn bucket của RAGFlow** để Operator tự tạo.

### 5c.7 🔴🔴 SỬA TIẾP KẾT LUẬN — Tenant mẫu pin CẢ POOL vào MỘT NODE

```yaml
pools:
- servers: 4
  volumesPerServer: 4
  nodeSelector: { kubernetes.io/hostname: vmlp-kubeengine08 }   # ← MỘT node duy nhất
```

`status: drivesOnline: 16, writeQuorum: 12` nghe rất khoẻ, **nhưng**:

**16 "drive" đó = 4 server × 4 volume, TẤT CẢ nằm trên `vmlp-kubeengine08`,
tất cả trên cùng `/dev/vda1`.**

| Chống được | Không chống được |
|---|---|
| Hỏng file lẻ / bit rot | ⛔ **Mất node vmlp-08 ⟹ MẤT SẠCH** |
| | ⛔ Hỏng ổ `/dev/vda1` ⟹ mất sạch |
| | ⛔ **Cạn inode của vmlp-08** ⟹ chết y hệt vrp-07 |

### ⚠️ Điều này làm SẬP lập luận của tôi ở đợt 1 và 2

Tôi đã ghi 2 lần: *"dùng Tenant ⟹ chia inode ra 4 node, mỗi node ~1,4M inode"*.
**SAI.** Nếu bắt chước y hệt mẫu (`nodeSelector` 1 hostname), **cả 5,66M inode dồn
vào MỘT node** — đúng vết xe đổ vrp-07, chỉ đổi tên node.

⟹ **Tenant ragflow BẮT BUỘC phải làm KHÁC mẫu**: bỏ `nodeSelector` cố định 1 hostname,
thay bằng cơ chế trải pod qua nhiều node (`podAntiAffinity` theo hostname,
hoặc `nodeSelector` rộng + `topologySpreadConstraints`).
Và PV phải tạo với `nodeAffinity` trỏ **4 node khác nhau**.

⚠️ Cần kiểm: Operator **v5.0.6 (2023)** có hỗ trợ `topologySpreadConstraints` trong pool không.

### 5c.8 Dung lượng `/home` trên node ứng viên

```
[vt_admin@vmlp-kubeengine07 ~]$ du -sh /home/app/app_data 2>/dev/null
(RỖNG — thư mục chưa tồn tại)
[vt_admin@vmlp-kubeengine07 ~]$ df -h /home
/dev/vda1  197G  97G used  92G avail  52%  /

[vt_admin@vmlp-kubeengine09 ~]$ du -sh /home/app/app_data 2>/dev/null
(RỖNG — thư mục chưa tồn tại)
[vt_admin@vmlp-kubeengine09 ~]$ df -h /home
/dev/vda1  197G  50G used  139G avail  27%  /
```

✅ Xác nhận **`/home` KHÔNG phải mount riêng** — nằm trên `/dev/vda1`, đúng như `lsblk` đợt 1.
✅ Cả vmlp-07 và vmlp-09 **chưa có `/home/app/app_data`** ⟹ chưa gánh dữ liệu MinIO nào.

| Node | Avail | IFree (đợt 1) | Đủ cho 37G + 5,7M inode? |
|---|---|---|---|
| vmlp-07 (.41) | 92G | 11.701.245 | ✅ |
| vmlp-09 (.43) | **139G** | **12.651.792** | ✅ **thoáng nhất** |

### 5c.9 Ghi chú — `rawUsage` của Tenant mẫu là số VÔ LÝ

```
rawCapacity: 343597383680    =  320 GiB
rawUsage:   2133630582784    = 1,94 TiB   ← LỚN HƠN capacity gấp 6 lần
```

Usage > capacity là **bất thường**. ❓ Giả thuyết (**chưa xác minh**): Operator v5.0.6
báo `rawUsage` là dung lượng **toàn ổ `/dev/vda1`** của cả 4 pod cộng lại,
không phải phần MinIO dùng.

⟹ **Đừng tin cột `rawUsage`** khi đánh giá dung lượng. Dùng `du` trên node thay thế.

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

### ✅ Đã có thêm sau đợt 2 (26/08)

- [x] ⭐ **Mạng 2 cụm thông cả 2 chiều** — R1 đóng
- [x] Tenant hiện có: 3 cái (`vcc`, `vic`, `viettel-telecom`), đều `Initialized`
- [x] `host-storage` = **PV tạo tay**, không có provisioner (`get sc` → NotFound)
- [x] ⭐ Đường dẫn PV Tenant: `/home/app/app_data/<tenant>/minio/data-<N>`
- [x] Cơ chế pin node: **`nodeAffinity` trong PV** (`kubernetes.io/hostname`), không dùng label
- [x] Không có node label minio/storage nào
- [x] Endpoint MinIO vRP: **ClusterIP** `172.16.213.63:9000,9001` ⟹ phải đổi
- [x] Secret có 5 key: `MINIO_HOST/PORT/USER/PASSWORD/ROOT_PASSWORD`
- [x] ⭐ Image MinIO vMLP là **2023-06**, lệch 2 năm so vRP **2025-06**
- [x] ✅ **Có sẵn `/tmp/ragflow-images.tar` trên vrp-07** — đúng 100% image + tag
- [x] ⭐ **Sửa kết luận sai đợt 1**: 4 disk/server là 4 **thư mục cùng 1 ổ**

### ❓ Còn thiếu (đợt khảo sát 3)

- [ ] `ragflow-minio-0` đang ở node nào, lỗi pull image cụ thể là gì (R13)
- [ ] Node vrp-07 hiện còn taint disk-pressure không (pod đã đổi sang ImagePullBackOff)
- [ ] Dung lượng file `/tmp/ragflow-images.tar` (ảnh hưởng thời gian scp)
- [ ] `/home/app/app_data` trên các node vMLP hiện chiếm bao nhiêu byte/inode
- [ ] Spec đầy đủ của một Tenant mẫu (`kubectl -n viettel-telecom get tenant -o yaml`)
  → để bắt chước đúng cấu trúc khi viết Tenant ragflow
- [ ] Version MinIO Operator có hỗ trợ image MinIO 2025-06 không (operator v5.0.6 khá cũ)

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

## 7b. Lệnh cần chạy — ĐỢT KHẢO SÁT 3

### 7b.1 Trên **vrp-04** (`10.208.137.51`, user `app`)

```
kubectl -n ragflow describe pod ragflow-minio-0 | tail -30
kubectl get node vrp-kubeengine07 -o jsonpath='{.spec.taints}'
kubectl -n ragflow get pod -o wide
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
kubectl -n ragflow describe pod ragflow-minio-0 | tail -30
│ └─ tail -30   describe in rất dài; phần Events NẰM Ở CUỐI.
│               30 dòng cuối là vừa đủ để đọc lý do pull fail
│   ⟹ trả lời: pod nằm node nào, image nào pull không được, lỗi gì
│      (registry unreachable / not found / auth)
│
kubectl get node vrp-kubeengine07 -o jsonpath='{.spec.taints}'
│ └─ -o jsonpath='{.spec.taints}'  trích ĐÚNG mảng taints, bỏ qua phần còn lại
│   ⟹ trả lời câu hỏi then chốt: taint disk-pressure CÒN hay ĐÃ HẠ.
│      In ra rỗng ⟹ đã hạ. Còn 'disk-pressure' ⟹ vẫn đang bị
│   ⚠️ Đây là số liệu QUYẾT ĐỊNH: nếu taint đã hạ thì phương án A
│      (cho MinIO sống lại để mc mirror) lại khả thi, ngắn hơn B nhiều
│
kubectl -n ragflow get pod -o wide
  └─ -o wide  thêm cột NODE ⟹ đối chiếu pod nào đã được gán node nào
```
</details>

### 7b.2 Trên **vrp-07** (`10.208.137.54`, user `root`)

```
ls -lh /tmp/ragflow-images.tar
df -i /
df -h /
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
ls -lh /tmp/ragflow-images.tar
│ ├─ -l  long: hiện kích thước, quyền, thời gian sửa
│ └─ -h  human-readable: kích thước ra M/G thay vì byte thô
│   ⟹ biết phải scp bao nhiêu, ước lượng thời gian
│
df -i /   → ⭐ ĐO LẠI inode node 07 SAU khi sự cố diễn tiến.
df -h /     Tracking cũ ghi 95% (IFree 331.807).
            Cần biết CON SỐ HIỆN TẠI để đánh giá mức khẩn cấp:
            còn tụt nữa ⟹ RAGFlow vẫn đang ghi, phải chặn upload gấp
```
</details>

### 7b.3 Trên **vmlp-08** (`10.208.137.42`, user `app`)

```
kubectl -n viettel-telecom get tenant viettel-telecom -o yaml
kubectl -n minio-operator get deploy minio-operator -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Và ssh vào **vmlp-09** (`10.208.137.43`) + **vmlp-07** (`10.208.137.41`):
```
du -sh /home/app/app_data 2>/dev/null
df -h /home
```

<details>
<summary>Giải nghĩa (bấm để mở)</summary>

```
kubectl -n viettel-telecom get tenant viettel-telecom -o yaml
│   ⟹ ⭐ BẢN MẪU để viết Tenant ragflow: pools/servers/volumesPerServer,
│      requestAutoCert, image, credential ref, resources...
│      Bắt chước đúng cấu trúc an toàn hơn tự viết từ tài liệu upstream,
│      vì Operator v5.0.6 là bản cũ, schema có thể khác bản mới nhất
│
kubectl -n minio-operator get deploy minio-operator -o jsonpath='{.spec.template.spec.containers[0].image}'
│ └─ jsonpath đi sâu vào container đầu tiên của pod template, lấy đúng field image
│   ⟹ xác nhận version Operator. v5.0.6 (2023) có thể KHÔNG hỗ trợ
│      image MinIO 2025-06 ⟹ đây là rủi ro cần loại trừ SỚM
│
du -sh /home/app/app_data 2>/dev/null
│ ├─ -s  chỉ in tổng
│ ├─ -h  human-readable
│ └─ 2>/dev/null  im lặng nếu thư mục chưa tồn tại trên node đó
│   ⟹ biết node đó đã gánh bao nhiêu dữ liệu MinIO của Tenant khác
│
df -h /home
    ⚠️ Kiểm xem /home có phải mount RIÊNG không, hay vẫn nằm trên /.
    lsblk đợt 1 nói chỉ có vda1 ⟹ kỳ vọng /home nằm trên /,
    nhưng PHẢI xác nhận vì đây là chỗ sẽ chứa 37G dữ liệu
```
</details>

---

## 8. Rủi ro đang theo dõi

| # | Rủi ro | Mức | Ghi chú |
|---|---|---|---|
| R1 | ~~Firewall chặn giữa 2 cụm~~ | ✅ **ĐÓNG** | Đo 26/08: ping OK 2 chiều + curl bắt tay HTTP thành công. Xem 5b.1 |
| R2 | vMLP cùng **mật độ** inode với vRP, single-node vẫn dồn 5,66M vào 1 node | 🟠 **CHẤP NHẬN CÓ Ý THỨC** | Kiên chốt single-node (5d) ⟹ **không chia inode**. Nhưng vmlp-09 có **12,65M inode free** vs vrp-07 chỉ **6,55M TỔNG** ⟹ **gấp đôi quỹ**, mua đủ thời gian. Xử lý gốc = Issue #4, làm riêng sau |
| R3 | Không có ổ rời ⟹ MinIO dùng chung `/dev/vda1` với OS | 🟠 | Cạn inode sẽ kéo sập cả node, không chỉ MinIO. **Cần alert `df -i`** |
| R4 | Cross-cluster: MinIO thành external dependency | 🟠 | RAGFlow probe deep-check ⟹ mạng chập là pod 0/1 ngay |
| ~~R5~~ | ~~RAGFlow vẫn đang ghi thêm object~~ | ✅ **ĐÓNG** | Kiên chốt **kệ RAGFlow, không cứu** ⟹ MinIO không chạy ⟹ **dữ liệu ĐỨNG YÊN**, không ghi thêm. Điều kiện lý tưởng để copy |
| R6 | Bucket 37G nằm trong **1 bucket duy nhất** | 🟢 **HẠ MỨC** | Không còn sức ép thời gian (dịch vụ đã down sẵn) ⟹ `mc mirror` chạy bao lâu cũng được |
| R7 | vMLP cũng dính `ImagePullBackOff` ⟹ airgap | 🟡 **HẠ MỨC** | Đã có đường vòng: import tar bằng `ctr -n k8s.io` trên từng node, không phụ thuộc registry. Gộp theo dõi cùng **R10** |
| ~~R8~~ | ~~Bản copy trung gian 37G~~ | ✅ **ĐÓNG** | Single-node ⟹ **không có bản trung gian**. Bản rsync sang **chính là bản dùng thật**. Xem 5d |
| ~~R9~~ | ~~Image MinIO vMLP cũ hơn vRP 2 năm~~ | ✅ **ĐÓNG** | ✅ `/tmp/ragflow-images.tar` trên vrp-07 chứa **đúng 100% image + tag** cần dùng ⟹ import bằng `ctr -n k8s.io`, **không cần đụng registry**. Vẫn phải nhớ: **không được dùng image 2023-06 sẵn có trên vMLP**. Xem 5b.3 + 5b.3b |
| **R10** | Registry vMLP đang lỗi kéo image | 🟠 | `minio-operator-...-zsqpz` **ImagePullBackOff 11 ngày** ⟹ Operator mất HA. Phải sửa **trước khi** apply Tenant. Xem 5b.5 |
| ~~R11~~ | ~~Credential lộ qua screenshot~~ | ⚪ **ĐÓNG** | **Kiên đánh giá không thành vấn đề** (VDI nội bộ). Vẫn giữ nguyên tắc không ghi secret vào repo. Xem 5b.7 |
| **R12** | 4 "disk" mỗi server là **4 thư mục cùng 1 ổ** | 🟠 | EC chỉ chịu lỗi **node**, **không** chịu lỗi ổ đĩa. Đừng nhầm "16 disk nên rất an toàn". Xem 5b.2 |
| ~~R13~~ | ~~`ragflow-minio-0` đổi `Pending` → `ImagePullBackOff`~~ | ✅ **LÀM RÕ** | Nguyên nhân: image thiếu prefix registry ⟹ containerd đi `docker.io` ⟹ DNS timeout (airgap). Xem 5c.2 |
| **R14** | 🔴 **Taint vrp-07 dao động SÁT MÉP ngưỡng** | 🔴 **CAO** | IFree 331.969 = **5,06%**, ngưỡng kubelet **5%**. Taint bật/tắt quanh lằn ranh ⟹ **cảm giác an toàn giả**. Chỉ cần ghi thêm vài nghìn object là bật lại. Xem 5c.3 |
| ~~R15~~ | ~~Tenant mẫu pin cả pool vào 1 node~~ | ⏸️ **HOÃN** | Không còn áp dụng cho lần migrate này (chốt single-node). **Giữ lại nguyên vẹn** — sẽ là rủi ro số 1 khi làm Issue #4 sau này. Xem 5c.7 |
| ~~R16~~ | ~~Operator v5.0.6 có hỗ trợ tính năng cần không~~ | ⏸️ **HOÃN** | Cùng lý do R15 — chỉ liên quan khi chuyển sang Tenant |
| **R17** | Image reference thiếu prefix registry | 🟠 | Lỗi này **sẽ tái phát ở cụm mới** nếu bê nguyên values sang. Phải sửa thành FQDN registry ở cả 2 nơi |
| **R18** | `mountPath` vMLP là `/export`, vRP là `/data` | 🟡 | Khác biệt layout — không được bê nguyên config vRP sang Tenant vMLP |

---

## 9. Việc tiếp theo

- [x] ~~Kiên chạy đợt khảo sát 2~~ ✅ **XONG 26/08** — kết quả ở mục 5b
- [x] ~~Kiên chạy đợt khảo sát 3~~ ✅ **XONG 26/08** — kết quả ở mục 5c
- [x] ~~Xem lại lựa chọn A vs B~~ ✅ **Giữ B** — nhưng đổi chỗ dựng MinIO tạm sang vMLP (xem 5c.4)
- [x] ~~Xác nhận image MinIO có sẵn~~ ✅ `/tmp/ragflow-images.tar` 838M trên vrp-07
- [x] ~~Lên kịch bản downtime~~ ✅ **KHÔNG CẦN** — dịch vụ đã down sẵn, Kiên chốt kệ RAGFlow

> Luồng theo kiến trúc **single-node** đã chốt ở **5d**.

### Bước 1 — chốt node đích + chuẩn bị (chưa động vào dữ liệu)

- [ ] Chốt node đích: ứng viên **vmlp-09** (`.43`) — 139G trống, inode **4%** (thoáng nhất)
- [ ] Chốt đường dẫn hostPath trên node đích
      → đề xuất `/home/app/app_data/ragflow/minio` (theo quy ước vMLP ở 5b.2)
- [ ] Tạo namespace `ragflow` trên vMLP
- [ ] scp `/tmp/ragflow-images.tar` (838M) từ vrp-07 → node đích
- [ ] `ctr -n k8s.io images import` trên node đích — ⚠️ **nhớ `-n k8s.io`**, không thì kubelet không thấy
- [ ] Xác minh image đã vào đúng namespace: `ctr -n k8s.io images ls | grep minio`

### Bước 2 — copy dữ liệu (37G, nguồn ĐỨNG YÊN)

- [ ] `rsync` từ vrp-07 (**chỉ ĐỌC**, không xoá gì bên nguồn) → node đích
- [ ] ⚠️ Dùng cờ giữ nguyên quyền/owner/timestamp — MinIO nhạy với metadata
- [ ] Đối chiếu **số inode** và **dung lượng** 2 bên sau khi copy xong

### Bước 3 — dựng workload MinIO trên vMLP

- [ ] Tạo PV: hostPath + `nodeAffinity` trỏ node đích + `Retain`
- [ ] Tạo PVC bind vào PV đó
- [ ] Tạo Secret credential cho MinIO (đặt giá trị riêng, không bê nguyên từ vRP — 5b.7)
- [ ] Deploy StatefulSet MinIO — ⚠️ image **2025-06**, `imagePullPolicy: IfNotPresent`
- [ ] ⚠️ Image reference phải ghi **đủ FQDN** hoặc dùng image đã import (R17)
- [ ] Tạo Service **NodePort** (bắt buộc, vì cross-cluster — ClusterIP không dùng được)

### Bước 4 — đấu nối lại với RAGFlow ở vRP

- [ ] Sửa `MINIO_HOST` + `MINIO_PORT` trong `ragflow-env-config` → `IP-node-vMLP:NodePort`
- [ ] Sửa credential trong secret nếu đặt giá trị mới ở bước 3
- [ ] ⚠️ Sửa luôn **image reference thiếu prefix registry** của các pod vRP (R17)
      — nếu không, RAGFlow/Redis vẫn `ImagePullBackOff` dù MinIO đã ok

### Bước 5 — verify (⭐ phần Kiên yêu cầu: không mất dữ liệu + kết nối thông)

- [ ] Đối chiếu **số object** nguồn ↔ đích
- [ ] Đối chiếu **tổng dung lượng** (kỳ vọng 37G) + **số inode**
- [ ] Spot-check **checksum** vài file ngẫu nhiên trong bucket lớn
      `73932b965e5e11f192725fd51894c519`
- [ ] Test S3 API từ vRP sang MinIO mới (health + list bucket + get 1 object)
- [ ] Kiểm RAGFlow đọc/ghi được file thật (upload thử 1 tài liệu)

### Bước 6 — dọn (chỉ làm SAU khi verify xong)

- [ ] Xoá `/data/ragflow/minio` trên vrp-07 → **thu hồi 5,66M inode**
- [ ] Xác nhận `df -i` vrp-07 tụt từ 95% xuống mức an toàn
- [ ] Đặt alert `df -i` trên Prometheus (nợ kỹ thuật từ tracking gốc)

### Việc tách ra làm SAU (không thuộc phiên này)

- [ ] **Issue #4 — chuyển sang Tenant erasure-coded** (cluster hoá theo chỉ đạo sếp).
      Khi đó dữ liệu đã ở vMLP ⟹ dựng MinIO tạm + `mc mirror` **trong nội bộ 1 cụm**,
      dễ và an toàn hơn làm ngay bây giờ. Rủi ro cần giải khi đó: **R15**, **R16**

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
| 26/08 | Khảo sát đợt 2 — kiểm mạng | ✅ **R1 ĐÓNG**: thông 2 chiều, curl bắt tay HTTP OK |
| 26/08 | Khảo sát đợt 2 — Tenant/PV vMLP | Ra **phát hiện 4**: hostPath `/home/app/app_data/<tenant>/minio/data-<N>`, `host-storage` là PV tạo tay |
| 26/08 | ⭐ Sửa kết luận sai đợt 1 | 4 disk/server = 4 **thư mục cùng 1 ổ**, EC chỉ chịu lỗi **node** |
| 26/08 | Khảo sát đợt 2 — image | **Phát hiện 5**: vMLP dùng registry `10.208.137.65:8890`, image MinIO **2023-06** (lệch 2 năm) |
| 26/08 | Kiên báo có sẵn tar image | ✅ **R9 ĐÓNG** — `/tmp/ragflow-images.tar` trên vrp-07, đúng 100% image + tag |
| 26/08 | Kiên đánh giá vụ lộ credential | Không thành vấn đề ⟹ **R11 đóng**, bỏ rotate khỏi kế hoạch |
| 26/08 | Phát hiện trạng thái pod đổi | `ragflow-minio-0`: `Pending` → **`ImagePullBackOff`** ⟹ **R13**, có thể taint đã hạ |
| 26/08 | Khảo sát đợt 3 — taint | 🔴 **Taint ĐÃ HẠ**, pod đã gán vrp-07. Chuỗi nhân quả cũ đứt |
| 26/08 | Khảo sát đợt 3 — describe pod | 🔴 **Lỗi thật**: image thiếu prefix registry → `docker.io` → DNS timeout (910 lần thử) |
| 26/08 | Đo lại inode vrp-07 | 6.221.631 / IFree **331.969** / **95%** — không đổi. **R14**: dao động sát mép ngưỡng 5% |
| 26/08 | Đọc Tenant mẫu | 🔴 **R15**: mẫu pin **cả pool vào 1 node** ⟹ Tenant ragflow phải làm KHÁC mẫu |
| 26/08 | ⭐ Sửa kết luận sai lần 2 | Lập luận "Tenant chia inode ra 4 node" **SAI** nếu bắt chước mẫu |
| 26/08 | Kiên chốt | ✅ **VẪN MIGRATE** |
| 26/08 | Kiên chốt | ✅ **KỆ RAGFlow, không cứu** ⟹ dữ liệu đứng yên, **R5 đóng**, bỏ bài toán downtime |
| 26/08 | Kiên hỏi lại *"dựng tạm là dựng cái gì?"* | ⭐ Lộ ra tôi **tự nhét giả định Tenant** mà Kiên chưa chốt |
| 26/08 | Kiên chốt kiến trúc | ✅ **SINGLE-NODE** ⟹ **bỏ MinIO tạm + `mc mirror`**, **R8/R15/R16 đóng/hoãn** |
