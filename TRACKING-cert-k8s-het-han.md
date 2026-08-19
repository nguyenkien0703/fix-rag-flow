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
| Kiến trúc etcd | ❓ **chưa xác minh** — nghi external etcd | Suy luận từ `!MISSING!`, chưa có bằng chứng trực tiếp |
| Ứng dụng bị ảnh hưởng | RAGFlow `v0.26.4`, namespace `ragflow`, deploy bằng Helm | Output 3.0 |
| User thao tác | worker: `app` / master: `vt_admin` → `su` sang `root` | Screenshot |

---

## 2. Tổng quan issue

| # | Issue | Mức độ | Trạng thái | Hướng xử lý |
|---|---|---|---|---|
| 1 | Cert lá control-plane hết hạn 18/08/2026 | 🔴 Cao | 🔶 **OPEN** | `kubeadm certs renew` bằng CA còn hạn → restart static pod. Lần lượt 48→49→50 |
| 2 | `kubectl` không chạy được dưới user `root` (thiếu kubeconfig) | 🟡 TB | 🔶 **OPEN** | Copy `admin.conf` → `~/.kube/config` **sau khi** renew xong |
| 3 | Toàn bộ PKI etcd báo `!MISSING!` | 🔴 Cao | 🔶 **OPEN** — chưa rõ có phải issue thật | Xác minh external vs stacked etcd (lệnh 4.1). Nếu stacked → escalate, nặng hơn issue #1 |
| 4 | `kubeadm` fallback default config → **cert mới có thể mất SAN `lb-apiserver.kubernetes.local`** | 🔴 **Cao (nâng từ 🟠)** | 🔶 **OPEN** | Đã xác định cụ thể nhờ output 3.0. **BẮT BUỘC** renew kèm `--config`, cấm dùng lệnh trần |
| 5 | Không có cảnh báo trước khi cert hết hạn | 🟡 TB | 🔶 **OPEN** | Dựng `x509-certificate-exporter` + alert trước 30 ngày |
| 6 | RAGFlow `v0.26.4` chưa upgrade được (việc gốc ban đầu) | 🟢 Thấp | 🔶 **OPEN** — bị chặn bởi #1 | Chạy lại `helm upgrade` sau khi cluster khôi phục |

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

⇒ ❓ **chưa xác minh** — lập luận trên là **gián tiếp**, chưa có bằng chứng trực tiếp.
Bắt buộc chạy lệnh 4.1 + 4.2 để xác nhận **trước khi** renew.

**Bị chặn bởi:** không phải "chưa biết cách fix" — chỉ là **chưa chạy lệnh xác minh**.

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

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| Không có alert cert sắp hết hạn | Chưa từng dựng monitoring cho PKI | **Tái diễn sau đúng 1 năm** (18/08/2027). Đây là sự cố lẽ ra phải biết trước 30 ngày |
| Không có quy trình renew định kỳ | Cert 1 năm, thao tác thủ công, không lịch | Phụ thuộc trí nhớ cá nhân; người phụ trách nghỉ/chuyển việc là mất |
| Chưa rõ kiến trúc etcd của cluster | Không có tài liệu topology | Mỗi lần sự cố lại mất thời gian chẩn đoán lại từ đầu |
| Không có tài liệu `certSANs` gốc của cluster | ConfigMap `kubeadm-config` là nơi duy nhất, mà nó chỉ đọc được khi cluster sống | Cluster chết = mất luôn thông tin cần để sửa cluster. Vòng lặp chết |
| `~/.kube/config` không được setup cho user vận hành | Thao tác qua `su root` | Mỗi lần sự cố phải mò lại; dễ nhầm lỗi kubeconfig thành lỗi cluster |

---

## 7. Việc tiếp theo

### Ngay lập tức — chẩn đoán (chỉ đọc, an toàn, chạy trên 48)

- [ ] **4.1** — Xác định etcd external hay stacked

  ```
  ls -l /etc/kubernetes/manifests/
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  ls -l /etc/kubernetes/manifests/
  │  │  └─ thư mục kubelet watch để chạy static pod (apiserver, scheduler,
  │  │     controller-manager, và etcd NẾU là stacked)
  │  └─ -l: long format — cần mtime để biết lần cuối manifest bị sửa
  └─ ĐỌC KẾT QUẢ:
     • KHÔNG có etcd.yaml → external etcd → khớp giả thuyết A → renew an toàn
     • CÓ etcd.yaml       → DỪNG LẠI, escalate. Nặng hơn issue cert
  ```
  </details>

- [ ] **4.2** — Xác nhận endpoint etcd và IP quảng bá

  ```
  grep -E 'etcd-servers|advertise-address' /etc/kubernetes/manifests/kube-apiserver.yaml
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  grep -E 'etcd-servers|advertise-address' <manifest>
  │    │                                    └─ manifest apiserver = NGUỒN SỰ THẬT về config
  │    │                                       thật, thay cho ConfigMap đang đọc không được
  │    └─ -E: regex mở rộng, `|` là OR mà không cần escape thành `\|`
  └─ ĐỌC KẾT QUẢ:
     • --etcd-servers=https://<IP khác>:2379  → external etcd ✔
     • --etcd-servers=https://127.0.0.1:2379  → stacked → mâu thuẫn 3.2 → DỪNG
     • --advertise-address=10.208.137.48      → IP này BẮT BUỘC phải có trong SAN cert mới
  ```
  </details>

- [ ] **4.3** — ⭐ Chụp SAN cert cũ (**quan trọng nhất, làm trước khi renew**)

  ```
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Alternative Name'
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  openssl x509 -in <cert> -noout -text | grep -A2 'Alternative Name'
  │       │     │          │      │            │  └─ -A2: in 2 dòng SAU dòng khớp.
  │       │     │          │      │            │     Chọn 2 (không phải 1) vì danh sách SAN
  │       │     │          │      │            │     dài có thể tràn sang dòng thứ hai
  │       │     │          │      │            └─ lọc đúng khối SAN, bỏ phần cert dài dòng
  │       │     │          │      └─ -text: decode cert ra dạng người đọc được
  │       │     │          └─ -noout: KHÔNG in lại PEM base64 (đỡ rác màn hình)
  │       │     └─ đọc từ file thay vì stdin
  │       └─ sub-command thao tác cert X.509
  └─ MỤC ĐÍCH: chép output ra chỗ khác TRƯỚC khi renew, để so sánh sau khi renew.
     ⭐ BẮT BUỘC PHẢI THẤY: lb-apiserver.kubernetes.local
        (output 3.0 chứng minh cluster dùng tên này làm endpoint)
     Kỳ vọng thấy thêm: 10.208.137.48, 10.233.0.1 (ClusterIP svc kubernetes — Kubespray
        mặc định dải 10.233.0.0/18, khác kubeadm thuần 10.96.0.0/12),
        kubernetes / kubernetes.default / kubernetes.default.svc.cluster.local,
        hostname node (vrp-kubeengine01), có thể cả IP .49 .50
     ⚠️ CHÉP LẠI TOÀN BỘ, không bỏ sót entry nào → dùng để soạn certSANs cho --config
        và để so sánh sau khi renew
  ```
  </details>

- [ ] **4.4** — Kiểm tra control-plane còn sống không (không cần kubectl)

  ```
  crictl ps -a --last 10
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  crictl ps -a --last 10
  │      │  │   └─ chỉ 10 container gần nhất — gọn màn hình, đủ thấy 4 static pod
  │      │  └─ -a: gồm cả container đã Exited. BẮT BUỘC có, nếu không sẽ không thấy
  │      │     container đang crashloop (nó Exited giữa các lần thử)
  │      └─ liệt kê ở tầng CRI (containerd), KHÔNG qua API server đang chết
  └─ ĐỌC CỘT STATE + ATTEMPT của kube-apiserver:
     • Running, ATTEMPT ổn định → apiserver sống, chỉ client bị chặn (như dự đoán 3.1)
     • Exited / ATTEMPT tăng   → crashloop, phải xem log trước khi renew
  Lỗi "connect endpoint": thêm -r unix:///run/containerd/containerd.sock
  ```
  </details>

- [ ] **4.5** — Xác nhận cơ chế LB và endpoint (đã biết tên, cần biết nó trỏ đi đâu)

  ```
  grep -E 'server:|lb-apiserver' /etc/kubernetes/admin.conf /etc/hosts
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  grep -E 'server:|lb-apiserver' /etc/kubernetes/admin.conf /etc/hosts
  │    │                          │                          └─ ⭐ chỗ Kubespray map
  │    │                          │                             lb-apiserver.kubernetes.local
  │    │                          │                             → thường là 127.0.0.1
  │    │                          └─ endpoint kubectl gọi tới. Đọc được KHÔNG cần cert
  │    │                             còn hạn (chỉ là text YAML) — chạy được cả khi cluster chết
  │    └─ -E: regex mở rộng, `|` là OR không cần escape
  └─ grep NHIỀU FILE cùng lúc → output tự động thêm tiền tố "<tên file>:" mỗi dòng,
     nên phân biệt được dòng nào của file nào mà không cần chạy 2 lệnh
     ĐỌC KẾT QUẢ:
     • /etc/hosts có "127.0.0.1 lb-apiserver.kubernetes.local"
       ⇒ XÁC NHẬN Kubespray localhost-LB: nginx/haproxy chạy trên CHÍNH node này,
         proxy sang 3 master. KHÔNG có VIP dùng chung
       ⇒ Hệ quả tốt: restart từng master KHÔNG làm client trên node khác mất kết nối,
         vì LB cục bộ tự chuyển sang master còn sống
     • /etc/hosts trỏ tới 1 IP thật ⇒ có LB/VIP tập trung → khi restart master phải
       kiểm tra health-check của LB có loại node đó ra không
  ```
  </details>

  > 📌 Output 3.0 **đã trả lời** phần lớn câu hỏi này: endpoint là
  > `lb-apiserver.kubernetes.local:6443`. Lệnh 4.5 giờ chỉ để xác nhận **cơ chế** phía sau
  > (LB cục bộ mỗi node hay LB tập trung) — điều này quyết định mức rủi ro khi restart
  > lần lượt từng master.

- [ ] **4.6** — Xác nhận có phải Kubespray không (để tìm nguồn `certSANs` gốc)

  ```
  ls -la /etc/kubernetes/kubeadm-config.yaml /etc/kubernetes/kubespray* 2>&1
  ```

  <details>
  <summary>Giải nghĩa</summary>

  ```
  ls -la <file1> <file2> 2>&1
  │  ││                   └─ gộp stderr vào stdout: thông báo "No such file" hiện ra ngay
  │  ││                      trong screenshot thay vì bị nuốt mất
  │  │└─ -a: hiện cả file ẩn (Kubespray có thể để lại file .kubespray*)
  │  └─ -l: long format, xem mtime để biết lần cuối cluster được dựng/nâng cấp
  └─ ⭐ /etc/kubernetes/kubeadm-config.yaml là VÀNG nếu tồn tại:
     Kubespray GHI file này ra đĩa khi chạy playbook, trong đó có ĐẦY ĐỦ certSANs.
     Có file này ⇒ renew kèm --config /etc/kubernetes/kubeadm-config.yaml là chuẩn nhất,
     không phải tự soạn lại từ việc đọc ngược cert cũ
  ```
  </details>

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
| Là stacked etcd nhưng PKI mất thật → renew không cứu được, có thể làm hỏng thêm | 🔴 Cao | Xác minh 4.1 + 4.2 **trước khi** renew. Nếu thấy `etcd.yaml` → dừng, escalate |
| Restart nhiều master cùng lúc → mất quorum etcd → cluster chết, phải restore snapshot | 🔴 Cao | Tuần tự 48→49→50, verify giữa mỗi bước |
| Node 49/50 có thể có tình trạng cert khác 48 (chưa kiểm tra) | 🟡 TB | Chạy `check-expiration` độc lập trên từng node trước khi thao tác |
| Không có snapshot etcd gần đây để rollback nếu hỏng | 🔴 Cao | ❓ **chưa xác minh** có snapshot không — **kiểm tra trước khi thao tác sửa** |
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
