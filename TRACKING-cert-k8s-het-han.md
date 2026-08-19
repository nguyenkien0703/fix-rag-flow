# TRACKING — Cert K8s control-plane hết hạn

> File sống. Cập nhật ngay sau mỗi lệnh chạy, không đợi cuối phiên.
> Bắt đầu: 2026-08-19. Trạng thái tổng: 🔶 **OPEN — chẩn đoán XONG, quy trình renew đã soạn,
> chưa thao tác sửa.**
>
> **➡️ Vào thẳng mục 7 → "⭐ QUY TRÌNH RENEW ĐẦY ĐỦ" để thực hiện.**
> Mọi ẩn số chặn việc renew đã được giải (xem bảng "Điều kiện tiên quyết" ở đó).

---

## 1. Mục tiêu

Gia hạn cert control-plane Kubernetes đã hết hạn để khôi phục truy cập `kubectl` và đảm bảo
cluster HA hoạt động ổn định, **không làm cert mới thiếu SAN** (rủi ro lớn nhất — sẽ làm toàn cụm
hỏng nặng hơn hiện tại).

### Số liệu triệu chứng ban đầu

| Hạng mục | Giá trị |
|---|---|
| Ngày phát hiện | 2026-08-19, khoảng **08:49 +07** |
| **Triệu chứng đầu tiên** | `helm upgrade ragflow` trên worker `vrp-kubeengine04` → `UPGRADE FAILED: Kubernetes cluster unreachable` |
| Cert LB endpoint hết hạn lúc | **2026-08-18T12:02:51Z** (chính xác đến giây, từ thông báo lỗi TLS) |
| Cert lá khác hết hạn lúc | **Aug 18, 2026 11:53 UTC** (bảng `check-expiration`, làm tròn phút) |
| RESIDUAL TIME của mọi cert lá | `<invalid>` (đã âm) |
| CA gốc (`ca`) hết hạn | **Jul 03, 2033 08:11 UTC** — còn `6y` |
| `front-proxy-ca` hết hạn | **Jul 03, 2033 08:11 UTC** — còn `6y` |
| Thời điểm phát sinh lỗi | `current time 2026-08-19T08:49:32+07:00` — node chạy **UTC+7**, đồng hồ đúng ⇒ **loại trừ lệch NTP** |
| Phạm vi ảnh hưởng | **Toàn cụm** — cả worker (kubeconfig user `app`) lẫn master đều hỏng |

### Bối cảnh hệ thống

| Hạng mục | Giá trị | Nguồn |
|---|---|---|
| Node đang thao tác | `vrp-kubeengine01` — **10.208.137.48** | Screenshot terminal + xác nhận của Kiên |
| **Master (3)** | **10.208.137.48 / .49 / .50** | Xác nhận của Kiên |
| **Worker (5)** | **10.208.137.51 / .52 / .53 / .54 / .55** | Xác nhận của Kiên |
| Tổng node | 8 (3 control-plane + 5 worker) | Suy ra từ trên |
| Node phát hiện lỗi | `vrp-kubeengine04` (worker), user `app` | Output 3.0 |
| ~~IP nghi VIP 10.208.216.4~~ | ❌ **LOẠI BỎ — thuộc cụm khác, không liên quan** | Kiên đính chính 2026-08-19 |
| ⭐ **Control-plane endpoint** | **`https://lb-apiserver.kubernetes.local:6443`** — là **DNS name**, không phải IP | ✅ Output 3.0 |
| Công cụ dựng cluster | ❓ **nghi Kubespray** — tên endpoint là mặc định Kubespray. **Nhưng dùng LB tập trung, không phải localhost-LB mặc định** ⇒ có tuỳ biến | Suy luận — **chưa xác minh** |
| Công cụ quản trị cert | `kubeadm` **v1.23.2** | ✅ Output 3.10 |
| ⚠️ **Version Kubernetes** | **v1.23.2 — ĐÃ END-OF-LIFE** (EOL 02/2023, quá hạn 3 năm) | ✅ Output 3.10 |
| Registry image | `10.60.129.132:8090` — registry nội bộ, không phải `registry.k8s.io` | ✅ Output 3.10 |
| SAN cert hiện tại | **18 entry** | ✅ Output 3.10 |
| ✅ **Kiến trúc etcd** | **EXTERNAL** — không có `etcd.yaml` trong manifests | ✅ Output 3.4 |
| Ngày dựng cluster | **06/07/2023** (mtime `kubeadm-config.yaml`) | ✅ Output 3.3 |
| Lần sửa apiserver gần nhất | **18/09/2024** — ❓ ai sửa, sửa gì chưa rõ | ✅ Output 3.4 (mtime) |
| Service CIDR | `172.16.128.0/x` (ClusterIP svc kubernetes = `172.16.128.1`) — **tùy biến**, không phải mặc định | ✅ Output 3.5 |
| ✅ **VIP / LB endpoint** | **`10.208.137.68`** = `lb-apiserver.kubernetes.local`. **LB TẬP TRUNG**, không phải localhost-LB | ✅ Output 3.7 |
| ✅ **Cơ chế LB** | **LB NGOÀI CỤM** — không master nào giữ VIP, không có keepalived/haproxy/nginx trên master | ✅ Output 3.8 + 3.9 |
| Health-check của LB | ❓ **không tự xác minh được từ trong cụm** — thiết bị của đội khác | Ràng buộc phạm vi, phải hỏi |
| Cluster CIDR (pod) | `172.16.0.0/17` | ✅ Output 3.6 |
| Service CIDR | `172.16.128.0/17` | ✅ Output 3.6 |
| ✅ **Cluster domain** | **`vrp`** (`dnsDomain: vrp`) — cert hiện tại dùng `cluster.local` mặc định ⇒ renew sẽ **thêm** `kubernetes.default.svc.vrp` | ✅ Output 3.12 |
| ✅ **`certificatesDir`** | `/etc/kubernetes/ssl` — **`pki` là symlink tới nó** ⇒ dùng đường dẫn nào cũng đúng | ✅ Output 3.13 |
| Owner thư mục cert | `kube:root`, quyền `755` (kubeadm mặc định `700`) | ✅ Output 3.13 |
| ✅ **etcd endpoints** | `https://10.208.137.48/49/50:2379`, cert riêng ở `/etc/ssl/etcd/ssl/` | ✅ Output 3.12 |
| `clusterName` | `vrp` | ✅ Output 3.12 |
| Người dựng cụm | ❓ **Không phải Kiên** (nhân viên mới, phụ trách deploy service). Cần hỏi sếp nếu cần | Kiên xác nhận |
| Ứng dụng bị ảnh hưởng | RAGFlow `v0.26.4`, namespace `ragflow`, deploy bằng Helm | Output 3.0 |
| User thao tác | worker: `app` / master: `vt_admin` → `su` sang `root` | Screenshot |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Cert lá control-plane hết hạn 18/08/2026 | 🔴 Cao | 🔶 **OPEN — đang thực hiện GĐ0** | `kubeadm certs renew all` **`--config /root/cluster-config-renew.yaml`** (file TÁCH ở GĐ0-ter, không phải file gốc) → so SAN → restart. Lần lượt 48→49→50 |
| 2 | `kubectl` không chạy được dưới user `root` (thiếu kubeconfig) | 🟡 TB | 🔶 **OPEN** | Copy `admin.conf` → `~/.kube/config` **sau khi** renew xong |
| 3 | ~~Toàn bộ PKI etcd báo `!MISSING!`~~ | ⚪ Không phải issue | ✅ **ĐÓNG** | Output 3.4: không có `etcd.yaml` ⇒ **etcd external** ⇒ `!MISSING!` chỉ là cosmetic |
| 4 | `kubeadm` fallback default config → cert mới mất SAN | 🔴 Cao | 🔶 **OPEN — đã có cách gỡ** | ✅ Output 3.6 xác nhận `kubeadm-config.yaml` còn đúng ⇒ renew **kèm `--config /etc/kubernetes/kubeadm-config.yaml`**. Cấm lệnh trần |
| 5 | Không có cảnh báo trước khi cert hết hạn | 🟡 TB | 🔶 **OPEN** | Dựng `x509-certificate-exporter` + alert trước 30 ngày |
| 6 | RAGFlow `v0.26.4` chưa upgrade được (việc gốc ban đầu) | 🟢 Thấp | 🔶 **OPEN** — bị chặn bởi #1 | Chạy lại `helm upgrade` sau khi cluster khôi phục |
| 7 | ~~`kubeadm-config.yaml` (2023) lỗi thời~~ | ⚪ Không phải issue | ✅ **ĐÓNG** | Output 3.6: `certSANs` khớp cert đang chạy ⇒ **dùng được `--config`** |
| 9 | 🔴 **File `kubeadm-config.yaml` có 4 YAML document — v1.23 không parse được cho `--config`** | 🔴 Cao | 🔶 **OPEN — đã có cách gỡ** | Output 3.11. Tách file chỉ chứa `ClusterConfiguration` → GĐ0-ter |
| 10 | Kubernetes **v1.23.2 đã EOL** (02/2023, quá hạn 3 năm) | 🟠 Cao | 🔶 **OPEN — ngoài phạm vi việc này** | Không chặn renew. Cần lên kế hoạch nâng cấp riêng, bàn với sếp |
| 11 | ~~`certificatesDir: /etc/kubernetes/ssl`~~ | ⚪ Không phải issue | ✅ **ĐÓNG** | Output 3.13: `pki` là **symlink** tới `ssl` ⇒ hai tên một thư mục ⇒ quy trình không phải sửa |
| 12 | Cert cụm **etcd external** chưa kiểm hạn | 🟡 TB | 🔶 **OPEN — ngoài phạm vi** | Cert ở `/etc/ssl/etcd/ssl/`, không do `kubeadm certs renew` quản. Kiểm sau khi khôi phục control-plane |
| 8 | LB tập trung `.68` — chưa rõ có health-check không | 🟡 **TB (hạ từ 🟠)** | 🔶 **OPEN — bị chặn bởi phạm vi** | ✅ Output 3.8: VIP **ngoài cụm**, master restart không đụng VIP. Còn lại: hỏi đội mạng về health-check port 6443 |

---

## 3. Lệnh đã chạy

> ⚠️ Chỉ ghi lệnh **đã có output thật**. Lệnh chưa chạy nằm ở mục 7.
> Đánh số theo **thứ tự thời gian thực tế**: 3.0 xảy ra trước 3.1.

### 📋 Giao ước cập nhật khi thực hiện quy trình mục 7

> Chốt với Kiên 2026-08-19. **Tách rõ 2 nhịp khác nhau** — đây là điểm dễ nhầm:

| Việc | Nhịp | Lý do |
|---|---|---|
| **Kiên gửi output** | **Ngay sau MỖI lệnh** | ⭐ Để còn cứu được nếu sai. Chạy hết cả giai đoạn rồi mới gửi thì lỗi ở GĐ3 chỉ lộ ra khi đã restart ở GĐ4 — **cửa sổ rollback đã đóng** |
| **Ghi vào file này** | Gom cụm ~3-5 lệnh, hoặc **ngay lập tức** nếu có bất thường | Tránh quên; nhưng không làm gián đoạn nhịp thao tác |

**Quy tắc đánh số:** output thật của quy trình mục 7 ghi tiếp từ **`3.10`**, theo thứ tự thời gian.
Mỗi mục ghi rõ **node nào** và **thuộc giai đoạn nào** (vd: `3.12 — [Node 48 / GĐ2] Renew cert`).

**Node 49 và 50:** node 48 ghi **đầy đủ** làm chuẩn. Node 49/50 **chỉ ghi điểm KHÁC** so với 48
(hoặc bất thường). Giống hệt thì ghi một dòng xác nhận `"đã chạy, kết quả giống node 48"` —
**không lặp lại output**, nhưng cũng **không được bỏ trống** như thể chưa chạy.

**Điểm dừng bắt buộc — Kiên PHẢI chờ xác nhận trước khi chạy tiếp:**

| Sau bước | Vì sao phải dừng |
|---|---|
| **GĐ2** (renew xong) | Cert mới đã ghi đĩa nhưng pod vẫn dùng cert cũ — còn cứu được |
| **GĐ3** (so SAN) | 🔴 **Chốt chặn quan trọng nhất.** SAN thiếu mà vẫn restart = hỏng toàn cụm, mất luôn cert cũ |
| **GĐ5** (verify node 48) | Node 48 chưa xanh mà sang 49 = hỏng 2 node cùng lúc |

### 3.0 ⭐ Lệnh làm lộ ra sự cố — deploy RAGFlow bằng Helm

**Node: `vrp-kubeengine04` (worker) — user `app`, ~08:49 +07 ngày 19/08**

```
helm upgrade ragflow . -n ragflow -f values.yaml
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `helm upgrade` | Nâng cấp release đã cài. Bước đầu tiên của nó là **gọi API server để lấy `/version`** — đây chính là chỗ chết, chưa kịp đụng tới chart |
| `ragflow` (đối số 1) | Tên **release**, không phải tên chart |
| `.` (đối số 2) | Chart nằm ở **thư mục hiện tại** (`helm_ragflow_v0.26.4/`), không phải chart từ repo remote |
| `-n ragflow` | Namespace đích. Viết tắt của `--namespace` |
| `-f values.yaml` | File values ghi đè giá trị mặc định của chart. Nhiều `-f` thì file sau đè file trước |

**Output** (gõ lại từ screenshot — VDI chặn clipboard, đã lược các lần lặp giống nhau):

```
Error: UPGRADE FAILED: Kubernetes cluster unreachable: Get "https://lb-apiserver.kubernetes.local:6443/version": tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time 2026-08-19T08:49:32+07:00 is after 2026-08-18T12:02:51Z
```

Lệnh `kubectl` chạy ngay sau đó trên cùng node, cùng user:

```
kubectl get pods -n ragflow
```

```
Unable to connect to the server: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time 2026-08-19T08:50:14+07:00 is after 2026-08-18T12:02:51Z
```

**Đọc được gì:**

- ⭐ **Control-plane endpoint là `https://lb-apiserver.kubernetes.local:6443`** — một **DNS name**,
  không phải IP node. Đây là thông tin **quyết định** cho bước renew: SAN của cert apiserver
  **bắt buộc** phải chứa tên này, nếu không toàn cụm sẽ hỏng sau khi renew.
- Tên `lb-apiserver.kubernetes.local` là **giá trị mặc định của Kubespray** ⇒ nghi cụm dựng bằng
  Kubespray (bên dưới vẫn là kubeadm — Kubespray dùng kubeadm làm engine).
  ⚠️ **Ghi chú bổ sung sau output 3.7:** ban đầu đã suy tiếp rằng cụm dùng **localhost-LB**
  (mặc định của Kubespray). **Suy luận đó SAI** — `/etc/hosts` trỏ tới VIP `10.208.137.68`,
  tức **LB tập trung**. Xem Bài học #11.
- **Mốc hết hạn chính xác: `2026-08-18T12:02:51Z`** — chi tiết hơn bảng `check-expiration`
  (chỉ có `11:53 UTC`). Chênh ~10 phút là bình thường, cert được `kubeadm init` sinh tuần tự.
- `current time 2026-08-19T08:49:32+07:00` ⇒ node chạy **UTC+7 và đồng hồ đúng**.
  ⇒ **Loại trừ được**: không phải lệch NTP làm cert "trông như" hết hạn. Cert hết hạn **thật**.
- ⭐ **Loại trừ được (quan trọng nhất): apiserver VẪN ĐANG CHẠY.**
  Lỗi là `tls: failed to verify certificate` — tức đã **bắt tay được TCP** và **vào tới giai đoạn
  TLS handshake**, chỉ thất bại ở khâu client verify cert. Nếu apiserver chết hẳn thì lỗi phải là
  `connection refused` hoặc `i/o timeout`.
  ⇒ Cluster **không chết**, chỉ là không client nào chịu tin nó. Chỉ cần renew + restart, **không**
  phải kịch bản cứu cluster chết / restore snapshot.
- Phạm vi: lỗi xảy ra trên **worker**, với kubeconfig của user `app` — chứng tỏ sự cố **toàn cụm**,
  không riêng master 48.

---

### 3.1 Kiểm tra cluster còn truy cập được không (lệnh phát hiện sự cố)

**Node: 10.208.137.48**

```
kubectl get nodes
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `kubectl` | Client CLI của K8s. Đọc cấu hình kết nối theo thứ tự: cờ `--kubeconfig` → biến môi trường `$KUBECONFIG` → `~/.kube/config`. **Không tìm thấy cả ba thì fallback về `localhost:8080`** |
| `get` | Động từ đọc, không thay đổi trạng thái — an toàn để chạy khi đang sự cố |
| `nodes` | Resource cấp cluster. Chọn `nodes` (không phải `pods`) vì nó không phụ thuộc namespace → loại bỏ biến số về quyền RBAC theo namespace khi chẩn đoán |

**Output:**

```
The connection to the server localhost:8080 was refused - did you specify the right host or port?
```

**Đọc được gì:**

- Đây **KHÔNG phải** lỗi cert. Lỗi cert sẽ hiện `x509: certificate has expired or is not yet valid`.
- `localhost:8080` là giá trị **fallback mặc định** khi kubectl không tìm thấy kubeconfig nào.
  Cổng `8080` là insecure-port, đã bị gỡ khỏi K8s từ v1.20 → chắc chắn không có gì lắng nghe ở đó.
- ⇒ Kết luận trực tiếp: user `vt_admin` trên master 48 **không có file `~/.kube/config`**.
- ⭐ **Đối chiếu với output 3.0** — cùng là sự cố cert, nhưng hai thông báo lỗi khác hẳn nhau:

  | Node / User | Thông báo | Nghĩa thật |
  |---|---|---|
  | worker 04 / `app` | `tls: failed to verify certificate: x509...` | **Có** kubeconfig → tới được TLS handshake → lỗi cert THẬT |
  | master 48 / `vt_admin` | `localhost:8080 refused` | **Không có** kubeconfig → chưa từng kết nối tới apiserver |

  ⇒ Bài học: `localhost:8080 refused` **không nói gì** về tình trạng cert hay cluster.
  Nếu chỉ nhìn output này ở master 48, rất dễ kết luận nhầm "apiserver đã chết".
  Chính output 3.0 ở worker mới chứng minh apiserver **còn sống**.

**Ghi chú thao tác:** trước đó Kiên có gõ `sudo kubeadm certs check-expiration` nhưng **bấm `^C`
hủy giữa chừng** (đang chờ nhập password sudo), nên lệnh đó **không có output** — không phải nó
báo lỗi. Sau đó `su` sang root rồi chạy lại, ra output 3.2.

---

### 3.2 Liệt kê toàn bộ cert và hạn sử dụng — xác định phạm vi thiệt hại

**Node: 10.208.137.48 — chạy dưới `root`**

```
kubeadm certs check-expiration
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `kubeadm` | Binary bootstrap cluster. Phải chạy **trên chính node control-plane** — nó đọc file cục bộ, không hỏi qua mạng |
| `certs` | Nhóm lệnh quản lý PKI. Ở kubeadm < v1.20 nhóm này tên là `alpha certs` |
| `check-expiration` | Đọc mọi cert trong `/etc/kubernetes/pki/` **và** cert nhúng base64 bên trong các kubeconfig (`admin.conf`, `controller-manager.conf`, `scheduler.conf`), in bảng RESIDUAL TIME. **Chỉ đọc, không sửa gì** — an toàn tuyệt đối |
| (chạy bằng `root`) | `/etc/kubernetes/pki/*.key` có chmod 600 owner root. Không có root → kubeadm báo permission denied thay vì `!MISSING!`. **Phân biệt quan trọng**: `!MISSING!` ở output dưới là *file không tồn tại*, không phải *không đọc được* |

**Output** (gõ lại nguyên văn từ screenshot — VDI chặn clipboard):

```
[check-expiration] Reading configuration from the cluster...
[check-expiration] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'
[check-expiration] Error reading configuration from the Cluster. Falling back to default configuration

CERTIFICATE                EXPIRES                  RESIDUAL TIME  CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Aug 18, 2026 11:53 UTC   <invalid>      ca                      no
apiserver                  Aug 18, 2026 11:53 UTC   <invalid>      ca                      no
!MISSING! apiserver-etcd-client
apiserver-kubelet-client   Aug 18, 2026 11:53 UTC   <invalid>      ca                      no
controller-manager.conf    Aug 18, 2026 11:53 UTC   <invalid>      ca                      no
!MISSING! etcd-healthcheck-client
!MISSING! etcd-peer
!MISSING! etcd-server
front-proxy-client         Aug 18, 2026 11:53 UTC   <invalid>      front-proxy-ca          no
scheduler.conf             Aug 18, 2026 11:53 UTC   <invalid>      ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME  EXTERNALLY MANAGED
ca                      Jul 03, 2033 08:11 UTC   6y             no
!MISSING! etcd-ca
front-proxy-ca          Jul 03, 2033 08:11 UTC   6y             no
```

**Đọc được gì:**

- ⭐ **CA gốc còn hạn tới 2033 (`6y`)** — đây là thông tin quyết định toàn bộ hướng xử lý.
  CA còn sống ⇒ chỉ cần **ký lại cert lá bằng CA hiện có**. Không phải rebuild PKI, không phải
  cho node join lại, kubelet trên worker không bị ảnh hưởng. Đây là kịch bản **nhẹ nhất** trong
  các kịch bản cert hết hạn.
- **Toàn bộ 6 cert lá hết hạn cùng một mốc** `Aug 18, 2026 11:53 UTC`. Cùng giờ cùng phút ⇒ chúng
  được sinh cùng lúc, tức lần `kubeadm init`/`renew` gần nhất là **17-18/08/2025** (mặc định 1 năm).
- `RESIDUAL TIME = <invalid>` nghĩa là thời gian còn lại đã âm, không phải lỗi parse file.
- Cột `EXTERNALLY MANAGED = no` cho mọi dòng ⇒ **không** có công cụ ngoài (cert-manager, Vault PKI)
  đang quản cert này ⇒ renew bằng `kubeadm` sẽ không bị ghi đè ngược. An toàn.
- Dòng `Error reading configuration from the Cluster. Falling back to default configuration`:
  kubeadm không gọi được API server nên **không đọc được ConfigMap `kubeadm-config`**, phải dùng
  **cấu hình mặc định** để suy ra đường dẫn và tham số cert.
  ⇒ 🔴 **Rủi ro trực tiếp**: nếu cluster có `certSANs` tùy biến (ví dụ IP VIP), renew bằng default
  config có thể sinh cert **thiếu SAN đó** → mọi client đi qua VIP sẽ báo
  `x509: certificate is valid for ..., not <VIP>` → **HA hỏng nặng hơn trước khi sửa**. Đây là
  lý do bắt buộc phải chụp SAN cũ trước (lệnh 4.3).
- 5 mục etcd + `etcd-ca` đều `!MISSING!`:
  - ⇒ **Loại trừ được**: không phải lỗi quyền (đang chạy root, các file khác đọc được bình thường)
    ⇒ file thật sự **không tồn tại** trên node này.
  - ❓ **chưa xác minh** nguyên nhân. Xem phân tích ở mục 4, issue #3.

---

### 3.3 Tìm file cấu hình gốc để renew đúng SAN

**Node: 10.208.137.48 — `root`**

```
ls -la /etc/kubernetes/kubeadm-config.yaml
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-l` | Long format. **Mục đích chính ở đây là xem `mtime`** — biết file được ghi lần cuối bao giờ, để đối chiếu với thời điểm cluster thay đổi |
| `-a` | Hiện cả file ẩn. Ở lệnh này không có tác dụng (đã chỉ đích danh 1 file), giữ lại cho nhất quán với các lệnh `ls` khác |
| `/etc/kubernetes/kubeadm-config.yaml` | File Kubespray/kubeadm ghi ra đĩa khi dựng cluster, chứa `ClusterConfiguration` **gồm cả `certSANs`**. Đây là nguồn đáng tin để renew, thay vì đọc ngược từ cert cũ |

**Output:**

```
-rw-r----- 1 root root 4463 Jul  6  2023 /etc/kubernetes/kubeadm-config.yaml
```

**Đọc được gì:**

- ✅ File **tồn tại**, 4463 bytes — đủ lớn để chứa `ClusterConfiguration` đầy đủ.
- Quyền `-rw-r-----` root:root — chỉ root đọc được, đúng chuẩn.
- ⚠️ **mtime = `Jul 6 2023`** ⇒ cluster được dựng **06/07/2023**, và file này **không được cập nhật
  từ đó tới nay** (3 năm).
- ⇒ **Chưa thể kết luận file này còn đúng.** Xem đối chiếu mtime ở mục 3.4.

---

### 3.4 Xác định kiến trúc etcd (external hay stacked)

**Node: 10.208.137.48 — `root`**

```
ls -l /etc/kubernetes/manifests/
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-l` | Long format — cần `mtime` để phát hiện manifest nào từng bị sửa riêng lẻ |
| `/etc/kubernetes/manifests/` | Thư mục kubelet **watch liên tục**. Mọi file YAML trong đây được chạy thành **static pod** — pod do kubelet quản trực tiếp, không qua scheduler, sống được cả khi API server chết |

**Output:**

```
total 16
-rw------- 1 root root 4895 Sep 18  2024 kube-apiserver.yaml
-rw------- 1 root root 3086 Jul  6  2023 kube-controller-manager.yaml
-rw------- 1 root root 1677 Jul  6  2023 kube-scheduler.yaml
```

**Đọc được gì:**

- ✅ **XÁC NHẬN: etcd là EXTERNAL.** Chỉ có 3 manifest, **không có `etcd.yaml`**.
  ⇒ Giả thuyết A ở issue #3 **đúng**. Các dòng `!MISSING!` trong bảng cert chỉ là **cosmetic** —
  kubeadm in tên cert nó "kỳ vọng" có, không tìm thấy file vì kiến trúc này không dùng chúng.
  ⇒ **Issue #3 ĐÓNG**, không phải sự cố.
- ⭐ **Hệ quả lớn cho kế hoạch thao tác:** không có etcd trên master ⇒ **không có quorum etcd nào
  để mất** khi restart control-plane. Rủi ro "restart nhiều master cùng lúc làm chết cluster"
  **giảm mạnh** — nhưng vẫn giữ nguyên tắc tuần tự 48→49→50 để còn đường rollback nếu cert mới sai SAN.
- ⚠️ **PHÁT HIỆN BẤT NGỜ — mtime lệch nhau 14 tháng:**

  | File | mtime |
  |---|---|
  | `kube-controller-manager.yaml` | Jul 6 2023 |
  | `kube-scheduler.yaml` | Jul 6 2023 |
  | `kubeadm-config.yaml` (mục 3.3) | Jul 6 2023 |
  | **`kube-apiserver.yaml`** | **Sep 18 2024** |

  Cluster dựng 07/2023, nhưng **riêng apiserver manifest bị sửa 09/2024**, trong khi
  `kubeadm-config.yaml` **không** được cập nhật theo.
  ⇒ 🔴 Nếu lần sửa 09/2024 có thêm/bớt `certSANs`, thì file config 2023 **đã lỗi thời** và renew
  bằng nó sẽ sinh cert **thiếu SAN**.
  ⇒ **Không được tin `kubeadm-config.yaml` một cách mù quáng.** Bắt buộc so `certSANs` trong file
  với SAN thật của cert đang chạy (mục 3.5) trước khi dùng.
- ❓ **Chưa xác minh:** ai sửa và sửa gì vào 09/2024. Kiên là nhân viên mới, không phải người dựng
  cụm — cần hỏi sếp/người bàn giao.

---

### 3.5 ⭐ Chụp SAN của cert đang chạy (mốc so sánh bắt buộc trước khi renew)

**Node: 10.208.137.48 — `root`**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Alternative Name'
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `x509` | Sub-command thao tác chứng chỉ X.509 |
| `-in <file>` | Đọc cert từ file thay vì stdin |
| `-noout` | **Không** in lại khối PEM base64 — nếu thiếu cờ này, output dài vô ích |
| `-text` | Decode cert sang dạng người đọc được (subject, issuer, hạn, extensions...) |
| `grep -A2` | `-A2` = in thêm **2 dòng SAU** dòng khớp. Chọn 2 (không phải 1) vì danh sách SAN dài **tràn sang dòng thứ hai** — đúng như output dưới |

**Output:**

```
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:lb-apiserver.kubernetes.local, DNS:localhost, DNS:vrp-kubeengine01, DNS:vrp-kubeengine01.vrp, DNS:vrp-kubeengine02, DNS:vrp-kubeengine02.vrp, DNS:vrp-kubeengine03, DNS:vrp-kubeengine03.vrp, IP Address:172.16.128.1, IP Address:10.208.137.48, IP Address:127.0.0.1, IP Address:10.208.137.68, IP Address:10.208.137.49, IP Address:10.208.137.50
Signature Algorithm: sha256WithRSAEncryption
```

**Bóc tách SAN — 18 entry, cert mới BẮT BUỘC giữ đủ:**

| Loại | Entry | Vai trò |
|---|---|---|
| DNS mặc định | `kubernetes`, `kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local` | Service `kubernetes` trong cluster — pod gọi API qua tên này |
| ⭐ DNS endpoint | **`lb-apiserver.kubernetes.local`** | **Endpoint mọi node dùng.** Mất entry này = toàn cụm hỏng |
| DNS localhost | `localhost` | Truy cập từ chính node |
| DNS hostname | `vrp-kubeengine01/02/03` + biến thể `.vrp` | 3 master. **Không có `04`, `05`** — bình thường, worker không cần trong SAN apiserver |
| IP ClusterIP | `172.16.128.1` | ClusterIP của svc `kubernetes` ⇒ service CIDR là `172.16.128.0/x` (**không** phải mặc định `10.96.0.0/12` của kubeadm, cũng không phải `10.233.0.0/18` của Kubespray) |
| IP master | `10.208.137.48`, `.49`, `.50` | 3 master, khớp Kiên xác nhận |
| IP loopback | `127.0.0.1` | Truy cập apiserver từ chính node. **Entry chuẩn của mọi cluster** — không nói gì về cơ chế LB (xem Bài học #11) |
| ⚠️ IP lạ | **`10.208.137.68`** | **Không thuộc master 48-50, cũng không thuộc worker 51-55** |

**Đọc được gì:**

- ✅ **Xác nhận `lb-apiserver.kubernetes.local` có trong SAN** — khớp hoàn toàn với output 3.0.
  Rủi ro ở issue #4 là **thật**: renew trần sẽ làm mất entry này.
- ⚠️ ~~Xác nhận cơ chế LB cục bộ: SAN có cả `127.0.0.1` và đủ 3 IP master~~
  ❌ **KẾT LUẬN NÀY SAI — đã bác bỏ bởi output 3.7.** `127.0.0.1` gần như **luôn** có trong SAN
  apiserver của mọi cluster (để truy cập từ chính node), **không** phải chữ ký của localhost-LB.
  Cơ chế LB thật chỉ đọc được từ `/etc/hosts`. Xem Bài học #11.
- ✅ **`10.208.137.68`** — đã xác định ở output 3.7: đây là **VIP / LB endpoint**
  (`/etc/hosts` map `lb-apiserver.kubernetes.local` → IP này). Bắt buộc giữ nguyên trong cert mới.
- Service CIDR `172.16.128.0/x` là **tùy biến**, không phải mặc định của kubeadm lẫn Kubespray.
  ⇒ Cluster này có cấu hình riêng ⇒ **càng khẳng định không được renew bằng default config.**
- ⇒ **Loại trừ được:** cert hiện tại **không hỏng về nội dung** — SAN đầy đủ, thuật toán
  `sha256WithRSAEncryption` bình thường. Vấn đề **duy nhất** là hết hạn.

---

### 3.6 ⭐ Đối chiếu `certSANs` trong file config với SAN thật của cert

**Node: 10.208.137.48 — `root`**

```
grep -A30 'certSANs' /etc/kubernetes/kubeadm-config.yaml
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `-A30` | In **30 dòng SAU** dòng khớp. **Vì sao 30 mà không phải 2** như lệnh `openssl` ở 3.5: `openssl` in SAN thành **một dòng dài** (18 entry cách nhau bởi dấu phẩy) nên `-A2` là đủ; còn YAML thì **mỗi entry một dòng** (`- ten`) — dùng `-A2` sẽ cắt mất 16 entry, đọc thiếu, soạn config sai |
| `'certSANs'` | Khoá YAML trong `ClusterConfiguration.apiServer` chứa danh sách SAN **khai thủ công** |

**Output:**

```
  certSANs:
  - kubernetes
  - kubernetes.default
  - kubernetes.default.svc
  - kubernetes.default.svc.vrp
  - 172.16.128.1
  - localhost
  - 127.0.0.1
  - vrp-kubeengine01
  - vrp-kubeengine02
  - vrp-kubeengine03
  - lb-apiserver.kubernetes.local
  - 10.208.137.68
  - 10.208.137.48
  - 10.208.137.49
  - 10.208.137.50
  - vrp-kubeengine01.vrp
  - vrp-kubeengine02.vrp
  - vrp-kubeengine03.vrp
  timeoutForControlPlane: 5m0s
controllerManager:
  extraArgs:
    node-monitor-grace-period: 40s
    node-monitor-period: 5s
    cluster-cidr: "172.16.0.0/17"
    service-cluster-ip-range: "172.16.128.0/17"
    node-cidr-mask-size: "24"
    profiling: "False"
    terminated-pod-gc-threshold: "12500"
    bind-address: 0.0.0.0
    leader-elect-lease-duration: 15s
```

**Đối chiếu 18 entry file config ↔ SAN cert thật (output 3.5):**

| # | `certSANs` trong file (2023) | Có trong cert đang chạy? |
|---|---|---|
| 1-3 | `kubernetes`, `kubernetes.default`, `kubernetes.default.svc` | ✅ |
| 4 | **`kubernetes.default.svc.vrp`** | ⚠️ **KHÔNG thấy** trong output 3.5 — xem ghi chú dưới |
| 5 | `172.16.128.1` | ✅ |
| 6-7 | `localhost`, `127.0.0.1` | ✅ |
| 8-10 | `vrp-kubeengine01`, `02`, `03` | ✅ |
| 11 | `lb-apiserver.kubernetes.local` | ✅ |
| 12 | `10.208.137.68` | ✅ |
| 13-15 | `10.208.137.48`, `.49`, `.50` | ✅ |
| 16-18 | `vrp-kubeengine01.vrp`, `02.vrp`, `03.vrp` | ✅ |
| — | `kubernetes.default.svc.cluster.local` | ✅ có trong cert, **KHÔNG có** trong file config |

**Đọc được gì:**

- ✅ **File config `kubeadm-config.yaml` (2023) KHỚP với cert đang chạy** — 17/18 entry trùng khít,
  gồm cả `lb-apiserver.kubernetes.local` và IP `10.208.137.68`.
  ⇒ **Nghi vấn "file 2023 lỗi thời" (issue #7) — BÁC BỎ.** Lần sửa `kube-apiserver.yaml` ngày
  18/09/2024 **không đụng tới `certSANs`**.
  ⇒ **Dùng được `--config /etc/kubernetes/kubeadm-config.yaml` để renew.** Đây là kết quả tốt nhất
  có thể — không phải tự soạn file config.
- ⚠️ **Một cặp entry lệch chiều nhau (không phải lỗi, nhưng phải biết):**

  | Entry | File config | Cert thật |
  |---|---|---|
  | `kubernetes.default.svc.vrp` | ✅ có | ❌ không thấy ở output 3.5 |
  | `kubernetes.default.svc.cluster.local` | ❌ không có | ✅ có |

  Giải thích: kubeadm **tự động** thêm `kubernetes.default.svc.<clusterDomain>` vào SAN, độc lập
  với `certSANs` khai trong file. Cluster domain thật của cụm này là `.vrp` (khớp hostname
  `vrp-kubeengine01.vrp`), nhưng cert lại chứa `cluster.local` — giá trị **mặc định** của kubeadm.
  ⇒ Suy ra: lần sinh cert gần nhất, kubeadm dùng `clusterDomain` mặc định `cluster.local`, còn
  entry `.vrp` khai thủ công trong file **có thể đã không được áp dụng**.
  ⇒ **Hệ quả khi renew kèm `--config`:** cert mới **có thể có thêm** `kubernetes.default.svc.vrp`.
  Đây là **thêm** SAN, không phải mất — **vô hại**, nhưng phải biết trước để không hoảng khi so sánh.
  ❓ **Chưa xác minh:** output 3.5 có thể bị cắt khi gõ lại từ screenshot. Cần kiểm lại bằng lệnh
  đếm chính xác (mục A1-bis).
- **Thông tin nền thu được thêm** (ngoài phạm vi cert nhưng đáng ghi):

  | Tham số | Giá trị | Ý nghĩa |
  |---|---|---|
  | `cluster-cidr` | `172.16.0.0/17` | Dải IP cấp cho **pod** |
  | `service-cluster-ip-range` | `172.16.128.0/17` | Dải IP cấp cho **service** — khớp ClusterIP `172.16.128.1` ở output 3.5 |
  | `node-cidr-mask-size` | `24` | Mỗi node được cấp `/24` = 254 pod/node |
  | `terminated-pod-gc-threshold` | `12500` | Ngưỡng dọn pod đã kết thúc — **cao bất thường** (mặc định 12500 là giá trị k8s mặc định, nhưng đáng chú ý) |
  | `timeoutForControlPlane` | `5m0s` | Thời gian kubeadm chờ control-plane sẵn sàng |

---

### 3.7 🔴 Xác định cơ chế LB — phát hiện quan trọng, lật ngược giả định trước đó

**Node: 10.208.137.48 — `root`**

```
grep lb-apiserver /etc/hosts
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `/etc/hosts` | File map hostname → IP ở **tầng OS**, được tra **TRƯỚC** DNS. Đây là nơi Kubespray ghi ánh xạ cho endpoint LB |
| (không dùng cờ) | Chỉ cần khớp chuỗi đơn giản, không cần regex |

**Output:**

```
10.208.137.68  lb-apiserver.kubernetes.local
```

**Đọc được gì:**

- 🔴 ⭐ **`10.208.137.68` LÀ VIP / LB TẬP TRUNG** — ẩn số lớn nhất còn lại đã có lời giải.
  Không phải node cũ, không phải IP dự phòng.
- ❌ **GIẢ ĐỊNH TRƯỚC ĐÓ SAI:** đã dự đoán Kubespray dùng **localhost-LB**
  (`127.0.0.1 lb-apiserver.kubernetes.local`, nginx cục bộ mỗi node). Thực tế cụm này dùng
  **LB tập trung** tại `.68`. Xem Bài học #11.
- ⭐ **Hệ quả TRỰC TIẾP tới kế hoạch restart** — khác hẳn kịch bản localhost-LB:

  | | Localhost-LB (đã dự đoán sai) | **LB tập trung (thực tế)** |
  |---|---|---|
  | Đường đi của client | node → nginx cục bộ → 3 master | node → **`.68`** → 3 master |
  | Restart master 48 | Node khác **tự failover** sang 49/50, không ai mất kết nối | **Phụ thuộc hoàn toàn** vào health-check của `.68` |
  | Rủi ro | Thấp | **Nếu `.68` không health-check → 1/3 request rơi vào node đang restart** |

  ⇒ **Việc mới bắt buộc:** phải xác minh `.68` có health-check không **trước khi** restart master.
- ~~❓ Chưa xác minh: `.68` là keepalived VIP nổi trên master hay LB ngoài?~~
  ✅ **ĐÃ TRẢ LỜI ở output 3.8: LB NGOÀI CỤM.** Không master nào mang IP này.
  ⇒ Kịch bản "VIP nhảy khi restart node đang giữ nó" **không xảy ra**. Master restart không đụng VIP.
  ⇒ Phần lo ngại về thứ tự restart ở bảng trên **được gỡ bỏ**; chỉ còn câu hỏi health-check.

---

### 3.8 ⭐ Xác định VIP nằm trong hay ngoài cụm — quyết định thứ tự restart

**Chạy trên CẢ 3 master: 48, 49, 50**

```
ip addr | grep 137.68
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `ip addr` | Liệt kê **mọi** địa chỉ IP trên **mọi** interface, **kể cả IP thứ cấp/VIP** do keepalived gắn thêm. Đây là lý do dùng `ip addr` chứ không phải `hostname -I` (chỉ ra IP chính) |
| `grep 137.68` | Lọc VIP. Dùng chuỗi ngắn `137.68` thay vì IP đầy đủ để dễ gõ tay qua VDI, vẫn đủ chính xác trong ngữ cảnh này |
| ⚠️ Đọc kết quả rỗng | **Output rỗng KHÔNG phải lệnh lỗi** — là "không có interface nào mang IP này". Đây chính là thông tin cần |

**Output:**

```
[root@vrp-kubeengine01 ~]# ip addr | grep 137.68
[root@vrp-kubeengine01 ~]#
```

```
[root@vrp-kubeengine02 ~]# ip addr | grep 137.68
[root@vrp-kubeengine02 ~]#
```

```
[root@vrp-kubeengine03 ~]# ip addr | grep 137.68
[root@vrp-kubeengine03 ~]#
```

**Rỗng trên cả 3 node.**

**Đọc được gì:**

- ✅ ⭐ **VIP `10.208.137.68` nằm HOÀN TOÀN NGOÀI cụm K8s.** Không master nào mang IP này.
- ⇒ **Loại trừ được: KHÔNG phải keepalived VIP nổi trên master.** Đây là kịch bản đã lo ngại
  ở output 3.7 — nay bác bỏ.
- ⇒ **Loại trừ được: không có split-brain keepalived** (kịch bản nhiều node cùng giữ VIP).
- ⭐ **Hệ quả TRỰC TIẾP — đây là kịch bản TỐT NHẤT cho việc restart:**

  | Kịch bản | Ảnh hưởng khi restart master | Thực tế? |
  |---|---|---|
  | Keepalived VIP trên master | VIP nhảy sang node khác, gián đoạn vài giây. Node giữ VIP phải restart **sau cùng** | ❌ Không |
  | Split-brain keepalived | Sự cố riêng, phải xử lý trước | ❌ Không |
  | **LB ngoài cụm** | **Master restart KHÔNG đụng tới VIP.** VIP vẫn sống, vẫn phân phối | ✅ **ĐÚNG** |

  ⇒ Thứ tự 48→49→50 **không còn ràng buộc "node nào phải sau cùng"**. Giữ tuần tự chỉ để còn
  đường rollback nếu cert mới sai SAN.
- ❓ **Chưa xác minh (và KHÔNG tự xác minh được từ trong cụm):** LB ngoài đó có **health-check**
  port 6443 không. Nếu không có, trong lúc master 48 restart thì LB vẫn đẩy ~1/3 request vào nó.
  ⇒ **Đây là ràng buộc phạm vi, không phải việc chưa làm** — thiết bị thuộc đội hạ tầng mạng.
  Xem mục "Cần hỏi người khác".

---

### 3.9 Kiểm tra có tiến trình LB chạy trên master không

**Node: 10.208.137.48 — `root`**

```
systemctl list-units --type=service --state=running | grep -Ei 'keepalived|haproxy|nginx'
```

| Cờ / Thành phần | Ý nghĩa |
|---|---|
| `list-units` | Liệt kê unit systemd đã nạp |
| `--type=service` | Chỉ lấy loại `.service`, bỏ `mount`/`socket`/`timer` cho gọn output |
| `--state=running` | **Chỉ unit ĐANG CHẠY.** Quan trọng: bỏ qua unit đã cài nhưng không bật — tránh dương tính giả |
| `grep -Ei` | `-E` regex mở rộng (`\|` là OR không cần escape); `-i` bỏ qua hoa/thường, phòng trường hợp unit tên `HAProxy` |

**Output:**

```
[root@vrp-kubeengine01 ~]# systemctl list-units --type=service --state=running | grep -Ei 'keepalived|haproxy|nginx'
[root@vrp-kubeengine01 ~]#
```

**Rỗng.**

**Đọc được gì:**

- ✅ **Master 48 KHÔNG chạy keepalived, haproxy, hay nginx.** Củng cố kết luận ở 3.8: không có
  thành phần LB nào trên master.
- ⇒ **Câu hỏi tự nhiên: vậy cái gì phân phối request tới 3 master?**
  Trả lời: **LB ngoài trỏ thẳng tới `10.208.137.48/49/50:6443`**. Khớp với việc **cả 3 IP master
  đều có trong SAN cert** (output 3.5) — LB gọi trực tiếp từng master nên cert phải hợp lệ cho
  từng IP, không chỉ cho tên `lb-apiserver.kubernetes.local`.
- ⚠️ **Giới hạn của bằng chứng này:** chỉ chạy trên **master 48**. Chưa kiểm 49/50.
  Rủi ro thấp (cấu hình 3 master thường đồng nhất) nhưng **chưa xác minh**.
  ⇒ Không chặn việc renew — nếu 49/50 có haproxy thì cũng chỉ là LB dự phòng, không đổi kết luận
  "VIP ở ngoài".
- ❓ Nếu cụm chạy LB dạng **static pod** thay vì systemd service, lệnh này sẽ không thấy.
  Kiểm bổ sung bằng `crictl ps | grep -Ei 'haproxy|nginx'` — nhưng output 3.4 đã cho thấy
  `/etc/kubernetes/manifests/` chỉ có 3 file (apiserver, controller-manager, scheduler),
  **không có manifest LB nào** ⇒ khả năng này đã bị loại trừ.

---

### 3.10 — [Node 48 / GĐ0] Tiền kiểm trước khi renew

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~10:36 +07 ngày 19/08**

Chạy liền 4 lệnh của Giai đoạn 0.

**a) Đếm số SAN entry của cert hiện tại**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
```

**Output:**

```
18
```

**b) Version kubeadm**

```
kubeadm version -o short
```

**Output:**

```
v1.23.2
```

**c) Version apiserver đang chạy**

```
grep image: /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Output:**

```
    image: 10.60.129.132:8090/kube-apiserver:v1.23.2
```

**d) Ghi SAN hiện tại ra file mốc**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A3 'Alternative Name' > /root/san-truoc-renew-48.txt
```

**Output:** (không in gì — đúng, vì đã chuyển hướng vào file; không có thông báo lỗi)

**Đọc được gì:**

- ✅ **SAN = 18 entry**, khớp chính xác số entry `certSANs` trong `kubeadm-config.yaml` (output 3.6).
  ⇒ Xác nhận cert **KHÔNG có** `kubernetes.default.svc.vrp`, **CÓ** `kubernetes.default.svc.cluster.local`.
  ⇒ **Dự đoán cho GĐ3:** renew kèm `--config` sẽ **THÊM** `kubernetes.default.svc.vrp` → SAN mới
  thành **19 entry**. Đây là **thêm**, không phải mất ⇒ `diff` hiện dòng `>` là **BÌNH THƯỜNG**.
- ✅ **Version khớp khít:** `kubeadm v1.23.2` = `kube-apiserver:v1.23.2`.
  ⇒ **Loại trừ được** rủi ro "binary kubeadm lệch version cluster sinh cert khác kỳ vọng".
- ✅ File mốc `/root/san-truoc-renew-48.txt` đã tạo, không lỗi ⇒ GĐ3 có cái để `diff`.
- 🔴 ⭐ **PHÁT HIỆN MỚI — Kubernetes v1.23.2 đã END-OF-LIFE.**
  v1.23 phát hành 12/2021, hết hỗ trợ chính thức **02/2023** — quá hạn hơn 3 năm.
  **Không chặn việc renew**, nhưng có 2 hệ quả cụ thể:
  1. ⚠️ **Ảnh hưởng TRỰC TIẾP tới GĐ2:** hành vi cờ `--config` của `kubeadm certs renew` ở nhánh
     1.23 kém ổn định hơn bản mới — có trường hợp kubeadm **bỏ qua `certSANs`** nếu file config
     có nhiều document YAML (`InitConfiguration` + `ClusterConfiguration` ngăn bởi `---`).
     ⇒ **Bước so SAN ở GĐ3 càng bắt buộc**, không được coi là thủ tục.
     ⇒ Cần kiểm cấu trúc file config **trước khi** renew — xem mục 3.11.
  2. Registry nội bộ `10.60.129.132:8090` — image kéo từ registry riêng (Harbor?), không phải
     `registry.k8s.io`. Phù hợp môi trường air-gapped. ❓ Chưa rõ registry này còn hoạt động
     không — **quan trọng khi restart**: nếu kubelet phải kéo lại image mà registry chết thì
     static pod không lên được. Xem rủi ro mới ở mục 8.

---

### 3.11 — [Node 48 / GĐ0-bis] 🔴 Cấu trúc file config KHÔNG dùng được cho `--config`

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ngày 19/08**

**a) Đếm số YAML document**

```
grep -c '^---' /etc/kubernetes/kubeadm-config.yaml
```

**Output:**

```
3
```

**b) Các `kind` có trong file**

```
grep '^kind:' /etc/kubernetes/kubeadm-config.yaml
```

**Output:**

```
kind: InitConfiguration
kind: ClusterConfiguration
kind: KubeProxyConfiguration
kind: KubeletConfiguration
```

**c) Image apiserver trong cache cục bộ**

```
crictl images | grep kube-apiserver
```

**Output:**

```
10.60.129.132:8090/kube-apiserver    v1.23.2    8a0228dd6a683    32.6MB
```

**Đọc được gì:**

- 🔴 ⭐ **KHÔNG ĐƯỢC chạy `kubeadm certs renew all --config /etc/kubernetes/kubeadm-config.yaml`
  như quy trình đã soạn.** File chứa **4 document** (3 dấu `---` ngăn 4 object).

  **Cơ chế hỏng:** `kubeadm certs renew --config` ở nhánh **v1.23** dùng
  `LoadOrDefaultInitConfiguration` để parse file. Hàm này hiểu `InitConfiguration` và
  `ClusterConfiguration`, nhưng gặp `KubeProxyConfiguration` / `KubeletConfiguration` thì tuỳ
  bản mà **báo lỗi `unknown kind`** hoặc **im lặng bỏ qua toàn bộ file** → rơi về **default config**.

  ⇒ Rơi về default = đúng thảm hoạ đang muốn tránh: cert mới mất `lb-apiserver.kubernetes.local`,
  mất VIP `10.208.137.68`, mất ClusterIP `172.16.128.1` → **toàn cụm hỏng**.

  ⚠️ **Nguy hiểm nhất:** nếu kubeadm **im lặng** bỏ qua, lệnh **vẫn báo "renewed" thành công**.
  Không có dấu hiệu gì bất thường. Chỉ bước `diff` SAN ở GĐ3 mới lộ ra.

  ⇒ **Cách gỡ:** tách file mới chỉ chứa `ClusterConfiguration`, giữ nguyên `certSANs` —
  xem GIAI ĐOẠN 0-ter trong quy trình.

- ✅ **Image CÓ trong cache cục bộ**: `10.60.129.132:8090/kube-apiserver:v1.23.2`,
  ID `8a0228dd6a683`, 32.6MB.
  ⇒ Khi restart ở GĐ4, kubelet **dùng image từ cache**, **không gọi ra registry**.
  ⇒ **Loại trừ được** rủi ro "registry nội bộ chết làm static pod không lên được".
  ⚠️ Mới kiểm trên node 48. Node 49/50 nên kiểm tương tự trước khi restart node đó.

- ❓ **Chưa xác minh:** bản v1.23.2 cụ thể này báo lỗi hay im lặng khi gặp `unknown kind`.
  **Không cần biết** — cách gỡ (tách file) an toàn cho cả hai trường hợp.

---

### 3.12 — [Node 48 / GĐ0-ter] Ranh giới `ClusterConfiguration` + 4 phát hiện mới

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~10:48 +07 ngày 19/08**

**a) Vị trí các document**

```
grep -n '^---\|^kind:' /etc/kubernetes/kubeadm-config.yaml
```

**Output:**

```
2:kind: InitConfiguration
13:---
15:kind: ClusterConfiguration
120:---
122:kind: KubeProxyConfiguration
160:---
162:kind: KubeletConfiguration
```

**b) Nội dung file** (`cat -n`, trích các dòng quyết định)

```
  1  apiVersion: kubeadm.k8s.io/v1beta2
  2  kind: InitConfiguration
  4    advertiseAddress: 10.208.137.48
 13  ---
 14  apiVersion: kubeadm.k8s.io/v1beta2      ← ⭐ BẮT ĐẦU khối cần cắt
 15  kind: ClusterConfiguration
 16  clusterName: vrp
 17  etcd:
 18    external:
 19      endpoints:
 20      - https://10.208.137.48:2379
 21      - https://10.208.137.49:2379
 22      - https://10.208.137.50:2379
 23      caFile: /etc/ssl/etcd/ssl/ca.pem
 24      certFile: /etc/ssl/etcd/ssl/node-vrp-kubeengine01.pem
 25      keyFile: /etc/ssl/etcd/ssl/node-vrp-kubeengine01-key.pem
 30  networking:
 31    dnsDomain: vrp
 32    serviceSubnet: "172.16.128.0/17"
 33    podSubnet: "172.16.0.0/17"
 34  kubernetesVersion: v1.23.2
 35  controlPlaneEndpoint: lb-apiserver.kubernetes.local:6443
 36  certificatesDir: /etc/kubernetes/ssl        ← 🔴 KHÔNG phải /etc/kubernetes/pki
 37  imageRepository: 10.60.129.132:8890
 78    certSANs:
 79    - kubernetes
 ...
 96    - vrp-kubeengine03.vrp
 97    timeoutForControlPlane: 5m0s
119        readOnly: true                       ← ⭐ KẾT THÚC khối cần cắt
120  ---
122  kind: KubeProxyConfiguration
162  kind: KubeletConfiguration
```

**Đọc được gì:**

- ✅ **Ranh giới cắt: dòng `14` → `119`.** Lấy từ dòng 14 (`apiVersion`) vì trường này **bắt buộc**
  phải đi kèm `kind`; kết thúc ở 119, ngay **trước** dấu `---` ở dòng 120.
- 🔴 ⭐ **PHÁT HIỆN NGHIÊM TRỌNG — `certificatesDir: /etc/kubernetes/ssl`** (dòng 36),
  **KHÔNG phải `/etc/kubernetes/pki`** như mặc định kubeadm.

  ⚠️ **Mọi lệnh `openssl` trong quy trình đang trỏ `/etc/kubernetes/pki/apiserver.crt`.**
  Nếu kubeadm ghi cert mới vào `/etc/kubernetes/ssl/` thì:
  - File SAN mốc `/root/san-truoc-renew-48.txt` (output 3.10) có thể **không phải cert đang chạy**
  - Bước `diff` ở GĐ3 sẽ so **nhầm file** → không phát hiện được cert mới thiếu SAN

  ⇒ Nhưng lệnh 0.1 (output 3.10) **chạy được** và ra 18 entry ⇒ `/etc/kubernetes/pki/apiserver.crt`
  **có tồn tại**. Hai khả năng: (a) `pki` là **symlink** tới `ssl` — Kubespray hay làm vậy;
  (b) hai thư mục riêng biệt, cert ở `pki` là bản cũ/thừa.
  ⇒ ❓ **PHẢI XÁC MINH TRƯỚC KHI RENEW** — xem GĐ0-quater.

- ✅ **`etcd.external` (dòng 17-25) — XÁC NHẬN DỨT ĐIỂM** etcd external, endpoints trỏ
  `10.208.137.48/49/50:2379`, cert etcd riêng ở `/etc/ssl/etcd/ssl/`.
  ⇒ Củng cố output 3.4. Cert etcd **không** do `kubeadm certs renew` quản ⇒ nằm ngoài phạm vi
  việc này, nhưng ❓ **chưa kiểm hạn** — cert etcd hết hạn sẽ gây sự cố riêng.
- ✅ **`dnsDomain: vrp` (dòng 31)** — cluster domain thật là **`vrp`**, không phải `cluster.local`.
  ⇒ **Giải thích được điểm lệch ở output 3.6**: file khai `kubernetes.default.svc.vrp` (đúng theo
  dnsDomain), nhưng cert đang chạy lại có `kubernetes.default.svc.cluster.local` (giá trị mặc định
  kubeadm). Nghĩa là lần sinh cert gần nhất, `dnsDomain` **chưa được áp dụng** vào SAN.
  ⇒ Renew kèm `--config` sẽ **thêm** `kubernetes.default.svc.vrp` → SAN 18 → **19 entry**.
- ✅ `certSANs` nằm **dòng 78-96**, đủ 18 entry, khớp output 3.6.
- ✅ `controlPlaneEndpoint: lb-apiserver.kubernetes.local:6443` (dòng 35) — khớp output 3.0.
- ⚠️ **`imageRepository: 10.60.129.132:8890`** (dòng 37) — cổng **8890**, trong khi image thật
  đang chạy là `10.60.129.132:8890/kube-apiserver` (output 3.11 hiện `8890`).
  ⇒ Khớp nhau. (Ghi chú: đọc từ screenshot qua VDI, cần soi kỹ 8890 vs 8090 khi thao tác.)

---

### 3.13 — [Node 48 / GĐ0-quater] ✅ `pki` là symlink tới `ssl` — quy trình KHÔNG phải sửa

**📍 Node 48 (`vrp-kubeengine01`) — user `vt_admin`** (lệnh chỉ đọc, không cần root)

```
ls -ld /etc/kubernetes/pki /etc/kubernetes/ssl
```

**Output:**

```
lrwxrwxrwx 1 root root   19 Jul  6  2023 /etc/kubernetes/pki -> /etc/kubernetes/ssl
drwxr-xr-x 2 kube root 4096 Jul  6  2023 /etc/kubernetes/ssl
```

**Đọc được gì:**

- ✅ ⭐ **`/etc/kubernetes/pki` là SYMLINK trỏ tới `/etc/kubernetes/ssl`.**
  Bằng chứng: ký tự đầu dòng là **`l`** (không phải `d`), kèm ký hiệu `-> /etc/kubernetes/ssl`,
  và kích thước `19` chính là độ dài chuỗi đường dẫn đích.
  ⇒ **Hai tên, MỘT thư mục.**
- ✅ ⇒ **Issue #11 ĐÓNG. Quy trình KHÔNG phải sửa gì:**
  - Mọi lệnh `openssl ... /etc/kubernetes/pki/apiserver.crt` **vẫn đọc đúng** cert đang chạy
  - File mốc `/root/san-truoc-renew-48.txt` (output 3.10) **đúng file**
  - Bước `diff` ở GĐ3 sẽ **so đúng file**, phát hiện được nếu cert mới thiếu SAN
  - Lệnh backup PKI ở GĐ1 (`tar czf ... /etc/kubernetes/pki`) vẫn gói đúng nội dung
- ⚠️ **Chi tiết phụ 1 — owner là `kube:root`, không phải `root:root`.**
  Kubespray tạo user hệ thống `kube` để chạy control-plane.
  ⇒ `kubeadm certs renew` chạy dưới `root` sẽ ghi cert mới với owner **`root:root`**, khác owner
  hiện tại. Với quyền thư mục `755` thì static pod **vẫn đọc được** (chạy privileged, mount
  hostPath) ⇒ **không chặn renew**.
  ⇒ Ghi lại để **không hoang mang** nếu thấy owner đổi sau renew — đó là bình thường.
- ⚠️ **Chi tiết phụ 2 — quyền thư mục `drwxr-xr-x` (755).**
  Kubeadm mặc định đặt `700` cho thư mục cert. `755` nghĩa là **mọi user trên node đọc được
  danh sách file** trong đó. Các file `.key` bên trong vẫn cần là `600` — ❓ chưa kiểm.
  ⇒ **Ngoài phạm vi việc renew**, nhưng là nợ kỹ thuật đáng ghi.
- 📌 **Ghi chú thao tác:** lệnh này chạy dưới `vt_admin` (không phải `root`) vẫn ra kết quả, vì
  `ls -ld` chỉ đọc metadata thư mục — không cần quyền đọc nội dung bên trong.

---

### 3.14 — [Node 48 / GĐ0-quater + 0-ter] Backup + tách file config

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ngày 19/08**

**a) Backup file config gốc**

```
cp -a /etc/kubernetes/kubeadm-config.yaml /root/kubeadm-config.yaml.bak-$(date +%F-%H%M)
```

**b) Backup thư mục manifests (GĐ4 sẽ đổi tên nó)**

```
cp -a /etc/kubernetes/manifests /root/manifests-backup-$(date +%F-%H%M)
```

**c) Tách khối `ClusterConfiguration` ra file riêng**

```
sed -n '14,119p' /etc/kubernetes/kubeadm-config.yaml > /root/cluster-config-renew.yaml
```

**Output:** cả 3 lệnh **không in gì**, quay lại prompt sạch.

**Đọc được gì:**

- ✅ **Cả 3 lệnh chạy thành công.** `cp` và `sed` theo triết lý Unix chỉ lên tiếng khi có lỗi
  ⇒ im lặng = không lỗi. Không có `No such file`, `Permission denied`, hay `No space left`.
- ✅ Đã có 2 bản backup ở `/root/` theo quy tắc backup Kiên đặt.
- ⚠️ ⭐ **NHƯNG: rỗng KHÔNG chứng minh nội dung file tách ra là ĐÚNG.**

  Áp dụng đúng Bài học #12 — *"output rỗng là bằng chứng, nhưng phải biết trước rỗng nghĩa là gì"*.
  Ở đây **rỗng = không lỗi cú pháp/quyền**, KHÔNG phải **rỗng = file có đủ `certSANs`**.

  **Kịch bản hỏng cụ thể:** nếu số dòng `14,119` đọc nhầm từ screenshot (VDI, chữ nhỏ), file cắt
  ra có thể **thiếu `certSANs`** hoặc **lẫn document khác** — mà lệnh `sed` **vẫn chạy thành công,
  vẫn im lặng**. Kubeadm sau đó đọc file sai rồi **im lặng rơi về default config** (bẫy đã bàn ở
  output 3.11) ⇒ cert mới mất SAN ⇒ toàn cụm hỏng.

  ⇒ **Bước verify 0t.4 là chỗ DUY NHẤT bắt được lỗi này trước khi cert bị ghi đè.**
  Không được bỏ qua.

- ❓ **Chưa xác minh:** nội dung `/root/cluster-config-renew.yaml`. Xem mục 3.15.

---

### 3.15 — [Node 48 / GĐ0-ter] ✅ Verify file tách: ĐẠT cả 3 phép kiểm

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~11:02 +07 ngày 19/08**

**a) Đếm số YAML document trong file đã tách**

```
grep -c '^---\|^kind:' /root/cluster-config-renew.yaml
```

**Output:**

```
1
```

**b) Đếm số entry `certSANs`**

```
sed -n '/certSANs:/,/timeoutForControlPlane/p' /root/cluster-config-renew.yaml | grep -c '^  - '
```

**Output:**

```
18
```

**c) Xác nhận file kết thúc đúng chỗ**

```
tail -3 /root/cluster-config-renew.yaml
```

**Output:**

```
      hostPath: /etc/kubernetes/kubescheduler-config.yaml
      mountPath: /etc/kubernetes/kubescheduler-config.yaml
      readOnly: true
```

**Đọc được gì:**

- ✅ **`1` document** — đúng một `kind: ClusterConfiguration`, **không có dấu `---` nào**.
  ⇒ Giải quyết đúng vấn đề ở output 3.11 (file gốc có 4 document, kubeadm v1.23 không parse được).
- ✅ **`18` entry `certSANs`** — khớp **cả ba** nguồn độc lập:
  file config gốc (output 3.6), cert đang chạy (output 3.10), và file vừa tách.
  ⇒ Không mất entry nào trong lúc cắt. Ba entry sống còn
  (`lb-apiserver.kubernetes.local`, `10.208.137.68`, `172.16.128.1`) đều nằm trong số này.
- ✅ **3 dòng cuối đúng y hệt dòng 117-119 của file gốc** (output 3.12) — `readOnly: true` của
  khối `scheduler.extraVolumes`.
  ⇒ File kết thúc **đúng dòng 119**, không cắt lố sang `---` (dòng 120) lẫn
  `kind: KubeProxyConfiguration` (dòng 122), cũng không cụt giữa chừng.
- ⭐ **Ba phép kiểm ĐỘC LẬP nhau, cùng chỉ một kết luận** — đây là điều làm kết luận đáng tin:
  đếm document (cấu trúc), đếm SAN (nội dung), xem dòng cuối (ranh giới). Một phép sai thì hai
  phép kia sẽ lệch theo.
  ⇒ **`sed -n '14,119p'` cắt CHÍNH XÁC.** File `/root/cluster-config-renew.yaml` dùng được cho
  `--config`.
- ❓ **Còn một điều chưa chứng minh:** file đúng **nội dung và cấu trúc**, nhưng chưa chắc
  **kubeadm v1.23 thực sự nuốt được**. Đó là hai việc khác nhau — đúng theo Bài học #14.
  ⇒ Bước `--dry-run` (0t.5) mới là phép kiểm cuối cùng.

---

### 3.16 — [Node 48 / GĐ0-ter] `--dry-run` KHÔNG được hỗ trợ ở kubeadm v1.23

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ngày 19/08**

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml --dry-run
```

**Output:**

```
unknown flag: --dry-run
To see the stack trace of this error execute with --v=5 or higher
```

**Đọc được gì:**

- ✅ **Không phải lỗi thao tác.** Đây là khả năng **đã lường trước** khi soạn bước 0t.5:
  `--dry-run` được thêm cho `kubeadm certs renew` ở bản **v1.26+**; v1.23.2 chưa có.
  ⇒ Thêm một biểu hiện cụ thể của việc chạy version EOL (Bài học #15).
- ✅ **Loại trừ được: KHÔNG có gì bị thay đổi.** Kubeadm dừng ngay ở khâu **parse tham số dòng
  lệnh**, chưa hề mở file config, chưa đụng tới `/etc/kubernetes/ssl`.
  ⇒ Cert thật nguyên vẹn, không cần rollback.
- ⚠️ ⭐ **NHƯNG: lỗi này KHÔNG nói gì về việc file config đúng hay sai.**
  Kubeadm chưa đọc tới file. ⇒ **Mất phép kiểm cuối cùng** — không còn cách nào xác nhận kubeadm
  nuốt được `/root/cluster-config-renew.yaml` **trước khi** nó ghi đè cert.
- 🔴 **Hệ quả: bước so SAN ở GĐ3 từ "chốt chặn quan trọng" thành PHÉP KIỂM DUY NHẤT.**
  Nó vẫn đủ an toàn vì cert mới chỉ nằm **trên đĩa**, static pod vẫn chạy cert cũ **trong bộ nhớ**
  cho tới khi restart ở GĐ4. Nhưng không còn lớp phòng thủ nào phía trước nữa.
- ⭐ **Điều chỉnh GĐ2 để thu hẹp rủi ro** (xem quy trình đã cập nhật):
  thay vì `renew all` một phát, tách thành **2 bước**:
  1. `renew apiserver` — **chỉ một cert**, rồi so SAN ngay
  2. Đúng thì mới `renew all` cho phần còn lại

  **Vì sao chia được:** `apiserver` là cert **DUY NHẤT** có `certSANs`. Các cert khác
  (`apiserver-kubelet-client`, `front-proxy-client`, cert nhúng trong `*.conf`) **không có SAN**
  ⇒ không chịu rủi ro "mất SAN do rơi về default config".
  ⇒ Nếu bước 1 hỏng, chỉ 1 cert bị ghi đè thay vì 6 — rollback nhẹ hơn hẳn.

---

### 3.17 — [Node 48 / GĐ1] Backup PKI — thông báo `Removing leading '/'` KHÔNG phải lỗi

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ngày 19/08**

> 🔴 **ĐÃ SỬA sau output 3.18: thêm cờ `-h`.** Bản trước thiếu cờ này nên tar chỉ lưu
> **symlink `pki`** chứ không gói cert bên trong — backup vô dụng khi rollback.

```
tar czhf /root/pki-backup-$(hostname)-$(date +%F-%H%M).tar.gz /etc/kubernetes/ssl /etc/kubernetes/*.conf /etc/kubernetes/kubeadm-config.yaml
```

**Output:**

```
tar: Removing leading `/' from member names
```

**Đọc được gì:**

- ✅ **KHÔNG PHẢI LỖI.** Đây là thông báo **informational** của `tar`, và nó **xác nhận lệnh chạy
  đúng**. Archive đã được tạo.
- **Cơ chế:** truyền đường dẫn **tuyệt đối** (`/etc/kubernetes/pki`) thì `tar` tự bỏ dấu `/` đầu,
  lưu vào archive thành đường dẫn **tương đối** `etc/kubernetes/pki/...`, rồi báo cho người dùng
  biết nó vừa làm vậy.
- ⭐ **Vì sao tar làm thế — đây là cơ chế AN TOÀN có chủ đích:**
  Nếu archive lưu đường dẫn tuyệt đối, bất kỳ ai giải nén nó ở **bất kỳ thư mục nào** cũng sẽ
  **ghi đè thẳng vào `/etc/kubernetes/` của hệ thống**. Giải nén một file backup lạ có thể phá
  hỏng máy đang chạy.
  ⇒ Bỏ `/` đầu ⇒ mặc định giải nén ra **thư mục hiện tại**; muốn về đúng chỗ cũ phải **cố ý**
  chỉ định `-C /`.
- ⭐ **Liên hệ trực tiếp tới bước ROLLBACK R1:** lệnh khôi phục trong file viết
  `tar xzf <file> -C /`. Cờ `-C /` **không thừa** — nó bù lại đúng dấu `/` mà tar đã bỏ ở bước
  backup này. Thiếu `-C /` thì file sẽ bung ra thư mục hiện tại (vd `/root/etc/kubernetes/...`),
  **không** khôi phục được gì.
- **Phân biệt 3 loại thông báo của `tar`:**

  | Loại | Ví dụ | Ý nghĩa |
  |---|---|---|
  | **Informational** (đang gặp) | `Removing leading '/' from member names` | Báo việc vừa làm. Archive **tạo thành công** |
  | Warning | `file changed as we read it` | Có vấn đề nhưng vẫn chạy tiếp |
  | Error | `Cannot open: Permission denied` / `No space left on device` | **Thất bại thật** |

- 📌 **Ghi chú:** dòng `To see the stack trace of this error execute with --v=5 or higher` ở phía
  trên màn hình là **tàn dư của lệnh `--dry-run`** ở output 3.16, **không liên quan** tới lệnh tar.
- ❓ **Chưa xác minh:** archive có thực sự đọc được không. Bắt buộc chạy `tar tzf` để xác nhận —
  `tar czf` có thể tạo file lỗi nếu hết dung lượng đĩa.

---

### 3.18 — [Cả 3 node / GĐ1] 🔴 Backup có thể KHÔNG chứa cert — symlink không được đi theo

**📍 Node 48, 49, 50 — user `root`, ~11:07–11:09 +07 ngày 19/08**

Kiên chạy backup trên **cả 3 node** (vượt trước một bước so với dự kiến).

⚠️ **Đây là lệnh bản CŨ — thiếu cờ `-h`.** Quy trình ở mục 7 đã được sửa sau phát hiện này.

```
tar czf /root/pki-backup-$(hostname)-$(date +%F-%H%M).tar.gz /etc/kubernetes/pki /etc/kubernetes/*.conf /etc/kubernetes/kubeadm-config.yaml
```

```
tar tzf /root/pki-backup-$(hostname)-*.tar.gz | head -20
```

<details>
<summary>Giải nghĩa — vì sao ĐẾM thay vì chỉ liệt kê</summary>

```
tar tzf <file> | wc -l
│   ││└─ f: đọc từ file
│   │└─ z: giải nén gzip
│   └─ t: liệt kê nội dung, KHÔNG giải nén
└─ ⭐ wc -l: ĐẾM SỐ DÒNG = số mục trong archive.
   VÌ SAO: output 3.18 cho thấy `head -20` chỉ hiện 6 dòng và trông "có vẻ ổn",
   nhưng thực chất `etc/kubernetes/pki` là symlink RỖNG — không có cert nào bên trong.
   Đếm số mục bắt được ngay:
   • ~6 mục   → 🔴 CHỈ CÓ symlink + file .conf, KHÔNG có cert. Backup VÔ DỤNG
   • 30-60 mục → ✅ có cả cert + key trong ssl/. Backup dùng được
```
</details>

Xem đích danh cert quan trọng có trong archive không:

📍 **Từng node 48 → 49 → 50** — user **`root`**

```
tar tzf /root/pki-backup-$(hostname)-<timestamp>.tar.gz | grep -E 'apiserver.crt|ca.crt|ca.key'
```

<details>
<summary>Cách đọc</summary>

```
grep -E 'apiserver.crt|ca.crt|ca.key'
│    │   └─ 3 file SỐNG CÒN: cert apiserver, CA cert, CA key
│    └─ -E: regex mở rộng, `|` là OR
└─ KỲ VỌNG: thấy đủ 3 dòng dạng etc/kubernetes/ssl/apiserver.crt ...
   • RỖNG → 🔴 backup KHÔNG có cert, KHÔNG ĐƯỢC RENEW, làm lại backup với `-h`
```
</details>

Kích thước file:

📍 **Từng node 48 → 49 → 50** — user **`root`**

```
ls -lh /root/pki-backup-*.tar.gz
```

```
ls -lh /root/pki-backup-*.tar.gz
```

**Output — giống hệt nhau trên cả 3 node:**

```
tar: Removing leading `/' from member names

etc/kubernetes/pki
etc/kubernetes/admin.conf
etc/kubernetes/controller-manager.conf
etc/kubernetes/kubelet.conf
etc/kubernetes/scheduler.conf
etc/kubernetes/kubeadm-config.yaml
```

| Node | File backup | Size | Thời điểm |
|---|---|---|---|
| 48 `vrp-kubeengine01` | `pki-backup-vrp-kubeengine01-2026-08-19-1107.tar.gz` | **11K** | 11:07 |
| 49 `vrp-kubeengine02` | `pki-backup-vrp-kubeengine02-2026-08-19-1108.tar.gz` | **11K** | 11:08 |
| 50 `vrp-kubeengine03` | `pki-backup-vrp-kubeengine03-2026-08-19-1109.tar.gz` | **11K** | 11:09 |

**Đọc được gì:**

- ✅ Archive **đọc được** trên cả 3 node (`tar tzf` chạy trót lọt) ⇒ file không hỏng, không bị
  cắt cụt do hết dung lượng.
- ✅ Đường dẫn trong archive **không có dấu `/` đầu** — khớp thông báo ở output 3.17, và xác nhận
  lệnh rollback **bắt buộc** cần cờ `-C /`.
- ✅ Có đủ 3 file `.conf` + `kubelet.conf` + `kubeadm-config.yaml`.
- 🔴 ⭐ **NGHI VẤN NGHIÊM TRỌNG: archive có thể KHÔNG chứa cert nào.**

  **Bằng chứng 1 — `etc/kubernetes/pki` chỉ hiện MỘT dòng.** Nếu tar gói cả nội dung thư mục,
  danh sách phải có `etc/kubernetes/pki/apiserver.crt`, `.../ca.crt`, `.../apiserver.key`...
  Ở đây chỉ có đúng một dòng `etc/kubernetes/pki`.

  **Bằng chứng 2 — cơ chế:** `pki` là **symlink** tới `ssl` (output 3.13). Mặc định `tar` **lưu
  symlink như một liên kết**, KHÔNG đi theo nó để gói nội dung đích. Cần cờ `-h` (hoặc
  `--dereference`) mới đi theo symlink.

  **Bằng chứng 3 — kích thước:** chỉ **11K**. Ba file `.conf` (mỗi file ~5-6KB chứa cert nhúng
  base64) đã chiếm gần hết. Toàn bộ PKI thật — hàng chục cert + key — **không thể** nén xuống
  còn vài trăm byte.

  ⇒ 🔴 **Nếu đúng, backup này KHÔNG khôi phục được cert.** Ta đang tưởng có mạng lưới an toàn
  trong khi thực tế không có — **nguy hiểm hơn là biết mình không có backup**.

- ⭐ **Đây chính là điều bước `tar tzf` sinh ra để bắt.** Nhưng phải **đọc kỹ danh sách**, không
  chỉ nhìn "lệnh chạy trót lọt". Xem Bài học #16.
- ❓ **Phải xác minh ngay** bằng cách đếm số mục trong archive — xem mục 3.19.
  **KHÔNG được renew** cho tới khi có backup thật sự chứa cert.

---

### 3.19 — [Node 48 / GĐ1] 🔴 XÁC NHẬN: backup KHÔNG chứa cert nào — phải làm lại

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~11:16 +07 ngày 19/08**

**a) Đếm số mục trong archive**

> 🔴 **KHÔNG dùng glob `*` khi trên node đã có nhiều bản backup.** Cú pháp tar là
> `tar tzf <archive> [thành viên...]` — glob khớp 2 file sẽ khiến tar hiểu file thứ hai là
> *thành viên cần tìm bên trong*, báo `Not found in archive`. Chỉ định **timestamp cụ thể**.

```
tar tzf /root/pki-backup-$(hostname)-<timestamp>.tar.gz | wc -l
```

**Output:**

```
6
```

**b) Tìm 3 file cert sống còn**

```
tar tzf /root/pki-backup-$(hostname)-*.tar.gz | grep -E 'apiserver.crt|ca.crt|ca.key'
```

**Output:**

```
(rỗng — không in ra dòng nào)
```

**Đọc được gì:**

- 🔴 ⭐ **XÁC NHẬN DỨT KHOÁT: archive KHÔNG chứa cert nào.** Nghi vấn ở output 3.18 là **đúng**.
- **`6` mục** — khớp chính xác 6 dòng đã thấy ở output 3.18, **không có gì thêm**. Nếu tar gói
  được nội dung thư mục `ssl/`, con số phải là **30-60** (hàng chục cert + key).
- **`grep` RỖNG** — đây là **bằng chứng phủ định dứt khoát**, không phải "chưa tìm thấy":
  `apiserver.crt`, `ca.crt`, `ca.key` là 3 file **bắt buộc phải có** trong mọi PKI của kubeadm.
  Không có chúng ⇒ archive chỉ chứa **symlink `pki` rỗng** + 5 file `.conf`/`.yaml`.
  (Áp dụng Bài học #12: rỗng là bằng chứng, khi đã biết trước "rỗng nghĩa là gì".)
- ⇒ **Cả 3 node đều vậy** — cùng lệnh, cùng kết quả 11K (output 3.18).
- 🔴 **Trạng thái thực tế: HIỆN KHÔNG CÓ BACKUP CERT NÀO.** Tuyệt đối **không được renew**
  cho tới khi có backup thật.
- 📌 **Nguyên nhân — lỗi khi soạn lệnh:** lệnh backup thiếu cờ `-h`, trong khi chính output 3.13
  đã xác định `pki` là symlink. Biết symlink nhưng không nối được sang hệ quả "tar cần `-h`".
  Xem Bài học #16.

---

### 3.20 — [Cả 3 node / GĐ1] ✅ Backup lại với `-h` — node 48 verify ĐẠT

**📍 Node 48, 49, 50 — user `root`, ~11:18–11:22 +07 ngày 19/08**

**a) Backup lại (cả 3 node)**

```
tar czhf /root/pki-backup-$(hostname)-$(date +%F-%H%M).tar.gz /etc/kubernetes/ssl /etc/kubernetes/*.conf /etc/kubernetes/kubeadm-config.yaml
```

**Output (cả 3 node):** `tar: Removing leading '/' from member names` — bình thường (output 3.17).

**b) Verify trên node 48**

```
tar tzf /root/pki-backup-vrp-kubeengine01-2026-08-19-1118.tar.gz | wc -l
```

**Output:**

```
18
```

```
tar tzf /root/pki-backup-vrp-kubeengine01-2026-08-19-1118.tar.gz | grep -E 'apiserver.crt|ca.crt|ca.key'
```

**Output:**

```
etc/kubernetes/ssl/front-proxy-ca.key
etc/kubernetes/ssl/ca.crt
etc/kubernetes/ssl/apiserver.crt
etc/kubernetes/ssl/ca.key
etc/kubernetes/ssl/front-proxy-ca.crt
```

**c) Kích thước — cả 3 node**

```
ls -lh /root/pki-backup-*.tar.gz
```

| Node | Bản CŨ (thiếu `-h`) | Bản MỚI (`czhf` + `/ssl`) |
|---|---|---|
| 48 `vrp-kubeengine01` | `-1107.tar.gz` — **11K** ❌ | `-1118.tar.gz` — **22K** ✅ |
| 49 `vrp-kubeengine02` | `-1108.tar.gz` — **11K** ❌ | `-1118.tar.gz` — **22K** ✅ |
| 50 `vrp-kubeengine03` | `-1109.tar.gz` — **11K** ❌ | `-1118.tar.gz` — **22K** ✅ |

**Đọc được gì:**

- ✅ ⭐ **Node 48: backup ĐẠT.** `18` mục (trước là `6`), và `grep` tìm thấy **đủ 3 file sống còn**
  `apiserver.crt`, `ca.crt`, `ca.key` — cộng thêm `front-proxy-ca.crt/key`.
  ⇒ Cờ `-h` + đường dẫn thật `/etc/kubernetes/ssl` đã giải quyết đúng vấn đề ở output 3.19.
- ✅ **Kích thước 22K vs 11K** — gấp đôi bản cũ, khớp với việc archive giờ chứa thêm ~12 file cert/key.
- ✅ **Cả 3 node đều có file `-1118.tar.gz` 22K** ⇒ backup trên 49/50 **đã tạo thành công**.
- ⚠️ **Node 49/50 báo `Cannot open: No such file or directory`** khi verify —
  **KHÔNG phải backup hỏng.** Nguyên nhân: lệnh verify được đưa với tên file **cứng**
  `pki-backup-vrp-kubeengine01-...`, chạy nguyên văn trên node 02/03 nên không tìm thấy.
  ⇒ Lỗi **soạn lệnh**, đã sửa bằng `$(hostname)`. Xem Bài học #17.
- ❓ **Chưa xác minh:** nội dung backup trên node 49/50 (mới chỉ biết kích thước đúng 22K).
  Cần verify lại bằng lệnh có `$(hostname)`.

---

### 3.21 — [Node 49, 50 / GĐ1] ✅ Backup verify ĐẠT — GIAI ĐOẠN 1 HOÀN TẤT

**📍 Node 49 (`vrp-kubeengine02`) và node 50 (`vrp-kubeengine03`) — user `root`, ~11:24 +07**

```
tar tzf /root/pki-backup-$(hostname)-2026-08-19-1118.tar.gz | wc -l
```

```
tar tzf /root/pki-backup-$(hostname)-2026-08-19-1118.tar.gz | grep -E 'apiserver.crt|ca.crt|ca.key'
```

**Output — giống hệt nhau trên cả node 49 và 50:**

```
18
```

```
etc/kubernetes/ssl/front-proxy-ca.key
etc/kubernetes/ssl/ca.crt
etc/kubernetes/ssl/apiserver.crt
etc/kubernetes/ssl/ca.key
etc/kubernetes/ssl/front-proxy-ca.crt
```

**Đọc được gì:**

- ✅ **Node 49 và 50 đều `18` mục** — khớp chính xác node 48 (output 3.20).
- ✅ **Đủ 3 file sống còn** `apiserver.crt`, `ca.crt`, `ca.key` trên cả hai node.
- ✅ **Lệnh dùng `$(hostname)` chạy đúng trên cả hai node** mà không phải sửa tay — xác nhận
  cách gỡ ở Bài học #17 là đúng.
- ✅ ⭐ **GIAI ĐOẠN 1 HOÀN TẤT.** Cả 3 master đã có backup **thật sự dùng được**:

  | Node | File backup | Số mục | Size | Verify |
  |---|---|---|---|---|
  | 48 `vrp-kubeengine01` | `pki-backup-vrp-kubeengine01-2026-08-19-1118.tar.gz` | 18 | 22K | ✅ |
  | 49 `vrp-kubeengine02` | `pki-backup-vrp-kubeengine02-2026-08-19-1118.tar.gz` | 18 | 22K | ✅ |
  | 50 `vrp-kubeengine03` | `pki-backup-vrp-kubeengine03-2026-08-19-1118.tar.gz` | 18 | 22K | ✅ |

  ⚠️ **Bản `-1107/-1108/-1109` (11K) là bản HỎNG** — giữ lại nhưng **KHÔNG dùng để rollback**.
- ⇒ **Đủ điều kiện an toàn để sang GĐ2 (renew).** Đường lùi đã có thật, không phải giả định.

---

### 3.22 — [Node 48 / GĐ2.1] 🛑 Renew cert `apiserver` — CHƯA VERIFY SAN

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ngày 19/08**

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml
```

**Output:**

```
certificate for serving the Kubernetes API renewed
```

**Đọc được gì:**

- ✅ **Lệnh chạy xong, không lỗi.** Không có `unknown kind`, `failed to unmarshal`, hay
  `unknown flag` — khác hẳn output 3.16.
- ✅ **Đúng MỘT cert được renew** (`apiserver`), như chủ đích. 5 cert còn lại chưa đụng tới.
- 🔴 ⭐ **NHƯNG: dòng "renewed" KHÔNG chứng minh SAN đúng.**

  Nhắc lại bẫy ở output 3.11: nếu kubeadm **im lặng** bỏ qua `--config` rồi rơi về **default
  config**, nó **vẫn in y hệt dòng này**. Thông báo thành công **không phân biệt được** hai
  trường hợp:
  - (a) đọc được file → cert có đủ 18-19 SAN ✅
  - (b) bỏ qua file → cert chỉ có SAN mặc định, **mất** `lb-apiserver.kubernetes.local`,
    `10.208.137.68`, `172.16.128.1` 🔴

  ⇒ Mất `--dry-run` (output 3.16) nên **không có cách nào biết trước**.
  ⇒ **`diff` SAN ở GĐ3 là PHÉP KIỂM DUY NHẤT.**

- ⭐ **Trạng thái hiện tại — cửa sổ CÒN CỨU ĐƯỢC:**

  | Ở đâu | Cert nào |
  |---|---|
  | **Trên đĩa** (`/etc/kubernetes/ssl/apiserver.crt`) | 🆕 **Cert MỚI** vừa ghi |
  | **Trong bộ nhớ** (static pod đang chạy) | 🕐 **Cert CŨ** — pod chưa restart |

  ⇒ Nếu SAN sai: chỉ cần restore backup `-1118`, **không cần restart gì**, cluster không hề
  bị ảnh hưởng. Sau khi restart ở GĐ4 thì cửa sổ này **đóng lại**.

- ❓ **Chưa xác minh:** SAN của cert mới. **TUYỆT ĐỐI KHÔNG chạy 2.2 hay GĐ4** trước khi có
  kết quả `diff`.

---

### 3.23 — [Node 48 / GĐ3] ✅✅ SO SÁNH SAN: **PASS** — cert mới giữ nguyên 18 entry

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~11:29 +07 ngày 19/08**

**a) Chụp SAN cert mới**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A3 'Alternative Name' > /root/san-sau-renew-48.txt
```

**b) So sánh trước/sau**

```
diff /root/san-truoc-renew-48.txt /root/san-sau-renew-48.txt
```

**Output:**

```
4c4
<       a4:6f:63:3e:3a:40:63:01:ab:29:eb:2a:12:50:38:14:68:48:
---
>       83:b5:28:99:ea:74:26:a3:a9:c8:66:3e:72:de:a9:1f:c9:aa:
```

**c) Đếm lại số SAN entry**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
```

**Output:**

```
18
```

**Đọc được gì:**

- ✅✅ ⭐ **PASS — kubeadm ĐÃ ĐỌC ĐƯỢC `--config`.** Cert mới giữ **nguyên vẹn toàn bộ SAN**.
- **Phân tích dòng `diff` khác nhau — KHÔNG phải SAN:**

  `4c4` = chỉ dòng thứ 4 khác. Nội dung là **chuỗi hex**, không phải `DNS:` hay `IP Address:`.
  Đây là **Subject Key Identifier** (hoặc byte đầu của chữ ký) — nằm ngay sau khối SAN nên bị
  `grep -A3` kéo vào phạm vi.

  ⭐ **Chuỗi này là fingerprint dẫn xuất từ public key. Cert mới có key khác ⇒ chuỗi BẮT BUỘC
  phải khác.** Nói cách khác: **dòng này khác chính là BẰNG CHỨNG cert đã thực sự được ký lại.**
  Nếu nó giống hệt thì mới đáng lo — nghĩa là cert không hề đổi.

- ✅ ⭐ **KHÔNG có dòng `<` nào chứa `DNS:` hoặc `IP Address:`** ⇒ **không mất entry SAN nào.**
  Ba entry sống còn đều còn nguyên:
  `lb-apiserver.kubernetes.local`, `10.208.137.68`, `172.16.128.1`.
- ✅ **Kiểm chéo độc lập: `18` entry — bằng ĐÚNG trước renew** (output 3.10).
  ⇒ Nếu kubeadm rơi về default config, con số phải tụt xuống **~8** (chỉ còn SAN mặc định:
  `kubernetes`, `kubernetes.default`, `.svc`, `.svc.cluster.local`, ClusterIP, IP node).
  Giữ nguyên 18 ⇒ `certSANs` từ `/root/cluster-config-renew.yaml` **đã được áp dụng**.
  ⇒ **Bẫy ở output 3.11 (kubeadm im lặng rơi về default) KHÔNG xảy ra.**
- ⚠️ **DỰ ĐOÁN CỦA TÔI SAI — nhưng theo hướng vô hại:**

  Ở output 3.10 và 3.12 tôi dự đoán SAN sẽ thành **19** vì `dnsDomain: vrp` (output 3.12) sẽ
  khiến kubeadm thêm `kubernetes.default.svc.vrp`. Thực tế **vẫn 18**.

  **Vì sao sai:** kubeadm v1.23 **không** tự sinh `kubernetes.default.svc.<dnsDomain>` — nó chỉ
  dùng đúng danh sách `certSANs` khai trong file, cộng SAN mặc định. Entry
  `kubernetes.default.svc.vrp` có trong `certSANs` (output 3.6) nhưng cert cũ cũng đã không có nó
  ⇒ nhiều khả năng kubeadm bỏ qua entry này vì trùng dạng với `kubernetes.default.svc.cluster.local`.

  **Hệ quả:** không có. Giữ nguyên 18 **an toàn hơn** là thêm entry mới. Ghi lại để không hoang
  mang khi thấy con số khác dự đoán.
- ⇒ ✅ **ĐỦ ĐIỀU KIỆN chạy 2.2 (`renew all`)** cho 5 cert còn lại.

---

### 3.24 — [Node 48 / GĐ2.2] ✅ Renew 6 cert — không có cert etcd, đúng dự đoán

**📍 Node 48 (`vrp-kubeengine01`) — user `root`, ~11:32 +07 ngày 19/08**

```
kubeadm certs renew all --config /root/cluster-config-renew.yaml
```

**Output:**

```
certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
certificate for the API server to connect to kubelet renewed
certificate embedded in the kubeconfig file for the controller manager to use renewed
certificate for the front proxy client renewed
certificate embedded in the kubeconfig file for the scheduler manager to use renewed

Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
```

**Đối chiếu 6 dòng với cert thật:**

| Dòng output | Cert tương ứng | Có `certSANs`? |
|---|---|---|
| `...kubeconfig file for the admin...` | `admin.conf` (cert nhúng base64) | Không |
| `...for serving the Kubernetes API` | **`apiserver`** — ký lại **lần 2** | ✅ **Có** |
| `...for the API server to connect to kubelet` | `apiserver-kubelet-client` | Không |
| `...kubeconfig file for the controller manager` | `controller-manager.conf` | Không |
| `...for the front proxy client` | `front-proxy-client` | Không |
| `...kubeconfig file for the scheduler manager` | `scheduler.conf` | Không |

**Đọc được gì:**

- ✅ **Đủ 6 cert renewed**, không lỗi. Khớp chính xác danh sách kỳ vọng.
- ✅ ⭐ **KHÔNG có dòng `certificate the apiserver uses to access etcd renewed`.**
  Đây là **bằng chứng dương** (không phải suy luận) cho việc cụm dùng **etcd external**:
  kubeadm biết nó không quản cert etcd nên không đụng tới.
  ⇒ Củng cố output 3.4 (không có `etcd.yaml`) và 3.12 (`etcd.external` trong config).
  ⇒ Cert etcd ở `/etc/ssl/etcd/ssl/` **không bị ảnh hưởng** bởi thao tác này.
- ✅ **Dòng cuối `Done renewing certificates. You must restart...`** — xác nhận điều đã ghi ở
  Bài học #5: **renew KHÔNG tự restart**. Static pod vẫn đang chạy cert cũ trong bộ nhớ.
  (Dòng này nhắc cả `etcd` là do kubeadm in thông báo cố định, không có nghĩa cụm này có etcd
  cần restart.)
- ⚠️ **`apiserver` đã bị ký lại LẦN THỨ HAI.** Lần 1 ở output 3.22 (verify PASS ở 3.23), lần này
  `all` bao gồm cả nó.
  ⇒ **Vô hại về chức năng** — chỉ là hạn 1 năm tính lại từ bây giờ, và key mới lần nữa.
  ⇒ **NHƯNG phải so SAN LẠI**: kết quả PASS ở output 3.23 chỉ chứng minh cho cert của lần 1.
  Về lý thuyết cùng file config thì cùng kết quả, nhưng **không được suy đoán** — chi phí kiểm
  là 2 lệnh, chi phí bỏ qua là restart với cert hỏng.
- ❓ **Chưa xác minh:** SAN của cert `apiserver` sau lần ký thứ 2. **KHÔNG restart** trước khi có
  kết quả.

---

### 3.25 → ... — [CHƯA CHẠY] Output các giai đoạn tiếp theo

> 🔶 **Khu vực này còn TRỐNG.**
> Đúng nguyên tắc của skill: **không có output thật thì không ghi** — không điền trước,
> không ước lượng, không tái tạo từ trí nhớ.
>
> Các mục sẽ được thêm theo thứ tự thời gian:

| Mục dự kiến | Node | Giai đoạn | Nội dung |
|---|---|---|---|
| ~~`3.10`~~ | 48 | GĐ0 | ✅ **ĐÃ CHẠY** — xem mục 3.10 ở trên |
| `3.11` | 48 | GĐ0-bis | 🔴 **MỚI**: kiểm cấu trúc `kubeadm-config.yaml` (do v1.23 EOL) |
| `3.12` | 48, 49, 50 | GĐ1 | Backup PKI + verify archive đọc được |
| `3.13` | 48 | GĐ2 | 🛑 Renew kèm `--config` — **điểm dừng 1** |
| `3.14` | 48 | GĐ3 | 🛑🛑 `diff` SAN trước/sau + `check-expiration` — **điểm dừng 2** |
| `3.15` | 48 | GĐ4 | Restart static pod, trạng thái container |
| `3.16` | 48 | GĐ5 | 🛑 Verify: `get nodes`, control-plane pods, `curl` qua LB — **điểm dừng 3** |
| `3.17` | 49 | GĐ2-5 | **Chỉ điểm khác** so với node 48 |
| `3.18` | 50 | GĐ2-5 | **Chỉ điểm khác** so với node 48 |
| `3.19` | 51-55 | GĐ6 | Cert kubelet trên 5 worker |
| `3.20` | 04 | GĐ6 | Chạy lại `helm upgrade ragflow` (issue #6) |

**Số thứ tự trên là dự kiến** — thực tế có thể lệch nếu phát sinh lệnh chẩn đoán giữa chừng.
Nguyên tắc: đánh số **theo thứ tự thời gian thực tế**, không theo thứ tự trong quy trình.

---

## 4. Issue chi tiết

### Issue #1 — Cert lá control-plane hết hạn 🔶 OPEN

**Root cause:** Cert do `kubeadm` sinh có hạn mặc định **1 năm**. Cluster init/renew lần cuối
khoảng 17-18/08/2025, không có cơ chế renew tự động và không có cảnh báo → hết hạn 18/08/2026.

**Bằng chứng:** Output 3.2 — 6 cert lá cùng hết hạn `Aug 18, 2026 11:53 UTC`, `RESIDUAL TIME <invalid>`.

**Điều kiện thuận lợi:** CA còn hạn 6 năm (output 3.2) ⇒ đủ để ký lại cert lá.

**Đã thử:** *(chưa thao tác sửa gì — mới ở giai đoạn chẩn đoán)*

**Hướng xử lý tiếp:** Xem mục 7, nhóm "Ngay lập tức". Bắt buộc theo thứ tự
backup → chụp SAN → renew → so SAN → restart → verify, lần lượt 48 → 49 → 50.

---

### Issue #2 — `kubectl` báo `localhost:8080` 🔶 OPEN

**Root cause:** User đang thao tác không có `~/.kube/config`. Đặc biệt sau khi `su` sang `root`,
`$HOME` đổi thành `/root` nên kể cả `vt_admin` có kubeconfig thì root vẫn không thấy.

**Bằng chứng:** Output 3.1 — thông báo `localhost:8080` là fallback mặc định của kubectl.

**⚠️ Lưu ý thứ tự:** Copy kubeconfig **bây giờ là vô ích** — cert nhúng trong `admin.conf` cũng
đã hết hạn (output 3.2 có dòng `admin.conf ... <invalid>`). Phải renew trước, copy sau.

**Hướng xử lý tiếp:** Sau khi renew xong mới copy `admin.conf` → `~/.kube/config`.

---

### Issue #3 — PKI etcd `!MISSING!` toàn bộ 🔶 OPEN, chưa rõ có phải issue thật

**Hai giả thuyết:**

| # | Giả thuyết | Ý nghĩa | Cách phân biệt |
|---|---|---|---|
| A | **External etcd** — etcd chạy trên cụm riêng, kubeadm không quản PKI của nó | Bình thường, `!MISSING!` là *cosmetic*. Renew an toàn | `/etc/kubernetes/manifests/etcd.yaml` **không tồn tại** + `--etcd-servers` trỏ IP ngoài |
| B | **Stacked etcd nhưng PKI bị xoá** | 🔴 Nghiêm trọng hơn cert hết hạn nhiều | `etcd.yaml` **có tồn tại** |

**Nghiêng về giả thuyết A**, lập luận:

Cluster chạy bình thường tới tận 18/08. Nếu là stacked etcd mà `/etc/kubernetes/pki/etcd/` bị
xoá, etcd static pod đã crashloop ngay từ lần restart đầu tiên và cluster chết từ trước đó,
không phải chết đúng hôm cert hết hạn. Việc `ca` và `front-proxy-ca` vẫn còn nguyên vẹn trong khi
**toàn bộ** nhánh etcd biến mất là dấu hiệu của khác biệt kiến trúc, không phải mất mát dữ liệu.

### ✅ ĐÃ XÁC MINH — giả thuyết A đúng, issue này ĐÓNG

Output 3.4 cho thấy `/etc/kubernetes/manifests/` chỉ có **3 file** (apiserver,
controller-manager, scheduler), **không có `etcd.yaml`** ⇒ **etcd chạy external**.

⇒ Các dòng `!MISSING!` là **cosmetic**, không phải PKI bị xóa. Không cần xử lý gì.

**Hệ quả tốt cho kế hoạch renew:** không có etcd trên master ⇒ **không có quorum etcd để mất**
khi restart control-plane. Đây là khác biệt lớn so với cluster stacked-etcd thông thường.

❓ **Chưa xác minh (không chặn việc renew):** cụm etcd external nằm ở đâu, PKI của nó do ai quản,
cert etcd có hết hạn không. Cert etcd hết hạn sẽ gây sự cố **riêng biệt** — apiserver không kết nối
được etcd. Hiện chưa có dấu hiệu này. Xác định bằng `grep etcd-servers` trên apiserver manifest.

---

### Issue #4 — kubeadm fallback default config 🔶 OPEN

**Root cause:** `check-expiration` và `renew` đều cố đọc ConfigMap `kubeadm-config` qua API server.
API server không truy cập được (cert hết hạn) → fallback default.

**Bằng chứng:** Output 3.2, dòng `Error reading configuration from the Cluster. Falling back to default configuration`.

**🔴 Rủi ro cụ thể — ĐÃ XÁC ĐỊNH, không còn là giả định:**

Output 3.0 chứng minh control-plane endpoint là **`lb-apiserver.kubernetes.local`** (DNS name).
Cert apiserver hiện tại **chắc chắn** có tên này trong `certSANs` — nếu không, cluster đã không
chạy được từ đầu.

Nhưng `kubeadm` đang **fallback default config** (không đọc được ConfigMap). Default config
**không biết** tới DNS name tùy biến này — nó chỉ sinh SAN mặc định (IP node, `kubernetes`,
`kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`,
ClusterIP của svc kubernetes).

⇒ **Nếu chạy `kubeadm certs renew all` trần**, cert mới **rất có thể mất** `lb-apiserver.kubernetes.local`
→ mọi `kubectl`/`helm` trên **mọi node** (đều trỏ qua tên này) sẽ báo
`x509: certificate is valid for ..., not lb-apiserver.kubernetes.local`
→ **cluster hỏng nặng hơn hiện tại**, và lúc đó không còn cert cũ để rollback.

**Cách gỡ bắt buộc:** chụp SAN cũ (4.3) → soạn file `kubeadm-config.yaml` khai lại đầy đủ
`apiServer.certSANs` → renew **kèm `--config`**. Xem mục 7.

❓ **Chưa xác minh:** cluster có phải dựng bằng Kubespray không. Nếu đúng, `certSANs` gốc nằm ở
biến Ansible `supplementary_addresses_in_ssl_keys` trong repo Kubespray — **nguồn đáng tin hơn**
để dựng lại file config, thay vì chỉ đọc ngược từ cert cũ.

**Cách gỡ:** Chụp SAN của cert cũ (lệnh 4.3) → nếu có VIP thì renew phải kèm `--config <file>`
khai báo lại `apiServer.certSANs`, **không dùng lệnh renew trần**.

---

## 5. Bài học

**Chỉ ghi cái không hiển nhiên:**

1. **`connection refused localhost:8080` ≠ lỗi cert.** Đây là fallback khi kubectl không có
   kubeconfig. Suýt kết luận nhầm là "apiserver đã chết". Thực tế **chưa biết** apiserver sống hay
   chết cho tới khi kiểm tra bằng `crictl` — apiserver hết hạn cert vẫn **chạy** bình thường,
   chỉ là *client* từ chối tin nó.

2. **`kubeadm certs check-expiration` đọc file cục bộ, không hỏi cluster.** Trong HA 3 master,
   mỗi node có bộ cert riêng do CA chung ký. Bảng ở node 48 **không nói gì** về node 49/50.
   Phải chạy độc lập trên từng node.

3. **Phải kiểm CA trước cert lá.** CA còn hạn vs hết hạn là hai kịch bản khác nhau hoàn toàn
   (renew nhẹ nhàng vs rebuild toàn bộ PKI + join lại mọi node). Nhìn cột dưới của bảng
   `check-expiration` trước khi hoảng.

4. **Renew khi mất API server là thao tác có rủi ro riêng.** Nghịch lý: cần API server để đọc
   config đúng, nhưng API server chết mới phải renew. Fallback default config có thể sinh cert
   thiếu SAN. Chụp SAN cũ trước khi renew là bước bắt buộc, không phải tùy chọn.

5. **`kubeadm certs renew` không tự restart control-plane.** Nó chỉ ghi file mới xuống đĩa.
   Static pod vẫn giữ cert cũ trong bộ nhớ cho tới khi bị tạo lại. Renew xong mà không restart =
   tưởng đã fix nhưng chưa.

6. **⚠️ Suy đoán topology từ tab SSH là sai lầm — đã mắc trong chính phiên này.**

   **Đã ghi sai:** kết luận `10.208.216.4` là VIP/LB của cluster, chỉ vì nó xuất hiện ở tab SSH số
   1 và số 5 trong screenshot. Từ đó dựng ra cả kịch bản rủi ro "SAN mất VIP 216.4 làm hỏng HA".

   **Cái làm lộ ra là sai:** Kiên đính chính — `10.208.216.4` thuộc **cụm khác**, không liên quan.
   Topology thật: master `137.48-50`, worker `137.51-55`, tất cả cùng một dải `137.x`.

   **Vì sao sai:** một cửa sổ terminal thường mở nhiều cụm/hệ thống khác nhau cùng lúc. Tab SSH
   phản ánh **thói quen làm việc của người dùng**, không phải topology hệ thống. Đây là nguồn dữ
   liệu ngoại vi bị dùng như bằng chứng.

   **Rút ra:** topology chỉ được lấy từ (a) người vận hành xác nhận trực tiếp, hoặc (b) file cấu
   hình trên node — `admin.conf`, manifest apiserver, `kubeadm-config`. Bằng chứng gián tiếp phải
   luôn đánh dấu `❓ chưa xác minh`, và **không được xây kịch bản rủi ro chồng lên nó** như đã làm.

7. **⭐ Thông báo lỗi của ứng dụng quý hơn lệnh chẩn đoán chuyên dụng.**

   Một dòng lỗi `helm upgrade` cho ra **nhiều thông tin hơn** cả `kubeadm certs check-expiration`:

   | Thông tin | Lấy từ đâu |
   |---|---|
   | Control-plane endpoint = `lb-apiserver.kubernetes.local` | ✅ Lỗi helm — `check-expiration` **không** in ra |
   | Nghi Kubespray (từ tên endpoint mặc định) | ✅ Lỗi helm |
   | Mốc hết hạn chính xác đến giây `12:02:51Z` | ✅ Lỗi helm (bảng chỉ có `11:53`) |
   | Timezone node + đồng hồ đúng → loại trừ lệch NTP | ✅ Lỗi helm |
   | **Apiserver còn sống** | ✅ Lỗi helm (`failed to verify` ≠ `connection refused`) |

   **Rút ra:** khi sự cố hạ tầng lộ ra qua ứng dụng, **đọc kỹ log gốc của ứng dụng trước**, đừng
   vội nhảy sang lệnh chẩn đoán hạ tầng. Ở đây đã suýt bỏ qua screenshot lỗi helm và đi hỏi vòng
   vo về VIP — trong khi câu trả lời nằm sẵn trong dòng lỗi đầu tiên.

8. **Phân biệt 3 loại lỗi kết nối — mỗi loại chỉ ra một tầng khác nhau:**

   | Thông báo | Tầng chết | Nghĩa |
   |---|---|---|
   | `connection to localhost:8080 refused` | Chưa tới tầng nào | **Thiếu kubeconfig** — client chưa biết phải gọi đi đâu |
   | `tls: failed to verify certificate: x509...` | TCP ✔ → TLS ✘ | Server **còn sống**, chỉ là cert client không chấp nhận |
   | `connection refused` / `i/o timeout` tới đúng endpoint | TCP ✘ | Server **thật sự chết** hoặc mạng chặn |

   Trong phiên này gặp loại 1 và loại 2 cùng lúc trên hai node khác nhau — nếu chỉ nhìn loại 1
   (ở master 48) sẽ chẩn đoán sai hoàn toàn.

9. **Nhận diện công cụ dựng cluster khi không phải người dựng — dấu hiệu trên node.**

   Kiên là nhân viên mới, không dựng cụm này. Vẫn suy ra được kha khá từ dấu vết trên node:

   | Dấu hiệu | Kết luận | Độ chắc |
   |---|---|---|
   | Endpoint tên `lb-apiserver.kubernetes.local` | **Kubespray** — đây là giá trị mặc định của biến `apiserver_loadbalancer_domain_name`. Kubeadm thuần **không bao giờ** tự sinh tên này | 🟠 Mạnh nhưng gián tiếp |
   | ~~SAN có `127.0.0.1` + 3 IP master~~ | ~~Kiểu localhost-LB~~ | ❌ **DẤU HIỆU SAI — đã bác bỏ.** `127.0.0.1` gần như **luôn** có trong SAN apiserver của mọi cluster, không nói gì về cơ chế LB. Xem Bài học #11 |
   | **`/etc/hosts` map endpoint → IP nào** | ⭐ **Đây mới là dấu hiệu đúng** về cơ chế LB: `127.0.0.1` = localhost-LB, IP khác = LB tập trung | ✅ **Chắc chắn** |
   | Tồn tại `/etc/kubernetes/kubeadm-config.yaml` | Công cụ tự động ghi config ra đĩa (kubeadm thuần thường không để lại) | 🟡 Vừa |
   | Hostname theo mẫu `vrp-kubeengine01..05` | Đặt tên tự động theo inventory | 🟡 Vừa |
   | Service CIDR `172.16.128.0/x` | **Tùy biến** — không phải mặc định của kubeadm (`10.96.0.0/12`) lẫn Kubespray (`10.233.0.0/18`) ⇒ có người khai riêng | ✅ Chắc |

   **Vẫn ❓ chưa xác minh 100%.** Bằng chứng dứt điểm sẽ là: `/etc/hosts` map
   `lb-apiserver.kubernetes.local → 127.0.0.1` (lệnh A4), hoặc thấy repo/inventory Kubespray.

   **Rút ra:** nhận diện được công cụ dựng cluster **thay đổi cách xử lý sự cố** — với Kubespray,
   `certSANs` gốc nằm ở biến Ansible `supplementary_addresses_in_ssl_keys` trong repo inventory,
   là nguồn đáng tin hơn file trên node. Đáng hỏi sếp/người bàn giao xem repo đó ở đâu.

10. **⚠️ mtime của file cấu hình là manh mối bị bỏ sót nhiều nhất.**

    `kubeadm-config.yaml`, `kube-controller-manager.yaml`, `kube-scheduler.yaml` đều `Jul 6 2023`,
    riêng `kube-apiserver.yaml` là **`Sep 18 2024`** — lệch 14 tháng.

    ⇒ Có người sửa apiserver **sau khi** dựng cluster, mà **không** cập nhật `kubeadm-config.yaml`.
    Nếu lần sửa đó thêm `certSANs` (rất có thể là IP `10.208.137.68`), thì file config 2023 **đã
    lỗi thời** và renew bằng nó sẽ sinh cert thiếu SAN.

    **Rút ra:** đừng chỉ hỏi "file config có tồn tại không" — phải hỏi **"nó còn khớp thực tế
    không"**. Một `ls -l` xem mtime tốn 2 giây nhưng lộ ra rủi ro mà `cat` file không cho thấy.
    Nguồn sự thật cuối cùng là **cert đang chạy**, không phải file config.

    **⚠️ Cập nhật sau output 3.6:** nghi vấn này **hoá ra là báo động giả** — `certSANs` trong file
    2023 khớp khít cert đang chạy. Lần sửa 09/2024 không đụng tới SAN.
    Nhưng **quy trình kiểm tra vẫn đúng**: chi phí kiểm là 1 lệnh `grep`, còn chi phí bỏ qua là
    cert thiếu SAN làm hỏng toàn cụm. Báo động giả ở đây là **kết quả chấp nhận được**, không phải
    lỗi suy luận.

11. **🔴 GIẢ ĐỊNH SAI ĐÃ MẮC: đoán cơ chế LB từ việc nhận diện công cụ.**

    **Đã kết luận sai:** "Kubespray dựng HA bằng **localhost-LB** — nginx cục bộ mỗi node,
    `/etc/hosts` map `lb-apiserver.kubernetes.local → 127.0.0.1`". Đã ghi vào file ở output 3.0 và
    3.5, còn dùng nó để lập luận rằng "SAN có cả `127.0.0.1` lẫn 3 IP master là chữ ký của
    localhost-LB".

    **Cái làm lộ ra là sai:** output 3.7 —

    ```
    10.208.137.68  lb-apiserver.kubernetes.local
    ```

    Trỏ tới **VIP tập trung**, không phải `127.0.0.1`.

    **Vì sao sai:** localhost-LB đúng là **mặc định** của Kubespray, nhưng Kubespray **hỗ trợ cả
    hai** chế độ (`loadbalancer_apiserver_localhost: true/false`). Cụm này chọn LB tập trung.
    Sai lầm là **suy từ "mặc định của công cụ" ra "cấu hình thực tế"** — trong khi việc nhận diện
    công cụ (Bài học #9) bản thân nó cũng mới chỉ là suy luận gián tiếp. **Hai tầng suy đoán chồng
    lên nhau.**

    Ngoài ra, lập luận "SAN có `127.0.0.1` là chữ ký localhost-LB" là **suy diễn ngược sai**:
    `127.0.0.1` gần như **luôn** có trong SAN apiserver của mọi cluster (để truy cập từ chính node),
    không nói lên gì về cơ chế LB.

    **Hệ quả thực tế nếu không phát hiện:** đã kết luận "restart master 48 thì node khác tự
    failover, rủi ro thấp". Với LB tập trung, điều đó **chỉ đúng nếu `.68` có health-check**.
    Không có health-check thì 1/3 request rơi vào node đang restart → **gián đoạn thật trong lúc
    thao tác**.

    **Rút ra:** cấu hình thực tế phải đọc từ **file trên node**, không suy từ mặc định của công cụ.
    Với LB/HA, `/etc/hosts` và cấu hình proxy là nguồn sự thật — kiểm **trước** khi lập kế hoạch
    restart, không phải sau.

12. **Output RỖNG là bằng chứng, không phải "lệnh chưa chạy được".**

    Cả 3 master trả về rỗng cho `ip addr | grep 137.68`, và master 48 rỗng cho lệnh `systemctl`.
    Nhìn qua dễ tưởng "chưa có thông tin gì" — thực ra đây là **kết luận dứt khoát**:

    | Output | Nghĩa |
    |---|---|
    | Rỗng ×3 node | **Không node nào mang VIP** ⇒ VIP nằm ngoài cụm ⇒ loại trừ keepalived-trên-master **và** split-brain |
    | Rỗng (systemctl) | Không có tiến trình LB nào trên master ⇒ củng cố kết luận trên |

    **Điều kiện để tin output rỗng:** phải chắc lệnh **thực sự chạy** chứ không lỗi cú pháp.
    Ở đây tin được vì prompt trả về sạch, không có `command not found` hay `No such file`.
    (Đối chiếu: ở output 3.3/3.4 đã cố ý thêm `2>&1` chính là để phân biệt "rỗng vì không có"
    với "rỗng vì lỗi bị nuốt".)

    **Rút ra:** khi thiết kế lệnh chẩn đoán, hãy nghĩ trước **"nếu rỗng thì nghĩa là gì"**.
    Lệnh mà output rỗng không kết luận được điều gì là lệnh chẩn đoán kém.

13. **Phân biệt "chưa xác minh" với "không thể tự xác minh" — hai loại bí khác nhau.**

    Sau output 3.8, câu hỏi "LB có health-check port 6443 không" **vẫn chưa có lời giải**, nhưng
    nó khác hẳn các ẩn số trước:

    | Loại | Ví dụ trong phiên này | Cách gỡ |
    |---|---|---|
    | Chưa xác minh — **tự tra được** | etcd external?, SAN cert?, VIP ở đâu? | Chạy thêm lệnh trên node |
    | **Không thể tự xác minh** — ngoài phạm vi | LB có health-check không? LB là thiết bị gì? | **Phải hỏi đội hạ tầng mạng** |

    Gộp hai loại này vào nhau sẽ dẫn tới chọn sai cách gỡ: cứ ngồi tra tiếp trong khi đáng lẽ
    phải gửi tin nhắn hỏi đội khác — hoặc ngược lại, hỏi người khác thứ mình tự tra được trong
    30 giây.

    **Rút ra:** khi bí, hỏi ngay "cái này nằm trong tay mình hay tay người khác?" trước khi
    quyết định chạy thêm lệnh hay đi hỏi.

14. **🔴 "File config tồn tại và nội dung đúng" ≠ "công cụ dùng được file đó".**

    Ở output 3.6 đã kiểm `certSANs` trong `kubeadm-config.yaml` — **khớp khít** 18/18 entry với
    cert đang chạy. Kết luận lúc đó: *"dùng được `--config`, đây là kết quả tốt nhất có thể"*.

    **Cái làm lộ ra là thiếu:** output 3.11 — file có **4 YAML document**, mà `kubeadm certs renew
    --config` ở v1.23 **không parse được** cấu trúc đó. Nội dung đúng, nhưng **định dạng công cụ
    không nuốt được**.

    **Vì sao suýt hỏng:** nếu chạy thẳng lệnh renew như quy trình đã soạn, kubeadm rơi về default
    config → cert mới mất `lb-apiserver.kubernetes.local` + VIP + ClusterIP → **toàn cụm hỏng**,
    và cert cũ đã bị ghi đè. Nguy hiểm nhất là kubeadm có thể **im lặng** bỏ qua file, **vẫn báo
    "renewed" thành công** — không có dấu hiệu bất thường nào cho tới bước `diff`.

    **Hai tầng kiểm khác nhau, phải làm cả hai:**

    | Tầng | Câu hỏi | Lệnh | Kết quả phiên này |
    |---|---|---|---|
    | Nội dung | `certSANs` có đúng không? | `grep -A30 certSANs` | ✅ Khớp 18/18 |
    | **Định dạng** | **Công cụ đọc được file không?** | `grep -c '^---'` + `grep '^kind:'` | 🔴 **4 document — KHÔNG đọc được** |

    **Rút ra:** kiểm nội dung xong đừng dừng — hỏi tiếp *"công cụ có thực sự dùng được file này
    không?"*. Với công cụ cũ (EOL), khoảng cách giữa "file đúng" và "công cụ hiểu file" càng rộng.
    Bước `--dry-run` ở GĐ0-ter sinh ra chính vì lý do này.

15. **Version EOL không chỉ là rủi ro bảo mật — nó đổi cả hành vi công cụ.**

    Phát hiện v1.23.2 EOL (output 3.10) ban đầu chỉ ghi như "nợ kỹ thuật, ngoài phạm vi".
    Nhưng nó **trực tiếp** sinh ra vấn đề ở output 3.11: cờ `--config` của `kubeadm certs renew`
    trên nhánh 1.23 kém khoan dung hơn bản mới. Bản mới hơn parse được file nhiều document;
    1.23 thì không.

    **Rút ra:** gặp cluster chạy version EOL, đừng chỉ ghi nhận rồi bỏ qua — **kiểm lại xem quy
    trình chuẩn có còn áp dụng được không**. Tài liệu trên mạng thường viết cho bản mới nhất.

16. **🔴 "Lệnh verify chạy trót lọt" ≠ "kết quả verify ĐẠT" — phải đọc nội dung.**

    Bước `tar tzf` ở GĐ1 sinh ra chính để kiểm backup có dùng được không. Nó **chạy trót lọt**
    trên cả 3 node, in ra danh sách gọn gàng 6 dòng — trông hoàn toàn bình thường.

    **Nhưng đọc kỹ danh sách:** `etc/kubernetes/pki` chỉ hiện **một dòng**, không có
    `apiserver.crt`, `ca.crt`, `ca.key` nào bên trong. Vì `pki` là **symlink** (output 3.13) mà
    `tar` mặc định **lưu symlink như liên kết**, không đi theo để gói nội dung — cần cờ `-h`.

    Kích thước **11K** củng cố: 3 file `.conf` chứa cert base64 đã chiếm gần hết; toàn bộ PKI
    thật không thể nén xuống vài trăm byte.

    ⇒ **Backup tưởng có nhưng không khôi phục được cert.** Đây **nguy hiểm hơn** là biết mình
    không có backup — vì ta sẽ dám renew với niềm tin sai rằng có đường lùi.

    **Rút ra:**
    - Lệnh verify phải **đọc kết quả**, không chỉ xem nó có chạy không. Bài học #12 nói *"output
      rỗng là bằng chứng"*; bài này là mặt kia: **output CÓ nội dung cũng phải soi nội dung đó**.
    - Thiết kế phép verify sao cho **sai lệch lộ ra bằng con số**, không phải bằng cảm nhận:
      `wc -l` (đếm mục) và `grep` đích danh `ca.key` bắt được ngay, còn `head -20` thì không.
    - **Với symlink, luôn hỏi: công cụ này đi theo liên kết hay lưu bản thân liên kết?**
      `tar` cần `-h`; `cp` cần `-L`; `rsync` cần `-L`; `du` cần `-L`. Mặc định của chúng đều là
      **không** đi theo.
    - Cách phòng thủ tốt hơn cả nhớ cờ: **dùng đường dẫn thật** (`/etc/kubernetes/ssl`) thay vì
      symlink (`/etc/kubernetes/pki`). Quy trình đã sửa theo hướng này — an toàn kép.

17. **Lệnh soạn cho nhiều node phải tự thích ứng — đừng nhúng tên node cứng.**

    Lệnh verify được đưa với tên file **cứng** `pki-backup-vrp-kubeengine01-...`. Kiên chạy
    nguyên văn trên node 02 và 03 → `Cannot open: No such file or directory`, tưởng backup hỏng.

    **Hai lỗi soạn lệnh liên tiếp trong cùng một bước, ngược chiều nhau:**

    | Lần | Lệnh | Vấn đề | Hậu quả |
    |---|---|---|---|
    | 1 | `...-$(hostname)-*.tar.gz` | Glob khớp **2 file** → tar hiểu file thứ 2 là *thành viên* | `Not found in archive` |
    | 2 | `...-vrp-kubeengine01-...` | Tên **cứng**, không đổi theo node | `No such file` trên 49/50 |

    **Cách đúng — kết hợp cả hai:** `$(hostname)` cho phần thay đổi theo node,
    **timestamp cụ thể** cho phần cần chính xác:
    `tar tzf /root/pki-backup-$(hostname)-2026-08-19-1118.tar.gz`

    **Rút ra:**
    - Lệnh dùng trên nhiều node: phần **định danh node** phải động (`$(hostname)`), phần **định
      danh phiên bản** phải tĩnh (timestamp cụ thể).
    - Biết trước một cái bẫy mà vẫn đưa lệnh dính bẫy thì cảnh báo vô nghĩa. Bẫy glob đã được ghi
      trong phần "cách đọc" của chính lệnh đó — **nhưng lệnh không được sửa theo**.
      ⇒ Phát hiện rủi ro phải dẫn tới **sửa lệnh**, không chỉ thêm ghi chú.

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| Không có alert cert sắp hết hạn | Chưa từng dựng monitoring cho PKI | **Tái diễn sau đúng 1 năm** (18/08/2027). Đây là sự cố lẽ ra phải biết trước 30 ngày |
| Không có quy trình renew định kỳ | Cert 1 năm, thao tác thủ công, không lịch | Phụ thuộc trí nhớ cá nhân; người phụ trách nghỉ/chuyển việc là mất |
| ~~Chưa rõ kiến trúc etcd~~ → **đã xác định: external** | Đã giải quyết trong phiên này | ✅ Đã ghi vào file này |
| **Không có tài liệu bàn giao cluster** — người vận hành hiện tại không phải người dựng | Kiên là nhân viên mới, phụ trách deploy service | Mọi sự cố hạ tầng đều phải chẩn đoán lại từ đầu. **Đây là nợ lớn nhất**, sinh ra mọi ẩn số khác trong phiên này |
| Không biết repo Kubespray/Ansible inventory ở đâu | Không có bàn giao | `certSANs` gốc và mọi cấu hình cluster nằm ở đó. Không có repo = không thể dựng lại cluster, không thể nâng cấp đúng cách |
| Không rõ ai sửa `kube-apiserver.yaml` ngày 18/09/2024 và sửa gì | Không có changelog/git cho `/etc/kubernetes` | Không biết cấu hình hiện tại lệch bao nhiêu so với file config gốc |
| Thư mục cert quyền `755` thay vì `700` mặc định | Kubespray cấu hình | Mọi user trên node đọc được danh sách file cert. Cần kiểm quyền file `.key` bên trong có phải `600` không |
| Vai trò IP `10.208.137.68` không rõ | Có trong SAN cert nhưng không thuộc danh sách node | Có thể là VIP hoặc node đã gỡ. Không rõ thì không dám bỏ, cũng không dám dựa vào |
| Không có tài liệu `certSANs` gốc của cluster | ConfigMap `kubeadm-config` là nơi duy nhất, mà nó chỉ đọc được khi cluster sống | Cluster chết = mất luôn thông tin cần để sửa cluster. Vòng lặp chết |
| `~/.kube/config` không được setup cho user vận hành | Thao tác qua `su root` | Mỗi lần sự cố phải mò lại; dễ nhầm lỗi kubeconfig thành lỗi cluster |

---

## 7. Việc tiếp theo

### Ngay lập tức — ✅ ĐÃ HOÀN THÀNH nhóm chẩn đoán ban đầu

- [x] ~~Xác định etcd external hay stacked~~ → ✅ **EXTERNAL** (output 3.4)
- [x] ~~Chụp SAN cert cũ~~ → ✅ **18 entry, đã ghi đầy đủ ở output 3.5**
- [x] ~~Tìm `kubeadm-config.yaml`~~ → ✅ **tồn tại, nhưng mtime 2023 — cần đối chiếu**
- [x] ~~Xác định control-plane endpoint~~ → ✅ **`lb-apiserver.kubernetes.local:6443`** (output 3.0)

### Bước kế tiếp — ✅ đã xong phần config, còn phần LB

- [x] ~~A1: đối chiếu `certSANs` với SAN cert~~ → ✅ **KHỚP** (output 3.6) ⇒ dùng được `--config`
- [x] ~~A4: xác nhận cơ chế LB~~ → 🔴 **LB TẬP TRUNG tại `10.208.137.68`** (output 3.7), không phải localhost-LB

### ✅ Đã xong phần LB — không còn ràng buộc thứ tự restart

- [x] ~~A6: VIP là keepalived trên master hay LB ngoài?~~ → ✅ **LB NGOÀI CỤM** (output 3.8,
      rỗng trên cả 3 master)
- [x] ~~A7: có keepalived/haproxy/nginx trên master?~~ → ✅ **KHÔNG** (output 3.9)
- ⇒ **Master restart không đụng tới VIP.** Thứ tự 48→49→50 giữ nguyên nhưng lý do đổi:
  không còn vì "node giữ VIP phải sau cùng", mà chỉ để **còn đường rollback** nếu cert mới sai SAN.

### Còn lại trước khi renew (chỉ đọc, chạy trên 48)

- [ ] **A8** — Đếm chính xác số SAN entry (làm rõ điểm lệch `.vrp` / `cluster.local` ở 3.6)

  ```
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  openssl ... | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
  │             │  │    │      │    ││
  │             │  │    │      │    │└─ E: regex mở rộng, `|` là OR không cần escape
  │             │  │    │      │    └─ c: chỉ ĐẾM số dòng khớp, không in nội dung
  │             │  │    │      └─ khớp cả entry DNS lẫn IP
  │             │  │    └─ thay bằng ký tự xuống dòng
  │             │  └─ ký tự cần thay: dấu phẩy
  │             └─ tr: openssl in SAN thành MỘT dòng dài 18 entry; tách thành 18 dòng
  │                riêng thì grep -c mới đếm đúng. Không có tr thì kết quả luôn là 1
  └─ MỤC ĐÍCH: đếm chính xác, tránh sai sót do gõ lại từ screenshot qua VDI
     • Ra 18 → khớp file config, cert KHÔNG có kubernetes.default.svc.vrp
       ⇒ renew kèm --config sẽ THÊM entry đó (vô hại, nhưng biết trước để không hoảng)
     • Ra 19 → cert đã có sẵn, output 3.5 bị sót khi gõ tay
  ```
  </details>

- [ ] **A9** — Xác nhận version kubeadm khớp version cluster đang chạy

  ```
  kubeadm version -o short
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  kubeadm version -o short
  │               │  └─ chỉ in chuỗi version (vd v1.28.5); bỏ cờ này sẽ ra khối JSON dài
  │               └─ -o: chọn định dạng output
  └─ ⚠️ VÌ SAO QUAN TRỌNG: kubeadm renew sinh cert theo logic của CHÍNH version binary đó.
     Nếu binary đã nâng cấp mà cluster vẫn chạy version cũ (hoặc ngược lại), cert sinh ra
     có thể khác kỳ vọng.
     ĐỐI CHIẾU với image tag trong /etc/kubernetes/manifests/kube-apiserver.yaml:
       grep image: /etc/kubernetes/manifests/kube-apiserver.yaml
     Hai con số phải khớp nhau
  ```
  </details>

### Cần hỏi người khác (không tự tra được — Kiên không phải người dựng cụm)

> Tách riêng vì đây là **"bị chặn bởi thông tin"**, khác hẳn "chưa biết cách làm".
> Không có câu trả lời vẫn renew được, nhưng có thì an toàn hơn hẳn.

- [ ] **Repo Kubespray / Ansible inventory của cụm này ở đâu?**
      → chứa `certSANs` gốc (biến `supplementary_addresses_in_ssl_keys`), là nguồn đáng tin nhất
- [ ] **Ai sửa `/etc/kubernetes/manifests/kube-apiserver.yaml` ngày 18/09/2024, sửa gì?**
      → quyết định `kubeadm-config.yaml` (2023) còn dùng được không
- [x] ~~**`10.208.137.68` là gì?**~~ → ✅ **VIP / LB endpoint** (output 3.7). Nhưng vẫn cần hỏi:
- [x] ~~**VIP `.68` do ai quản?** keepalived trên master hay LB ngoài?~~ → ✅ **LB NGOÀI CỤM**
      (output 3.8/3.9: không master nào giữ VIP, không có keepalived/haproxy/nginx trên master)
- [ ] 🔴 **LB `.68` có health-check port 6443 không?** — **câu hỏi quan trọng nhất còn lại.**
      Có → restart master an toàn, LB tự loại node đang down.
      Không → mỗi lần restart có ~1/3 request lỗi. **Không tự kiểm được từ trong cụm**
- [ ] **LB `.68` là thiết bị gì, ai vận hành?** (F5 / HAProxy trên VM riêng / LB của đội mạng)
- [ ] **Cluster domain là `.vrp` hay `cluster.local`?** File config khai `.vrp`, cert lại dùng
      `cluster.local` (output 3.6). Cần biết bên nào đúng để không đổi hành vi cluster khi renew
- [ ] **Có ai từng renew cert cụm này chưa?** Nếu có, làm bằng cách nào (kubeadm hay playbook Kubespray)
- [ ] **Cửa sổ bảo trì** để thao tác — có gián đoạn ngắn API server khi restart

### ⭐ QUY TRÌNH RENEW ĐẦY ĐỦ — 3 node, thực hiện tuần tự

> **Trạng thái: chưa thực hiện.** Mọi output dưới đây là *kỳ vọng*, không phải kết quả thật.
> Chạy tới đâu, dán output thật vào mục 3 tới đó (đánh số `3.10`, `3.11`...).
>
> **Nguyên tắc bất di bất dịch:** làm **XONG HẲN** node 48 (gồm cả verify) rồi mới sang 49;
> xong 49 mới sang 50. **Không bao giờ** chạy song song 2 node.
>
> 📋 **Nhịp làm việc** (chốt với Kiên): gửi output **ngay sau mỗi lệnh**, chờ xác nhận rồi mới
> chạy lệnh tiếp. Ba điểm 🛑 dưới đây là **bắt buộc dừng**, không được tự chạy tiếp.
> Chi tiết ở mục 3 → "Giao ước cập nhật".

##### 📍 Bảng tra cứu node / user — mỗi lệnh trong quy trình đều có nhãn này

| Giai đoạn | Chạy ở đâu | User | Ghi chú |
|---|---|---|---|
| GĐ0 Tiền kiểm | Node **48** `vrp-kubeengine01` | `root` | Chỉ đọc |
| GĐ1 Backup | **Cả 3** master 48 → 49 → 50 | `root` | Lần lượt, không song song |
| GĐ2 Renew | Node **48** trước | `root` | 49/50 làm sau khi 48 xong hẳn |
| GĐ3 So SAN | Node **48** | `root` | 🛑🛑 Chốt chặn |
| GĐ4 Restart | Node **48** | `root` | Không đứt SSH |
| GĐ5 Verify | Node **48** | `root` | — |
| GĐ6.2 Cert kubelet | **5 worker** `.51` → `.55` | `root` | — |
| GĐ6.3 Helm | Worker **`vrp-kubeengine04`** | ⚠️ **`app`** | **Khác user!** Đúng nơi phát hiện sự cố |
| ROLLBACK | Node đang gặp sự cố | `root` | — |

> ⚠️ **Vì sao phải ghi rõ user:** chính phiên này đã có bằng chứng — cùng một sự cố cert nhưng
> `vt_admin` trên master 48 báo `localhost:8080 refused` (output 3.1) còn `app` trên worker 04
> báo `x509: certificate has expired` (output 3.0). **Sai user ⇒ đọc sai triệu chứng ⇒ chẩn đoán sai.**
>
> Master: đăng nhập `vt_admin` rồi `su` sang `root` (như đã làm ở output 3.2).
> Worker: user `app` cho lệnh helm — **không** dùng `root`, vì kubeconfig và Helm release
> nằm ở `$HOME` của `app`.

#### Điều kiện tiên quyết

| Điều kiện | Trạng thái | Nguồn |
|---|---|---|
| CA còn hạn | ✅ tới 2033 (`6y`) | Output 3.2 |
| etcd external (không có quorum trên master để mất) | ✅ | Output 3.4 |
| `kubeadm-config.yaml` còn khớp cert | ✅ 18/18 entry | Output 3.6 |
| VIP ngoài cụm (restart master không đụng VIP) | ✅ | Output 3.8 + 3.9 |
| Cửa sổ bảo trì đã thống nhất | ❓ **cần xác nhận với sếp trước khi bắt đầu** | — |

---

#### GIAI ĐOẠN 0 — Tiền kiểm (chỉ đọc, chạy trên node 48)

Gộp A8 + A9 vào đây, không cần round-trip riêng.

**0.1 — Đếm chính xác số SAN entry của cert hiện tại**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
openssl x509 -in <cert> -noout -text | tr ',' '\n' | grep -cE 'DNS:|IP Address:'
│       │     │          │      │       │  │    │     │    ││
│       │     │          │      │       │  │    │     │    │└─ E: regex mở rộng,
│       │     │          │      │       │  │    │     │    │   `|` là OR không cần escape
│       │     │          │      │       │  │    │     │    └─ c: chỉ ĐẾM dòng khớp,
│       │     │          │      │       │  │    │     │       không in nội dung
│       │     │          │      │       │  │    │     └─ khớp cả entry DNS lẫn IP
│       │     │          │      │       │  │    └─ thay bằng ký tự xuống dòng
│       │     │          │      │       │  └─ ký tự cần thay: dấu phẩy
│       │     │          │      │       └─ tr: openssl in SAN thành MỘT dòng dài 18 entry.
│       │     │          │      │          Không tách dòng thì `grep -c` luôn trả về 1
│       │     │          │      └─ -text: decode cert sang dạng người đọc
│       │     │          └─ -noout: không in lại khối PEM base64
│       │     └─ đọc cert từ file
│       └─ sub-command thao tác cert X.509
└─ ⭐ GHI LẠI CON SỐ NÀY — dùng để so sánh sau khi renew (bước 4.1)
   • Kỳ vọng 18 → khớp certSANs trong file config
   • Ra 19 → cert đã có sẵn kubernetes.default.svc.vrp, output 3.5 bị sót khi gõ tay
```
</details>

**0.2 — Xác nhận version kubeadm khớp version cluster**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubeadm version -o short
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
kubeadm version -o short
│               │  └─ chỉ in chuỗi version (vd v1.28.5)
│               └─ -o: chọn định dạng. Bỏ cờ này ra khối JSON dài, khó đọc qua VDI
└─ ⚠️ VÌ SAO QUAN TRỌNG: `kubeadm certs renew` sinh cert theo logic của CHÍNH binary này.
   Binary nâng cấp mà cluster còn version cũ (hoặc ngược lại) → cert có thể khác kỳ vọng
```
</details>

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
grep image: /etc/kubernetes/manifests/kube-apiserver.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
grep image: /etc/kubernetes/manifests/kube-apiserver.yaml
│    │      └─ manifest static pod — nguồn sự thật về version ĐANG CHẠY
│    └─ dòng `image: registry.k8s.io/kube-apiserver:v1.xx.x`
└─ ⭐ ĐỐI CHIẾU với kết quả 0.2: hai version phải KHỚP.
   Lệch minor version (vd kubeadm v1.29 vs apiserver v1.28) → DỪNG, hỏi lại trước khi renew
```
</details>

**0.3 — Ghi lại SAN đầy đủ ra file để so sánh về sau**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A3 'Alternative Name' > /root/san-truoc-renew-48.txt
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
openssl ... | grep -A3 'Alternative Name' > /root/san-truoc-renew-48.txt
              │    │                       │ └─ tên file có hậu tố -48: mỗi node một file
              │    │                       │    riêng, tránh ghi đè khi làm node 49/50
              │    │                       └─ `>` GHI ĐÈ file (không phải `>>` nối thêm) —
              │    │                          chạy lại lệnh sẽ tạo file sạch, không lẫn lộn
              │    └─ -A3: 3 dòng sau (rộng hơn -A2 ở output 3.5 để chắc chắn không sót)
              └─ lọc khối SAN
└─ ⭐ VÌ SAO GHI RA FILE thay vì chỉ nhìn màn hình: bước 4.1 sẽ `diff` file này với SAN
   sau renew. So bằng mắt 18 entry trên VDI rất dễ sót — máy so chính xác hơn người
```
</details>

---

#### 🔴 GIAI ĐOẠN 0-bis — Kiểm bổ sung (phát sinh sau output 3.10: v1.23.2 EOL)

> Hai rủi ro mới lộ ra từ GĐ0, đều **ảnh hưởng trực tiếp** tới GĐ2 và GĐ4.
> Chi phí kiểm: 2 lệnh. Chi phí bỏ qua: phát hiện khi đã renew/restart, phải rollback.

**0b.1 — ⭐ Cấu trúc `kubeadm-config.yaml` có mấy YAML document?**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
grep -c '^---' /etc/kubernetes/kubeadm-config.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
grep -c '^---' /etc/kubernetes/kubeadm-config.yaml
│    │   ││
│    │   │└─ `---` là dấu ngăn cách document trong YAML: một file có thể chứa
│    │   │   NHIỀU object (InitConfiguration, ClusterConfiguration, KubeletConfiguration...)
│    │   └─ `^`: neo đầu dòng — chỉ khớp `---` đứng đầu dòng, bỏ qua `---` nằm giữa
│    │      chuỗi hay trong comment
│    └─ -c: ĐẾM số dòng khớp, không in nội dung
└─ ⚠️ VÌ SAO QUAN TRỌNG VỚI v1.23:
   `kubeadm certs renew --config <file>` ở nhánh 1.23 đọc ClusterConfiguration từ file.
   File nhiều document => kubeadm có thể parse nhầm hoặc bỏ qua certSANs.
   ĐỌC KẾT QUẢ:
   • 0 hoặc 1  → file một document, --config hoạt động bình thường ✔
   • ≥ 2       → file nhiều document → RỦI RO --config không ăn certSANs
                 ⇒ vẫn chạy renew, nhưng GĐ3 gần như CHẮC CHẮN sẽ phát hiện thiếu SAN
                 ⇒ báo lại để soạn file config rút gọn chỉ chứa ClusterConfiguration
```
</details>

Xem luôn các `kind` có trong file:

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
grep '^kind:' /etc/kubernetes/kubeadm-config.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
grep '^kind:' /etc/kubernetes/kubeadm-config.yaml
│     ││
│     │└─ `kind:` là trường khai loại object trong YAML của Kubernetes
│     └─ `^`: neo đầu dòng — `kind:` của document cấp cao nhất luôn ở cột 0,
│        còn `kind:` lồng bên trong sẽ có thụt lề nên bị loại
└─ ĐỌC KẾT QUẢ:
   • Chỉ `kind: ClusterConfiguration`       → lý tưởng, --config chắc chắn đúng
   • Có thêm `kind: InitConfiguration`      → phổ biến với Kubespray, thường vẫn OK
   • Có `kind: KubeletConfiguration` / `KubeProxyConfiguration` → file gộp nhiều loại,
     rủi ro cao hơn với 1.23
```
</details>

**0b.2 — Image apiserver còn trong cache cục bộ không?**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
crictl images | grep kube-apiserver
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
crictl images | grep kube-apiserver
│      │        └─ lọc dòng chứa tên image cần
│      └─ liệt kê image đã có SẴN trên node (trong containerd), KHÔNG gọi ra registry
└─ ⭐ VÌ SAO CẦN: image kéo từ registry NỘI BỘ `10.60.129.132:8090` (output 3.10),
   không phải registry.k8s.io. Khi restart ở GĐ4, kubelet tạo lại static pod:
   • Image CÓ trong cache → dùng luôn, KHÔNG cần registry ⇒ an toàn kể cả registry chết
   • Image KHÔNG có       → kubelet phải kéo từ 10.60.129.132:8090.
                            Registry chết = static pod KHÔNG LÊN ĐƯỢC = node hỏng
   ĐỌC KẾT QUẢ: phải thấy dòng chứa `kube-apiserver` và tag `v1.23.2`
   ⚠️ Nếu KHÔNG thấy → DỪNG, kiểm registry sống không trước khi restart:
      curl -sS -o /dev/null -w '%{http_code}\n' http://10.60.129.132:8090/v2/
```
</details>

---

#### 🔒 QUY TẮC BACKUP — áp dụng cho MỌI bước có sửa file

> Kiên chốt 2026-08-19: *"trước khi làm gì thì cũng cần có backup"*.
>
> **Nguyên tắc:** file nào sắp bị **sửa / ghi đè / đổi tên** thì phải có bản sao **trước đó**.
> File chỉ **đọc** thì không cần — nhưng khi phân vân thì cứ backup, chi phí gần bằng 0.

| Bước | Đụng vào file nào | Kiểu đụng | Backup |
|---|---|---|---|
| GĐ0, 0-bis, 0-ter | `kubeadm-config.yaml` | **Chỉ đọc** (`grep`, `cat`, `sed -n`) | Vẫn backup — xem 0q.2 |
| GĐ1 | — | — | Đây **chính là** bước backup PKI |
| **GĐ2 renew** | `/etc/kubernetes/ssl/*` (hoặc `pki`), `*.conf` | 🔴 **GHI ĐÈ** | ✅ GĐ1 đã lo |
| **GĐ4 restart** | thư mục `manifests/` | 🔴 **ĐỔI TÊN** | ✅ 0q.3 |
| GĐ5 | `~/.kube/config` | 🔴 **GHI ĐÈ** | ✅ 0q.4 |

> ⚠️ `sed -n '14,119p' <nguồn> > /root/<đích>` **KHÔNG sửa file nguồn** — nó chỉ đọc và ghi ra
> file mới ở `/root/`. Nhưng vẫn backup theo nguyên tắc trên.

---

#### 🔴 GIAI ĐOẠN 0-quater — Xác minh `certificatesDir` + backup (BẮT BUỘC)

> Phát sinh sau output 3.12: file config khai **`certificatesDir: /etc/kubernetes/ssl`**,
> không phải `/etc/kubernetes/pki` mà mọi lệnh trong quy trình đang dùng.
> **Nếu sai thư mục, bước `diff` SAN ở GĐ3 sẽ so nhầm file và không phát hiện được cert hỏng.**

**0q.1 — ✅ ĐÃ CHẠY (output 3.13): `pki` là SYMLINK tới `ssl`** — quy trình không phải sửa đường dẫn

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
ls -ld /etc/kubernetes/pki /etc/kubernetes/ssl
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
ls -ld /etc/kubernetes/pki /etc/kubernetes/ssl
│  ││
│  │└─ ⭐ d: hiện thông tin CHÍNH thư mục, KHÔNG liệt kê nội dung bên trong.
│  │   Thiếu `d` thì ls đổ ra toàn bộ file trong cả hai thư mục — rối, và
│  │   quan trọng hơn là KHÔNG thấy được thư mục đó có phải symlink không
│  └─ -l: long format — cần để thấy ký tự đầu tiên (`d` = thư mục, `l` = symlink)
└─ ĐỌC KẾT QUẢ — nhìn KÝ TỰ ĐẦU mỗi dòng:
   • `lrwxrwxrwx ... pki -> ssl`  → pki là SYMLINK trỏ tới ssl ⇒ HAI TÊN MỘT THƯ MỤC
     ⇒ ✅ mọi lệnh /etc/kubernetes/pki/... trong quy trình VẪN ĐÚNG, không phải sửa gì
   • `drwx------ ... pki` VÀ `drwx------ ... ssl` (cả hai đều `d`)
     → HAI thư mục RIÊNG BIỆT ⇒ 🔴 phải đổi mọi đường dẫn sang /etc/kubernetes/ssl
   • Một trong hai báo "No such file or directory" → chỉ tồn tại một thư mục, dùng cái đó
```
</details>

> ✅ **Không cần lệnh so cert bổ sung** — vì là symlink nên chỉ có MỘT file duy nhất.
> Rủi ro "so nhầm file ở GĐ3" đã được loại bỏ.

**0q.2 — Backup file config gốc (trước khi tách)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
cp -a /etc/kubernetes/kubeadm-config.yaml /root/kubeadm-config.yaml.bak-$(date +%F-%H%M)
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
cp -a <nguồn> <đích>
│  │
│  └─ ⭐ -a (archive) = -dR --preserve=all: giữ NGUYÊN quyền, owner, timestamp, symlink.
│     `cp` trần sẽ đổi mtime thành thời điểm copy và đặt owner theo user đang chạy
│     → mất thông tin "file này sửa lần cuối 06/07/2023" vốn là manh mối quan trọng
│     (chính mtime đã lộ ra chuyện apiserver.yaml bị sửa 09/2024 — xem Bài học #10)
└─ $(date +%F-%H%M) → 2026-08-19-1048: chạy lại không ghi đè bản backup trước
   Đặt ở /root/ chứ không cùng thư mục /etc/kubernetes/ — tránh kubeadm/kubelet
   quét nhầm file .bak
```
</details>

**0q.3 — Backup thư mục manifests (GĐ4 sẽ đổi tên nó)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
cp -a /etc/kubernetes/manifests /root/manifests-backup-$(date +%F-%H%M)
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
cp -a /etc/kubernetes/manifests /root/manifests-backup-<timestamp>
│  │  └─ 3 file: kube-apiserver.yaml, kube-controller-manager.yaml, kube-scheduler.yaml
│  └─ -a: copy đệ quy + giữ nguyên quyền/mtime (xem 0q.2)
└─ ⭐ VÌ SAO CẦN: GĐ4 đổi tên thư mục này thành manifests.off rồi đổi lại.
   Nếu thao tác bị gián đoạn giữa chừng (mất SSH, gõ nhầm), thư mục có thể ở trạng
   thái dở dang → control-plane KHÔNG BAO GIỜ chạy lại. Có bản copy thì khôi phục được.
   ⚠️ Đặt ở /root/, KHÔNG để trong /etc/kubernetes/ — kubelet quét mọi thứ trong đó
```
</details>

**0q.4 — Backup kubeconfig hiện tại (GĐ5 sẽ ghi đè)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
cp -a /root/.kube/config /root/kube-config.bak-$(date +%F-%H%M) 2>/dev/null || echo "chua co ~/.kube/config - bo qua"
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
cp -a <nguồn> <đích> 2>/dev/null || echo "..."
│                     │            │  └─ chạy khi vế trái THẤT BẠI
│                     │            └─ `||` = OR: chỉ chạy vế phải nếu vế trái exit code ≠ 0
│                     └─ nuốt thông báo lỗi "No such file" — vì đây là trường hợp
│                        BÌNH THƯỜNG (output 3.1 cho thấy root chưa có ~/.kube/config)
└─ ⭐ Cấu trúc `lệnh || echo` giúp lệnh KHÔNG BAO GIỜ báo lỗi đỏ, mà in thông báo dễ hiểu.
   Hữu ích khi file có thể có hoặc không — tránh hoang mang lúc thao tác gấp
```
</details>

---

#### 🔴 GIAI ĐOẠN 0-ter — Tách file config (BẮT BUỘC, phát sinh sau output 3.11)

> **Vì sao bắt buộc:** `/etc/kubernetes/kubeadm-config.yaml` chứa **4 document**
> (`InitConfiguration`, `ClusterConfiguration`, `KubeProxyConfiguration`, `KubeletConfiguration`).
> `kubeadm certs renew --config` ở v1.23 **không parse được** file như vậy → rơi về default config
> → cert mới mất SAN → **toàn cụm hỏng**.
>
> ⇒ Phải tạo file mới **chỉ chứa `ClusterConfiguration`**.

**0t.1 — ✅ ĐÃ CHẠY (output 3.12)** — Xem chính xác phạm vi khối `ClusterConfiguration`

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
grep -n '^---\|^kind:' /etc/kubernetes/kubeadm-config.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
grep -n '^---\|^kind:' /etc/kubernetes/kubeadm-config.yaml
│    │   │     │
│    │   │     └─ `\|` = OR trong regex CƠ BẢN (BRE). Ở đây KHÔNG dùng -E nên `|`
│    │   │        phải escape thành `\|`. Nếu dùng -E thì viết `|` trần
│    │   └─ khớp dòng bắt đầu bằng `---` (ngăn document) hoặc `kind:` (loại object)
│    └─ -n: ⭐ IN SỐ DÒNG — đây là mục đích chính, cần biết ClusterConfiguration
│       bắt đầu và kết thúc ở dòng nào để cắt cho đúng
└─ ĐỌC KẾT QUẢ: tìm dòng `kind: ClusterConfiguration`, rồi tìm dấu `---` KẾ TIẾP.
   Khối cần lấy nằm giữa hai mốc đó (không gồm dấu `---` sau).
   Ví dụ: kind ở dòng 15, `---` kế tiếp ở dòng 78 → cần lấy dòng 12..77
   (lùi lên vài dòng để lấy cả `apiVersion:` đứng trước `kind:`)
```
</details>

**0t.2 — ✅ ĐÃ CHẠY (output 3.12)** — Xem toàn bộ file để xác định ranh giới

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
cat -n /etc/kubernetes/kubeadm-config.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
cat -n /etc/kubernetes/kubeadm-config.yaml
│   │
│   └─ -n: đánh số dòng — khớp với số dòng ở 0t.1 để cắt chính xác
└─ File 4463 bytes (~120 dòng), đủ ngắn để xem hết một lần.
   ⭐ CẦN NHÌN: khối ClusterConfiguration bắt đầu từ dòng `apiVersion: kubeadm.k8s.io/v1beta2`
   (hoặc v1beta3) NGAY TRƯỚC `kind: ClusterConfiguration`, kết thúc ngay TRƯỚC dấu `---` kế tiếp
   ⚠️ Gửi output này cho mình xác nhận ranh giới trước khi cắt — cắt sai làm mất certSANs
```
</details>

**0t.3 — Tách khối `ClusterConfiguration` ra file riêng**

> ✅ **Số dòng ĐÃ XÁC ĐỊNH từ output 3.12: cắt dòng `14` → `119`.**
> Dòng 14 là `apiVersion` (bắt buộc đi kèm `kind` ở dòng 15); dòng 119 là dòng cuối
> trước dấu `---` ở dòng 120.

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
sed -n '14,119p' /etc/kubernetes/kubeadm-config.yaml > /root/cluster-config-renew.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
sed -n '<đầu>,<cuối>p' <file nguồn> > <file đích>
│   │   │              │             └─ `>` ghi đè file đích (chạy lại được, không nối thêm)
│   │   │              └─ ĐỌC, không sửa file gốc — file gốc giữ nguyên làm bản đối chiếu
│   │   └─ dải dòng cần lấy: '14,119' (xác định từ output 3.12)
│   │      `p` cuối = print (in ra) dòng trong dải đó
│   └─ ⭐ -n: TẮT chế độ tự in mọi dòng của sed.
│      KHÔNG có -n thì sed in TẤT CẢ các dòng, cộng thêm in LẶP LẠI dải đã chọn
│      → file đích có nội dung thừa và lặp. Đây là cờ dễ quên nhất của sed
└─ Đặt file ở /root/ chứ KHÔNG ghi đè /etc/kubernetes/kubeadm-config.yaml:
   file gốc là bản ghi lịch sử của cluster, không được sửa
```
</details>

**0t.4 — Kiểm file vừa tách: đúng 1 document, có đủ 18 `certSANs`**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
grep -c '^---\|^kind:' /root/cluster-config-renew.yaml
```

<details>
<summary>Cách đọc</summary>

```
KỲ VỌNG: 1  (đúng một dòng `kind: ClusterConfiguration`, KHÔNG có dấu `---` nào)
• Ra 2+ → cắt lẫn document khác, làm lại 0t.3 với dải dòng hẹp hơn
• Ra 0  → cắt trượt, không có kind nào, làm lại
```
</details>

```
grep -A20 'certSANs' /root/cluster-config-renew.yaml
```

<details>
<summary>Cách đọc</summary>

```
KỲ VỌNG: đủ 18 entry, giống hệt output 3.6. ⭐ SOI KỸ 3 entry sống còn:
  - lb-apiserver.kubernetes.local
  - 10.208.137.68
  - 172.16.128.1
Thiếu bất kỳ entry nào → cắt sai → làm lại 0t.3, KHÔNG renew
```
</details>

**Đếm chính xác thay vì đếm bằng mắt** (18 dòng trên VDI rất dễ sót):

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
sed -n '/certSANs:/,/timeoutForControlPlane/p' /root/cluster-config-renew.yaml | grep -c '^  - '
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
sed -n '/certSANs:/,/timeoutForControlPlane/p' <file> | grep -c '^  - '
│   │   │            │                          │       │    │
│   │   │            │                          │       │    └─ khớp dòng bắt đầu bằng
│   │   │            │                          │       │       ĐÚNG 2 dấu cách + "- "
│   │   │            │                          │       │       = đúng mức thụt lề của
│   │   │            │                          │       │       entry certSANs. Dùng `^  - `
│   │   │            │                          │       │       thay vì `- ` để KHÔNG đếm
│   │   │            │                          │       │       nhầm entry ở mức khác
│   │   │            │                          │       └─ -c: ĐẾM, không in
│   │   │            │                          └─ giới hạn phạm vi: chỉ trong khối certSANs
│   │   │            └─ mốc KẾT THÚC: dòng ngay sau danh sách SAN (xem output 3.12, dòng 97)
│   │   └─ mốc BẮT ĐẦU: dòng `certSANs:`
│   └─ -n + p: chỉ in dải giữa hai mốc (xem giải nghĩa -n ở 0t.3)
└─ ⭐ KỲ VỌNG: 18 — khớp output 3.6 và output 3.10 (SAN cert hiện tại cũng 18)
   • Ra 18 → ✅ file tách đúng, sang GĐ1
   • Ra < 18 → 🔴 cắt thiếu, file config sai → LÀM LẠI 0t.3, KHÔNG renew
   • Ra > 18 → cắt lẫn danh sách khác → kiểm lại ranh giới dòng
```
</details>

**Kiểm file có parse được như YAML hợp lệ không:**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
tail -3 /root/cluster-config-renew.yaml
```

<details>
<summary>Cách đọc</summary>

```
tail -3 <file>
│    │
│    └─ 3 dòng CUỐI file
└─ ⭐ MỤC ĐÍCH: xác nhận file kết thúc ĐÚNG CHỖ, không cắt cụt giữa chừng.
   KỲ VỌNG (theo output 3.12, dòng 117-119):
       hostPath: /etc/kubernetes/kubescheduler-config.yaml
       mountPath: /etc/kubernetes/kubescheduler-config.yaml
       readOnly: true
   • Thấy dấu `---` ở cuối     → 🔴 cắt lố sang document sau, sửa lại thành '14,119p'
   • Thấy `kind: KubeProxy...` → 🔴 cắt lố nhiều, sai hoàn toàn
   • Dòng cuối cụt giữa chừng  → 🔴 cắt thiếu
```
</details>

**0t.5 — ❌ ĐÃ THỬ, KHÔNG DÙNG ĐƯỢC (output 3.16): v1.23 không hỗ trợ `--dry-run`**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml --dry-run
```

<details>
<summary>Giải nghĩa lệnh — ⭐ bước an toàn quan trọng nhất</summary>

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml --dry-run
│                   │          │                                       │
│                   │          │                                       └─ ⭐⭐ CHẠY THỬ:
│                   │          │          kubeadm làm MỌI thứ như thật nhưng ghi cert ra
│                   │          │          THƯ MỤC TẠM, KHÔNG đụng /etc/kubernetes/pki
│                   │          └─ file vừa tách ở 0t.3
│                   └─ chỉ renew MỘT cert `apiserver` thay vì `all` — đủ để kiểm parse,
│                      phạm vi hẹp nhất có thể
└─ ⭐ VÌ SAO BƯỚC NÀY QUÝ: kiểm được kubeadm CÓ ĐỌC ĐƯỢC file mới không, mà KHÔNG
   phải renew thật. Nếu file vẫn sai, lỗi hiện ra ngay ở đây — cert thật còn nguyên vẹn.
   ĐỌC KẾT QUẢ:
   • In đường dẫn thư mục tạm + "certificate ... renewed" → ✅ file OK, sang GĐ1
   • Lỗi `unknown kind` / `failed to unmarshal` → file vẫn sai, quay lại 0t.3
   • ⚠️ v1.23 có thể KHÔNG hỗ trợ --dry-run cho `certs renew`: nếu báo
     `unknown flag: --dry-run` thì bỏ qua bước này, dựa vào 0t.4 + so SAN ở GĐ3
```
</details>

---

#### GIAI ĐOẠN 1 — Backup (BẮT BUỘC, chạy trên CẢ 3 node trước khi renew node đầu tiên)

> Backup cả 3 node **trước**, không backup từng node ngay trước khi renew nó.
> Lý do: nếu node 48 hỏng và cần dựng lại, có thể vẫn cần đối chiếu PKI của 49/50.

📍 **Từng node 48 → 49 → 50** (`vrp-kubeengine01/02/03`) — user **`root`**

> ⚠️ Chạy **lần lượt**, không song song. Ghi rõ đã backup xong node nào.

```
tar czf /root/pki-backup-$(hostname)-$(date +%F-%H%M).tar.gz /etc/kubernetes/pki /etc/kubernetes/*.conf /etc/kubernetes/kubeadm-config.yaml
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
tar czf <đích> <nguồn1> <nguồn2> <nguồn3>
│   │││  │
│   │││  └─ $(hostname) → vrp-kubeengine01/02/03: biết file backup của node nào
│   │││     $(date +%F-%H%M) → 2026-08-19-1430: chạy lại không ghi đè bản trước
│   ││└─ f: chỉ định tên file đích. PHẢI đứng cuối cụm cờ, ngay trước tên file
│   │└─ z: nén gzip
│   └─ c: create archive
│   └─ ⭐⭐ h: ĐI THEO SYMLINK (--dereference) — gói NỘI DUNG đích thay vì
│      lưu bản thân liên kết. THIẾU CỜ NÀY = backup rỗng, xem output 3.18
└─ BA NGUỒN, thiếu cái nào cũng không rollback được:
   • /etc/kubernetes/ssl        → ⭐ dùng đường dẫn THẬT thay vì symlink `pki`.
                                   An toàn kép: kể cả quên -h vẫn gói đúng nội dung
   • /etc/kubernetes/*.conf     → admin.conf, kubelet.conf, controller-manager.conf,
                                  scheduler.conf. Cert nhúng base64 BÊN TRONG, renew
                                  cũng ghi đè các file này → phải backup
   • kubeadm-config.yaml        → file dùng cho --config, mất là không renew đúng SAN được
```
</details>

> ℹ️ **`tar: Removing leading '/' from member names` là BÌNH THƯỜNG, không phải lỗi.**
> Tar bỏ dấu `/` đầu để archive lưu đường dẫn tương đối — cơ chế an toàn, tránh việc giải nén
> ở đâu cũng ghi đè thẳng vào hệ thống. Đây chính là lý do lệnh rollback R1 cần cờ `-C /`.
> Chi tiết: xem output 3.17.

Kiểm tra backup thật sự đọc được (đừng tin file `.tar.gz` chỉ vì nó tồn tại):

📍 **Từng node 48 → 49 → 50** — user **`root`**

```
tar tzf /root/pki-backup-$(hostname)-*.tar.gz | head -20
```

<details>
<summary>Giải nghĩa lệnh</summary>

```
tar tzf <file> | head -20
│   ││└─ f: đọc từ file
│   │└─ z: giải nén gzip
│   └─ t: LIỆT KÊ nội dung, KHÔNG giải nén ra đĩa (khác `x` là extract)
└─ ⭐ VÌ SAO CẦN BƯỚC NÀY: `tar czf` có thể tạo file lỗi nếu hết dung lượng đĩa mà
   không báo rõ. `tar tzf` chạy trót lọt = archive đọc được = rollback được.
   head -20: chỉ xem 20 dòng đầu cho gọn, đủ để xác nhận có đường dẫn pki/
```
</details>

---

#### GIAI ĐOẠN 2 — Renew cert (node 48 trước)

> ⚠️ **GĐ2 đã ĐIỀU CHỈNH sau output 3.16** (`--dry-run` không dùng được ở v1.23).
> Chia làm **2 bước** thay vì `renew all` một phát, để thu hẹp thiệt hại nếu file config
> vẫn không được kubeadm chấp nhận.

**2.1 — ⭐ Renew RIÊNG cert `apiserver` trước (cert duy nhất có SAN)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

> 🔴 Node 49/50 làm **sau**, khi node 48 đã verify xong.

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml
```

<details>
<summary>Giải nghĩa — vì sao tách riêng `apiserver`</summary>

```
kubeadm certs renew apiserver --config /root/cluster-config-renew.yaml
│                   │          └─ file đã tách + verify ở output 3.15
│                   └─ ⭐ CHỈ cert `apiserver`, KHÔNG phải `all`
└─ VÌ SAO CHIA 2 BƯỚC:
   `apiserver` là cert DUY NHẤT có certSANs. Các cert còn lại
   (apiserver-kubelet-client, front-proxy-client, cert trong admin.conf /
   controller-manager.conf / scheduler.conf) KHÔNG có SAN
   ⇒ chúng không chịu rủi ro "mất SAN do kubeadm rơi về default config"
   ⇒ Nếu bước này hỏng: chỉ 1 cert bị ghi đè thay vì 6 → rollback nhẹ hơn hẳn
   ⇒ Mất --dry-run (output 3.16) nên đây là cách thu hẹp rủi ro tốt nhất còn lại
```
</details>

**Output kỳ vọng:**

```
certificate for serving the Kubernetes API renewed

Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
```

> ## 🛑🛑 DỪNG NGAY TẠI ĐÂY — so SAN trước khi renew tiếp
>
> Chạy **GIAI ĐOẠN 3** (so SAN) **NGAY BÂY GIỜ**, trước khi chạy 2.2.
> Chỉ khi `diff` cho kết quả đúng mới quay lại chạy 2.2.
>
> **Lý do:** đây là lúc duy nhất biết được kubeadm có đọc `--config` hay không, mà mới chỉ
> 1 cert bị ảnh hưởng.

**2.2 — Renew các cert còn lại (CHỈ chạy sau khi GĐ3 PASS)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubeadm certs renew all --config /root/cluster-config-renew.yaml
```

<details>
<summary>Giải nghĩa lệnh — ⭐ LỆNH QUAN TRỌNG NHẤT CẢ QUY TRÌNH</summary>

```
kubeadm certs renew all --config /root/cluster-config-renew.yaml
│       │     │     │    │
│       │     │     │    └─ ⭐⭐ CỜ SỐNG CÒN + ⚠️ FILE ĐÃ TÁCH ở GĐ0-ter,
│       │     │     │       KHÔNG phải /etc/kubernetes/kubeadm-config.yaml gốc
│       │     │     │       (file gốc có 4 document, v1.23 parse không được — output 3.11)
│       │     │     └─ renew MỌI cert: apiserver, apiserver-kubelet-client,
│       │     │        front-proxy-client, + cert nhúng trong admin.conf /
│       │     │        controller-manager.conf / scheduler.conf
│       │     │        (KHÔNG có cert etcd vì cụm này dùng etcd external)
│       │     └─ ký lại bằng CA hiện có trong /etc/kubernetes/pki/ca.key
│       │        ⇒ CA KHÔNG đổi ⇒ kubelet worker KHÔNG cần join lại
│       └─ nhóm lệnh quản lý PKI
└─ Hạn mới = 1 năm KỂ TỪ LÚC CHẠY (không cộng dồn vào hạn cũ)

⭐⭐ VÌ SAO BẮT BUỘC --config, KHÔNG ĐƯỢC DÙNG LỆNH TRẦN:
   kubeadm đang KHÔNG đọc được ConfigMap kubeadm-config (API server chết vì cert hết
   hạn) → nó fallback về DEFAULT CONFIG. Default config KHÔNG biết:
     • lb-apiserver.kubernetes.local   ← endpoint MỌI node dùng
     • 10.208.137.68                   ← VIP
     • 172.16.128.1                    ← ClusterIP tuỳ biến
   Chạy `kubeadm certs renew all` TRẦN ⇒ cert mới THIẾU 3 entry trên ⇒ mọi kubectl/helm
   trên MỌI node báo `x509: certificate is valid for ..., not lb-apiserver.kubernetes.local`
   ⇒ CLUSTER HỎNG NẶNG HƠN TRƯỚC KHI SỬA, và cert cũ đã bị ghi đè.
```
</details>

**Output kỳ vọng** (chưa chạy — dán output thật vào mục 3 sau khi chạy):

```
certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
certificate the apiserver uses to access etcd renewed        ← có thể KHÔNG xuất hiện (etcd external)
certificate for the API server to connect to kubelet renewed
certificate embedded in the kubeconfig file for the controller manager to use renewed
certificate for the front proxy client renewed
certificate embedded in the kubeconfig file for the scheduler manager to use renewed

Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager,
kube-scheduler and etcd, so that they can use the new certificates.
```

> ⚠️ Dòng cuối chính là xác nhận: **renew KHÔNG tự restart**. Phải làm giai đoạn 3.

> ## 🛑 ĐIỂM DỪNG 1 — gửi output renew, chờ xác nhận
>
> Cert mới **đã ghi xuống đĩa**, nhưng static pod **vẫn đang dùng cert cũ trong bộ nhớ**.
> Đây là trạng thái **còn cứu được hoàn toàn** bằng restore backup.
>
> ⚠️ **Thứ tự đúng sau khi GĐ2 chia 2 bước (output 3.16):**
> `2.1 renew apiserver` → **GĐ3 so SAN** → nếu PASS → `2.2 renew all` → **GĐ3 lần 2** → GĐ4 restart.
> **Không** chạy 2.2 trước khi so SAN lần 1.

---

#### GIAI ĐOẠN 3 — ⭐ SO SÁNH SAN TRƯỚC/SAU (chốt chặn — DỪNG nếu không khớp)

> **Đây là bước quyết định an toàn của cả quy trình** — và sau output 3.16 (`--dry-run` không
> dùng được) nó là **PHÉP KIỂM DUY NHẤT** còn lại.
>
> ⚠️ **Chạy GĐ3 HAI LẦN:** lần 1 ngay sau `2.1 renew apiserver` (quan trọng nhất — lúc này mới
> 1 cert bị ghi đè), lần 2 sau `2.2 renew all` để xác nhận lần cuối.
>
> Làm bước này **TRƯỚC** khi restart.
> Cert mới đã ghi xuống đĩa nhưng static pod vẫn dùng cert cũ trong bộ nhớ → **vẫn còn cứu được**
> bằng cách restore backup. Restart rồi mới phát hiện sai thì cluster đã hỏng.

**3.1 — Chụp SAN của cert mới**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A3 'Alternative Name' > /root/san-sau-renew-48.txt
```

**3.2 — So sánh bằng máy, không so bằng mắt**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
diff /root/san-truoc-renew-48.txt /root/san-sau-renew-48.txt
```

<details>
<summary>Giải nghĩa lệnh + cách đọc kết quả</summary>

```
diff <file cũ> <file mới>
│    └─ THỨ TỰ QUAN TRỌNG: file cũ trước, file mới sau.
│       Đảo ngược thì dấu `<` và `>` đổi nghĩa, dễ đọc nhầm
└─ ĐỌC KẾT QUẢ:
   • KHÔNG IN GÌ (exit 0)  → ✅ SAN giống hệt nhau → AN TOÀN, sang giai đoạn 4
   • Dòng `>` có thêm `DNS:kubernetes.default.svc.vrp`
                           → ✅ CHẤP NHẬN ĐƯỢC. Đây là entry THÊM (đã dự đoán ở output 3.6),
                             không phải mất. Kubeadm áp certSANs từ file config
   • Dòng `<` có entry mà `>` KHÔNG có
                           → 🔴 DỪNG NGAY. Cert mới THIẾU SAN. KHÔNG restart.
                             Chuyển sang giai đoạn ROLLBACK
   ⭐ SOI KỸ 3 entry sống còn, cert mới BẮT BUỘC có đủ:
     • DNS:lb-apiserver.kubernetes.local
     • IP Address:10.208.137.68
     • IP Address:172.16.128.1
```
</details>

**3.3 — Kiểm hạn mới**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubeadm certs check-expiration
```

<details>
<summary>Cách đọc</summary>

```
Cột RESIDUAL TIME của mọi cert lá phải là 364d (hoặc ~1y), KHÔNG còn <invalid>.
Các dòng !MISSING! của etcd VẪN CÒN — đúng như cũ, vì etcd external (output 3.4).
Đây KHÔNG phải lỗi.
```
</details>

---

> ## 🛑🛑 ĐIỂM DỪNG 2 — QUAN TRỌNG NHẤT CẢ QUY TRÌNH
>
> Gửi output `diff` (bước 3.2) và `check-expiration` (bước 3.3), **chờ xác nhận rồi mới restart**.
>
> **Vì sao đây là điểm không thể quay lại:** restart xong, static pod nạp cert mới. Nếu cert
> thiếu SAN thì **mọi client trên mọi node** mất kết nối — và cert cũ đã bị ghi đè từ GĐ2.
> Lúc đó chỉ còn đường restore backup trong tình trạng cluster đang hỏng, khó hơn nhiều.
>
> ✅ `diff` không in gì, hoặc chỉ thêm `DNS:kubernetes.default.svc.vrp` → được phép restart
> 🔴 `diff` cho thấy **mất** entry → **KHÔNG restart**, chuyển sang ROLLBACK

---

#### GIAI ĐOẠN 4 — Restart control-plane (chỉ khi giai đoạn 3 PASS)

**4.1 — Tái tạo static pod bằng cách di chuyển manifest**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
mv /etc/kubernetes/manifests /etc/kubernetes/manifests.off
```

<details>
<summary>Giải nghĩa — vì sao dùng cách này thay vì restart kubelet</summary>

```
mv /etc/kubernetes/manifests /etc/kubernetes/manifests.off
│  └─ kubelet WATCH thư mục này liên tục. Đổi tên = với kubelet là "manifest biến mất"
│     → kubelet XOÁ 3 static pod (apiserver, controller-manager, scheduler)
└─ ⭐ VÌ SAO KHÔNG DÙNG `systemctl restart kubelet`:
     • restart kubelet ảnh hưởng MỌI pod trên node, mất ~30-60s
     • cách này chỉ tái tạo đúng 3 static pod control-plane — phạm vi hẹp hơn, nhanh hơn
     • với etcd external thì càng an toàn: không có etcd static pod để lo
   ⚠️ KHÔNG làm đứt SSH — SSH không đi qua apiserver
```
</details>

Chờ ~20 giây rồi kiểm tra pod đã bị xoá:

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
crictl ps | grep -E 'apiserver|scheduler|controller'
```

<details>
<summary>Giải nghĩa</summary>

```
crictl ps | grep -E 'apiserver|scheduler|controller'
│      │    │    └─ -E: regex mở rộng, `|` là OR
│      │    └─ lọc 3 container control-plane
│      └─ ps (KHÔNG có -a): chỉ container ĐANG CHẠY
└─ KỲ VỌNG: output RỖNG = 3 pod đã bị xoá hết = kubelet đã nhận biết
   Còn container → chờ thêm 10-20s rồi chạy lại. KHÔNG sang bước sau khi chưa rỗng
Lỗi "connect endpoint": thêm -r unix:///run/containerd/containerd.sock
```
</details>

**4.2 — Đưa manifest trở lại**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
mv /etc/kubernetes/manifests.off /etc/kubernetes/manifests
```

<details>
<summary>Giải nghĩa</summary>

```
mv /etc/kubernetes/manifests.off /etc/kubernetes/manifests
└─ kubelet phát hiện manifest xuất hiện → tạo lại 3 static pod,
   lần này ĐỌC CERT MỚI từ hostPath /etc/kubernetes/pki
⚠️ Nếu quên bước này, control-plane node 48 sẽ không bao giờ chạy lại
```
</details>

Chờ ~30-60 giây cho pod khởi động:

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
crictl ps | grep -E 'apiserver|scheduler|controller'
```

<details>
<summary>Cách đọc</summary>

```
KỲ VỌNG: 3 container, cột STATE = Running, cột ATTEMPT thấp (0 hoặc 1)
• ATTEMPT tăng dần → crashloop → xem log ngay:
    crictl logs $(crictl ps -a --name kube-apiserver -q | head -1)
• Chưa thấy container → chờ thêm, apiserver khởi động chậm hơn 2 cái kia
```
</details>

---

#### GIAI ĐOẠN 5 — Verify node 48 (bắt buộc PASS mới sang node 49)

**5.1 — Cập nhật kubeconfig (cert cũ trong `~/.kube/config` đã hết hạn)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
cp /etc/kubernetes/admin.conf /root/.kube/config
```

<details>
<summary>Giải nghĩa — vì sao phải làm bước này</summary>

```
cp /etc/kubernetes/admin.conf /root/.kube/config
│  │                          └─ nơi kubectl tìm khi chạy dưới root
│  └─ file này VỪA ĐƯỢC RENEW GHI ĐÈ ở giai đoạn 2 (cert nhúng base64 bên trong)
└─ ⭐ Đây chính là issue #2 trong bảng tổng quan. Trước renew thì copy VÔ ÍCH vì
   admin.conf cũng đã hết hạn (output 3.2 có dòng `admin.conf ... <invalid>`)
Nếu /root/.kube/ chưa tồn tại: mkdir -p /root/.kube
```
</details>

**5.2 — Kiểm tra cluster trả lời**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubectl get nodes
```

<details>
<summary>Cách đọc</summary>

```
KỲ VỌNG: bảng 8 node (3 master + 5 worker), STATUS = Ready
• Vẫn `x509: certificate has expired` → kubeconfig chưa cập nhật (làm lại 5.1)
• `Unable to connect ... connection refused` → apiserver chưa lên, chờ thêm
• Một số node NotReady → BÌNH THƯỜNG ở giai đoạn này nếu đó là 49/50 (chưa renew).
  Ghi lại node nào NotReady để đối chiếu sau khi làm xong cả 3
```
</details>

**5.3 — Kiểm tra control-plane pod**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubectl -n kube-system get pods -l tier=control-plane -o wide
```

<details>
<summary>Giải nghĩa</summary>

```
kubectl -n kube-system get pods -l tier=control-plane -o wide
│        │              │        │                     └─ -o wide: hiện thêm cột NODE
│        │              │        │                        → biết pod nào của node nào
│        │              │        └─ -l: lọc theo label. kubeadm gắn sẵn tier=control-plane
│        │              │           cho 3 static pod
│        │              └─ resource cần xem
│        └─ namespace của thành phần hệ thống
└─ KỲ VỌNG: pod của node 48 có AGE vài phút (vừa restart), READY 1/1, RESTARTS 0
   Pod của 49/50 vẫn AGE cũ (chưa restart) — đúng, chưa tới lượt
```
</details>

**5.4 — Kiểm tra qua chính endpoint LB (quan trọng nhất)**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
curl -sS --cacert /etc/kubernetes/pki/ca.crt https://lb-apiserver.kubernetes.local:6443/version
```

<details>
<summary>Giải nghĩa — vì sao bước này quý hơn kubectl</summary>

```
curl -sS --cacert /etc/kubernetes/pki/ca.crt https://lb-apiserver.kubernetes.local:6443/version
     ││   │                                   │
     ││   │                                   └─ ⭐ gọi qua ĐÚNG endpoint mọi client dùng,
     ││   │                                      qua VIP .68 — thứ đã làm helm chết ban đầu
     ││   └─ --cacert: dùng CA của cluster để verify cert server.
     ││      KHÔNG dùng -k (bỏ qua verify) — vì mục đích chính LÀ verify cert!
     │└─ S: vẫn hiện lỗi khi có (nếu chỉ -s thì lỗi bị nuốt luôn)
     └─ s: tắt thanh tiến trình cho gọn output
└─ ⭐ VÌ SAO QUÝ HƠN `kubectl get nodes`: kubectl có thể đi đường khác tuỳ kubeconfig.
   Lệnh này kiểm ĐÚNG đường mà helm/kubectl trên worker đi → chứng minh SAN mới hợp lệ
   cho tên lb-apiserver.kubernetes.local
   KỲ VỌNG: JSON {"major":"1","minor":"xx",...}
   • `certificate is valid for ..., not lb-apiserver.kubernetes.local` → 🔴 cert thiếu SAN,
     ROLLBACK ngay
```
</details>

> ## 🛑 ĐIỂM DỪNG 3 — gửi output verify node 48, chờ xác nhận
>
> **Chỉ khi 5.1→5.4 đều PASS mới sang node 49.** Node 48 chưa xanh mà đã đụng vào 49
> = hỏng 2 node cùng lúc, cluster chỉ còn 1 master.
>
> Sau khi xác nhận: lặp lại GIAI ĐOẠN 2→5 trên node 49 (đổi hậu tố file thành `-49`),
> rồi node 50. **Với 49/50 chỉ cần gửi output nào KHÁC node 48** — giống hệt thì báo một dòng.

---

#### GIAI ĐOẠN 6 — Sau khi xong cả 3 node

**6.1 — Kiểm tra toàn cụm**

📍 **Node 48** (`vrp-kubeengine01`) — user **`root`**

```
kubectl get nodes -o wide
```

**6.2 — Kiểm cert kubelet trên 5 worker `137.51 → .55`**

📍 **Từng worker `10.208.137.51` → `.55`** (`vrp-kubeengine04` …) — user **`root`**

```
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
```

<details>
<summary>Giải nghĩa</summary>

```
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
│                │                     └─ symlink trỏ tới cert kubelet ĐANG dùng.
│                │                        Hậu tố -current do cơ chế rotate: kubelet sinh
│                │                        file mới rồi đổi symlink, giữ file cũ lại
│                └─ PKI RIÊNG của kubelet, khác /etc/kubernetes/pki của control-plane
└─ -dates: chỉ in notBefore/notAfter, không cần -text
   • Còn hạn → kubelet đã tự rotate (rotateCertificates mặc định true) ✔
   • Hết hạn → worker tắt lâu ngày, bỏ lỡ cửa sổ rotate → phải kubeadm join lại
```
</details>

**6.3 — Chạy lại việc gốc: upgrade RAGFlow (issue #6)**

📍 **Worker `vrp-kubeengine04`** — user **`app`** ⚠️ **KHÁC user `root` của mọi lệnh trên**

> Đây là node/user đã phát hiện sự cố ban đầu (output 3.0) — chạy lại đúng chỗ đó để xác nhận đã khỏi.

```
helm upgrade ragflow . -n ragflow -f values.yaml
```

**6.4 — Dọn backup sau khi cluster ổn định vài ngày**

> ⚠️ **KHÔNG xoá ngay.** Giữ ít nhất 1 tuần — cert mới có thể lộ vấn đề sau vài ngày.

---

#### 🔴 ROLLBACK — khi giai đoạn 3 phát hiện SAN thiếu, hoặc pod crashloop

> Chỉ dùng khi **chưa restart** (giai đoạn 3 fail) hoặc **đã restart nhưng hỏng** (giai đoạn 4/5 fail).

**R1 — Nếu CHƯA restart (dễ):**

📍 **Node đang gặp sự cố** — user **`root`**

```
tar xzf /root/pki-backup-$(hostname)-2026-08-19-1118.tar.gz -C /
```

<details>
<summary>Giải nghĩa</summary>

```
tar xzf <file> -C /
│   ││└─ f: đọc từ file
│   │└─ z: giải nén gzip
│   └─ x: EXTRACT (khác `t` là liệt kê, `c` là tạo)
└─ -C /: giải nén tương đối với thư mục gốc `/`.
   Archive lưu đường dẫn dạng `etc/kubernetes/pki/...` (không có `/` đầu) nên cần -C /
   để file về đúng /etc/kubernetes/pki/
⚠️ TIMESTAMP PHẢI LÀ `-1118` — đây là bản backup ĐÚNG (18 mục, 22K, output 3.20/3.21).
   TUYỆT ĐỐI KHÔNG dùng bản `-1107/-1108/-1109` (11K): chúng KHÔNG chứa cert nào
   (output 3.19), restore bằng chúng sẽ không khôi phục được gì
Vì chưa restart, static pod vẫn dùng cert cũ trong bộ nhớ ⇒ restore xong là như chưa có gì
```
</details>

**R2 — Nếu ĐÃ restart và hỏng:** restore như R1, rồi làm lại giai đoạn 4 (di chuyển manifest)
để static pod nạp lại cert cũ.

**R3 — Nếu node 48 hỏng hẳn:** cluster vẫn còn 49/50 phục vụ qua VIP. Không hoảng —
dừng lại, báo cáo, xử lý node 48 riêng. **Tuyệt đối không** tiếp tục làm 49/50 khi 48 đang hỏng.

### Dài hạn — chống tái diễn (issue #5, nợ kỹ thuật)

- [ ] Dựng `x509-certificate-exporter` (enix) — scrape file PKI trên node, cho metric `x509_cert_not_after`
- [ ] Alert rule: `(x509_cert_not_after - time()) / 86400 < 30` → cảnh báo trước 30 ngày
- [ ] Lịch renew định kỳ 6 tháng/lần trong cửa sổ bảo trì, thay vì đợi hết hạn
- [ ] **Ghi lại `certSANs` và topology cluster vào tài liệu** — gỡ vòng lặp chết ở mục 6
- [ ] Đánh giá `--cert-validity-period` (kubeadm ≥1.31) cho cluster dựng mới

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| ⭐ **Cert mới mất SAN `lb-apiserver.kubernetes.local`** → toàn cụm hỏng nặng hơn hiện tại | 🟠 **Hạ từ 🔴 — đã có cách gỡ** | ✅ Output 3.6: `kubeadm-config.yaml` còn khớp ⇒ renew **kèm `--config /etc/kubernetes/kubeadm-config.yaml`**. Vẫn so SAN trước/sau, chỉ restart khi khớp |
| LB ngoài `.68` có thể không health-check → trong lúc restart master, ~1/3 request bị đẩy vào node đang khởi động lại | 🟡 **TB (hạ từ 🟠)** | **Không tự kiểm được** (thiết bị đội khác). Giảm thiểu: thao tác trong cửa sổ bảo trì; restart từng node và **chờ node đó Ready hẳn** trước khi sang node kế |
| ~~`.68` là keepalived VIP nổi trên master → VIP nhảy khi restart~~ | ⚪ **Đã loại bỏ** | Output 3.8: rỗng trên cả 3 master ⇒ VIP **ngoài cụm**, restart master không đụng tới VIP |
| **5 worker `.51-.55` chưa được kiểm tra** — kubelet client cert có thể cũng hết hạn | 🟡 TB | Sau khi control-plane xanh, kiểm `kubelet-client-current.pem` trên từng worker |
| ~~Là stacked etcd nhưng PKI mất thật~~ | ⚪ **Đã loại bỏ** | Output 3.4: **etcd external**, không có `etcd.yaml` |
| ~~`kubeadm-config.yaml` (2023) lỗi thời~~ | ⚪ **Đã loại bỏ** | Output 3.6: `certSANs` khớp khít cert đang chạy |
| ~~`diff` SAN ở GĐ3 so nhầm file do `certificatesDir` khác~~ | ⚪ **Đã loại bỏ** | Output 3.13: `pki` → symlink → `ssl`. Mọi đường dẫn trong quy trình đọc đúng file |
| Cert cụm **etcd external** (`/etc/ssl/etcd/ssl/`) chưa kiểm hạn — sự cố riêng biệt | 🟡 TB | Kiểm sau khi khôi phục control-plane. Không do `kubeadm certs renew` quản |
| ~~Restart nhiều master cùng lúc → mất quorum etcd~~ | 🟢 **Hạ từ 🔴** | etcd **external** (output 3.4) ⇒ không có quorum trên master để mất. Vẫn giữ tuần tự 48→49→50 để còn đường rollback nếu cert mới sai SAN |
| Node 49/50 có thể có tình trạng cert khác 48 (chưa kiểm tra) | 🟡 TB | Chạy `check-expiration` độc lập trên từng node trước khi thao tác |
| ~~Registry nội bộ không truy cập được khi restart~~ | ⚪ **Đã loại bỏ (node 48)** | ✅ Output 3.11: image `kube-apiserver:v1.23.2` **có trong cache cục bộ** ⇒ kubelet không cần gọi registry. ⚠️ Nên kiểm lại tương tự trên 49/50 |
| 🔴 **`--config` trỏ file gốc 4-document → kubeadm v1.23 rơi về default → cert mất SAN → toàn cụm hỏng** | 🔴 **Cao — đã xác nhận** | ✅ Output 3.11. Gỡ bằng GĐ0-ter (tách file). ⚠️ Nguy hiểm vì kubeadm có thể **im lặng** bỏ qua, vẫn báo "renewed" — chỉ `diff` SAN ở GĐ3 mới lộ ra |
| ~~Backup GĐ1 lần 1 (11:07-11:09) không chứa cert~~ | ⚪ **ĐÃ XỬ LÝ** | ✅ Output 3.20+3.21: backup lại bằng `tar czhf ... /etc/kubernetes/ssl` — cả 3 node đạt **18 mục, 22K**, đủ `apiserver.crt`/`ca.crt`/`ca.key`. Bản `-1107/08/09` (11K) giữ lại nhưng **không dùng để rollback** |
| Không có snapshot etcd gần đây để rollback nếu hỏng | 🟡 **Hạ từ 🔴** | etcd external ⇒ việc renew cert control-plane **không đụng tới dữ liệu etcd**. Backup PKI (mục Ngắn hạn) mới là bản lùi cần thiết |
| Gián đoạn API server lúc restart static pod | 🟡 TB | Thực hiện trong cửa sổ bảo trì đã thống nhất với quản lý |
| Worker node tắt lâu ngày, kubelet cert hết hạn không tự rotate được | 🟢 Thấp | Kiểm tra sau khi control-plane khôi phục; node nào hỏng thì join lại |

---

## Phụ lục — Nguồn dữ liệu

| Mục | Nguồn | Độ tin cậy |
|---|---|---|
| Output 3.0 | Screenshot terminal worker `vrp-kubeengine04`, 2026-08-19 ~08:49 +07 | ✅ Trực tiếp |
| Output 3.1, 3.2 | Screenshot terminal master 48, phiên 2026-08-19 | ✅ Trực tiếp |
| Master `137.48/49/50` + worker `137.51-55` | Kiên xác nhận trong phiên | ✅ Trực tiếp |
| Trình tự sự cố (helm → phát hiện cert → sang master) | Kiên kể lại trong phiên | ✅ Trực tiếp |
| ~~10.208.216.4 là VIP của cluster~~ | ~~Suy đoán từ tab SSH~~ | ❌ **SAI — đã bác bỏ**, thuộc cụm khác (Kiên đính chính). Xem Bài học #6 |
| Endpoint `lb-apiserver.kubernetes.local:6443` | Thông báo lỗi TLS của helm + kubectl | ✅ **Trực tiếp** |
| Cluster dựng bằng Kubespray | Suy luận từ tên endpoint mặc định | ❓ **Chưa xác minh** — chờ lệnh 4.6 |
| Cơ chế LB (cục bộ mỗi node vs tập trung) | Chưa có dữ liệu | ❓ **Chưa xác minh** — chờ lệnh 4.5 |
| Kiến trúc etcd external | Suy luận gián tiếp từ `!MISSING!` + cluster còn sống tới 18/08 | ❓ **Chưa xác minh** |
| Hạn cert kubeadm mặc định 1 năm | Kiến thức chung về kubeadm | ✅ Ổn định qua các version |
