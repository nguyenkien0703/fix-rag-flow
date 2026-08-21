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

```bash
ssh 10.208.137.51 'echo "=== CAC NAMESPACE CONTAINERD ==="; sudo ctr namespaces list; echo "=== CONTAINER NS default (nerdctl/n8n?) ==="; sudo ctr -n default containers list; echo "=== NERDCTL PS ==="; sudo nerdctl ps -a 2>/dev/null || echo "nerdctl khong co trong PATH"; echo "=== IMAGE NS default ==="; sudo ctr -n default images list -q; echo "=== NERDCTL NAMESPACE ==="; sudo nerdctl namespace ls 2>/dev/null'
```

<details>
<summary>Giải nghĩa lệnh 1.6 — vì sao lệnh này chạy TRƯỚC mọi lệnh dọn dẹp</summary>

```
ctr namespaces list
└─ Liệt kê tất cả namespace của containerd trên node. Kỳ vọng thấy ít nhất:
   `k8s.io` (kubelet) và `default` (nerdctl). Nếu n8n được deploy với
   `nerdctl --namespace k8s.io` thì nó NẰM CHUNG với pod k8s ⟹ image GC của kubelet
   CÓ THỂ xóa image n8n ⟹ tình huống nguy hiểm, phải đổi chiến lược.

ctr -n default containers list
└─ Liệt kê container trong namespace default. Nếu thấy n8n ở đây ⟹ THỞ PHÀO:
   dọn image trong k8s.io hoàn toàn không đụng tới nó.

nerdctl ps -a
├─ ps    : liệt kê container đang chạy
└─ -a (--all) : gồm cả container đã dừng.
   Cần -a để thấy container n8n cũ đã stop (chúng vẫn giữ image ⟹ image không bị coi
   là "unused" ⟹ ảnh hưởng tính toán khi prune).

|| echo "..." : nếu lệnh trước THẤT BẠI (exit code ≠ 0) thì in thông báo thay vì im lặng.
                Tránh trường hợp lệnh không tồn tại mà output trống, gây hiểu nhầm là
                "không có container nào".

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

---

## 2. Kết quả thu thập (điền sau khi chạy)

### 2.1 Bảng tài nguyên node

| Node | IP | Role | CPU | RAM | Disk total | Disk used % | Inode used % | DiskPressure | Thông registry |
|---|---|---|---|---|---|---|---|---|---|
| vrp-kubeengine01 | .48 | master | | | | | | | |
| vrp-kubeengine02 | .49 | master | | | | | | | |
| vrp-kubeengine03 | .50 | master | | | | | | | |
| vrp-kubeengine04 | .51 | worker ⚠️ n8n | | | | | | | |
| vrp-kubeengine05 | .52 | worker | | | | | | | |
| vrp-kubeengine06 | .53 | worker | | | | | | | |
| vrp-kubeengine07 | .54 | worker | | | | | | | |
| vrp-kubeengine08 | .55 | worker | | | | | | | |

### 2.2 Kết luận n8n namespace (từ lệnh 1.6)

> ⬜ CHƯA CHẠY — điền vào đây trước khi làm bất kỳ thao tác dọn dẹp nào.

### 2.3 Output thật

> Dán nguyên văn output từng lệnh vào đây, kèm số hiệu lệnh.

---

## 3. Việc tiếp theo (chưa làm)

- [ ] Chạy toàn bộ mục 1, điền bảng 2.1
- [ ] Chốt n8n namespace (2.2) — **chặn mọi thao tác ghi cho tới khi có kết luận này**
- [ ] Phân loại node: thông registry (được dọn image) vs không thông (cấm dọn)
- [ ] Chốt thủ phạm ăn disk thật sự (containerd? log? etcd? emptyDir?)
- [ ] Đề xuất fix triệt để (chưa viết — chờ số liệu)
- [ ] Cải thiện Helm chart RAGFlow v0.26.4 (**Kiên chưa liệt kê cụ thể — xem mục 4**)

## 4. Câu hỏi còn treo cho Kiên

1. Helm chart v0.26.4 "chưa có" những gì cần bổ sung? (resource limits? PVC sizing?
   nodeSelector/affinity? log rotation? imagePullPolicy? priorityClass?)
   ⟹ Cần Kiên liệt kê để làm đúng phạm vi, không tự đoán.
2. Có được phép SSH bằng key từ `.51` sang các node khác không, hay phải gõ tay từng node?
3. RAGFlow đang chạy trên cụm vRP này hay cụm khác? (memory ghi endpoint `10.208.137.54:8999`
   ⟹ **trùng dải IP cụm vRP**, node `.54` = vrp-kubeengine07 ⟹ RAGFlow NẰM TRÊN CHÍNH CỤM NÀY)
