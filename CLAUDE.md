# CLAUDE.md — repo `fix-rag-flow`

Repo này chứa toàn bộ điều tra/vận hành RAGFlow và hạ tầng cụm **vRP**.

## 🚨 RÀNG BUỘC AN TOÀN — ĐỌC TRƯỚC MỌI THAO TÁC GHI TRÊN CỤM vRP

Cụm **vRP** là cụm k8s **airgap**, CentOS 7, k8s **v1.23.2**, containerd **1.5.8**.
Chi tiết đầy đủ: memory `vrp-cluster-topology.md` + `TRACKING-vrp-disk-pressure.md`.

| Node | IP | Vai trò |
|---|---|---|
| vrp-kubeengine01/02/03 | .48 / .49 / .50 | control-plane, master |
| **vrp-kubeengine04** | **10.208.137.51** | worker — ⚠️ **jump box (kubectl) + n8n chạy bằng `nerdctl`** |
| vrp-kubeengine05..08 | .52 / .53 / .54 / .55 | worker (RAGFlow ở .54) |

### 👤 User nào chạy lệnh gì

| Việc | User |
|---|---|
| `kubectl ...` | **`app`** |
| `nerdctl ps` / `nerdctl images` (n8n) | **`root`** — `su -` trước, **KHÔNG dùng `sudo nerdctl`** |
| `ctr` / `crictl` | **`root`** |

### 3 luật cứng

1. **`.51` chạy n8n bằng `nerdctl` — n8n DOWN LÀ RẤT NGUY HIỂM.**
   Không prune/xóa image trên `.51` khi chưa xác nhận n8n nằm ở containerd namespace nào
   (`ctr namespaces list`; kỳ vọng nerdctl ở `default`, pod k8s ở `k8s.io`).
   `.51` cũng là node dùng để gõ `kubectl` ⟹ mất nó là mất luôn khả năng thao tác.

2. **KHÔNG phải node nào cũng thông tới registry `10.60.170.184:8083`.**
   Node **không thông** thì **TUYỆT ĐỐI KHÔNG xóa image** — airgap, xóa xong không kéo lại được,
   sẽ thành `ImagePullBackOff` vĩnh viễn. Phải phân loại node trước khi dọn.

3. **Không có Docker.** Dùng `crictl` (chỉ thấy namespace `k8s.io`, an toàn) hoặc `ctr -n <ns>`
   (thấy mọi namespace, mạnh nhưng dễ gây tai nạn — luôn ghi rõ `-n`).

## Quy tắc trình bày lệnh (kế thừa global CLAUDE.md)

- **Mọi lệnh có cờ/tham số PHẢI kèm `<details>` giải nghĩa**, liệt kê cả cờ đã biết.
  Lệnh dài dùng sơ đồ `│ └─` thay vì bảng.
- **Collapse phải nằm TRONG FILE tracking**, không chỉ in ra chat. Soạn lệnh cho Kiên chạy
  ⟹ ghi vào file trước, rồi mới nhắc lại trong chat.
- ⭐ **Trong CHAT thì KHÔNG giải thích lệnh** (Kiên chốt 2026-08-21) — chat chỉ đưa **lệnh trần**,
  phần giải nghĩa nằm trọn trong file tracking. Tránh lặp nội dung ở 2 chỗ.
- ⭐ **Kết thúc MỖI lượt phải nói rõ: "Kiên cần chạy lệnh gì"** — liệt kê thẳng, đúng thứ tự,
  kèm user cần dùng. Không để Kiên phải tự mò trong file xem tới bước nào.

## Bài học vận hành đã trả giá (đừng lặp lại)

- **`sed` không khớp pattern vẫn `exit 0`** — đã trượt âm thầm **2 lần** (`minimum_should_match`,
  `timeout=600`→`timeout="600s"`). Mọi patch sed phải **`grep` verify sau khi apply**.
- **`kubectl` không có `--until-time`** (chỉ `--since`/`--since-time`). Cắt cửa sổ log bằng
  `awk '$0 >= "[TS_DAU" && $0 <= "[TS_CUOI~"'` (`~` = ASCII 126 làm chặn trên).
- **RAGFlow không log duration** ở access log — cột `270774` là **response size**, không phải
  thời gian. Trước khi tin một cột log là duration, kiểm nó có **biến thiên** cùng latency không.
- **Phải đọc source THẬT trong container** (`kubectl exec ... grep`), không đọc GitHub — image
  đang chạy là bản custom, lệch upstream.
- **`du` trong `/var/lib/kubelet` phải có `-x`** — không thì bò sang mount point PV/NFS, số sai
  và chạy hàng chục phút.
- **Disk đầy có thể là hết INODE, không phải hết dung lượng** — luôn kiểm cả `df -h` lẫn `df -i`.

## 🔴 Nợ bảo mật còn treo

Bearer token RAGFlow + mật khẩu ES `aihub_prod` **đã lọt vào git history** (PR #8, các commit
trước `b79e701`). Đã redact ở bản mới nhưng history cũ vẫn còn ⟹ **cần rotate token**.
Không commit thêm secret vào repo này.
