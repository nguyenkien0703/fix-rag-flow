# TRACKING — Cert K8s control-plane hết hạn

> File sống. Cập nhật ngay sau mỗi lệnh chạy, không đợi cuối phiên.
> Bắt đầu: 2026-08-19. Trạng thái tổng: 🔶 **OPEN — chưa thao tác sửa, mới chẩn đoán.**

---

## 1. Mục tiêu

Gia hạn cert control-plane Kubernetes đã hết hạn để khôi phục truy cập `kubectl` và đảm bảo
cluster HA hoạt động ổn định, **không làm mất quorum etcd và không làm hỏng HA qua VIP**.

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
| Công cụ dựng cluster | ❓ **nghi Kubespray** — `lb-apiserver.kubernetes.local` là tên mặc định của Kubespray. Bên dưới vẫn là kubeadm | Suy luận từ tên endpoint — **chưa xác minh** |
| Công cụ quản trị cert | `kubeadm` (lệnh `certs check-expiration` chạy được) | Output 3.2 |
| ✅ **Kiến trúc etcd** | **EXTERNAL** — không có `etcd.yaml` trong manifests | ✅ Output 3.4 |
| Ngày dựng cluster | **06/07/2023** (mtime `kubeadm-config.yaml`) | ✅ Output 3.3 |
| Lần sửa apiserver gần nhất | **18/09/2024** — ❓ ai sửa, sửa gì chưa rõ | ✅ Output 3.4 (mtime) |
| Service CIDR | `172.16.128.0/x` (ClusterIP svc kubernetes = `172.16.128.1`) — **tùy biến**, không phải mặc định | ✅ Output 3.5 |
| ⚠️ IP lạ trong SAN | **`10.208.137.68`** — không thuộc master 48-50 lẫn worker 51-55 | ✅ Output 3.5 — ❓ vai trò chưa rõ |
| Người dựng cụm | ❓ **Không phải Kiên** (nhân viên mới, phụ trách deploy service). Cần hỏi sếp nếu cần | Kiên xác nhận |
| Ứng dụng bị ảnh hưởng | RAGFlow `v0.26.4`, namespace `ragflow`, deploy bằng Helm | Output 3.0 |
| User thao tác | worker: `app` / master: `vt_admin` → `su` sang `root` | Screenshot |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Cert lá control-plane hết hạn 18/08/2026 | 🔴 Cao | 🔶 **OPEN** | `kubeadm certs renew` bằng CA còn hạn → restart static pod. Lần lượt 48→49→50 |
| 2 | `kubectl` không chạy được dưới user `root` (thiếu kubeconfig) | 🟡 TB | 🔶 **OPEN** | Copy `admin.conf` → `~/.kube/config` **sau khi** renew xong |
| 3 | ~~Toàn bộ PKI etcd báo `!MISSING!`~~ | ⚪ Không phải issue | ✅ **ĐÓNG** | Output 3.4: không có `etcd.yaml` ⇒ **etcd external** ⇒ `!MISSING!` chỉ là cosmetic |
| 4 | `kubeadm` fallback default config → **cert mới có thể mất SAN `lb-apiserver.kubernetes.local`** | 🔴 **Cao (nâng từ 🟠)** | 🔶 **OPEN** | Đã xác định cụ thể nhờ output 3.0. **BẮT BUỘC** renew kèm `--config`, cấm dùng lệnh trần |
| 5 | Không có cảnh báo trước khi cert hết hạn | 🟡 TB | 🔶 **OPEN** | Dựng `x509-certificate-exporter` + alert trước 30 ngày |
| 6 | RAGFlow `v0.26.4` chưa upgrade được (việc gốc ban đầu) | 🟢 Thấp | 🔶 **OPEN** — bị chặn bởi #1 | Chạy lại `helm upgrade` sau khi cluster khôi phục |
| 7 | `kubeadm-config.yaml` (2023) có thể lỗi thời so với apiserver manifest (2024) | 🟠 Cao | 🔶 **OPEN** | So `certSANs` trong file với SAN thật ở output 3.5 trước khi dùng renew |

---

## 3. Lệnh đã chạy

> ⚠️ Chỉ ghi lệnh **đã có output thật**. Lệnh chưa chạy nằm ở mục 7.
> Đánh số theo **thứ tự thời gian thực tế**: 3.0 xảy ra trước 3.1.

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
- Tên `lb-apiserver.kubernetes.local` là **giá trị mặc định của Kubespray**. Kubespray dựng HA
  bằng nginx/HAProxy chạy cục bộ trên **mỗi** node, listen `127.0.0.1:6443` rồi map hostname này
  vào `/etc/hosts` từng node → mỗi node tự LB sang 3 master, **không dùng VIP dùng chung**.
  ❓ chưa xác minh, nhưng khớp với việc `kubeadm` vẫn dùng được (Kubespray dùng kubeadm làm engine).
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
| IP loopback | `127.0.0.1` | Khớp cơ chế LB cục bộ |
| ⚠️ IP lạ | **`10.208.137.68`** | **Không thuộc master 48-50, cũng không thuộc worker 51-55** |

**Đọc được gì:**

- ✅ **Xác nhận `lb-apiserver.kubernetes.local` có trong SAN** — khớp hoàn toàn với output 3.0.
  Rủi ro ở issue #4 là **thật**: renew trần sẽ làm mất entry này.
- ✅ **Xác nhận cơ chế LB cục bộ**: SAN có cả `127.0.0.1` **và** đủ 3 IP master. Đây là chữ ký của
  kiểu "nginx cục bộ trên mỗi node proxy sang 3 master" — client nối `127.0.0.1:6443`, nginx
  chuyển tiếp tới một trong 3 IP master, cert phải hợp lệ cho **cả hai đầu**.
- ⚠️ **`10.208.137.68` — chưa rõ là gì.** Ba khả năng: (a) VIP keepalived, (b) node cũ đã gỡ,
  (c) IP dự phòng khai sẵn lúc dựng. ❓ **chưa xác minh**.
  ⇒ **Không cần biết nó là gì để renew** — chỉ cần **giữ nguyên** trong cert mới.
- Service CIDR `172.16.128.0/x` là **tùy biến**, không phải mặc định của kubeadm lẫn Kubespray.
  ⇒ Cluster này có cấu hình riêng ⇒ **càng khẳng định không được renew bằng default config.**
- ⇒ **Loại trừ được:** cert hiện tại **không hỏng về nội dung** — SAN đầy đủ, thuật toán
  `sha256WithRSAEncryption` bình thường. Vấn đề **duy nhất** là hết hạn.

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
   | SAN có **cả** `127.0.0.1` **và** đủ 3 IP master | Kiểu **localhost-LB**: nginx cục bộ mỗi node → 3 master. Không dùng VIP dùng chung | 🟠 Mạnh |
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

### Bước kế tiếp — đối chiếu config trước khi renew (vẫn chỉ đọc, chạy trên 48)

- [ ] **A1** — ⭐ Đọc `certSANs` trong file config, so với SAN thật ở output 3.5

  ```
  grep -A30 'certSANs' /etc/kubernetes/kubeadm-config.yaml
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  grep -A30 'certSANs' /etc/kubernetes/kubeadm-config.yaml
  │    │      │         └─ file Kubespray ghi ra khi dựng cluster (06/07/2023)
  │    │      └─ khoá YAML chứa danh sách SAN bổ sung cho cert apiserver
  │    └─ -A30: in 30 dòng SAU dòng khớp. Chọn 30 vì SAN dạng YAML mỗi entry MỘT dòng
  │       (`- ten`), 18 entry + lề an toàn. Dùng -A2 như lệnh openssl sẽ CẮT MẤT danh sách
  └─ ⭐ VIỆC PHẢI LÀM: đối chiếu từng dòng với 18 entry ở output 3.5.
     • Khớp đủ 18       → dùng --config file này để renew, AN TOÀN
     • THIẾU entry nào  → file 2023 đã lỗi thời (khớp nghi vấn mtime 2024)
                          → PHẢI tự soạn file config mới, bổ sung entry thiếu
     ⚠️ Chú ý riêng 10.208.137.68 — nếu file config KHÔNG có IP này thì gần như
        chắc chắn nó được thêm vào lần sửa 09/2024
  ```
  </details>

- [ ] **A2** — Xem toàn bộ cấu hình cluster để soạn file renew cho đúng

  ```
  cat /etc/kubernetes/kubeadm-config.yaml
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  cat /etc/kubernetes/kubeadm-config.yaml
  │   └─ file chỉ 4463 bytes (~120 dòng) — đủ ngắn để đọc hết một lần,
  │      không cần phân trang
  └─ CẦN SOI các khoá:
     • kind: ClusterConfiguration     → phần kubeadm dùng khi renew
     • controlPlaneEndpoint           → phải là lb-apiserver.kubernetes.local:6443
     • apiServer.certSANs             → danh sách SAN (đối chiếu A1)
     • etcd.external.endpoints        → xác nhận cụm etcd ngoài nằm ở đâu
     • networking.serviceSubnet       → phải khớp 172.16.128.0/x (từ output 3.5)
     • kubernetesVersion              → phải khớp version đang chạy, LỆCH LÀ NGUY HIỂM
  ```
  </details>

- [ ] **A3** — Xác nhận version kubeadm khớp version cluster

  ```
  kubeadm version -o short
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  kubeadm version -o short
  │               │  └─ chỉ in chuỗi version (vd v1.28.5) thay vì khối JSON dài
  │               └─ -o: định dạng output. Bỏ cờ này sẽ ra JSON nhiều dòng
  └─ ⚠️ VÌ SAO QUAN TRỌNG: kubeadm renew sinh cert theo logic của CHÍNH version nó.
     Nếu binary kubeadm trên node đã được nâng cấp mà cluster vẫn chạy version cũ
     (hoặc ngược lại), cert sinh ra có thể khác kỳ vọng.
     Đối chiếu với `kubernetesVersion` trong file config (A2) và với image tag
     trong /etc/kubernetes/manifests/kube-apiserver.yaml
  ```
  </details>

- [ ] **A4** — Xác nhận cơ chế LB cục bộ (giải thích vì sao restart tuần tự là an toàn)

  ```
  grep lb-apiserver /etc/hosts
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  grep lb-apiserver /etc/hosts
  │                  └─ file map hostname → IP ở tầng OS, được tra TRƯỚC DNS
  └─ ĐỌC KẾT QUẢ:
     • "127.0.0.1 lb-apiserver.kubernetes.local"
       ⇒ XÁC NHẬN nginx/haproxy cục bộ trên chính node này, upstream 3 master.
         Hệ quả: restart master 48 KHÔNG làm client trên node khác mất kết nối —
         LB cục bộ của node đó tự chuyển sang 49/50. Rất thuận lợi cho renew tuần tự
     • trỏ tới IP thật (vd 10.208.137.68)
       ⇒ LB tập trung → restart master phải kiểm health-check LB có loại node ra không
  ```
  </details>

- [ ] **A5** — Làm rõ `10.208.137.68` là gì (không chặn renew, nhưng nên biết)

  ```
  ping -c 2 10.208.137.68
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  ping -c 2 10.208.137.68
  │    │  └─ gửi đúng 2 gói rồi dừng. KHÔNG có -c thì ping chạy vô hạn,
  │    │     phải Ctrl-C — bất tiện khi thao tác qua VDI
  │    └─ -c: count
  └─ ĐỌC KẾT QUẢ:
     • Có phản hồi  → IP đang sống, nhiều khả năng là VIP hoặc node còn hoạt động
     • Không phản hồi → node cũ đã gỡ, hoặc IP dự phòng chưa dùng
     ⚠️ DÙ KẾT QUẢ THẾ NÀO: cert mới VẪN PHẢI GIỮ IP này trong SAN.
        Xoá đi là thay đổi hành vi cluster, ngoài phạm vi việc gia hạn cert
  ```
  </details>

### Cần hỏi người khác (không tự tra được — Kiên không phải người dựng cụm)

> Tách riêng vì đây là **"bị chặn bởi thông tin"**, khác hẳn "chưa biết cách làm".
> Không có câu trả lời vẫn renew được, nhưng có thì an toàn hơn hẳn.

- [ ] **Repo Kubespray / Ansible inventory của cụm này ở đâu?**
      → chứa `certSANs` gốc (biến `supplementary_addresses_in_ssl_keys`), là nguồn đáng tin nhất
- [ ] **Ai sửa `/etc/kubernetes/manifests/kube-apiserver.yaml` ngày 18/09/2024, sửa gì?**
      → quyết định `kubeadm-config.yaml` (2023) còn dùng được không
- [ ] **`10.208.137.68` là gì?** VIP, node đã gỡ, hay IP dự phòng?
- [ ] **Có ai từng renew cert cụm này chưa?** Nếu có, làm bằng cách nào (kubeadm hay playbook Kubespray)
- [ ] **Cửa sổ bảo trì** để thao tác — có gián đoạn ngắn API server khi restart

### Ngắn hạn — thao tác sửa (⚠️ chỉ chạy sau khi 4.1–4.5 xác nhận an toàn)

- [ ] Backup PKI + kubeconfig trên **cả 3 node**, trước khi động vào bất cứ node nào
- [ ] Renew trên **48** → so sánh SAN mới với SAN đã chụp ở 4.3 → restart control-plane → verify
- [ ] Chỉ khi 48 xanh hoàn toàn: lặp lại cho **49**
- [ ] Chỉ khi 49 xanh hoàn toàn: lặp lại cho **50**
- [ ] Copy `admin.conf` → `~/.kube/config` cho user vận hành (issue #2)
- [ ] Kiểm tra kubelet client cert trên **5 worker `137.51 → .55`**:

  ```
  openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
  │                │                     └─ symlink trỏ tới cert kubelet ĐANG dùng.
  │                │                        Hậu tố -current là do cơ chế rotate: kubelet
  │                │                        sinh file mới rồi đổi symlink, giữ file cũ lại
  │                └─ PKI riêng của kubelet, KHÁC /etc/kubernetes/pki của control-plane
  └─ -dates: in notBefore/notAfter. KHÔNG cần -text vì chỉ quan tâm hạn
     ĐỌC KẾT QUẢ:
     • notAfter còn hạn → kubelet đã tự rotate (rotateCertificates: true mặc định) ✔
     • notAfter đã qua  → worker này tắt lâu ngày, bỏ lỡ cửa sổ rotate → phải join lại
  ```
  </details>

  > Kubelet **tự rotate** cert client nên bình thường không cần can thiệp. Rủi ro chỉ xảy ra với
  > worker tắt/mất mạng dài ngày — bỏ lỡ cửa sổ rotate thì cert chết hẳn, phải `kubeadm join` lại.

> ⚠️ **Ràng buộc tuyệt đối:** không renew/restart 2 node cùng lúc. Nếu là stacked etcd, mất quorum
> 2/3 = cluster chết hẳn, phải restore từ snapshot. Nếu external etcd thì rủi ro thấp hơn nhưng
> vẫn giữ nguyên tắc tuần tự để còn đường rollback khi cert mới sai SAN.

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
| ⭐ **Cert mới mất SAN `lb-apiserver.kubernetes.local`** → **toàn cụm** hỏng nặng hơn hiện tại, không còn cert cũ để lùi | 🔴 **Cao — đã xác nhận, không còn là giả định** | Chụp SAN cũ (4.3) → tìm `kubeadm-config.yaml` trên đĩa (4.6) → renew **kèm `--config`** → so SAN trước/sau → chỉ restart khi SAN khớp |
| **5 worker `.51-.55` chưa được kiểm tra** — kubelet client cert có thể cũng hết hạn | 🟡 TB | Sau khi control-plane xanh, kiểm `kubelet-client-current.pem` trên từng worker |
| ~~Là stacked etcd nhưng PKI mất thật~~ | ⚪ **Đã loại bỏ** | Output 3.4 xác nhận **etcd external**, không có `etcd.yaml`. Rủi ro này không tồn tại |
| `kubeadm-config.yaml` (2023) lỗi thời so với apiserver manifest (2024) → renew bằng nó vẫn thiếu SAN | 🟠 Cao | Đối chiếu `certSANs` trong file với 18 entry ở output 3.5 (lệnh A1) **trước khi** dùng |
| Cert của cụm **etcd external** cũng có thể sắp/đã hết hạn — sự cố riêng biệt chưa kiểm tra | 🟡 TB | Sau khi khôi phục control-plane, xác định endpoint etcd và kiểm hạn cert phía đó |
| ~~Restart nhiều master cùng lúc → mất quorum etcd~~ | 🟢 **Hạ từ 🔴** | etcd **external** (output 3.4) ⇒ không có quorum trên master để mất. Vẫn giữ tuần tự 48→49→50 để còn đường rollback nếu cert mới sai SAN |
| Node 49/50 có thể có tình trạng cert khác 48 (chưa kiểm tra) | 🟡 TB | Chạy `check-expiration` độc lập trên từng node trước khi thao tác |
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
