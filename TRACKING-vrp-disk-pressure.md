# TRACKING — Disk pressure cụm vRP (airgap) + cải thiện Helm chart RAGFlow v0.26.4

> File sống. Mỗi lệnh chạy xong **dán output thật vào đây**, không tóm tắt.
> Bắt đầu: 2026-08-21.

## 0. Bối cảnh đã biết (chưa cần verify lại)

| Hạng mục | Giá trị |
|---|---|
| Tên cụm | **vRP** |
| K8s version | v1.23.2 |
| Container runtime | **containerd 1.5.8** (không phải Docker ⟹ dùng `ctr`/`crictl`, không dùng `docker`) |
| OS | CentOS Linux 7 (Core), kernel 3.10.0-1160.90.1.el7 |
| Tuổi cụm | 3y46d |
| Mạng | **Airgap** — chỉ thông tới registry nội bộ |
| Registry | `10.60.170.184:8083` |
| Master | `.48` (kubeengine01), `.49` (02), `.50` (03) |
| Worker | `.51` (04), `.52` (05), `.53` (06), `.54` (07), `.55` (08) |

### 👤 USER NÀO CHẠY LỆNH GÌ (xác nhận từ Kiên 2026-08-21)

| Việc | User | Ghi chú |
|---|---|---|
| `kubectl ...` | **`app`** | User thao tác k8s hằng ngày, trên `.51` |
| `nerdctl ps` / `nerdctl images` (n8n) | **`root`** | ⚠️ Phải `su -` sang root trước. **KHÔNG dùng `sudo nerdctl`** |
| `ctr` / `crictl` | **`root`** | Cùng nhóm với nerdctl, cần quyền truy cập containerd socket |

```bash
su -
```
Sau khi vào root mới gõ `nerdctl ps` / `nerdctl images` / `ctr ...` / `crictl ...`.
Các lệnh `kubectl` thì thoát về user `app` (`exit`) rồi gõ.

### ⚠️ Ràng buộc an toàn — ĐỌC TRƯỚC KHI GÕ BẤT KỲ LỆNH GHI NÀO

- **`.51` (vrp-kubeengine04) là node NHẠY CẢM NHẤT:**
  - Là node hay dùng để gõ `kubectl` (jump box thao tác).
  - **Đang chạy n8n deploy bằng `nerdctl`** (container ngoài k8s, **không** do kubelet quản lý).
  - ⟹ **n8n down là rất nguy hiểm.** Mọi lệnh dọn image/prune trên `.51` phải **loại trừ**
    image của n8n. `nerdctl` mặc định nằm ở namespace `default` của containerd,
    còn pod k8s nằm ở namespace `k8s.io` ⟹ **hai namespace khác nhau**, đây là điểm cứu cánh
    nhưng PHẢI verify chứ không được giả định (xem lệnh 1.6).

- **Không phải node nào cũng thông tới registry.** Đã biết lệnh pull thủ công hoạt động trên
  *một vài* node:
  ```
  ctr -n k8s.io images pull 10.60.170.184:8083/vmlp/lfnovo/ragflow:v2-latest --skip-verify=true
  ```
  Chưa biết node nào thông / node nào không ⟹ **lệnh 1.7 để xác định dứt điểm**.
  ⟹ **Node KHÔNG thông registry thì tuyệt đối không được xóa image** (xóa xong không kéo lại được).

### Vòng lặp sự cố đang gặp (giả thuyết cần verify)

```
Disk đầy trên node
   └─> kubelet đặt node vào trạng thái DiskPressure
        └─> evict pod (theo QoS: BestEffort trước, rồi Burstable)
             └─> kubelet image GC xóa image "không còn dùng"
                  └─> pod được schedule lại / restart
                       └─> node KHÔNG thông registry ⟹ không pull được
                            └─> ImagePullBackOff (kéo dài, không tự khỏi)
```

**Điểm cần verify:** thật sự là image GC xóa image, hay là do người vận hành prune tay?
Bằng chứng nằm ở log kubelet — xem lệnh 1.8.

---

## 1. Bước 1 — Thu thập thông tin cụm (CHỈ ĐỌC, an toàn tuyệt đối)

> Toàn bộ lệnh mục 1 là **read-only**. Không lệnh nào xóa/sửa gì.
> Chạy từ `.51` (nơi có kubectl) trừ khi ghi rõ "chạy trên từng node".

### 1.1 — Tổng quan node + capacity (RAM / CPU / disk ephemeral)

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,CPU:.status.capacity.cpu,RAM:.status.capacity.memory,DISK:.status.capacity.ephemeral-storage,PODS:.status.capacity.pods,DISK_ALLOC:.status.allocatable.ephemeral-storage'
```

<details>
<summary>Giải nghĩa lệnh 1.1</summary>

```
kubectl get nodes -o custom-columns='...'
│         │         │
│         │         └─ -o custom-columns : tự chọn cột hiển thị thay vì output mặc định.
│         │            Cú pháp: TÊN_CỘT:đường_dẫn_JSONPath, các cột cách nhau bằng dấu phẩy.
│         │            Dùng thay cho `-o wide` vì `-o wide` KHÔNG hiện capacity RAM/CPU/disk.
│         │
│         └─ get nodes : liệt kê object kiểu Node.
│
└─ kubectl : CLI của k8s.

Từng cột:
├─ .metadata.name                → tên node (vrp-kubeengine0X)
├─ .status.addresses[?(@.type=="InternalIP")].address
│                                → lọc mảng addresses, lấy phần tử có type=InternalIP.
│                                  `[?(...)]` là filter expression của JSONPath.
├─ .status.capacity.cpu          → tổng CPU (số core, đơn vị "1" = 1 core)
├─ .status.capacity.memory       → tổng RAM (đơn vị Ki)
├─ .status.capacity.ephemeral-storage
│                                → tổng disk mà kubelet tính cho ephemeral (chính là nodefs).
│                                  ⭐ ĐÂY LÀ CON SỐ LIÊN QUAN TRỰC TIẾP TỚI DiskPressure.
├─ .status.capacity.pods         → trần số pod trên node (mặc định thường 110)
└─ .status.allocatable.ephemeral-storage
                                 → phần disk THỰC SỰ dùng được sau khi trừ reserved
                                   (kube-reserved + system-reserved + eviction-hard).
                                   capacity - allocatable = phần bị giữ lại.
```
</details>

### 1.2 — Node condition: node nào đang DiskPressure / MemoryPressure

```bash
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n | .status.conditions[] | select(.type=="DiskPressure" or .type=="MemoryPressure" or .type=="PIDPressure" or .type=="Ready") | "\($n)\t\(.type)=\(.status)\t\(.lastTransitionTime)\t\(.message)"'
```

Nếu node **không có `jq`** (rất có thể trên CentOS 7 airgap), dùng bản không cần jq:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,CONDITIONS:.status.conditions[*].type,STATUS:.status.conditions[*].status'
```

<details>
<summary>Giải nghĩa lệnh 1.2</summary>

```
kubectl get nodes -o json | jq -r '...'
│                    │        │  │
│                    │        │  └─ -r (--raw-output) : in chuỗi KHÔNG có dấu ngoặc kép bao quanh.
│                    │        │     Không có -r thì mỗi dòng ra dạng "abc" (có nháy) — khó đọc/khó grep.
│                    │        └─ jq : bộ xử lý JSON dòng lệnh.
│                    └─ -o json : xuất toàn bộ object dạng JSON để jq bóc.
│
Biểu thức jq bóc từng mảnh:
├─ .items[]                     → duyệt từng node trong danh sách
├─ .metadata.name as $n         → lưu tên node vào biến $n (vì bước sau ta đi sâu vào
│                                 .status.conditions và mất ngữ cảnh tên node)
├─ .status.conditions[]         → duyệt từng condition của node
├─ select(.type=="DiskPressure" or ...)
│                               → chỉ giữ 4 condition ta quan tâm
└─ "\($n)\t\(.type)=\(.status)\t..."
                                → nội suy chuỗi, \t là tab cho dễ căn cột

Ý nghĩa nghiệp vụ:
├─ DiskPressure=True   → kubelet ĐANG evict pod vì disk. Đây là node cần xử lý gấp.
├─ lastTransitionTime  → ⭐ thời điểm chuyển trạng thái. Rất quan trọng: đối chiếu với
│                        thời điểm pod bị ImagePullBackOff để chứng minh quan hệ nhân quả.
└─ message             → kubelet nói rõ ngưỡng nào bị vượt (nodefs hay imagefs).
```
</details>

### 1.3 — Disk thực tế trên TỪNG node (chạy trên mỗi node qua SSH)

```bash
for n in 48 49 50 51 52 53 54 55; do
  echo "===== 10.208.137.$n ====="
  ssh 10.208.137.$n 'hostname; echo "--- df ---"; df -hT -x tmpfs -x devtmpfs; echo "--- mem ---"; free -g; echo "--- cpu ---"; nproc; echo "--- inode ---"; df -i -x tmpfs -x devtmpfs'
done 2>&1 | tee /tmp/vrp-node-resources.txt
```

<details>
<summary>Giải nghĩa lệnh 1.3</summary>

```
for n in 48 49 ... ; do ... done 2>&1 | tee /tmp/vrp-node-resources.txt
│                                   │        │
│                                   │        └─ tee FILE : vừa in ra màn hình VỪA ghi vào file.
│                                   │           ⭐ Quan trọng với VDI (clipboard bị chặn): có file
│                                   │              thì sau đó có thể xem lại/cắt từng phần thay vì
│                                   │              phải screenshot cả màn hình dài.
│                                   └─ 2>&1 : gộp stderr vào stdout, để lỗi SSH (node không vào được)
│                                             cũng lọt vào file thay vì bay mất.
│
ssh HOST 'lệnh1; lệnh2; ...'
└─ Chuỗi trong nháy đơn được chạy TRÊN NODE ĐÍCH, không phải máy hiện tại.
   Dùng nháy ĐƠN (không phải nháy kép) để $ và biến không bị máy local nội suy trước.

df -hT -x tmpfs -x devtmpfs
├─ -h  : human readable (G/M thay vì block 1K) — dễ đọc
├─ -T  : hiện thêm cột TYPE (xfs/ext4/overlay) — cần để phân biệt filesystem thật
│        với overlay của container
└─ -x TYPE : LOẠI TRỪ filesystem kiểu đó. tmpfs/devtmpfs là RAM-based, không phải
             disk thật ⟹ loại đi cho output gọn, tránh nhiễu.

free -g
└─ -g : hiện đơn vị GiB. (Các cờ khác cùng họ: -m MiB, -k KiB mặc định, -h tự chọn.)
        Cột cần nhìn: `available` — RAM thực sự còn dùng được, KHÔNG phải cột `free`
        (cột free không tính phần cache có thể thu hồi ⟹ nhìn free hay hoảng nhầm).

nproc
└─ In số CPU core khả dụng. Không có cờ, đơn giản nhất trong nhóm.

df -i
└─ -i (--inodes) : hiện số INODE thay vì dung lượng.
   ⭐ Bẫy kinh điển: disk còn trống GB nhưng HẾT INODE thì vẫn không ghi được file mới,
      và triệu chứng giống hệt "đầy disk". Container/log sinh cực nhiều file nhỏ ⟹
      dễ cạn inode trước khi cạn dung lượng. PHẢI kiểm cả hai.
```
</details>

### 1.4 — Thư mục nào đang ăn disk (chạy trên node bị đầy)

```bash
ssh 10.208.137.<NODE> 'sudo du -shx /var/lib/containerd /var/lib/kubelet /var/log /var/lib/etcd /opt 2>/dev/null | sort -rh'
```

<details>
<summary>Giải nghĩa lệnh 1.4</summary>

```
du -shx DIR1 DIR2 ... | sort -rh
│  ││││
│  │││└─ -x (--one-file-system) : ⭐ KHÔNG đi sang filesystem khác khi gặp mount point.
│  │││    Cực quan trọng ở đây: /var/lib/kubelet chứa hàng trăm mount point của PV
│  │││    (NFS, Longhorn...). Không có -x thì du sẽ bò sang đếm cả dung lượng storage
│  │││    từ xa ⟹ số liệu sai bét và lệnh chạy hàng chục phút.
│  ││└─ -h : human readable (G/M)
│  │└─ -s (--summarize) : chỉ in TỔNG mỗi thư mục, không liệt kê từng file con.
│  └─ du : disk usage.
│
sort -rh
├─ -h (--human-numeric-sort) : hiểu hậu tố G/M/K khi so sánh.
│    Không có -h thì "9.9M" bị coi là lớn hơn "10G" (so sánh chuỗi) ⟹ sắp xếp sai.
└─ -r (--reverse) : giảm dần ⟹ thủ phạm ăn disk nhiều nhất nằm dòng ĐẦU.

Ý nghĩa từng thư mục:
├─ /var/lib/containerd → image layer + container rootfs. ⭐ Thường là thủ phạm số 1.
├─ /var/lib/kubelet    → emptyDir, volume mount, pod logs
├─ /var/log            → log hệ thống + log container (thường symlink về đây)
├─ /var/lib/etcd       → CHỈ có trên master. etcd phình do không compact/defrag.
└─ /opt                → app cài tay (nerdctl/n8n có thể nằm đây)

2>/dev/null : nuốt lỗi "Permission denied" cho các thư mục không đọc được ⟹ output sạch.
```
</details>

### 1.5 — Dung lượng image trong containerd

```bash
ssh 10.208.137.<NODE> 'sudo crictl images --digests | head -50; echo "--- TONG SO IMAGE ---"; sudo crictl images -q | wc -l; echo "--- CTR k8s.io ---"; sudo ctr -n k8s.io images list -q | wc -l'
```

<details>
<summary>Giải nghĩa lệnh 1.5</summary>

```
crictl images --digests
│      │      └─ --digests : hiện cả sha256 digest, không chỉ tag.
│      │         Cần để phát hiện image cùng tag nhưng khác digest (tag `:latest` bị
│      │         đẩy đè nhiều lần ⟹ nhiều layer mồ côi tích tụ ăn disk).
│      └─ images : liệt kê image mà CRI (kubelet) nhìn thấy.
└─ crictl : CLI chuẩn CRI. ⭐ Đây là công cụ ĐÚNG cho k8s, vì nó chỉ nhìn namespace `k8s.io`.

crictl images -q | wc -l
├─ -q (--quiet) : chỉ in ID, mỗi dòng một image ⟹ đếm bằng wc -l cho ra số image.
└─ wc -l : đếm số dòng.

ctr -n k8s.io images list -q
│   │
│   └─ -n NAMESPACE : ⭐⭐ ĐIỂM SỐNG CÒN CỦA PHIÊN NÀY.
│      containerd chia namespace tách biệt hoàn toàn:
│        • `k8s.io`  → image/container của kubelet (pod k8s)
│        • `default` → image/container của nerdctl (⟹ n8n trên .51 NẰM Ở ĐÂY)
│      Hai namespace KHÔNG thấy nhau. Nghĩa là: xóa image trong `k8s.io`
│      KHÔNG đụng tới n8n. Nhưng PHẢI verify bằng lệnh 1.6 trước khi tin.
└─ ctr : CLI cấp thấp của containerd (thấp hơn crictl, thấy được cả namespace khác).

So sánh crictl vs ctr:
├─ crictl → chỉ k8s.io, an toàn, dùng để xem/dọn image của pod
└─ ctr    → thấy mọi namespace, mạnh hơn nhưng dễ gây tai nạn ⟹ luôn kèm -n rõ ràng
```
</details>

### 1.6 — ⭐ SỐNG CÒN: xác định n8n trên `.51` nằm ở containerd namespace nào

**Chạy TRÊN node `.51`, bằng user `root`** (`su -` trước, KHÔNG dùng `sudo nerdctl`):

```bash
su -
```

```bash
nerdctl ps -a
```

```bash
nerdctl images
```

```bash
nerdctl namespace ls
```

```bash
ctr namespaces list
```

```bash
ctr -n default containers list
```

```bash
ctr -n k8s.io containers list | wc -l
```

Gộp một lượt ghi ra file (vẫn ở user root):

```bash
{ echo "=== NERDCTL PS -A ==="; nerdctl ps -a; echo "=== NERDCTL IMAGES ==="; nerdctl images; echo "=== NERDCTL NAMESPACE LS ==="; nerdctl namespace ls; echo "=== CTR NAMESPACES ==="; ctr namespaces list; echo "=== CTR -n default CONTAINERS ==="; ctr -n default containers list; } 2>&1 | tee /tmp/vrp-n8n-namespace.txt
```

<details>
<summary>Giải nghĩa lệnh 1.6 — vì sao lệnh này chạy TRƯỚC mọi lệnh dọn dẹp</summary>

```
⚠️ PHẢI Ở USER root (`su -`). KHÔNG dùng `sudo nerdctl` — Kiên xác nhận cách dùng
   trên cụm này là su sang root rồi gõ `nerdctl` trần.

nerdctl ps -a
├─ ps    : liệt kê container nerdctl đang chạy ⟹ ⭐ tìm container n8n ở đây
└─ -a (--all) : gồm cả container đã dừng.
   Cần -a để thấy container n8n cũ đã stop (chúng vẫn giữ image ⟹ image không bị coi
   là "unused" ⟹ ảnh hưởng tính toán khi prune).
   ⭐ Cột cần ghi lại: IMAGE (tên đầy đủ + tag) và NAMES của n8n — để sau này lập
      danh sách image CẤM XÓA.

nerdctl images
└─ Liệt kê image trong namespace mặc định mà nerdctl đang dùng.
   ⭐ Ghi lại image của n8n vào mục 2.2 — đây là danh sách bảo vệ.

nerdctl namespace ls
└─ ⭐⭐ LỆNH QUYẾT ĐỊNH. Cho biết nerdctl đang làm việc ở namespace nào và có bao nhiêu
   container/image mỗi namespace. Nếu n8n nằm ở `default` ⟹ tách biệt hoàn toàn với
   pod k8s (`k8s.io`) ⟹ dọn image k8s.io AN TOÀN.
   Nếu n8n nằm ở `k8s.io` ⟹ NGUY HIỂM, image GC của kubelet có thể xóa image n8n.

ctr namespaces list
└─ Liệt kê tất cả namespace của containerd trên node. Kỳ vọng thấy ít nhất:
   `k8s.io` (kubelet) và `default` (nerdctl). Nếu n8n được deploy với
   `nerdctl --namespace k8s.io` thì nó NẰM CHUNG với pod k8s ⟹ image GC của kubelet
   CÓ THỂ xóa image n8n ⟹ tình huống nguy hiểm, phải đổi chiến lược.

ctr -n default containers list
└─ Liệt kê container trong namespace default. Nếu thấy n8n ở đây ⟹ THỞ PHÀO:
   dọn image trong k8s.io hoàn toàn không đụng tới nó.

{ lệnh1; lệnh2; ...; } 2>&1 | tee FILE
├─ { ...; } : gom nhiều lệnh thành một khối, để `| tee` nhận output của CẢ KHỐI
│             chứ không chỉ lệnh cuối. ⚠️ Bắt buộc có dấu `;` trước `}`.
├─ 2>&1     : gộp stderr vào stdout ⟹ lỗi cũng lọt vào file thay vì bay mất
└─ tee FILE : vừa in màn hình vừa ghi file ⟹ VDI chặn clipboard thì vẫn xem lại được

⚠️ KẾT LUẬN CẦN RÚT RA TỪ LỆNH NÀY (ghi vào mục 2.2 trước khi làm gì tiếp):
   n8n nằm ở namespace ......... ⟹ dọn image k8s.io [CÓ / KHÔNG] ảnh hưởng n8n.
```
</details>

### 1.7 — ⭐ Xác định node nào THÔNG tới registry (quyết định node nào được phép dọn image)

```bash
for n in 48 49 50 51 52 53 54 55; do
  printf "10.208.137.%s : " "$n"
  ssh -o ConnectTimeout=5 10.208.137.$n 'timeout 10 curl -sk -o /dev/null -w "HTTP=%{http_code} connect=%{time_connect}s total=%{time_total}s\n" https://10.60.170.184:8083/v2/ || echo "KHONG THONG"'
done 2>&1 | tee /tmp/vrp-registry-reachability.txt
```

<details>
<summary>Giải nghĩa lệnh 1.7</summary>

```
printf "10.208.137.%s : " "$n"
└─ Dùng printf thay echo vì printf KHÔNG tự xuống dòng ⟹ kết quả curl in tiếp
   ngay trên cùng một dòng ⟹ mỗi node đúng một dòng, dễ đọc.

ssh -o ConnectTimeout=5
└─ -o OPTION=VALUE : truyền tuỳ chọn ssh_config ngay trên dòng lệnh.
   ConnectTimeout=5 ⟹ node chết thì bỏ qua sau 5 giây thay vì treo vài phút.

timeout 10 curl ...
└─ timeout N LỆNH : giết lệnh sau N giây. Lớp bảo vệ thứ hai (ssh timeout chỉ lo
   khâu kết nối SSH, không lo curl treo bên trong node).

curl -sk -o /dev/null -w "..."
├─ -s (--silent)      : tắt thanh tiến trình + thông báo lỗi ⟹ output sạch để so sánh
├─ -k (--insecure)    : ⭐ BỎ QUA verify chứng chỉ TLS. Cần vì registry nội bộ dùng
│                       self-signed cert — đây chính là lý do lệnh pull thủ công phải
│                       kèm `--skip-verify=true`.
├─ -o /dev/null       : vứt body đi, ta chỉ cần biết CÓ KẾT NỐI ĐƯỢC KHÔNG
└─ -w "FORMAT"        : (--write-out) in các biến đo được SAU khi xong.
    ├─ %{http_code}     → mã HTTP. ⭐ `/v2/` của Docker Registry API trả **200 hoặc 401**
    │                     đều nghĩa là THÔNG (401 = tới nơi nhưng cần auth).
    │                     000 = không kết nối được ⟹ KHÔNG THÔNG.
    ├─ %{time_connect}  → thời gian bắt tay TCP. Cao bất thường ⟹ nghi route/firewall chậm.
    └─ %{time_total}    → tổng thời gian.

|| echo "KHONG THONG" : curl thất bại (exit ≠ 0) ⟹ in rõ ràng thay vì dòng trống.

⚠️ Nếu registry chạy HTTP (không TLS) thì đổi https:// thành http://. Thử cả hai nếu cần.

⚠️ QUY TẮC RÚT RA:
   Node "KHONG THONG"  ⟹ 🚫 TUYỆT ĐỐI KHÔNG xóa image trên node đó.
   Node "HTTP=200/401" ⟹ ✅ có thể dọn image an toàn (kéo lại được).
```
</details>

### 1.8 — Chứng minh kubelet image GC là thủ phạm (không phải đoán)

```bash
ssh 10.208.137.<NODE> 'sudo journalctl -u kubelet --since "7 days ago" | grep -iE "evict|DiskPressure|ImageGC|garbage|free.*disk|failed to garbage" | tail -80'
```

<details>
<summary>Giải nghĩa lệnh 1.8</summary>

```
journalctl -u kubelet --since "7 days ago"
│          │          └─ --since "..." : lọc từ mốc thời gian. Nhận cả chuỗi tự nhiên
│          │             ("7 days ago", "2026-08-20 10:00:00").
│          │             ⚠️ Ghi nhớ từ phiên trước: `--until-time` là cờ của KUBECTL và
│          │                KHÔNG tồn tại; còn journalctl thì có `--until` (khác tên).
│          └─ -u UNIT : chỉ lấy log của systemd unit tên `kubelet`, bỏ qua log toàn hệ thống.
│
grep -iE "pattern1|pattern2|..."
├─ -i : không phân biệt hoa thường (kubelet log lúc "DiskPressure" lúc "diskPressure")
└─ -E : bật regex mở rộng ⟹ dùng được `|` (hoặc) mà không phải escape thành `\|`
        (Các cờ họ hàng: -F = chuỗi thuần không regex; -o = chỉ in phần khớp.)

tail -80
└─ -N : 80 dòng CUỐI (mới nhất). Log kubelet 7 ngày có thể hàng trăm nghìn dòng.

⭐ CÁC DÒNG CẦN TÌM (bằng chứng chốt vòng lặp sự cố):
├─ "attempting to reclaim ephemeral-storage"      → kubelet bắt đầu đòi lại disk
├─ "Eviction manager: must evict pod(s)"          → chứng minh CÓ evict thật
├─ "ImageGCFailed" / "failed to garbage collect"  → GC chạy nhưng thất bại
└─ "Disk usage on image filesystem is at X% which is over the high threshold (85%)"
                                                  → ⭐ dòng vàng: nói rõ NGƯỠNG và % thật.
                                                    Mặc định k8s: imagefs high = 85%,
                                                    tức GC KHỞI ĐỘNG ở 85%, không phải 100%.
```
</details>

### 1.9 — Pod đang ImagePullBackOff và nằm ở node nào

```bash
kubectl get pods -A -o wide | grep -E "ImagePull|ErrImage|Evicted|CrashLoop" | tee /tmp/vrp-broken-pods.txt
```

```bash
kubectl get pods -A --field-selector=status.phase=Failed -o wide | awk '{print $8}' | sort | uniq -c | sort -rn
```

<details>
<summary>Giải nghĩa lệnh 1.9</summary>

```
kubectl get pods -A -o wide
├─ -A (--all-namespaces) : mọi namespace. (Viết dài: --all-namespaces)
└─ -o wide : thêm cột NODE + IP ⟹ ⭐ cần thiết để biết pod hỏng TẬP TRUNG ở node nào.
             Đây là cách nhanh nhất quy chiếu triệu chứng về đúng node bệnh.

grep -E "ImagePull|ErrImage|Evicted|CrashLoop"
└─ 4 triệu chứng khác nhau, gom một lượt:
   ├─ ImagePullBackOff → đã thử pull, thất bại, đang backoff (chờ lâu dần)
   ├─ ErrImagePull     → lần pull đầu vừa lỗi (giai đoạn trước BackOff)
   ├─ Evicted          → ⭐ dấu vết TRỰC TIẾP của disk/memory pressure
   └─ CrashLoopBackOff → khác nhóm (lỗi app), lấy kèm để nhìn toàn cảnh

--field-selector=status.phase=Failed
└─ Lọc PHÍA SERVER (API server lọc rồi mới trả về), khác với grep là lọc phía client.
   Nhanh hơn nhiều trên cụm nhiều pod. Pod Evicted có phase = Failed.

awk '{print $8}' | sort | uniq -c | sort -rn
│         │         │      │        │
│         │         │      │        └─ sort -rn : -n so sánh theo SỐ (không phải chuỗi),
│         │         │      │           -r giảm dần ⟹ node nhiều pod hỏng nhất lên đầu.
│         │         └──────┴─ uniq -c : gộp dòng trùng + đếm.
│         │                   ⚠️ uniq CHỈ gộp dòng trùng LIỀN KỀ ⟹ BẮT BUỘC `sort` trước.
│         └─ sort : sắp xếp để dòng giống nhau nằm cạnh nhau.
└─ awk '{print $8}' : in cột thứ 8 (cột NODE trong output -o wide -A).
   ⚠️ Verify số cột trước: chạy thử không có awk, đếm cột. Output -A có thêm cột
      NAMESPACE ở đầu nên chỉ số cột lệch 1 so với khi không có -A.
```
</details>

### 1.10 — Cấu hình eviction threshold + image GC hiện tại của kubelet

```bash
ssh 10.208.137.<NODE> 'echo "=== KUBELET CONFIG FILE ==="; sudo grep -iE "eviction|imagegc|imageMinimum|nodefs|imagefs|reserved" /var/lib/kubelet/config.yaml; echo "=== KUBELET CMDLINE ==="; ps -ef | grep [k]ubelet | tr " " "\n" | grep -iE "eviction|image-gc|reserved"'
```

<details>
<summary>Giải nghĩa lệnh 1.10</summary>

```
grep -iE "eviction|imagegc|imageMinimum|nodefs|imagefs|reserved"
└─ Tìm các khoá cấu hình quyết định hành vi disk của kubelet.

Mặc định của k8s 1.23 (nếu KHÔNG thấy khoá nào ⟹ đang dùng mặc định này):
├─ evictionHard.nodefs.available   = 10%  → dưới 10% thì evict pod
├─ evictionHard.imagefs.available  = 15%  → dưới 15% thì evict + GC image
├─ imageGCHighThresholdPercent     = 85   → ⭐ vượt 85% là BẮT ĐẦU xóa image
├─ imageGCLowThresholdPercent      = 80   → xóa cho tới khi về 80% thì dừng
└─ imageMinimumGCAge               = 2m0s → image mới hơn 2 phút thì tha

⭐ ĐÒN BẨY CHÍNH CHO CỤM AIRGAP:
   `imageMinimumGCAge` mặc định chỉ 2 PHÚT — quá ngắn. Trên cụm airgap, image bị xóa
   là mất luôn (không pull lại được). Nâng giá trị này lên (ví dụ 168h = 7 ngày)
   khiến GC không dám đụng image, ĐỔI LẤY việc disk phải được dọn bằng cách khác.
   Đây là đánh đổi có chủ đích, không phải fix miễn phí.

ps -ef | grep [k]ubelet
│         │
│         └─ [k]ubelet : mẹo cũ — đặt ký tự đầu vào ngoặc vuông biến nó thành character
│            class regex khớp đúng "k", nhưng CHUỖI LỆNH grep tự nó lại là "[k]ubelet"
│            nên KHÔNG tự khớp chính nó ⟹ output không có dòng rác `grep kubelet`.
│            Thay cho cách viết dài `| grep kubelet | grep -v grep`.
│
tr " " "\n"
└─ tr SET1 SET2 : thay từng ký tự SET1 bằng SET2. Ở đây đổi dấu cách thành xuống dòng
   ⟹ mỗi tham số dòng lệnh của kubelet thành MỘT DÒNG ⟹ grep bắt được từng cờ riêng lẻ
   (nếu để nguyên một dòng dài thì grep trả về cả dòng khổng lồ, không đọc nổi).

⚠️ Cờ trên cmdline ĐÈ LÊN config.yaml ⟹ phải xem cả hai, không chỉ file config.
```
</details>

### 1.11 — ⭐ TRUY 45G CÒN THIẾU trên `.51` (user root)

```bash
du -shx /* 2>/dev/null | sort -rh | head -20
```

```bash
du -shx /var/* 2>/dev/null | sort -rh | head -20
```

```bash
lsof -nP 2>/dev/null | awk '$5=="REG" && /deleted/ {s+=$7} END {printf "File da xoa nhung process con giu: %.2f GB\n", s/1024/1024/1024}'
```

```bash
find / -xdev -type f -size +1G -exec ls -lh {} \; 2>/dev/null | awk '{print $5, $9}' | sort -rh | head -20
```

```bash
du -sh /var/lib/containerd/io.containerd.content.v1.content /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs 2>/dev/null
```

<details>
<summary>Giải nghĩa lệnh 1.11</summary>

```
du -shx /* | sort -rh | head -20
│  ││││  │
│  ││││  └─ /* : shell tự bung thành danh sách mọi thư mục cấp 1 (/bin /boot /etc /home /opt ...).
│  ││││       Dùng /* thay vì / vì `du -sh /` chỉ cho MỘT con số tổng, không chỉ ra thủ phạm.
│  │││└─ -x : ⭐ không vượt sang filesystem khác. Bắt buộc — nếu không sẽ bò vào /proc, /sys,
│  │││        và mọi mount PV, cho số vô nghĩa và chạy rất lâu.
│  ││└─ -h : human readable
│  │└─ -s : chỉ in tổng mỗi mục
└──┴─ head -20 : 20 dòng đầu (sau sort -rh là 20 thư mục to nhất)

lsof -nP | awk '$5=="REG" && /deleted/ {s+=$7} END {...}'
│    ││
│    │└─ -P : không đổi số port sang tên dịch vụ (nhanh hơn, tránh tra /etc/services)
│    └─ -n : không resolve IP sang hostname (⭐ tránh treo lệnh khi DNS chậm — cụm airgap
│            rất hay bị treo ở bước resolve này)
│
│ ⭐ VÌ SAO CẦN LỆNH NÀY — bẫy kinh điển:
│   File bị `rm` nhưng process vẫn đang mở nó ⟹ inode chưa được giải phóng ⟹
│   **`du` KHÔNG đếm** (file không còn trong cây thư mục) nhưng **`df` VẪN tính**.
│   ⟹ Đây là nguyên nhân số 1 của chênh lệch "df nói đầy, du nói không".
│   Triệu chứng khớp chính xác với 45G đang thiếu.
│   Cách sửa: restart process đang giữ fd (KHÔNG phải xóa file — file đã xóa rồi).
│
awk '$5=="REG" && /deleted/ {s+=$7} END {printf ...}'
├─ $5=="REG"   : chỉ lấy dòng file thường (REG = regular file), bỏ socket/pipe/dir
├─ /deleted/   : dòng có chữ "(deleted)" — file đã bị xóa nhưng fd còn mở
├─ {s+=$7}     : cộng dồn cột 7 (SIZE, đơn vị byte)
└─ END{...}    : sau khi duyệt hết mới in, chia 1024³ ra GB

find / -xdev -type f -size +1G -exec ls -lh {} \;
│      │ │     │       │         │
│      │ │     │       │         └─ -exec LỆNH {} \; : chạy lệnh cho từng file tìm được.
│      │ │     │       │            `{}` là chỗ thay tên file, `\;` kết thúc (phải escape
│      │ │     │       │            dấu ; để shell không nuốt mất).
│      │ │     │       └─ -size +1G : lớn hơn 1 GiB. Dấu `+` = "lớn hơn" (`-` = nhỏ hơn,
│      │ │     │          không dấu = đúng bằng).
│      │ │     └─ -type f : chỉ file thường, bỏ thư mục/symlink
│      │ └─ -xdev : ⭐ CÙNG Ý NGHĨA với `-x` của du — không vượt filesystem.
│      │            (find dùng tên `-xdev`, du dùng `-x` — khác tên, cùng tác dụng.)
│      └─ / : bắt đầu từ gốc
└─ Mục đích: tìm file đơn lẻ khổng lồ (image tarball import tay, core dump, log app,
   backup .sql, file swap) mà `du -sh` theo thư mục có thể làm mờ đi.

du -sh /var/lib/containerd/io.containerd.content.v1.content
                          /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
└─ Bóc 38G containerd thành 2 phần để biết dọn kiểu nào có tác dụng:
   ├─ content/    → blob layer đã tải về (image store). `nerdctl rmi` dọn phần này.
   └─ snapshots/  → filesystem của container đang/đã chạy. Chỉ dọn được khi xóa container.
   Nếu snapshots to bất thường ⟹ có nhiều container chết chưa xóa.
```
</details>

### 1.12 — ⭐ Đo CẢ HAI registry, trên **5 WORKER** (.51→.55)

⚠️ Phát hiện: cụm dùng **ít nhất 2 registry** — `10.60.170.184:8083` và
`10.208.137.65:8890` (registry sau xuất hiện trong hầu hết image của `nerdctl images`).

> **Vì sao chỉ 5 worker, không phải 8 node** (Kiên chỉnh 2026-08-21): workload nằm hết ở
> 5 worker `.51`–`.55`; 3 master `.48`–`.50` không chạy gì của mình. Master vẫn có kubelet +
> image GC và chạy pod hệ thống (apiserver/etcd/CNI/kube-proxy) nên **về lý thuyết vẫn có
> rủi ro** — nhưng cả 3 đang `DiskPressure=False`, disk chỉ ~49G ⟹ **không gấp, để sau.**

```bash
for n in 51 52 53 54 55; do printf "10.208.137.%-3s " "$n"; ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no 10.208.137.$n 'printf "R1(184:8083)="; timeout 8 curl -sk -o /dev/null -w "%{http_code}" https://10.60.170.184:8083/v2/ 2>/dev/null || printf "FAIL"; printf "  R2(65:8890)="; timeout 8 curl -sk -o /dev/null -w "%{http_code}" https://10.208.137.65:8890/v2/ 2>/dev/null || printf "FAIL"; echo' 2>/dev/null || echo "SSH FAIL"; done | tee /tmp/vrp-registry-2reg.txt
```

<details>
<summary>Giải nghĩa lệnh 1.12</summary>

```
printf "10.208.137.%-3s " "$n"
└─ %-3s : chuỗi, căn TRÁI (dấu `-`), rộng tối thiểu 3 ký tự ⟹ các cột thẳng hàng
   dù số node là 48 hay 5. (%3s không có dấu trừ = căn phải.)

ssh -o StrictHostKeyChecking=no
└─ Không hỏi "xác nhận host key?" ở lần SSH đầu tới node mới ⟹ loop không bị treo
   chờ gõ yes. Chấp nhận được ở đây vì đang SSH trong mạng nội bộ đã biết rõ.

timeout 8 curl -sk -o /dev/null -w "%{http_code}"
└─ Chỉ in mã HTTP, không xuống dòng (không có \n trong -w) ⟹ nối vào printf trước đó
   cho ra một dòng gọn cho mỗi node.

Đọc kết quả:
├─ 200 hoặc 401 ⟹ ✅ THÔNG (401 = tới nơi, chỉ thiếu auth)
├─ 000          ⟹ 🚫 KHÔNG THÔNG (không kết nối được)
└─ FAIL         ⟹ 🚫 curl lỗi hẳn

⚠️ Nếu registry chạy HTTP thuần thì đổi https:// → http://.
   Registry `65:8890` chưa rõ dùng scheme nào — nếu ra 000 với https, thử lại http.

⭐ QUY TẮC SỐNG CÒN:
   Node KHÔNG thông ⟹ 🚫 CẤM xóa image trên node đó (airgap, xóa là mất vĩnh viễn).
```
</details>

### 1.13 — Xem 67 image rác trong namespace `default` (user root, trên `.51`)

```bash
nerdctl images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}' | sort -rh | head -40
```

```bash
nerdctl system df
```

<details>
<summary>Giải nghĩa lệnh 1.13</summary>

```
nerdctl images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}'
│              │
│              └─ --format 'GO_TEMPLATE' : tự chọn cột theo cú pháp Go template.
│                 Dùng thay output mặc định để: (a) đưa Size lên ĐẦU ⟹ `sort -rh` sắp được,
│                 (b) bỏ cột thừa cho gọn màn hình VDI.
│                 Các trường dùng được: .Repository .Tag .ID .Size .CreatedSince .Platform
│
sort -rh
└─ -h hiểu hậu tố GiB/MiB ⟹ sắp đúng. Không có -h thì "990 MiB" > "1.5 GiB" (sai).

nerdctl system df
└─ Tổng hợp dung lượng theo nhóm: Images / Containers / Volumes,
   kèm cột RECLAIMABLE = ⭐ dọn được bao nhiêu.
   Đây là con số cần để ước lượng lợi ích TRƯỚC khi dọn — biết trước sẽ thu về bao nhiêu GB.

⚠️ TUYỆT ĐỐI KHÔNG chạy `nerdctl system prune -a` — nó xóa hết image không gắn container
   đang chạy. n8n chỉ dùng 2 image, nhưng prune -a cũng sẽ xóa luôn image dự phòng và
   KHÔNG THỂ kéo lại nếu node mất kết nối registry. Phải xóa CÓ CHỌN LỌC bằng `nerdctl rmi`.
```
</details>

### 1.14 — ⭐⭐ BÓC 23G trong `/var` + 16G trong `/home` (user root, `.51`)

Đây là **đòn bẩy lớn nhất hiện tại** (~42G tiềm năng, so với image nerdctl chưa rõ bao nhiêu).

```bash
du -shx /var/* 2>/dev/null | sort -rh | head -15
```

```bash
du -shx /home/* /root/* 2>/dev/null | sort -rh | head -15
```

```bash
find /home /root -xdev -type f -size +200M -exec ls -lh {} \; 2>/dev/null | awk '{print $5"\t"$6" "$7" "$8"\t"$9}' | sort -rh | head -25
```

```bash
du -shx /var/lib/* 2>/dev/null | sort -rh | head -15
```

<details>
<summary>Giải nghĩa lệnh 1.14</summary>

```
du -shx /var/*   (thay vì /var)
└─ `/var/*` bung thành /var/lib, /var/log, /var/cache, /var/tmp...
   ⟹ chỉ ra thư mục con nào ăn 23G, thay vì một con số tổng 61G vô dụng.
   Vẫn giữ -x để không bò sang mount point khác.

du -shx /var/lib/*
└─ Đào sâu thêm một tầng. Kỳ vọng thấy:
   ├─ containerd  38G  (đã biết)
   ├─ docker      ?    ⭐ nếu có ⟹ Docker CŨ còn sót trước khi chuyển sang containerd.
   │                     Cụm 3 năm tuổi rất dễ dính. Đây là rác THUẦN TÚY, dọn được hết.
   ├─ etcd        ?    (thường chỉ có ở master, nếu có ở worker thì lạ)
   ├─ rancher / longhorn ?  (nếu cụm từng dùng Rancher/Longhorn)
   └─ kubelet     352K (đã biết, không đáng kể)

find /home /root -xdev -type f -size +200M -exec ls -lh {} \;
│                 │            │
│                 │            └─ -size +200M : lớn hơn 200 MiB. Hạ ngưỡng từ 1G xuống 200M
│                 │               vì 16G có thể là nhiều file vừa vừa, không phải một file to.
│                 └─ -xdev : không vượt filesystem (tương đương -x của du)
│
awk '{print $5"\t"$6" "$7" "$8"\t"$9}'
└─ Bóc output `ls -lh` lấy 3 nhóm cột:
   ├─ $5        → SIZE (dung lượng)
   ├─ $6 $7 $8  → ngày tháng năm sửa đổi ⭐ QUAN TRỌNG: file 2 năm không đụng ⟹ dọn được
   └─ $9        → đường dẫn file
   Có ngày tháng mới quyết định được file nào bỏ đi an toàn.

⭐ KỲ VỌNG TÌM THẤY ở /home và /root (cụm airgap 3 năm tuổi):
   ├─ *.tar / *.tar.gz  → image tarball import tay (`ctr images import`). Sau khi import
   │                       xong thì tarball là RÁC — image đã nằm trong containerd rồi.
   │                       ⭐ Đây là nghi phạm số 1, và dọn được với rủi ro gần bằng 0.
   ├─ *.sql / *.dump    → backup database để quên
   ├─ *.log             → log ứng dụng ngoài /var/log
   └─ thư mục source / helm chart / kube backup

⚠️ KHÔNG XÓA GÌ Ở BƯỚC NÀY. Chỉ liệt kê để Kiên xác nhận từng thứ có ai cần không.
```
</details>

### 1.15 — ⭐ Verify: 69 image là 69 BẢN THẬT hay chỉ nhiều TAG trỏ chung? (user root, `.51`)

Quyết định lợi ích thật của việc dọn image. Nếu chỉ là nhiều tag ⟹ dọn không thu về mấy GB.

```bash
nerdctl images --format '{{.ID}}' | sort | uniq -c | sort -rn | head -20
```

```bash
echo "So dong image (ke ca tag trung): $(nerdctl images -q | wc -l)"; echo "So IMAGE ID DUY NHAT: $(nerdctl images --format '{{.ID}}' | sort -u | wc -l)"
```

```bash
du -sh /var/lib/containerd/io.containerd.content.v1.content 2>/dev/null; du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs 2>/dev/null
```

<details>
<summary>Giải nghĩa lệnh 1.15</summary>

```
nerdctl images --format '{{.ID}}' | sort | uniq -c | sort -rn
└─ Đếm mỗi Image ID xuất hiện bao nhiêu lần.
   ├─ Nếu ra toàn số 1  ⟹ 69 image THẬT SỰ khác nhau ⟹ dọn thu về nhiều
   └─ Nếu ra 2, 3       ⟹ ⭐ cùng image nhiều tag ⟹ **cột Size bị đếm trùng**,
                            lợi ích dọn NHỎ HƠN nhiều so với tổng cột Size.
   (Dấu hiệu đã thấy: `bitnami/kafka` và `.../vmlp/bitnami/kafka` cùng ID `5a85aeb27ffa`.)

So sánh 2 con số:
├─ `nerdctl images -q | wc -l`              → số DÒNG (mỗi tag một dòng)
└─ `nerdctl images --format '{{.ID}}' | sort -u | wc -l`  → số IMAGE ID DUY NHẤT
   Chênh lệch giữa hai số = số tag thừa. ⭐ Đây là con số nói thật.

sort -u
└─ -u (--unique) : loại dòng trùng ngay trong lúc sort ⟹ gọn hơn `sort | uniq`.

du -sh .../io.containerd.content.v1.content       → blob layer thật (image store)
du -sh .../io.containerd.snapshotter.v1.overlayfs → filesystem container đang/đã chạy
└─ ⭐ Hai con số này là SỰ THẬT về disk, không bị đếm trùng như cột Size của `nerdctl images`.
   Cộng lại phải xấp xỉ 38G. Tỷ lệ giữa chúng cho biết dọn kiểu nào có tác dụng:
   ├─ content lớn      ⟹ image rác nhiều ⟹ `nerdctl rmi` có tác dụng
   └─ snapshots lớn    ⟹ container chết chưa xóa ⟹ phải xóa container trước
```
</details>

---

## 2. Kết quả thu thập (điền sau khi chạy)

### 2.1 Bảng tài nguyên node — ✅ ĐÃ CHẠY 2026-08-21

Nguồn: `kubectl get nodes -o custom-columns=...` (user `app` trên `.51`).

| Node | IP | Role | CPU | RAM | Disk capacity | Disk used % | Inode used % | DiskPressure | Thông registry |
|---|---|---|---|---|---|---|---|---|---|
| vrp-kubeengine01 | .48 | master | 4 | 8008432Ki (~7.6G) | 51473868Ki (~49G) | ? | ? | False | ? |
| vrp-kubeengine02 | .49 | master | 4 | 8008424Ki (~7.6G) | 51473868Ki (~49G) | ? | ? | False | ? |
| vrp-kubeengine03 | .50 | master | 4 | 8008432Ki (~7.6G) | 51473868Ki (~49G) | ? | ? | False | ? |
| **vrp-kubeengine04** | **.51** | worker ⚠️ n8n | 8 | 16265348Ki (~15.5G) | 103079844Ki (~98G) | **88%** | 24% | 🔴 **True** | ✅ **HTTP=401, 0.208s** |
| vrp-kubeengine05 | .52 | worker | 8 | 16265356Ki (~15.5G) | 103079844Ki (~98G) | ? | ? | False | ? |
| vrp-kubeengine06 | .53 | worker | 16 | 32778180Ki (~31G) | 206291924Ki (~197G) | ? | ? | False | ? |
| vrp-kubeengine07 | .54 | worker | 8 | 16265356Ki (~15.5G) | 103079844Ki (~98G) | ? | ? | False | ? |
| vrp-kubeengine08 | .55 | worker | 16 | 32778180Ki (~31G) | 206291924Ki (~197G) | ? | ? | False | ? |

- **`maxPods = 50` trên MỌI node** (không phải 110 mặc định) ⟹ trần pod thấp, đáng lưu ý khi
  hàng chục pod `Evicted` không được dọn vẫn chiếm slot.
- Cụm **không đồng nhất**: master yếu (4C/8G/49G), worker chia 2 hạng
  (8C/16G/98G vs 16C/32G/197G) ⟹ scheduling lệch tải là rủi ro thật.
- 🔴 **Node đang `DiskPressure=True` là `.51` (kubeengine04)** — chính là node 88% disk + chạy n8n.
  Các node khác `False`. Nhưng pod hỏng nằm rải khắp `.53`/`.54`/`.55`
  ⟹ **các node kia ĐÃ TỪNG DiskPressure rồi hồi lại**, để lại di chứng ImagePullBackOff
  (image bị GC xóa mất, không tự khỏi). Đây là bằng chứng cho vòng lặp ở mục 0.

> ⚠️ **ĐÍNH CHÍNH (2026-08-21):** bản ghi trước đọc nhầm thành `.52` DiskPressure=True.
> Đọc lệch dòng khi phân giải chuỗi CSV nén `False,False,True,False,True`. Kiên bắt lỗi.
> **Bài học:** bảng CSV nén nhiều cột phải đếm vị trí + **đối chiếu chéo với số liệu độc lập**.
> Ở đây `df` 88% trên `.51` đã mâu thuẫn với kết luận sai ngay từ đầu — lẽ ra phải bắt được.

### 2.1b Disk chi tiết `.51` (user root) — ✅ ĐÃ CHẠY

```
$ df -hT -x tmpfs -x devtmpfs
Filesystem     Type   Size  Used Avail Use% Mounted on
/dev/vda1      ext4    99G   83G   12G  88% /

$ df -i -x tmpfs -x devtmpfs
Filesystem      Inodes   IUsed   IFree IUse% Mounted on
/dev/vda1      6553600 1519494 5034106   24% /

$ du -shx /var/lib/containerd /var/lib/kubelet /var/log 2>/dev/null | sort -rh
38G     /var/lib/containerd
325M    /var/log
352K    /var/lib/kubelet
```

**Đọc ra được gì:**
- ✅ **KHÔNG phải vấn đề inode** (24%) ⟹ loại trừ giả thuyết cạn inode.
- ✅ **KHÔNG phải log** (325M) và **KHÔNG phải kubelet/emptyDir** (352K).
- 🔴 `/var/lib/containerd` = **38G** — thủ phạm lớn nhất đã xác định.
- ⚠️ **LỖ HỔNG CHƯA GIẢI THÍCH ĐƯỢC: 83G used − 38G containerd − 0.3G log ≈ 45G ở ĐÂU?**
  Chưa biết. **Phải tìm ra trước khi kết luận** — xem lệnh 1.11.
  Nghi ngờ: `/var/lib/docker` cũ còn sót, `/opt`, `/home`, `/root`, image tarball import tay,
  file log ứng dụng ngoài `/var/log`, hoặc file đã xóa nhưng process còn giữ fd.
- 88% > `imageGCHighThresholdPercent=85` ⟹ **GC ĐANG chạy liên tục trên `.51`** dù
  `DiskPressure=False` (GC khởi động ở 85%, còn DiskPressure là ngưỡng khác — 
  `imagefs.available<15%` tức used>85%... hiện avail 12G/99G = 12% ⟹ **sát mép**).

### 2.1c Registry reachability — ✅ ĐÃ CHẠY (mới `.51`)

```
$ curl -sk -o /dev/null -w "HTTP=%{http_code} total=%{time_total}s\n" https://10.60.170.184:8083/v2/
HTTP=401 total=0.208s
```
⟹ **`.51` THÔNG registry** (401 = tới nơi, cần auth). Còn 7 node chưa đo.

⚠️ **PHÁT HIỆN: có ÍT NHẤT 2 REGISTRY trong cụm, không phải 1 như đã ghi ban đầu:**
- `10.60.170.184:8083` — registry Kiên đưa lúc đầu (lệnh pull RAGFlow)
- `10.208.137.65:8890` — ⭐ registry xuất hiện trong **hầu hết** image của `nerdctl images`
  (`vmlp/litellm-database`, `vmlp/bitnami/*`, `vmlp/istio/*`, `vmlp/n8n`, `vmlp/prometheus`...)
  ⟹ Đây mới là registry dùng thường xuyên. **Phải đo reachability CẢ HAI.**

### 2.1d Pod hỏng — ✅ ĐÃ CHẠY

```
NAMESPACE      POD                                    STATUS                  AGE     NODE
ragflow        ragflow-755fc96fc6-f6w2p               Init:ImagePullBackOff   170m    vrp-kubeengine06
qdrant         qdrant-0                               Init:ErrImagePull       3d23h   vrp-kubeengine08
postgres-test  postgres-0                             ImagePullBackOff        7h27m   vrp-kubeengine07
open-webui     open-webui-deployment-5b5fb6dffb-g2ck4 ErrImagePull            27h     vrp-kubeengine08
monitoring     signoz-clickhouse-operator-...-4nxs9   ImagePullBackOff        5d22h   vrp-kubeengine07
monitoring     signoz-agent-k8s-infra-otel-agent-...  Evicted                 13m     vrp-kubeengine04
litellm        nginx-7d855f4db4-4vs2b                 ErrImagePull            3d23h   vrp-kubeengine08
litellm        litellm-96674b5d5-* (7 pod)            Evicted                 24d     vrp-kubeengine04
litellm        nginx-7d855f4db4-* (~9 pod)            Evicted                 8-14d   .51 / .55
monitoring     signoz-clickhouse-operator-* (5 pod)   Evicted                 6d19h   vrp-kubeengine07
```

**Đọc ra được gì:**
- 🔴 **RAGFlow ĐANG CHẾT** (`Init:ImagePullBackOff`, 170m, trên `.53`) — chính là hệ quả
  trực tiếp của vụ disk này.
- Pod `Evicted` **tuổi 24 ngày vẫn chưa được dọn** ⟹ rác tích tụ, ăn slot trong `maxPods=50`.
- `Init:` prefix ở ragflow/qdrant ⟹ chết ở **initContainer** (nhớ: values.yaml có
  `codePatch` initContainer) ⟹ image của initContainer bị mất, không chỉ image chính.
- Trải đều 4 node ⟹ vấn đề **toàn cụm**, không phải một node lẻ.

### 2.1e Thông tin đăng nhập / thao tác (xác nhận 2026-08-21)

- SSH từ `.51` sang các node khác: **ĐƯỢC**. Hoặc SSH thẳng vào từng node cũng được
  (chỉ 5 worker, ít node).
- Trên `.51`: login user `vt_admin` → `su` → `su -` để thành root.
- User `app` dùng cho `kubectl`.

### 2.2 Kết luận n8n namespace — ✅ ĐÃ CHỐT 2026-08-21

```
$ nerdctl namespace ls
NAME      CONTAINERS  IMAGES  VOLUMES
default   2           69      2
k8s.io    35          12      0

$ ctr namespaces list
NAME     LABELS
default
k8s.io
```

```
$ nerdctl ps -a
CONTAINER ID   IMAGE                                     STATUS  PORTS                        NAMES
a4d311916c34   docker.io/n8nio/n8n:1.123.38-curl         Up      10.208.137.51:8827->5678/tcp n8n_nerdctl_n8n_1
af16685f4334   10.208.137.65:8890/vmlp/postgres:16.4     Up      10.208.137.51:8828->5432/tcp n8n_nerdctl_postgres_1
```

- n8n nằm ở containerd namespace: **`default`**
- Pod k8s nằm ở namespace: **`k8s.io`** ✅ đã xác nhận
- ⟹ Dọn image trong `k8s.io` có ảnh hưởng n8n không? **[ ] CÓ  [✅] KHÔNG**

**Danh sách image CẤM XÓA trên `.51`** (n8n stack đang chạy):

| Image (repo:tag) | Image ID | Size | Container đang dùng |
|---|---|---|---|
| `docker.io/n8nio/n8n:1.123.38-curl` | `b3c147fbfb46` | 1.4 GiB | `n8n_nerdctl_n8n_1` (Up 3 months) |
| `10.208.137.65:8890/vmlp/postgres:16.4` | `07ad6d638531` | 436.2 MiB | `n8n_nerdctl_postgres_1` (Up 3 months) |

⚠️ Ngoài 2 image trên, còn **2 volume** trong namespace `default` (`VOLUMES 2`) — gần như chắc
chắn là data của n8n + postgres. **TUYỆT ĐỐI KHÔNG chạy `nerdctl volume prune`.**

### 2.2b ⭐⭐ PHÁT HIỆN LỚN — LẬT NGƯỢC GIẢ THUYẾT BAN ĐẦU

```
default   CONTAINERS 2    IMAGES 69   ← 2 container mà 69 image!
k8s.io    CONTAINERS 35   IMAGES 12   ← 35 container mà chỉ 12 image!
```

**Hai điều bất thường, ngược chiều nhau:**

**(1) Namespace `default` (nerdctl) = 69 image cho 2 container ⟹ ~67 image RÁC.**
Đây mới là thủ phạm ăn disk chính, KHÔNG phải image k8s. Bằng chứng từ `nerdctl images`:
image tuổi **22-24 tháng**, nhiều bản trùng lặp, tổng cộng rất lớn —
`ghcr.io/berriai/litellm-database` 1.5 GiB ×2 bản, `n8n` 1.3-1.5 GiB ×**7 bản**
(`1.122.5`, `custom`, `1.123.27`, `1.123.27-curl`, `1.123.38`, `1.123.38-curl`, `v0`, `fix-no-tracing`),
`codev-version-api:latest` 1.1 GiB, `langfuse` 909 MiB, `mysql` 871 MiB, `bitnami/kafka` 571 MiB...

⭐ **kubelet image GC KHÔNG NHÌN THẤY namespace `default`** — nó chỉ quản `k8s.io`.
⟹ 67 image rác này **không bao giờ được dọn tự động**, tích tụ tự do suốt 3 năm.
⟹ Chúng đẩy disk lên 88%, khiến GC phải quét sạch namespace `k8s.io` để bù.

**(2) Namespace `k8s.io` = chỉ 12 image cho 35 container ⟹ ĐÃ BỊ GC QUÉT SẠCH.**
35 container bình thường cần nhiều hơn 12 image. Con số thấp bất thường này chính là
**dấu vết image GC đã hoạt động mạnh**. Pod nào restart sau đó ⟹ ImagePullBackOff.

**⟹ CƠ CHẾ THẬT SỰ CỦA SỰ CỐ (khác giả thuyết ban đầu ở mục 0):**

```
nerdctl (namespace `default`) tích 67 image rác, KHÔNG AI DỌN suốt 3 năm
   └─> disk lên 88%, vượt imageGCHighThreshold=85%
        └─> kubelet image GC kích hoạt — NHƯNG chỉ dọn được namespace `k8s.io`
             └─> GC xóa sạch image k8s (còn 12), KHÔNG đụng được 67 image rác gây ra vấn đề
                  └─> disk VẪN 88% (vì rác nằm ở `default`) ⟹ GC chạy lại, xóa tiếp
                       └─> pod restart ⟹ image không còn ⟹ ImagePullBackOff
```

**Đây là điểm mấu chốt:** GC đang **trừng phạt nhầm đối tượng**. Nó xóa image k8s (cần thiết,
đang dùng) trong khi thủ phạm thật (image nerdctl rác) nằm ngoài tầm với của nó.
Nghĩa là **dọn 67 image rác ở `default` sẽ giải quyết tận gốc**, và đó cũng là việc
**an toàn nhất** vì chỉ cần chừa đúng 2 image của n8n.

### 2.2c ✅ ĐÃ TRUY RA 45G — và nó KHÔNG phải fd rác

```
$ du -shx /* 2>/dev/null | sort -rh | head -20
61G     /var          ← containerd 38G nằm trong đây ⟹ CÒN 23G KHÁC trong /var
16G     /home         ← ⭐ THỦ PHẠM MỚI, hoàn toàn ngoài dự đoán ban đầu
3.4G    /root
3.0G    /usr
818M    /run
335M    /opt
327M    /boot
41M     /etc
19M     /tmp
16K     /lost+found
4.0K    /u01 /srv /mnt /media /data /backup_data

$ lsof -nP | awk '$5=="REG" && /deleted/ {s+=$7} END {...}'
File da xoa nhung process con giu: 0.02 GB     ← ❌ GIẢ THUYẾT fd RÁC BỊ LOẠI BỎ

$ nerdctl system df
FATA[0000] unknown subcommand "df" for "system"   ← nerdctl bản này KHÔNG có `system df`
```

**Cân đối lại:** 61 + 16 + 3.4 + 3.0 + 0.8 + 0.3 + 0.3 ≈ **85G** ≈ khớp 83G used ✅

**45G "bí ẩn" phân bổ như sau:**

| Nơi | Dung lượng | Trạng thái |
|---|---|---|
| `/var` ngoài containerd (61G − 38G) | **23G** | 🔴 **CHƯA BIẾT LÀ GÌ** — cần bóc tiếp |
| `/home` | **16G** | 🔴 **CHƯA BIẾT LÀ GÌ** — bất thường với node k8s |
| `/root` | 3.4G | Cần xem |
| `/usr` | 3.0G | Bình thường (hệ điều hành) |

- ❌ **Loại bỏ giả thuyết "file đã xóa mà process giữ fd"** — chỉ 0.02 GB, không đáng kể.
- ⚠️ `/var` = 61G nhưng lần đo trước `du` các thư mục con chỉ ra containerd 38G + log 325M
  + kubelet 352K ≈ 38.3G ⟹ **còn 23G trong `/var` chưa rõ nằm ở thư mục con nào.**
  Nghi: `/var/lib/docker` (Docker cũ còn sót từ trước khi chuyển containerd), `/var/lib/etcd`,
  `/var/cache`, `/var/lib/rancher`, `/var/lib/longhorn`.
- ⚠️ `/home` = 16G trên một node k8s là **bất thường** — nghi file người dùng để lại:
  image tarball (`.tar` import tay ở cụm airgap), backup `.sql`, log cũ, source code.
  ⭐ Nếu là tarball/backup thì đây là **16G dọn được ngay, rủi ro gần bằng 0** — sau khi
  xác nhận không ai cần.

⟹ **Đòn bẩy có thể lớn hơn dự tính:** 23G + 16G + 3.4G ≈ **42G tiềm năng**, so với việc
dọn image nerdctl. Nhưng phải biết chúng là GÌ trước — xem lệnh **1.14**.

### 2.2c-bis ✅ BÓC XONG TOÀN BỘ DISK `.51` — không còn ẩn số

```
$ du -shx /var/* | sort -rh | head
58G     /var/lib
1.3G    /var/spool
454M    /var/cache
325M    /var/log

$ du -shx /var/lib/* | sort -rh | head
38G     /var/lib/containerd
20G     /var/lib/nerdctl        ← ⭐ MỚI LỘ RA, chưa từng nằm trong danh sách nghi phạm
192M    /var/lib/rpm
20M     /var/lib/yum
352K    /var/lib/kubelet

$ du -shx /home/* /root/* | sort -rh | head
15G     /home/app               ← ⭐ tarball + backup + pgdata n8n
3.4G    /root/images            ← ⭐ tarball
388M    /home/vt_admin
9.2M    /root/sd-agent-4.8.rpm
188K×N  /home/backup_2026MMDD   ← ~15 thư mục, mỗi cái chỉ 184-188K, không đáng kể
```

**Bảng cân đối cuối cùng cho 83G used:**

| Mục | Size | Dọn được? |
|---|---|---|
| `/var/lib/containerd` | 38G | Một phần (xem 2.2d) |
| `/var/lib/nerdctl` | **20G** | 🔴 **PHẦN LỚN LÀ DATA n8n — KHÔNG ĐỤNG** |
| `/home/app` | 15G | ✅ ~13G tarball/backup — trừ pgdata sống |
| `/root/images` | 3.4G | ✅ tarball RAGFlow |
| `/usr` | 3.0G | ❌ hệ điều hành |
| `/var/spool` + `/var/cache` + `/var/log` | ~2G | Một phần |

⚠️ **`/var/lib/nerdctl` 20G là phát hiện quan trọng:** đây là nơi nerdctl lưu **volume data +
metadata**, TÁCH BIỆT khỏi `/var/lib/containerd`. Khớp với `nerdctl namespace ls` báo
`default` có **2 volume** ⟹ chính là data của n8n + postgres.
🔴 **TUYỆT ĐỐI KHÔNG `nerdctl volume prune` / không xóa `/var/lib/nerdctl`.**

### 2.2c-ter ⭐ DANH SÁCH TARBALL/BACKUP DỌN ĐƯỢC (~13-14G)

```
$ find /home /root -xdev -type f -size +200M -exec ls -lh {} \; | sort -rh
3.4G  Jul 31 10:55  /root/images/ragflow-v0264_custom.tar
1.4G  Mar 30 17:30  /home/app/workspace/n8n_nerdctl/n8n_backup_2026-03-30.sql
1.2G  May  8 17:16  /home/app/workspace/images/n8n.tar
1.2G  May 13 17:34  /home/app/workspace/images/n8n_nerdctl/n8n-curl.tar
1.2G  Mar 30 16:43  /home/app/workspace/images/n8nio.tar
1.2G  Aug  7 10:35  /home/app/rag_flow_backup_20260807.sql
1.1G  Dec 25 2025   /home/app/workspace/images/n8n_1_122_5.tar
1.0G  Aug 21 12:00  /home/app/persistent-data/n8n_20251218_2006/postgres/pgdata/base/16384/24993
862M  Jun 15 2025   /home/app/workspace/langfuse/langfuse-3.68.tar
700M  May 25 16:35  /home/app/signoz/signoz-images/signoz_images.zip
594M  Jul 27 16:01  /home/app/open-notebook/open-notebook-images.zip
567M  Jul 27 15:21  /home/app/open-notebook/open-notebook.tar
369M  Jul  7 16:02  /home/app/signoz-migrate/metrics_samples.native
263M  Apr  7 10:55  /home/app/workspace/images/n8n_curl.tar
261M  May 26 08:14  /home/app/signoz/ctr_signoz_images/zookeeper.tar
261M  May 25 16:35  /home/app/signoz/signoz-images/signoz_zookeeper_3.7.1.tar
256M  Jul  7 16:02  /home/app/signoz-migrate/metrics_timeseries.native
```

**Phân loại:**

| Nhóm | Ước tính | Đánh giá |
|---|---|---|
| **Image tarball** (`.tar`, `.zip`) — ragflow, n8n ×5, langfuse, signoz, open-notebook | **~10G** | ✅ **Rác thuần túy** nếu image đã import vào containerd. Verify bằng `nerdctl images` / `ctr -n k8s.io images ls` xem image tương ứng đã có chưa |
| **Backup SQL** — `n8n_backup_2026-03-30.sql` (1.4G), `rag_flow_backup_20260807.sql` (1.2G) | **~2.6G** | ⚠️ **Quyết định nghiệp vụ** — backup có nơi lưu khác không? Nếu đây là bản duy nhất thì phải chuyển đi trước khi xóa |
| **signoz-migrate `.native`** | ~0.6G | ⚠️ Dữ liệu migrate — hỏi còn cần không |

🔴🔴 **FILE TUYỆT ĐỐI KHÔNG ĐƯỢC ĐỤNG:**
```
1.0G  Aug 21 12:00  /home/app/persistent-data/n8n_20251218_2006/postgres/pgdata/base/16384/24993
```
- `pgdata/base/...` = **file dữ liệu PostgreSQL SỐNG** của n8n.
- **`Aug 21 12:00` = đang được GHI ngay lúc chạy lệnh** (hôm nay).
- ⚠️ **BẪY:** tên thư mục `n8n_20251218_2006` trông như backup cũ tháng 12/2025 —
  **nhưng timestamp nói ngược lại.** Đây là thư mục data đang hoạt động, chỉ đặt tên theo
  ngày khởi tạo. **Xóa = mất toàn bộ workflow n8n.**
- ⟹ Khi dọn `/home/app`, **PHẢI loại trừ `persistent-data/`.**

### 2.2d ⚠️ Image nerdctl: mỗi image có 2 TAG, chưa chắc là 2 BẢN SAO

`nerdctl images` cho thấy mọi image xuất hiện **2 lần** — tag ngắn và tag đầy đủ, **cùng size**:

```
909.3 MiB  langfuse/langfuse:3.68                            14 months ago
909.3 MiB  10.208.137.65:8890/vmlp/langfuse:3.68             14 months ago
871.9 MiB  mysql:9.3.0                                       13 months ago
871.9 MiB  10.208.137.65:8890/vmlp/mysql:9.3.0               13 months ago
871.9 MiB  10.208.137.65:8890/vmlp/library/mysql:9.3.0       13 months ago   ← thậm chí 3 tag
571.7 MiB  bitnami/kafka:2.8.1-debian-10-r99                 22 months ago
571.7 MiB  10.208.137.65:8890/vmlp/bitnami/kafka:...         22 months ago
```

🔴 **CẢNH BÁO — ĐỪNG CỘNG DỒN CỘT SIZE.** Rất có thể đây là **cùng một image mang nhiều tag**
(trỏ chung một Image ID, chung layer blob) chứ không phải nhiều bản sao.
Nếu đúng vậy: **xóa bớt một tag KHÔNG thu về GB nào** — layer chỉ thực sự được giải phóng
khi tag CUỐI CÙNG trỏ tới nó bị xóa.

### 2.2d-bis ✅ ĐÃ VERIFY — kết quả thật

```
$ echo "So dong: $(nerdctl images -q | wc -l)"
So dong: 71
$ echo "So Image ID duy nhat: $(nerdctl images --format '{{.ID}}' | sort -u | wc -l)"
So Image ID duy nhat: 47

$ du -sh /var/lib/containerd/io.containerd.content.v1.content
17G     .../io.containerd.content.v1.content          ← blob layer image
$ du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
22G     .../io.containerd.snapshotter.v1.overlayfs    ← ⭐ rootfs container
```

**Đọc ra được gì:**

1. **71 dòng / 47 Image ID** ⟹ có **24 tag thừa**, nhưng vẫn có **47 image thật**.
   Cảnh báo "đếm trùng" ở trên là **đúng nhưng không nghiêm trọng như lo ngại** —
   không phải 69→35, mà là 71→47.

2. ⭐⭐ **`snapshots` (22G) > `content` (17G)** — đây mới là phát hiện quan trọng.
   - `content` = blob layer của image ⟹ `nerdctl rmi` / `crictl rmi` dọn phần này.
   - `snapshots` = **filesystem của từng container** đang/đã chạy.
     Snapshot chỉ được giải phóng khi **CONTAINER bị xóa**, KHÔNG phải khi image bị xóa.
   - 35 container `k8s.io` + 2 container `default` + container chết chưa dọn đang giữ 22G.

   ⟹ 🔴 **`nerdctl rmi` / image GC một mình sẽ cho kết quả đáng thất vọng** —
   chỉ với tới được 17G, và chỉ phần không container nào tham chiếu.
   **Muốn thu hồi 22G snapshots thì phải dọn CONTAINER trước** (pod Evicted tồn đọng!).

   ⟹ Điều này cũng **giải thích vì sao image GC của kubelet chạy mãi mà disk không giảm**:
   nó xóa image (content) nhưng snapshot của container chết vẫn nằm nguyên đó.

3. **Liên hệ với ~20 pod `Evicted` tuổi 8-24 ngày:** mỗi pod Evicted vẫn còn container
   ở trạng thái exited, mỗi container giữ một snapshot ⟹ **dọn pod Evicted có thể thu về
   một phần đáng kể trong 22G**, và đây là việc **rủi ro rất thấp**.

### 2.3 Output thật

> Dán nguyên văn output từng lệnh vào đây, kèm số hiệu lệnh.

---

## 3. Việc tiếp theo

### ✅ Đã xong
- [x] Chốt n8n namespace = `default`, tách biệt `k8s.io` ⟹ **dọn image k8s.io an toàn**
- [x] Bảng tài nguyên node (2.1) — còn thiếu disk% của 7 node
- [x] Loại trừ inode (24%), log (325M), kubelet (352K) khỏi danh sách nghi phạm trên `.51`
- [x] Xác định `.51` thông registry `10.60.170.184:8083`
- [x] Phát hiện cơ chế thật: **GC trừng phạt nhầm namespace** (2.2b)

- [x] **Lệnh 1.11 — đã truy ra 45G.** ❌ Không phải fd rác (chỉ 0.02G). Phân bổ:
      `/var` ngoài containerd **23G** + `/home` **16G** + `/root` 3.4G + `/usr` 3G.
- [x] Đính chính: node DiskPressure=True là **`.51`**, không phải `.52` (đọc nhầm cột)

### 🔴 Ngay lập tức
- [ ] ⭐⭐ **Lệnh 1.14 — bóc 23G `/var` + 16G `/home`.** Đòn bẩy lớn nhất (~42G tiềm năng).
      Nghi số 1: image tarball `.tar` import tay còn sót (rác thuần túy, dọn rủi ro ~0),
      và `/var/lib/docker` cũ từ trước khi chuyển containerd.
- [ ] ⭐ **Lệnh 1.15 — verify 69 image là bản thật hay chỉ nhiều tag.** Đã thấy dấu hiệu
      tag trùng (cùng Image ID) ⟹ **lợi ích dọn image có thể nhỏ hơn tưởng nhiều.**
      Phải biết trước khi đề xuất, tránh hứa hão.
- [ ] **Lệnh 1.12 — đo 2 registry trên 5 worker.** Chưa có bảng này thì **cấm dọn image**
      trên node ngoài `.51`.
- [ ] **Lệnh 1.3 — disk% + inode của 4 worker còn lại** (`.52`→`.55`).

### Sau khi có số liệu
- [ ] Lệnh 1.13 — liệt kê 67 image rác `default`, ước lượng thu hồi được bao nhiêu GB
- [ ] Lệnh 1.8 — log kubelet, xác nhận GC/eviction bằng chứng cứ thay vì suy luận
- [ ] Lệnh 1.10 — đọc ngưỡng eviction/GC hiện tại (mặc định hay đã tuỳ chỉnh?)
- [ ] Dọn ~20 pod `Evicted` tuổi 8-24 ngày (chiếm slot `maxPods=50`)
- [ ] Đề xuất fix triệt để — **chưa viết, chờ số liệu**
- [ ] Cải thiện Helm chart RAGFlow v0.26.4 (**Kiên chưa liệt kê cụ thể — xem mục 4**)

### 💡 KẾ HOẠCH FIX cho `.51` — đã đủ số liệu, xếp theo (lợi ích ÷ rủi ro)

> Nguyên tắc: **làm từ việc rủi ro thấp nhất trước**, đo lại `df -h /` sau mỗi bước.
> Mục tiêu: đưa `.51` từ 88% xuống dưới 80% (dưới `imageGCLowThreshold`) ⟹ GC ngừng hẳn,
> `DiskPressure` tự hết.
> **Cần giải phóng tối thiểu ~8G** (88%→80% của 99G). Các bước dưới thừa sức đạt.

| # | Việc | Thu hồi | Rủi ro | Cần ai quyết |
|---|---|---|---|---|
| **1** | **Xóa image tarball `.tar`/`.zip`** đã import xong (ragflow 3.4G, n8n ×5 ~4.9G, langfuse, signoz, open-notebook) | **~10G** | 🟢 **Rất thấp** — verify image đã có trong containerd trước | Không (kỹ thuật) |
| **2** | **Dọn pod `Evicted`** (~20 pod, 8-24 ngày) ⟹ giải phóng snapshot | **? trong 22G** | 🟢 Rất thấp | Không |
| **3** | **Xóa 24 tag thừa + image không container nào dùng** trong `default` | ? phần của 17G | 🟡 Thấp — chừa 2 image n8n | Không |
| **4** | Xử lý backup SQL (`n8n_backup` 1.4G, `rag_flow_backup` 1.2G) | ~2.6G | 🟡 **Quyết định nghiệp vụ** | ⚠️ **Kiên/anh Cường** |
| **5** | `signoz-migrate/*.native` (~0.6G) | ~0.6G | 🟡 Hỏi còn cần không | ⚠️ Kiên |
| **6** | Nâng `imageMinimumGCAge` 2m → 168h (chống tái diễn) | 0 | 🟡 Cần restart kubelet | Không |
| **7** | Pre-pull image thiết yếu sau khi dọn | 0 | 🟢 | Không |

**🔴 DANH SÁCH CẤM ĐỤNG (nhắc lại, đã có đủ bằng chứng):**
- `/var/lib/nerdctl` (20G) — volume data n8n + postgres
- `/home/app/persistent-data/` — **pgdata SỐNG của n8n**, đang ghi lúc 12:00 hôm nay
- Image `docker.io/n8nio/n8n:1.123.38-curl` và `10.208.137.65:8890/vmlp/postgres:16.4`
- **KHÔNG** `nerdctl volume prune`, **KHÔNG** `nerdctl system prune -a`

### ⚠️ Vì sao image GC chạy mãi mà disk không giảm — đã giải thích được

`snapshots 22G > content 17G`. GC xóa **image (content)** nhưng **snapshot của container chết
vẫn nằm nguyên**. Cộng thêm 20G `/var/lib/nerdctl` + 18G tarball/backup mà GC **hoàn toàn
không với tới được** ⟹ GC xóa sạch image k8s (còn 12) mà disk vẫn 88%
⟹ tiếp tục xóa ⟹ **ImagePullBackOff toàn cụm.**

Nói cách khác: **GC đang bị giao một việc bất khả thi.** 58/83G nằm ngoài tầm với của nó.
Fix đúng là **giải phóng phần GC không với tới được** (bước 1, 4, 5), chứ không phải
chỉnh GC (bước 6 chỉ là chống tái diễn).

## 3b. LỆNH THỰC THI FIX trên `.51` (user root)

> ⚠️ **CHƯA CHẠY BƯỚC XÓA NÀO cho tới khi verify xong.** Mỗi bước có phần VERIFY trước,
> XÓA sau, và ĐO LẠI. Đo `df -h /` trước khi bắt đầu để có mốc so sánh.

```bash
df -h /
```

### Bước 0 — VERIFY: image trong tarball đã nằm trong containerd chưa?

Chỉ khi image đã có sẵn thì tarball mới là rác. Chạy trước khi xóa bất cứ `.tar` nào.

```bash
nerdctl images | grep -iE "ragflow|n8n|langfuse|signoz|open-notebook|zookeeper"
```

```bash
ctr -n k8s.io images list -q | grep -iE "ragflow|signoz|langfuse"
```

<details>
<summary>Giải nghĩa bước 0</summary>

```
Mục đích: chứng minh tarball là BẢN SAO THỪA, không phải bản duy nhất.

Logic: `.tar` sinh ra từ `docker save`/`ctr images export` để chuyển image vào cụm airgap.
Sau khi `ctr images import` xong thì image nằm trong containerd, tarball hết nhiệm vụ.
NHƯNG nếu image ĐÃ BỊ GC XÓA MẤT mà tarball vẫn còn ⟹ tarball là bản CỨU HỘ duy nhất
⟹ 🔴 KHÔNG ĐƯỢC XÓA, thậm chí phải dùng nó để import lại.

⭐ Đây chính là tình huống dễ xảy ra ở cụm này (GC đã quét sạch k8s.io còn 12 image).
   `/root/images/ragflow-v0264_custom.tar` 3.4G có thể là thứ CỨU được pod ragflow
   đang Init:ImagePullBackOff — đừng vội xóa.

grep -iE "ragflow|n8n|..." : -i không phân biệt hoa thường, -E bật regex mở rộng cho dấu `|`.
```
</details>

### Bước 1 — Dọn pod `Evicted` (rủi ro thấp nhất, làm trước)

Chạy bằng user **`app`** (kubectl):

```bash
kubectl get pods -A --field-selector=status.phase=Failed -o wide | head -30
```

```bash
kubectl get pods -A --field-selector=status.phase=Failed -o json | jq -r '.items[] | select(.status.reason=="Evicted") | "\(.metadata.namespace) \(.metadata.name)"' | wc -l
```

Sau khi xem danh sách và thấy hợp lý, mới xóa:

```bash
kubectl get pods -A --field-selector=status.phase=Failed -o json | jq -r '.items[] | select(.status.reason=="Evicted") | "kubectl delete pod -n \(.metadata.namespace) \(.metadata.name)"' > /tmp/del-evicted.sh
```

```bash
cat /tmp/del-evicted.sh | head -20
```

```bash
bash /tmp/del-evicted.sh
```

<details>
<summary>Giải nghĩa bước 1</summary>

```
Vì sao SINH RA FILE .sh rồi mới chạy, thay vì pipe thẳng vào `xargs kubectl delete`:
⭐ Để ĐỌC ĐƯỢC danh sách sẽ xóa TRƯỚC KHI xóa. Pipe thẳng = xóa mù.
   Đây là thao tác ghi trên cụm production ⟹ luôn tách "sinh lệnh" khỏi "chạy lệnh".

select(.status.reason=="Evicted")
└─ Lọc CHÍNH XÁC pod bị evict. ⚠️ QUAN TRỌNG: `status.phase=Failed` bao gồm cả pod fail
   vì lý do KHÁC (OOMKilled, lỗi app). Chỉ xóa đúng Evicted, đừng xóa nhầm pod đang
   được điều tra vì lý do khác.

Vì sao dọn pod Evicted lại thu hồi disk:
├─ Mỗi pod Evicted vẫn còn container ở trạng thái exited trên node
├─ Mỗi container exited giữ một SNAPSHOT trong containerd (phần 22G)
└─ Snapshot chỉ giải phóng khi container bị xóa ⟹ xóa pod ⟹ kubelet xóa container
   ⟹ snapshot được thu hồi.
   ⭐ Đây là lý do bước này vừa an toàn vừa có tác dụng thật lên 22G snapshots.

Lợi ích phụ: giải phóng slot trong `maxPods=50` (trần thấp, ~20 pod rác đang chiếm chỗ).
```
</details>

### Bước 2 — Xóa image tarball đã import (thu ~10G)

⚠️ **Chỉ chạy sau khi bước 0 xác nhận image tương ứng ĐÃ CÓ trong containerd.**

Xem lại danh sách + tổng dung lượng trước:

```bash
find /home /root -xdev -type f \( -name "*.tar" -o -name "*.zip" \) -size +100M -exec ls -lh {} \; 2>/dev/null | awk '{s+=$5; print $5"\t"$9} END {print "---"}' | sort -rh
```

```bash
find /home /root -xdev -type f \( -name "*.tar" -o -name "*.zip" \) -size +100M -not -path "*/persistent-data/*" 2>/dev/null | tee /tmp/tarball-to-delete.txt | wc -l
```

```bash
cat /tmp/tarball-to-delete.txt
```

Chuyển sang thư mục chờ xóa (an toàn hơn xóa thẳng — có thể hoàn tác):

```bash
mkdir -p /home/PENDING_DELETE_20260821
```

```bash
while read -r f; do mv -v "$f" /home/PENDING_DELETE_20260821/; done < /tmp/tarball-to-delete.txt
```

```bash
df -h /
```

<details>
<summary>Giải nghĩa bước 2</summary>

```
find ... \( -name "*.tar" -o -name "*.zip" \) ...
│         │  │              │
│         │  │              └─ -o : HOẶC (OR). Không có -o thì find hiểu là AND ⟹ tìm file
│         │  │                 vừa .tar vừa .zip = không bao giờ khớp.
│         │  └─ -name "*.tar" : khớp theo TÊN. Dấu nháy kép bắt buộc để shell không bung
│         │     `*` thành tên file trong thư mục hiện tại trước khi find nhận được.
│         └─ \( ... \) : nhóm điều kiện. Phải escape ngoặc bằng `\` vì `(` `)` là ký tự
│            đặc biệt của shell. Không nhóm thì `-size +100M` chỉ áp cho vế cuối.
│
-not -path "*/persistent-data/*"
└─ ⭐⭐ LÁ CHẮN SỐNG CÒN. Loại trừ mọi đường dẫn chứa `persistent-data`
   ⟹ pgdata SỐNG của n8n không bao giờ lọt vào danh sách xóa.
   (`-not` còn viết được là `!`, nhưng `!` phải escape trong shell ⟹ dùng `-not` cho an toàn.)

⭐ VÌ SAO `mv` SANG THƯ MỤC CHỜ, KHÔNG `rm` THẲNG:
   `mv` trong CÙNG filesystem chỉ đổi đường dẫn, KHÔNG giải phóng disk ngay —
   nhưng cho phép HOÀN TÁC nếu phát hiện xóa nhầm.
   ⚠️ HỆ QUẢ: `df` sẽ KHÔNG giảm sau bước mv. Disk chỉ thực sự thu hồi khi `rm` thư mục
   PENDING sau vài ngày chạy ổn định.
   ⟹ Nếu cần giải phóng disk NGAY (đang DiskPressure), phải `rm` thật:
      `while read -r f; do rm -v "$f"; done < /tmp/tarball-to-delete.txt`
      Chỉ làm sau khi bước 0 xác nhận chắc chắn.

mv -v : -v (--verbose) in từng file được chuyển ⟹ có nhật ký để đối chiếu, biết chính xác
        cái gì đã bị di chuyển.

while read -r f; do ... done < FILE
├─ -r : ⭐ KHÔNG diễn giải dấu `\` trong tên file. Bắt buộc khi xử lý đường dẫn.
└─ Đọc từng dòng an toàn hơn `for f in $(cat FILE)` — cách sau vỡ khi tên file có dấu cách.
   "$f" luôn phải trong nháy kép, cùng lý do.
```
</details>

### Bước 3 — Xóa image không container nào dùng trong `default` (chừa n8n)

```bash
nerdctl ps -a --format '{{.Image}}'
```

```bash
nerdctl images --format '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}' | sort -u
```

<details>
<summary>Giải nghĩa bước 3</summary>

```
nerdctl ps -a --format '{{.Image}}'
└─ Liệt kê image ĐANG ĐƯỢC container dùng (kể cả container đã dừng, nhờ -a).
   ⭐ Đây là DANH SÁCH BẢO VỆ. Kỳ vọng chỉ ra 2 dòng:
      docker.io/n8nio/n8n:1.123.38-curl
      10.208.137.65:8890/vmlp/postgres:16.4

Cách làm an toàn: đối chiếu thủ công 2 danh sách, chọn ra image cần xóa, rồi
`nerdctl rmi <ID>` TỪNG CÁI. KHÔNG dùng prune tự động.

🔴 TUYỆT ĐỐI KHÔNG:
   ├─ `nerdctl system prune -a`  → xóa mọi image không gắn container ĐANG CHẠY.
   │                                Ở cụm airgap = mất vĩnh viễn, không pull lại được.
   └─ `nerdctl volume prune`     → xóa volume ⟹ MẤT DATA n8n (20G /var/lib/nerdctl).

⚠️ Nhắc lại từ 2.2d-bis: xóa image chỉ đụng tới `content` (17G).
   Phần `snapshots` (22G) chỉ giảm khi xóa CONTAINER ⟹ bước 1 mới là bước có tác dụng ở đó.
   Đừng kỳ vọng bước 3 trả về nhiều GB.
```
</details>

### Bước 4 — Chống tái diễn: nâng `imageMinimumGCAge`

⚠️ Chỉ làm sau khi disk đã về dưới 80% và cụm ổn định. Cần restart kubelet (có rủi ro).

```bash
grep -nE "imageMinimumGCAge|imageGCHighThresholdPercent|imageGCLowThresholdPercent|evictionHard" /var/lib/kubelet/config.yaml
```

<details>
<summary>Giải nghĩa bước 4</summary>

```
Đọc TRƯỚC khi sửa — để biết đang dùng mặc định hay đã tuỳ chỉnh, và có mốc để hoàn tác.

Mặc định k8s 1.23:
├─ imageMinimumGCAge           = 2m0s  ⟹ image mới hơn 2 phút thì tha
├─ imageGCHighThresholdPercent = 85    ⟹ vượt 85% bắt đầu xóa image
└─ imageGCLowThresholdPercent  = 80    ⟹ xóa cho tới khi về 80%

⭐ ĐỀ XUẤT cho cụm airgap: `imageMinimumGCAge: 168h` (7 ngày).
   Lý do: ở cụm airgap, image bị xóa là MẤT VĨNH VIỄN (node không thông registry).
   2 phút quá ngắn — image vừa pull về, pod chưa kịp ổn định đã bị GC xóa.

⚠️ ĐÁNH ĐỔI PHẢI HIỂU RÕ: nâng giá trị này khiến GC gần như không dọn được gì nữa
   ⟹ disk BẮT BUỘC phải được dọn bằng cách khác (bước 1-3 + giám sát định kỳ).
   Nếu chỉ nâng mà không dọn ⟹ disk đầy 100% ⟹ node NotReady ⟹ tệ hơn hiện tại.
   ⟹ Đây là bước CUỐI CÙNG, không phải bước đầu.

Sau khi sửa file phải: `systemctl restart kubelet` ⟹ ⚠️ pod trên node bị gián đoạn ngắn.
Trên `.51` có n8n (nerdctl, NGOÀI k8s) ⟹ restart kubelet KHÔNG ảnh hưởng n8n. ✅
```
</details>

---

## 4. Câu hỏi còn treo cho Kiên

1. Helm chart v0.26.4 "chưa có" những gì cần bổ sung? (resource limits? PVC sizing?
   nodeSelector/affinity? log rotation? imagePullPolicy? priorityClass?)
   ⟹ Cần Kiên liệt kê để làm đúng phạm vi, không tự đoán. **VẪN CHƯA CÓ CÂU TRẢ LỜI.**

4. ⚠️ **Backup SQL — quyết định nghiệp vụ, cần Kiên/anh Cường:**
   - `/home/app/workspace/n8n_nerdctl/n8n_backup_2026-03-30.sql` (1.4G, 30/3)
   - `/home/app/rag_flow_backup_20260807.sql` (1.2G, 7/8)
   ⟹ Có nơi lưu backup khác không? Nếu đây là bản duy nhất thì **phải chuyển đi trước khi xóa**.

5. `/home/app/signoz-migrate/*.native` (~0.6G) — việc migrate signoz xong chưa, còn cần không?

6. `/root/images/ragflow-v0264_custom.tar` (3.4G) — ⚠️ **có thể là bản cứu hộ duy nhất**
   của image RAGFlow custom (pod ragflow đang `Init:ImagePullBackOff`).
   **Kiểm tra image đã có trong containerd chưa TRƯỚC KHI xóa** — nếu chưa, đây chính là
   thứ dùng để `ctr images import` cứu pod ragflow.
2. ~~SSH từ `.51` sang node khác~~ ✅ **ĐƯỢC** (xác nhận 2026-08-21). Hoặc SSH thẳng vào
   từng node cũng được — chỉ 5 worker, ít node.
3. RAGFlow đang chạy trên cụm vRP này hay cụm khác? (memory ghi endpoint `10.208.137.54:8999`
   ⟹ **trùng dải IP cụm vRP**, node `.54` = vrp-kubeengine07 ⟹ RAGFlow NẰM TRÊN CHÍNH CỤM NÀY)
