# 📦 BÀN GIAO — Kiến trúc cross-cluster của RAGFlow (vRP ↔ vMLP)

> **Đối tượng đọc**: bên nhận PoC **migrate MySQL → PostgreSQL** và **MinIO → SeaweedFS**.
> **Người soạn**: KienNV · **Ngày**: 28/09/2026
> **Nguồn**: tổng hợp từ các file tracking/runbook trong repo (mục 11). Số liệu có ghi ngày đo;
> số nào chưa đo lại thì coi là **ảnh chụp tại thời điểm đó**, không phải hiện trạng.
>
> ⚠️ File này **không chứa secret**. Credential nằm trong Secret k8s (mục 7.3), hỏi KienNV khi cần.

---

## 1. ⚡ TÓM TẮT — 1 phút

- RAGFlow **chạy ở cụm vRP**, nhưng **MinIO nằm ở cụm vMLP** (chuyển sang 26/08/2026 vì vRP
  node 07 cạn inode). ES và LiteLLM (embedding) là dịch vụ **ngoài** namespace/cụm.
- Hai cụm **cùng dải `10.208.137.0/24`**, thông L2, không NAT, không service mesh,
  **không có DNS xuyên cụm** ⟹ gọi nhau bằng **`IP:NodePort`**.
- **Không dùng Ingress.** RAGFlow expose bằng NodePort **`8999`** (L4).
- Cả hai cụm: **airgap**, CentOS 7, k8s **v1.23.2**, containerd **1.5.8**, **không có Docker**.
- Vận hành/triển khai: **vào VDI → ssh thẳng vào node của từng cụm** (mục 2).

---

## 2. 🚪 Đường vào cho người vận hành / triển khai

```
 Máy người vận hành
        │
        ▼
 ┌──────────────┐   (clipboard bị chặn ⟹ lấy output bằng screenshot)
 │     VDI      │
 └──────┬───────┘
        │ ssh
        ├──────────────────────────────┬──────────────────────────────────┐
        ▼                              ▼                                  ▼
 vRP  vrp-kubeengine04 (.51)     vRP  node khác (.48–.55)        vMLP vmlp-kubeengine08 (.42)
      ⭐ jump box kubectl              ssh thẳng được                    ⭐ jump box kubectl
      ⚠️ có n8n (nerdctl)                                               + các node .35–.44
```

### 2.1 Cách đăng nhập — **hai cụm KHÁC NHAU**

| Cụm | ssh thẳng `root@`? | Cách lên root | Node gõ `kubectl` | User gõ `kubectl` |
|---|---|---|---|---|
| **vRP** | ✅ được | ssh `root@<node>`, hoặc `vt_admin` → `su -` | **`.51`** (vrp-kubeengine04) | **`app`** |
| **vMLP** | ❌ **bị chặn** (`PermitRootLogin no`) | ssh `vt_admin@<node>` → `su -` (**cần mật khẩu root**) | **`.42`** (vmlp-kubeengine08) | **`app`** |

- vMLP: `vt_admin` có sudo nhưng **đòi mật khẩu** ⟹ lệnh từ xa (`rsync`, `scp`, `ssh ... 'cmd'`)
  **phải dùng `vt_admin@`**, không dựa được vào `sudo` trong phiên không TTY.
  (Đã phải sửa lệnh rsync 3 lần vì điểm này — `TRACKING-migrate-minio-vRP-to-vMLP.md` mục 7c.-1.)
- **Quy ước gọi tên node**: luôn có prefix `vrp-` / `vmlp-` (vd `vrp-07`, `vmlp-09`) để không nhầm cụm.

### 2.2 User nào chạy lệnh gì (vRP)

| Việc | User |
|---|---|
| `kubectl ...` | `app` |
| `nerdctl ps/images` (n8n) | `root` — `su -` trước, **không dùng `sudo nerdctl`** |
| `ctr` / `crictl` | `root` |

---

## 3. 🗺️ Sơ đồ luồng dữ liệu của RAGFlow

```
                 Client (n8n / app / người dùng — ❓ xem mục 10)
                           │  HTTP  NodePort 8999 (L4, không Ingress)
                           ▼
┌──────────────────────────── cụm vRP (10.208.137.48–.55) ────────────────────────────┐
│  ns: ragflow                                                                        │
│  deploy/ragflow  (image custom, 3 replicas, pod đặt node nào không cố định)         │
│     │                                                                               │
│     ├── MySQL  sts/ragflow-mysql   vrp-06 (.53)   svc ClusterIP ragflow-mysql:3306  │
│     ├── Redis  sts/ragflow-redis   vrp-07 (.54)   svc ragflow-redis-svc:6379        │
│     └── MinIO  sts/ragflow-minio   ⛔ replicas=0 (đã chuyển đi)                     │
└─────┬──────────────────────────┬────────────────────────────┬───────────────────────┘
      │ S3  10.208.137.43:9000   │ HTTPS 10.211.145.107:8051  │ HTTP 10.208.137.53:8992
      ▼                          ▼                            ▼
┌──── cụm vMLP ────┐     ┌──── Elasticsearch ────┐    ┌──── LiteLLM (embedding) ────┐
│ ns: ragflow      │     │ NGOÀI cả 2 cụm        │    │ NodePort 8992 trên vRP,     │
│ sts/ragflow-minio│     │ dải 10.211.x (khác    │    │ ngoài ns ragflow            │
│ vmlp-09 (.43)    │     │ dải 2 cụm)            │    │ model qwen3-8b-embedding    │
│ NodePort 9000    │     │ user aihub_prod       │    └─────────────────────────────┘
└──────────────────┘     └───────────────────────┘
```

### 3.1 Bảng thành phần

| Thành phần | Cụm / node | Endpoint RAGFlow dùng | Dữ liệu nằm ở | RAGFlow tìm nó bằng |
|---|---|---|---|---|
| RAGFlow API/UI | vRP, pod trôi | `<IP node vRP bất kỳ>:8999` (test hay dùng `10.208.137.54:8999`) | — | — |
| **MySQL** | vRP **vrp-06 (.53)** | `ragflow-mysql.ragflow.svc:3306` | hostPath **`/data/ragflow/mysql`** trên vrp-06 | Service DNS nội cụm |
| Redis | vRP vrp-07 (.54) | `ragflow-redis-svc:6379` | — | Service DNS nội cụm |
| **MinIO** | **vMLP vmlp-09 (.43)** | **`10.208.137.43:9000`** | hostPath **`/home/app/app_data/ragflow/minio`** trên vmlp-09 | `MINIO_HOST`/`MINIO_PORT` trong Secret |
| Elasticsearch | ngoài cụm | `https://10.211.145.107:8051` | — | `service_conf.es.hosts` |
| LiteLLM embedding | vRP, NodePort | `http://10.208.137.53:8992/` | — | lưu trong **DB** (bảng cấu hình LLM), không nằm trong env |

---

## 4. Cụm vRP (nguồn — nơi RAGFlow chạy)

| Node | IP | Vai trò | Ghi chú |
|---|---|---|---|
| vrp-kubeengine01/02/03 | .48 / .49 / .50 | control-plane | 4C / ~7.6G / ~49G disk |
| **vrp-kubeengine04** | **.51** | worker | ⚠️ **jump box + n8n chạy bằng `nerdctl`** |
| vrp-kubeengine05 | .52 | worker | 8C / 16G |
| vrp-kubeengine06 | .53 | worker | 16C / 32G — **MySQL RAGFlow** + ⚠️ **PostgreSQL chạy thẳng trên host** (không phải của RAGFlow) |
| vrp-kubeengine07 | .54 | worker | 8C / 16G — Redis RAGFlow |
| vrp-kubeengine08 | .55 | worker | 16C / 32G |

| Hạng mục | Giá trị |
|---|---|
| API server | VIP/LB tập trung **`10.208.137.68`** = `lb-apiserver.kubernetes.local:6443` (map trong `/etc/hosts`) |
| Công cụ dựng cụm | nghi **Kubespray** (tên endpoint là mặc định Kubespray) — chưa xác minh |
| Cluster domain | **`vrp`** (`dnsDomain: vrp`), không phải `cluster.local` |
| etcd | external, `https://10.208.137.48/49/50:2379` |
| `maxPods` | **50**/node (không phải 110) |
| NodePort range | chưa ghi nhận (đang dùng 8999, 8992 ⟹ **không** phải dải mặc định 30000–32767) |

### 4.1 Registry (airgap) — có **3** cái

| Registry | Phục vụ | Reachability |
|---|---|---|
| `10.60.170.184:8083` | image RAGFlow custom (`vmlp/lfnovo/ragflow:v2-latest`) | ✅ `.51` thông. **Không phải node nào cũng thông** |
| `10.208.137.65:8890` | phần lớn image nerdctl (`vmlp/*`) | ❓ chưa đo |
| `10.60.129.132:8890` | image hệ thống k8s (calico, kube-proxy) | ❓ chưa đo |

Registry dùng self-signed cert ⟹ pull tay phải có `--skip-verify=true`.

---

## 5. Cụm vMLP (đích — nơi MinIO đang chạy)

10 node, dải `10.208.137.35–.44`, cùng CentOS 7 / k8s v1.23.2 / containerd 1.5.8.

| Node | IP | Ghi chú (đo 26/08) |
|---|---|---|
| vmlp-kubeengine01/02/03 | .35 / .36 / .37 | control-plane |
| vmlp-kubeengine04 | .38 | ⛔ **SchedulingDisabled** — loại khỏi mọi phương án |
| vmlp-kubeengine05 | .39 | CPU req 5% |
| vmlp-kubeengine06 | .40 | 🔴 CPU req **80%** — tránh đặt workload nặng |
| vmlp-kubeengine07 | .41 | CPU req 11% |
| **vmlp-kubeengine08** | **.42** | **jump box `kubectl`** |
| **vmlp-kubeengine09** | **.43** | **MinIO RAGFlow** — CPU req 12% |
| vmlp-kubeengine10 | .44 | 🔴 CPU req **72%** |

| Hạng mục | Giá trị |
|---|---|
| Taint | không node nào có taint (05/06/07/09/10) |
| **NodePort range** | ⚠️ **`8000–10000`** — khác mặc định. Đặt `30900` sẽ bị API server từ chối |
| StorageClass | `local-path` (default), `local-storage`, `nfs-delete`, `nfs-retain`. PV MinIO là **PV tạo tay** (`host-storage`, không có provisioner) |
| Namespace liên quan | `ragflow` (tạo mới cho MinIO), **`minio-operator`** (có sẵn, image cũ ~2 năm — đã **không dùng**, MinIO RAGFlow là StatefulSet thường), `ingress-controller` (❓ chưa khảo sát), `storage` |
| Hàng xóm | cùng cụm có Tenant MinIO của `vcc`, `vic`, `viettel-telecom` ⟹ tách credential riêng cho ragflow |
| Ổ đĩa | **không được cấp block device mới** — chạy trên `/dev/vda1` sẵn có ("có gì dùng nấy") |

---

## 6. Mạng giữa hai cụm (đo 26/08)

| Chiều | Kết quả |
|---|---|
| vrp-04 (.51) → vmlp-08 (.42) | ping 0% loss, RTT avg **0.73 ms**; `curl :9000/minio/health/live` bắt tay HTTP OK |
| vmlp-08 (.42) → vrp-07 (.54) | ping 0% loss, RTT avg **0.61 ms** |

⟹ Không có firewall chặn giữa 2 cụm ở các cổng đã thử. **Chưa kiểm** tường lửa tới dải ES `10.211.x`.

---

## 7. 🎯 Thông tin dành riêng cho PoC

### 7.1 MySQL → PostgreSQL

**Hiện trạng MySQL**

| Hạng mục | Giá trị |
|---|---|
| Image | `mysql:8.0.39`, **1 replica**, chạy với `--disable-log-bin` (không có binlog ⟹ không làm CDC/replica từ binlog được nếu không bật lại) |
| Node / dữ liệu | vrp-06 (.53), hostPath `/data/ragflow/mysql`, PV tạo tay `pv-ragflow-mysql-node06.yaml` (khai 5Gi nhưng **không enforce**, dùng chung đĩa hệ thống) |
| Schema | `rag_flow` |
| Kích thước (05/08) | working set ~**1.85 GB**. Lớn nhất: `document` 1.05 GB (**239.395 dòng**), `file` 328 MB, `task` 295 MB, `pipeline_operation_log` 192 MB, `file2document` 179 MB |
| Tải (05/08) | ~93 QPS, `max_connections` 1000, `Max_used_connections` 184 |
| Index tự thêm | `idx_document_kb_create ON document (kb_id, create_time DESC)` — **không có trong schema gốc**, phải tạo lại bên Postgres |
| Lần migrate trước | 07/08 chuyển node07 → node06 bằng **copy datadir** (có downtime). Chi tiết: `PLAN-mysql-migrate-node06.md` |

**RAGFlow có hỗ trợ Postgres không?** — **Có ở mức code upstream v0.26.4** (đã đọc source trong repo):

| Bằng chứng | Vị trí |
|---|---|
| Chọn DB bằng env `DB_TYPE` (mặc định `mysql`) | `ragflow-0.26.4/common/settings.py:73`, `:220` |
| Pool Postgres có retry | `ragflow-0.26.4/api/db/db_models.py:321` (`RetryingPooledPostgresqlDatabase`), `:462` |
| Lock riêng cho Postgres | `ragflow-0.26.4/api/db/db_models.py:528` (`PostgresDatabaseLock`) |
| Mẫu config | `ragflow-0.26.4/docker/service_conf.yaml.template:76` (block `postgres:` đang comment) |

**🔴 Điểm chặn đã thấy — bên PoC phải xử lý:**

1. **Patch code tự viết dùng hàm riêng của MySQL.** `patches/0001-fix-pipeline-log-deadlock.patch`
   (đang áp qua initContainer, file `helm_ragflow_v0.26.4/files/code-patch/api/db/services/pipeline_operation_log_service.py:250`, `:259`)
   gọi `SELECT GET_LOCK(...)` / `RELEASE_LOCK(...)`. **Postgres không có hai hàm này** ⟹ chạy trên
   Postgres sẽ lỗi. Tương đương bên Postgres là advisory lock (`pg_try_advisory_lock` / `pg_advisory_unlock`, nhận key kiểu số chứ không phải chuỗi).
2. **Helm chart chưa hỗ trợ Postgres.** `helm_ragflow_v0.26.4/templates/env.yaml` chỉ render biến
   `MYSQL_*`, không có `DB_TYPE`/`POSTGRES_*`. Phải sửa chart hoặc tự inject env.
3. **Image đang chạy là bản CUSTOM** (`10.60.170.184:8083/vmlp/lfnovo/ragflow:v2-latest`, đã sửa
   phần build query tiếng Việt), **lệch upstream**. Mọi kết luận "code hỗ trợ X" ở trên phải
   **kiểm lại trong container thật** (`kubectl exec ... grep`), không tin GitHub.
4. Chuyển dữ liệu: MySQL → Postgres **khác engine**, không copy datadir được như lần trước;
   cần công cụ chuyển đổi (vd pgloader) và kiểm kỹ kiểu dữ liệu, collation, index, constraint.
   Sếp từng lưu ý: *"tránh sai sót user/pass, các constraint"*.

### 7.2 MinIO → SeaweedFS

**Hiện trạng MinIO**

| Hạng mục | Giá trị |
|---|---|
| Vị trí | vMLP **vmlp-09 (.43)**, ns `ragflow`, `sts/ragflow-minio`, **single-node** |
| Image | `docker.io/minio/minio:RELEASE.2025-06-13T11-33-47Z` |
| Dữ liệu | hostPath `/home/app/app_data/ragflow/minio` (trên `/dev/vda1`) |
| Dung lượng (26/08) | **37G on-disk / 20,3 GiB logic / 5.664.048 inode** |
| Endpoint | S3 `10.208.137.43:9000`, console `10.208.137.43:9901` (NodePort) |
| Manifest | `manifests-vmlp/minio-vmlp.yaml` (6 object, có comment) · runbook `RUNBOOK-minio-vmlp.md` |
| Backup | 🔴 **chưa có** — bản trên vmlp-09 là **bản duy nhất** |

**⭐ Vì sao cân nhắc SeaweedFS — bài toán INODE, không phải dung lượng:**

- RAGFlow ghi **mỗi chunk tài liệu = 1 object**; MinIO lưu mỗi object thành
  **1 thư mục + `xl.meta` + `part.1` ≈ 3 inode**. Số inode tăng theo **số object**, không theo GB.
- vRP node 07 sập RAGFlow vì **cạn inode khi đĩa còn trống**. Migrate sang vMLP chỉ **mua thêm thời gian**:
  inode vmlp-09 đã ~47% và vẫn tăng. `/home` nằm trên `/` ⟹ cạn inode là **chết cả node**.
- `.minio.sys/multipart/` rỗng ⟹ **không có object rác** để dọn; 5,66 triệu inode đều là object thật.
- ⟹ Tiêu chí PoC nên đo **số inode / 1 triệu object** chứ không chỉ throughput.

**RAGFlow nối storage thế nào** (source upstream v0.26.4):

| Bằng chứng | Vị trí |
|---|---|
| Chọn backend bằng env `STORAGE_IMPL` (mặc định `MINIO`) — hỗ trợ `MINIO`, `AWS_S3`, `OSS`, `GCS`, `AZURE_SPN/SAS`, OpenDAL | `ragflow-0.26.4/common/settings.py:133`, `:338-350`; connector ở `ragflow-0.26.4/rag/utils/*_conn.py` |
| `AWS_S3` nhận `endpoint_url`, `signature_version`, `addressing_style` (dùng được cho S3-compatible) | `ragflow-0.26.4/rag/utils/s3_conn.py:36-38`, `:84-89`; mẫu `docker/service_conf.yaml.template:84-101` |

⟹ Hai hướng cho PoC (**chưa ai thử**): (a) giữ `STORAGE_IMPL=MINIO`, trỏ `MINIO_HOST` sang S3 gateway
của SeaweedFS; (b) `STORAGE_IMPL=AWS_S3` + `endpoint_url` + `addressing_style: path`.
Cần kiểm các API RAGFlow thực sự gọi (`bucket_exists`, `put`, `get`, `obj_exist`, xóa bucket theo `kb_id`...)
có chạy đúng trên SeaweedFS không.

**Ràng buộc khi triển khai SeaweedFS trên vMLP**: NodePort phải trong **8000–10000**; không có
block device mới; tránh vmlp-04 (cordon), vmlp-06/10 (CPU cao); image phải mang vào bằng
tarball/registry nội bộ (airgap).

### 7.3 Chỗ cấu hình cần đổi khi cắt chuyển

| Cái gì | Ở đâu |
|---|---|
| Endpoint + credential MinIO | Secret **`ragflow-env-config`** (ns `ragflow`, cụm vRP): `MINIO_HOST`, `MINIO_PORT`, `MINIO_USER`, `MINIO_PASSWORD`, `MINIO_ROOT_PASSWORD` |
| Endpoint MySQL | `templates/env.yaml:27` render `MYSQL_HOST` = Service DNS; khi `mysql.enabled=false` thì lấy `env.MYSQL_HOST` (`:30`) |
| service_conf | `helm_ragflow_v0.26.4/templates/ragflow_config.yaml` |
| Mẹo đã dùng lần trước | đổi **NodePort bên đích cho khớp** endpoint cũ thay vì sửa config RAGFlow — ít rủi ro hơn |

---

## 8. 🔴 Ràng buộc an toàn — ĐỌC TRƯỚC MỌI THAO TÁC GHI

1. **vrp-04 (.51) chạy n8n bằng `nerdctl` — n8n down là RẤT NGUY HIỂM.** Cũng là node gõ `kubectl`
   của vRP. **Cấm**: `nerdctl volume prune`, `nerdctl system prune -a`, đụng `/var/lib/nerdctl`,
   `/home/app/persistent-data/` (pgdata sống của n8n, tên thư mục trông như backup nhưng **không phải**).
2. **vrp-06 (.53) có PostgreSQL chạy thẳng trên host** ở `/home/app/postgres/data` (~83G, đang ghi) —
   **không phải của RAGFlow, tuyệt đối không đụng.** Khi dựng Postgres PoC đừng nhầm với instance này.
3. **Không phải node nào cũng thông registry.** Node không thông ⟹ **không được xóa image**
   (airgap, xóa là không kéo lại được ⟹ `ImagePullBackOff` vĩnh viễn).
4. **Không có Docker.** Dùng `crictl` (chỉ thấy ns `k8s.io`) hoặc `ctr -n <ns>` (luôn ghi rõ `-n`).
5. **Không `rm` trực tiếp trong thư mục dữ liệu MinIO** — chỉ xóa qua S3 API/`mc`.
6. CentOS 7 root có alias `rm -i` ⟹ dòng kết thúc bằng `?` là **đang hỏi, chưa xóa**.
7. Đĩa đầy có thể là **hết inode** ⟹ luôn xem cả `df -h` lẫn `df -i`. `du` trong
   `/var/lib/kubelet` phải có `-x`.

---

## 9. 🔍 Lệnh kiểm tra nhanh hiện trạng (chỉ đọc)

**Trên vrp-04 (.51), user `app`:**

```bash
kubectl -n ragflow get pods -o wide
kubectl -n ragflow get svc
```

<details><summary>Giải nghĩa</summary>

```
kubectl -n ragflow get pods -o wide
│       │  │       │   │    └─ -o wide : in thêm cột IP pod + NODE đang chạy (biết pod nằm node nào)
│       │  │       │   └─ pods : loại object cần liệt kê
│       │  │       └─ get : chỉ ĐỌC, không thay đổi gì
│       │  └─ ragflow : tên namespace
│       └─ -n : chọn namespace (không có thì mặc định là "default")
└─ kubectl : CLI gọi API server của cụm vRP

kubectl -n ragflow get svc
                       └─ svc : Service — xem TYPE (NodePort/ClusterIP) và cặp cổng 80:8999
```
</details>

**Trên vmlp-08 (.42), user `app`:**

```bash
kubectl -n ragflow get pods,svc,pv -o wide
curl -s -o /dev/null -w '%{http_code}\n' http://10.208.137.43:9000/minio/health/live
```

<details><summary>Giải nghĩa</summary>

```
kubectl -n ragflow get pods,svc,pv -o wide
                       └─ pods,svc,pv : liệt kê nhiều loại object trong 1 lệnh
                          (pv là object cấp cụm, không thuộc namespace — -n bị bỏ qua cho pv)

curl -s -o /dev/null -w '%{http_code}\n' http://10.208.137.43:9000/minio/health/live
│    │  │            │  └─ '%{http_code}\n' : chỉ in mã HTTP. 200 = MinIO sống
│    │  │            └─ -w : --write-out, in thông tin sau khi request xong
│    │  └─ -o /dev/null : bỏ body response, không in ra màn hình
│    └─ -s : silent, tắt thanh tiến trình
└─ /minio/health/live : endpoint health của MinIO, không cần credential
```
</details>

**Trên vmlp-09 (.43), sau khi `su -`** — theo dõi inode:

```bash
df -i /home
```

<details><summary>Giải nghĩa</summary>

```
df -i /home
│  │  └─ /home : filesystem chứa /home (trên vmlp-09 là "/" — dùng chung ổ hệ thống)
│  └─ -i : hiện INODE (IUsed/IFree/IUse%) thay vì dung lượng. Đây là trục đã làm sập RAGFlow
└─ df : disk free theo filesystem
```
</details>

---

## 10. ❓ Chưa khảo sát / chưa rõ — bên PoC nên xác nhận

| # | Câu hỏi | Vì sao quan trọng |
|---|---|---|
| 1 | **Ai gọi RAGFlow `:8999`?** (n8n, app ngoài, người dùng) và trước đó có LB/domain nào không | Cắt chuyển cần biết client nào bị ảnh hưởng, có cần thông báo không |
| 2 | Control-plane vMLP: VIP/LB API server, `dnsDomain` | Chưa từng ghi nhận, chỉ biết jump box .42 |
| 3 | Namespace `ingress-controller` trên vMLP dùng làm gì | Có thể là lựa chọn expose SeaweedFS thay cho NodePort |
| 4 | Route/firewall từ vRP tới ES `10.211.x` | ES khác dải; mất kết nối là RAGFlow hỏng retrieval |
| 5 | NodePort range thật của vRP | Đang dùng 8999/8992 ⟹ đã tùy biến, chưa đọc cấu hình |
| 6 | Reachability 2 registry `10.208.137.65:8890`, `10.60.129.132:8890` từ từng node | Quyết định node nào được dọn image, node nào nhận image PoC |
| 7 | KB xóa trên UI có xóa object tương ứng không | Nếu không ⟹ object mồ côi, ảnh hưởng số liệu migrate |
| 8 | Số object thật hiện tại (thay vì suy từ inode) | Làm baseline cho PoC SeaweedFS |

---

## 11. 📚 Tài liệu gốc trong repo

| File | Đọc khi cần |
|---|---|
| `RUNBOOK-minio-vmlp.md` | Vận hành MinIO trên vMLP: file ở đâu, lệnh nào, sự cố đã gặp |
| `TRACKING-migrate-minio-vRP-to-vMLP.md` | Vì sao chuyển, 14 phát hiện, rủi ro, toàn bộ lệnh rsync |
| `TRACKING-minio-can-inode.md` | Cơ chế MinIO ăn inode, số liệu đo |
| `manifests-vmlp/minio-vmlp.yaml` | Manifest MinIO đang chạy (có comment) |
| `TRACKING-mysql-load-assessment.md` | Hiện trạng/tải MySQL, bảng lớn, query chậm |
| `PLAN-mysql-migrate-node06.md` | Lần migrate MySQL gần nhất (copy datadir), lỗi quyền khi rsync |
| `TRACKING-cert-k8s-het-han.md` | Control-plane vRP: VIP, Kubespray, etcd, dnsDomain |
| `TRACKING-vrp-disk-pressure.md` | Disk/registry/n8n trên vRP, các thư mục cấm đụng |
| `TRACKING-api-retrieval-latency.md` | ES, LiteLLM embedding, luồng retrieval |
| `helm_ragflow_v0.26.4/` | Chart đang deploy (values, env, code-patch) |
| `patches/` | Patch code tự viết (có patch dùng `GET_LOCK` MySQL) |
