# TRACKING — Nâng RagFlow v0.24 → v0.26.4 + scale 3 replicas

**Ngày:** 2026-07-29 → 2026-07-31
**Namespace:** `ragflow` (prod), `ragflow-custom` (test)
**Release name:** `ragflow`
**Chart mới:** `helm_ragflow_v0.26.4/` (branch `worktree-update-investigate-notes`)

---

## 1. Mục tiêu

| Mục tiêu | Trạng thái |
|---|---|
| Nâng chart lên v0.26.4 khớp với image v0.26 | ✅ Đạt |
| Scale lên 3 replicas (tăng throughput task_executor + chịu tải API) | ✅ Đạt |
| Tránh node `vrp-kubeengine04` (sắp cạn tài nguyên) | ✅ Đạt |
| Giữ mysql/minio/redis trên node có label `ragflow-target=true` | ✅ Đạt |
| Retrieval/embedding hoạt động lại | ⚠️ Workaround |

### Bối cảnh hạ tầng

- Cluster 8 node: 3 master + 5 worker (`vrp-kubeengine04..08`), k8s `v1.23.2`
- **Air-gapped** — không pull được image từ internet, phải copy thủ công lên từng node
- ES **ngoài cluster**: `https://10.211.145.107:8051`, user `aihub_prod`
- Embedding endpoint: `http://10.208.137.53:8992/`
- Image ragflow custom (AI engineer build từ code v0.26, sửa phần build query tiếng Việt):
  `10.60.170.184:8083/vmlp/lfnovo/ragflow:v2-latest`
- Storage: local PV — `local-mysql`, `local-minio`, `local-redis`, `local-elasticsearch`

---

## 2. Tổng quan issue

| # | Issue | Trạng thái | Giải pháp |
|---|---|---|---|
| 1 | 502 toàn bộ endpoint — user ES thiếu quyền `monitor` | ✅ FIXED | Team ES cấp cluster privilege `monitor` |
| 2 | `CrashLoopBackOff` — `cp: cannot remove ragflow.conf: Device or resource busy` | ✅ FIXED | Chart v0.26.4 mount `ragflow.conf.python` (file nguồn) |
| 3 | 502 sau khi hết CrashLoop — không server nào start | ✅ FIXED | Set `API_PROXY_SCHEME: "python"` |
| 4 | `helm upgrade` fail — `missing required field "serviceName"` | ✅ FIXED | Thêm `serviceName` vào 5 StatefulSet |
| 5 | `helm upgrade` fail — PVC/StatefulSet `spec is immutable` | ✅ FIXED | Khớp `storageClassName` + `serviceName` với prod |
| 6 | minio `ImagePullBackOff` | ✅ FIXED | Giữ image cũ đã cache trên node |
| 7 | mysql/minio/redis `Pending` lúc được lúc không | ✅ FIXED | Dọn image ragflow 7.2GB khỏi node07 (hết disk-pressure) |
| 8 | Pod ragflow `Init:ImagePullBackOff` trên node07 | ✅ FIXED | Loại node07 khỏi affinity ragflow |
| 9 | `LookupError: Instance default not found` (embedding) | ⚠️ WORKAROUND | Sửa DB thủ công — **bug upstream #17578 chưa fix** |
| 10 | Query chậm 13-15s trên KB 141k doc (issue #4 cũ) | 🔶 OPEN | AI engineer đã custom image, cần test lại |

---

## 3. Issue đã FIXED

### Issue 1 — 502 toàn bộ endpoint: ES thiếu cluster privilege `monitor`

**Triệu chứng**

Toàn bộ app trả 502, kể cả trang login và `/logout`. Pod báo `1/1 Running`.

```
AuthorizationException(403, 'security_exception',
'action [cluster:monitor/main] is unauthorized for user [aihub_prod]
 with effective roles [aihub_role], this action is granted by
 the cluster privileges [monitor,manage,all]')
Waiting Elasticsearch https://10.211.145.107:8051 to be healthy.
```

**Root cause**

RagFlow lúc boot gọi health-check `GET /` (= action `cluster:monitor/main`). ES trả 403.
RagFlow hiểu 403 là "ES chưa sẵn sàng" → **retry vô hạn**, không bao giờ bind port 9380
→ nginx mất upstream → 502 mọi endpoint.

**Bằng chứng**

Gọi trực tiếp cùng credential từ 2 pod ở 2 namespace khác nhau, cùng thời điểm:

```
kubectl -n ragflow-custom exec $POD_OK -c ragflow -- curl -sk -u "aihub_prod:***" -o /dev/null -w "%{http_code}\n" https://10.211.145.107:8051/
```

```
kubectl -n ragflow exec $POD_BAD -c ragflow -- curl -sk -u "aihub_prod:***" -o /dev/null -w "%{http_code}\n" https://10.211.145.107:8051/
```

Kết quả: **cả hai đều 403** → loại trừ network/node/image.

**Đã thử**

| Phương án | Kết quả |
|---|---|
| Nghi `ClosedPoolError` là bug riêng | ❌ Sai — chỉ là hệ quả của restart pod |
| Nghi patch `timeout=600→30` gây lỗi | ❌ Sai — sed pattern chưa bao giờ khớp (code thật `timeout="600s"`) |
| Nghi image v1 vs v2 khác nhau | ❌ Sai — user xác nhận cùng image, chỉ khác tag |
| Nghi network path từ node07 (do lỗi x509 lúc helm upgrade) | ❌ Loại — cả 2 pod ở 2 node đều 403 |
| Gọi `GET /` trực tiếp từ 2 pod cùng lúc | ✅ Phân định — quyền ES |

**Nghịch lý đã giải thích**: bản `ragflow-custom` ban đầu vẫn chạy được vì **đã boot xong
từ trước** khi quyền bị siết. Sau khi user rollout nó, nó chết y hệt → xác nhận giả thuyết.

**Giải pháp cuối**

Team ES cấp thêm cluster privilege `monitor` cho role `aihub_role`.
Verify sau khi cấp: `ES_GET_root=200`, log ghi `Elasticsearch ... is healthy`.

---

### Issue 2 — CrashLoopBackOff: chart mount đè file entrypoint cần ghi

**Triệu chứng**

```
Start RAGFlow cluster, version:
v0.26.4
cp: cannot remove '/etc/nginx/conf.d/ragflow.conf': Device or resource busy
```
Container `Exit Code: 1`, `CrashLoopBackOff`. Init container `ragflow-code-patch` exit 0 (không phải thủ phạm).

**Root cause**

Entrypoint v0.26 có logic mới — chọn 1 trong 3 biến thể nginx config theo `API_PROXY_SCHEME`
rồi `cp -f` đè lên `/etc/nginx/conf.d/ragflow.conf`. Nhưng chart v0.24 mount đè đúng file đó
bằng `subPath` → bind-mount read-only của kernel → `EBUSY` → `set -e` → exit 1.

**Bằng chứng**

Đọc entrypoint trong image bằng cách override command thành `sleep` (pod crash vẫn đọc được):

```
kubectl -n $NS run tmp-inspect --restart=Never --image=$IMG --overrides='{"spec":{"containers":[{"name":"tmp-inspect","image":"'$IMG'","imagePullPolicy":"IfNotPresent","command":["sleep","3600"]}]}}'
```

```
kubectl -n $NS wait --for=condition=Ready pod/tmp-inspect --timeout=120s
```

```
kubectl -n $NS exec tmp-inspect -- grep -n -iE "cp |mv |nginx|conf\.d" /ragflow/entrypoint.sh
```

Output cho thấy dòng 188-205 và `set -e` ở đầu file.

**Giải pháp cuối**

Chart v0.26.4 upstream **đã tự fix**: đổi mount sang file **nguồn** thay vì file **đích**.

```yaml
# v0.24 (sai voi image v0.26)
- mountPath: /etc/nginx/conf.d/ragflow.conf
  subPath: ragflow.conf

# v0.26.4 (dung)
- mountPath: /etc/nginx/conf.d/ragflow.conf.python
  subPath: ragflow.conf.python
```

Cách này tốt hơn phương án ban đầu (xóa mount) vì vẫn custom được nginx config.
`client_max_body_size 128M` được giữ nguyên (nằm ở `nginx.conf`, không phải `ragflow.conf`).

---

### Issue 3 — 502 sau khi hết CrashLoop: không server nào được start

**Triệu chứng**

Pod `1/1 Running`, nginx chạy, `sync_data_source.py` chạy — nhưng **không có**
`python3 api/ragflow_server.py`. Log có `Starting nginx...` nhưng **thiếu** dòng
`Attempt to start RAGFlow python server...`. `curl 127.0.0.1:9380` → `http_code=000`, exit 7.

**Root cause — bug logic của upstream v0.26.4**

Fetch `docker/entrypoint.sh` từ GitHub v0.26.4:

```
Khoi CHON nginx config (co nhanh else):
  else
      cp -f "$NGINX_CONF_DIR/ragflow.conf.python" "$NGINX_CONF_DIR/ragflow.conf"
      echo "Default: applied nginx config: ragflow.conf.python"
  fi

Khoi START server (KHONG co nhanh else):
  if [[ "$API_PROXY_SCHEME" == "hybrid" ]] || [[ "$API_PROXY_SCHEME" == "python" ]]; then ... fi
  if [[ "$API_PROXY_SCHEME" == "hybrid" ]] || [[ "$API_PROXY_SCHEME" == "go" ]]; then ... fi
```

Khi `API_PROXY_SCHEME` **rỗng**: nginx được cấu hình trỏ tới Python server, nhưng
**không server nào được khởi động** → nginx không có upstream → 502.

**Bằng chứng**

Log của user có đúng dòng `Default: applied nginx config: ragflow.conf.python`
(nhánh `else` của khối chọn config) nhưng không có dòng start server nào.

**Giải pháp cuối**

Thêm vào `values.yaml` mục `env:`:

```yaml
env:
  API_PROXY_SCHEME: "python"
```

Verify sau deploy: log có `Attempt to start RAGFlow python server...`, `ps aux` có
`python3 api/ragflow_server.py`, API trả 401 (không phải 000).

**Ghi chú**: v0.26 có thêm **Go server** (`bin/ragflow_server --api`). Scheme `go`/`hybrid`
có thể giải quyết vấn đề single-process Python — xem mục 7.

---

### Issue 4 — `missing required field "serviceName"`

**Triệu chứng**

```
Error: UPGRADE FAILED: error validating "": error validating data:
ValidationError(StatefulSet.spec): missing required field "serviceName"
in io.k8s.api.apps.v1.StatefulSetSpec
```

**Root cause**

`serviceName` là field **bắt buộc** của `StatefulSetSpec`. Chart upstream chỉ đặt nó cho
`redis.yaml`; thiếu ở `minio`/`mysql`/`elasticsearch`/`opensearch`/`infinity`.
Bug này có **cả ở chart v0.24** (đã đối chiếu).

Các StatefulSet này đang chạy trên prod → chúng từng được tạo thành công → k8s cũ validate
lỏng hơn. Lỗi chỉ lộ khi chạy `helm upgrade` → **latent failure**.

**Giải pháp cuối** (commit `e3d4af5`)

Thêm `serviceName` vào 5 file. Nhưng phải khớp **đúng tên Service đang chạy** — xem Issue 5.

---

### Issue 5 — PVC/StatefulSet `spec is immutable`

**Triệu chứng**

```
cannot patch "ragflow-minio" with kind PersistentVolumeClaim:
  spec: Forbidden: spec is immutable after creation
  - StorageClassName: nil,
  + StorageClassName: &"local-minio",

cannot patch "ragflow-mysql" with kind StatefulSet:
  updates to statefulset spec for fields other than 'replicas', 'template',
  'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

**Root cause**

Hai field immutable bị values mới cố sửa:

1. `storageClassName` của PVC — values để trống, prod dùng `local-minio`/`local-mysql`/`local-redis`
2. `serviceName` của StatefulSet — tên mình thêm ở Issue 4 **khác** tên prod đang dùng

**Bằng chứng**

```
kubectl -n ragflow get sts -o custom-columns='NAME:.metadata.name,SVCNAME:.spec.serviceName'
```

| StatefulSet | Prod đang có | Đã thêm nhầm |
|---|---|---|
| `ragflow-minio` | `ragflow-minio-headless` | `ragflow-minio` |
| `ragflow-mysql` | `mysql` | `ragflow-mysql` |
| `ragflow-redis` | `ragflow-redis` | (đúng) |

```
kubectl -n ragflow get pvc -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage'
```

**Giải pháp cuối** (commit `5170c52`)

Sửa template + values cho khớp chính xác prod. Nguyên tắc: **đọc cấu hình thực tế trong
cluster, không tin file values**.

---

### Issue 6 — minio `ImagePullBackOff`

**Triệu chứng**: `ragflow-minio-0` `ImagePullBackOff`, trong khi mysql/redis Running bình thường.

**Root cause**

Chart v0.26.4 upstream đổi minio image:
`quay.io/minio/minio:RELEASE.2023-12-20` → `pgsty/minio:RELEASE.2026-03-25`

Cluster air-gapped, node chỉ cache bản cũ.

**Bằng chứng** (chạy trên node07)

```
sudo /usr/local/bin/ctr -n k8s.io images ls | grep -E "mysql|minio|valkey"
```

| Service | Node có | Chart yêu cầu | Khớp |
|---|---|---|---|
| minio | `docker.io/minio/minio:RELEASE.2025-06-13T11-33-47Z` | `pgsty/minio:RELEASE.2026-03-25...` | ✗ |
| mysql | `docker.io/library/mysql:8.0.39` | `mysql:8.0.39` | ✓ |
| redis | `docker.io/valkey/valkey:8` | `valkey/valkey:8` | ✓ |

**Giải pháp cuối** (commit `411a3a9`): giữ image đã cache trong values.

---

### Issue 7 — mysql/minio/redis Pending "lúc được lúc không"

**Triệu chứng**

3 pod Pending, có lúc tự Running rồi lại Pending. Events:

```
0/8 nodes are available:
  1 node(s) had taint {node.kubernetes.io/disk-pressure: }, that the pod didn't tolerate,
  3 node(s) had taint {node-role.kubernetes.io/master: }, that the pod didn't tolerate,
  4 node(s) didn't match Pod's node affinity/selector.
```

**Root cause**

Node07 hết dung lượng đĩa → kubelet tự bật `DiskPressure=True` → gắn taint
`node.kubernetes.io/disk-pressure:NoSchedule`. mysql/minio/redis bị ghim ở node07
bởi local PV (`nodeAffinity: ragflow-target In [true]`) → không schedule được.

Taint dao động theo dung lượng → giải thích hiện tượng "lúc được lúc không".

**Bằng chứng**

```
kubectl describe node vrp-kubeengine07 | grep -A5 "Taints:"
```
→ `Taints: node.kubernetes.io/disk-pressure:NoSchedule`

```
kubectl get nodes -o json | python3 -c "import json,sys; [print(f\"{n['metadata']['name']}: {c['type']}={c['status']}\") for n in json.load(sys.stdin)['items'] for c in n['status']['conditions'] if c['type']=='DiskPressure' and c['status']=='True']"
```
→ `vrp-kubeengine07: DiskPressure=True - kubelet has disk pressure`

Thủ phạm chiếm đĩa:

```
sudo /usr/local/bin/ctr -n k8s.io images ls | grep -i ragflow
```
→ `infiniflow/ragflow:v0.24.0` — **7.2 GiB** (trong khi mysql+minio+redis chỉ ~840MB)

**Đã thử — các chẩn đoán sai trước khi tìm ra**

| Giả thuyết | Kết quả |
|---|---|
| Node07 thiếu CPU/RAM | ❌ Sai — chỉ dùng 1% CPU, 3% RAM |
| PV nodeAffinity xung đột với nodeSelector | ❌ Sai — cả 3 PV đều `ragflow-target In [true]`, khớp node07 |
| StatefulSet mysql dùng `volumeClaimTemplates` khác minio | ❌ Sai — cả hai đều rỗng, dùng PVC tĩnh |
| Node07 bị taint hoặc `Unschedulable` | ✅ Đúng — nhưng phải check **đúng lúc** taint đang bật |

**Giải pháp cuối** (chạy trên node07)

```
sudo /usr/local/bin/ctr -n k8s.io images rm infiniflow/ragflow:v0.24.0
```

```
sudo crictl rmi --prune
```

Kubelet tự gỡ taint sau 1-2 phút → pod tự schedule.

---

### Issue 8 — Pod ragflow `Init:ImagePullBackOff` trên node07

**Triệu chứng**: sau khi dọn image ở Issue 7, pod ragflow mới lại rơi vào node07 → không có image.

**Root cause — vòng luẩn quẩn**

```
Copy image ragflow len node07  -> dia day -> disk-pressure -> mysql/minio/redis Pending
Xoa image khoi node07          -> het disk-pressure -> pod ragflow lai roi vao day -> khong co image
```

Affinity cũ chỉ loại `vrp-kubeengine04`, node07 vẫn hợp lệ cho ragflow.

**Giải pháp cuối** (commit `28eb246`)

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: NotIn
            values:
              - vrp-kubeengine04    # tai nguyen sap can kiet
              - vrp-kubeengine07    # danh rieng cho mysql/minio/redis
```

---

## 4. Issue chưa xong

### Issue 9 — ⚠️ WORKAROUND: `LookupError: Instance default not found`

**Triệu chứng**

Retrieval/embedding fail trên UI:

```
LookupError('Instance default not found for model
qwen3-8b-embedding___OpenAI-API@OpenAI-API-Compatible.')
```

**Root cause — bug upstream đã được báo cáo**

GitHub issue **[#17578](https://github.com/infiniflow/ragflow/issues/17578)**
— mở 2026-07-30, **còn `open`**, maintainer `Yannnnnnny` trả lời 2026-07-31:
*"We will look into these migration issues and improve the upgrade experience. Contributions and PRs are welcome!"*

Issue mô tả 3 lỗ hổng của `mysql_migration.py` khi nâng v0.25.5 → v0.26.4:

| Gap | Triệu chứng | Nguyên nhân |
|---|---|---|
| 1 | `ValueError: url cannot be None` | Không migrate `tenant_llm.api_base` → `tenant_model_instance.extra` dạng `{"base_url":...}` |
| 2 | `RuntimeError: Unknown model type: vision` | Không map `vision` → `image2text` |
| **3** | **`LookupError: Instance default not found`** ← của ta | `instance_name` hardcode `"default"` gây trùng; **thiếu UNIQUE constraint** trên `(provider_id, instance_name)` |

**Cơ chế cụ thể** (`api/db/joint_services/tenant_model_service.py`):

```python
# split_model_name(): rsplit("@", 2)
# "qwen3-8b-embedding___OpenAI-API@OpenAI-API-Compatible" chi co 1 dau @
#   -> pure_model_name = "qwen3-8b-embedding___OpenAI-API"
#   -> provider_name   = "OpenAI-API-Compatible"
#   -> instance_name   = "default"    <- GAN MAC DINH

# _resolve_instance_for_model() dong 214-235:
instance_obj = get_by_provider_id_and_instance_name(provider_obj.id, "default")
if instance_obj: return instance_obj          # khong thay
active_instances = [... if status == ACTIVE]
if len(active_instances) == 1:                # fallback CHI hoat dong khi dung 1
    return active_instances[0]
raise LookupError(f"Instance {instance_name} not found for model {model_name}.")
```

Ban đầu có **3 instance ACTIVE** cùng provider → fallback thất bại.

**Bằng chứng**

```
kubectl -n ragflow exec $POD_MYSQL -- mysql -uroot -p"$MYSQL_PW" -D rag_flow -t -e "SELECT id, provider_id, instance_name, status FROM tenant_model_instance;"
```

Trước fix: 3 dòng (`qwen3-8b-embedding`, `Test`, `qwen3.5-35b-a3b`) — tất cả `active`, cùng `provider_id`.

**Đã thử**

| Phương án | Kết quả |
|---|---|
| Add lại model qua UI | ❌ Không đủ — UI tạo instance tên mới, KB cũ vẫn trỏ format cũ |
| Xóa hết instance rồi add lại 1 cái (`Kien_default`) | ⚠️ Gần đúng — nhưng `model_name` UI lưu là tên thuần, KB cần tên có `___OpenAI-API` |
| Query `SELECT ... status FROM tenant_model_provider` | ❌ **Chẩn đoán sai** — bảng không có cột `status`, `2>/dev/null` nuốt lỗi SQL → tưởng bảng rỗng |
| UPDATE `tenant_model.model_name` thành `qwen3-8b-embedding___OpenAI-API` | ⚠️ Retrieval chạy, **nhưng UI Model Providers báo lỗi** `102 Model 'qwen3-8b-embedding' not found` |
| UPDATE `knowledgebase.embd_id` sang format mới | ⏸️ Chưa làm — user quyết định giữ nguyên vì đang chạy được |

**Trạng thái hiện tại**

```
tenant_model_provider:  1 dong  (OpenAI-API-Compatible, tenant 22cdb01e486a11f1ac9749e86cfe939a)
tenant_model_instance:  1 dong  (qwen3-8b-embedding, active,
                                 extra={"base_url":"http://10.208.137.53:8992/","region":"default"})
tenant_model:           1 dong  (model_name=qwen3-8b-embedding___OpenAI-API, embedding, active,
                                 extra={"max_tokens":8192,"is_tools":false})
knowledgebase (20 KB):  embd_id=qwen3-8b-embedding___OpenAI-API@OpenAI-API-Compatible
```

**Vì sao là WORKAROUND, không phải FIXED**

- State nằm **ngoài Git/Helm** — sửa trực tiếp MySQL, không reproduce được từ chart
- Bug upstream chưa có bản vá
- `model_name` bị đặt lệch chuẩn v0.26 (có hậu tố `___OpenAI-API`) → **UI Model Providers báo lỗi**
- Nâng version tiếp theo sẽ **tái phát**

**Còn tồn đọng**

1. UI Settings → Model Providers hiển thị lỗi `102 Model 'qwen3-8b-embedding' not found for provider 'OpenAI-API-Compatible'` → **không sửa được model qua UI**, phải dùng SQL
2. Chỉ được có **đúng 1 instance ACTIVE** — thêm model thứ 2 sẽ làm fallback hỏng lại
3. Gap 1 và Gap 2 của issue #17578 chưa gặp nhưng có thể lộ ra khi dùng VLM/vision model

**Hướng xử lý tiếp**

1. **(Làm được ngay, không downtime)** Chuẩn hoá dữ liệu sang format v0.26 — sửa KB thay vì sửa model:
   ```
   QQ "CREATE TABLE knowledgebase_bak_20260731 AS SELECT * FROM knowledgebase;"
   ```
   ```
   QQ "UPDATE tenant_model SET model_name='qwen3-8b-embedding' WHERE id='5d40793e8cd511f18d5d67e68cb92881';"
   ```
   ```
   QQ "UPDATE knowledgebase SET embd_id='qwen3-8b-embedding@OpenAI-API-Compatible' WHERE embd_id='qwen3-8b-embedding___OpenAI-API@OpenAI-API-Compatible';"
   ```
   Sau đó UI hoạt động lại bình thường. **Vector trong ES không bị ảnh hưởng** — `embd_id` chỉ là
   con trỏ tới cấu hình, model thật gọi tới endpoint vẫn là `qwen3-8b-embedding` cùng số chiều.

2. **(Ngắn hạn)** Thêm UNIQUE constraint để tránh tái phát:
   ```
   QQ "ALTER TABLE tenant_model_instance ADD UNIQUE KEY uk_provider_instance (provider_id, instance_name);"
   ```

3. **(Dài hạn)** Theo dõi issue #17578, nâng version khi upstream có fix.

---

### Issue 10 — 🔶 OPEN: Query chậm 13-15s trên KB 141k doc

**Bối cảnh**: đây là issue #4 từ phiên trước, xem `investigate_issue_4/04-root-cause.md`.

**Tiến triển**

- ✅ Đã bác bỏ giả thuyết "thiếu `minimum_should_match`" bằng số liệu:
  ES **có** áp dụng đúng tham số, nhưng ép lên 100% cũng chỉ giảm hit từ 141,340 → 140,469 (99.4%)
- ✅ Xác định nguyên nhân thật: `rag_tokenizer` tách câu thành ít mệnh đề OR, một số chứa hư từ
  (`(v à)^1.0`) khớp gần hết corpus
- ✅ Code v0.26 **đã có sẵn** `minimum_should_match` (dòng 92/165/229 `rag/nlp/query.py`) — upstream tự fix
- ✅ AI engineer đã custom image v0.26 sửa phần build query → **user báo time đã giảm đáng kể**

**Còn tồn đọng**: chưa đo lại số liệu sau khi lên v0.26.4 + image custom mới.

**Hướng xử lý tiếp**

1. Chạy lại `investigate_issue_4/measure3.sh` để có số liệu mới
2. So sánh với baseline cũ (UI ~13s, ES `_search` ~3.2s)
3. Cập nhật `04-root-cause.md` mục 10 với kết quả

---

## 5. Bài học

### Helm / Kubernetes

| Bài học | Cách phát hiện sớm |
|---|---|
| `values.yaml` nhận **mọi** key, nhưng chỉ key mà template tham chiếu mới có tác dụng. Helm không cảnh báo | `helm template . -s templates/x.yaml \| grep <thu-vua-them>` — không thấy thì vô nghĩa |
| Chart v0.24 và v0.26 **hardcode** `replicas: 1`, không đọc từ values | `grep -n replicas templates/ragflow.yaml` |
| Chart không đọc `nodePort`, `nodeSelector` cho mysql/minio/redis | Render rồi đối chiếu, đừng tin file values |
| `serviceName`, `storageClassName` là **immutable** — phải khớp chính xác cái đang chạy | `kubectl get sts -o custom-columns='NAME:.metadata.name,SVCNAME:.spec.serviceName'` |
| Chart và image có **hợp đồng ngầm**: file nào entrypoint tự tạo/ghi thì chart không được mount đè | Đọc `entrypoint.sh` của image mới trước khi nâng version |
| StatefulSet không tự rollout như Deployment — pod hỏng có thể chặn cả chuỗi | `kubectl delete pod <sts>-0` để force |

### Chẩn đoán

| Bài học | Cách phát hiện sớm |
|---|---|
| Pod `1/1 Running` ≠ app Ready. Không có readinessProbe thì k8s không biết app kẹt | `exec ... curl 127.0.0.1:9380` — `000` = chưa listen |
| Endpoint nhẹ (`/logout`) làm **control probe** hoàn hảo: nó chậm → bottleneck không ở downstream | Đo latency nhiều tầng, đừng chỉ đo tầng cuối |
| `2>/dev/null` trong hàm tiện ích nuốt luôn **lỗi SQL thật** → "cột sai" biến thành "bảng rỗng" | Query trả rỗng bất ngờ → chạy lại **không có** `2>/dev/null` |
| Sed patch không khớp vẫn exit 0 → patch trượt âm thầm, pod vẫn Running với code chưa patch | Thêm `grep -q '<expected>' \|\| exit 1` sau mỗi sed |
| `total_hits` mặc định bị cap ở 10,000 (`relation: gte`) → không phân biệt được "lọc có tác dụng" với "chạm trần đếm" | Dùng `track_total_hits: true, size: 0` |
| Test 1-replica **không phát hiện** được lỗi của prod N-replica: scale mở rộng không gian trạng thái | Test với cùng số replica như prod |

### Latent failure — chủ đề lặp lại 3 lần trong phiên

| Trường hợp | Ẩn vì | Lộ ra khi |
|---|---|---|
| Quyền ES `monitor` bị gỡ | App chỉ gọi `GET /` **một lần lúc boot**; vận hành hàng ngày chỉ dùng `_search`/`_bulk` (index-level) | Restart pod |
| `serviceName` thiếu ở StatefulSet | k8s cũ validate lỏng, resource đã tạo được từ trước | `helm upgrade` trên cluster mới hơn |
| Image ragflow 7.2GB trên node07 | Đĩa chưa vượt ngưỡng | Copy thêm image → `disk-pressure` |

> **Nguyên tắc**: một service chỉ thực sự healthy khi nó **restart được**.
> Uptime dài không chứng minh cấu hình đúng.

### Air-gapped

| Bài học | Cách phát hiện sớm |
|---|---|
| Nâng chart = có thể đổi image repository/tag → node không có → `ImagePullBackOff` | `diff` values cũ/mới phần `image:` trước khi upgrade |
| Image ragflow ~7-8GB/bản. Copy lên **tất cả** node worker phải tính trước dung lượng | `df -h /var/lib/containerd` trên từng node |
| Tag chứa `latest` (kể cả `v1-latest`) là **mutable** — cùng tên khác nội dung giữa các node | Yêu cầu tag theo version cụ thể |
| `IfNotPresent` ≠ không bao giờ pull. Nó **thử pull** nếu node chưa có → `ImagePullBackOff` (khác `Never` → `ErrImageNeverPull`) | Đếm node có image: `for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do ...; done` |

### RagFlow

| Bài học |
|---|
| 1 container chạy **3 process**: `ragflow_server.py` (API) + `task_executor.py` + `sync_data_source.py`. Scale replicas là nhân cả 3 |
| `task_executor` dùng **Redis Stream Consumer Group** → an toàn tuyệt đối khi scale, không bao giờ 2 pod xử lý 1 file |
| `sync_data_source` **không có** cơ chế chống trùng — poll toàn bộ bảng rồi tự chạy. Chỉ an toàn khi bảng `connector` rỗng (đã verify: 0 dòng) |
| API là **Quart (ASGI)** chạy bằng `app.run()` — single-process. Log tự cảnh báo: *"Please use an ASGI server (e.g. Hypercorn) directly in production"* |
| `___` là separator cũ (v0.24): `<model>___<api_name>`. Runtime cắt bằng `split("___")[0]`. v0.26 dùng tên thuần |

---

## 6. Nợ kỹ thuật

| Nợ | Nguồn | Rủi ro nếu bỏ quên |
|---|---|---|
| Model config sửa trực tiếp MySQL, không có trong Git/Helm | Issue 9 | Nâng version/restore DB → mất, retrieval chết lại |
| `model_name` lệch chuẩn v0.26 (`___OpenAI-API`) | Issue 9 | UI Model Providers không dùng được |
| Chỉ được 1 instance ACTIVE | Bug #17578 Gap 3 | Thêm model thứ 2 → hỏng lại |
| `codePatch` initContainer vẫn bật, patch `minimum_should_match` | values.yaml | Code v0.26 đã có sẵn → patch có thể thừa; sed trượt âm thầm |
| Patch `es_conn.py timeout` đã comment nhưng chưa xoá hẳn | values.yaml | Gây hiểu nhầm |
| Không có readinessProbe | Chart upstream | Pod `1/1 Running` khi app chưa sẵn sàng → 502 khó chẩn đoán |
| PVC `ragflow-es-data` 20Gi đã xoá (ES nội bộ) | `elasticsearch.enabled: false` | Không có (đã xác nhận pod Pending 65 ngày, không dùng) |
| Chart custom lệch upstream 6 điểm | commit 615bca8..28eb246 | Nâng version sau phải port lại |

---

## 7. Việc tiếp theo

### Ngay lập tức

- [ ] Đo lại latency query sau khi lên v0.26.4 (`investigate_issue_4/measure3.sh`)
- [ ] Verify `codePatch` còn khớp code v0.26 không:
      ```
      kubectl -n ragflow exec $POD -c ragflow -- grep -n minimum_should_match /ragflow/rag/nlp/query.py
      ```
- [ ] Kiểm tra dung lượng các node worker sau khi copy image v2-latest:
      ```
      for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do echo "$n"; done
      ```

### Ngắn hạn

- [ ] Chuẩn hoá `embd_id` sang format v0.26 (Issue 9, hướng 1) — trả UI về hoạt động bình thường
- [ ] Thêm UNIQUE constraint `(provider_id, instance_name)`
- [ ] Thêm `readinessProbe` vào chart (probe `:9380`) — sẽ rút ngắn mọi lần debug 502 sau này
- [ ] Bỏ `codePatch` nếu xác nhận code v0.26 đã có sẵn fix
- [ ] Dọn image ragflow cũ trên **tất cả** node (không chỉ node07)

### Dài hạn

- [ ] Theo dõi issue #17578, nâng version khi upstream fix migration
- [ ] Cân nhắc `API_PROXY_SCHEME: "go"` hoặc `"hybrid"` — Go server xử lý concurrency tốt hơn
      Python single-process, giải quyết mục tiêu "chịu tải nhiều bên gọi API" mà không cần Hypercorn.
      ❓ Chưa xác minh Go server đã đủ endpoint chưa, và patch Python có còn tác dụng không
- [ ] Tách 3 process thành 3 Deployment riêng để scale độc lập (web / task_executor / datasync)
- [ ] Yêu cầu AI engineer tag image theo version cụ thể thay vì `*-latest`

---

## 8. Rủi ro còn lại

| Rủi ro | Mức độ | Giảm thiểu |
|---|---|---|
| Model config mất khi restore DB / nâng version | **Cao** | Chuẩn hoá format v0.26 + ghi lại SQL vào repo |
| Thêm model thứ 2 làm hỏng retrieval | **Cao** | Kiểm tra `SELECT COUNT(*) FROM tenant_model_instance WHERE status='active'` phải = 1 |
| Node worker hết đĩa do image ragflow tích tụ | Trung bình | Dọn định kỳ `crictl rmi --prune`; giám sát `DiskPressure` |
| Ai đó thêm Connector qua UI → 3 pod cùng sync trùng | Trung bình | Bảng `connector` hiện rỗng; cân nhắc `--disable-datasync` |
| Node07 lại disk-pressure → mất mysql/minio/redis | Trung bình | Đã loại node07 khỏi affinity ragflow (commit 28eb246) |
| Single-process Quart → 1 request nặng chặn cả pod | Trung bình | Đã có 3 replicas chia tải; cân nhắc scheme `go`/`hybrid` |
| Chart custom lệch upstream, nâng version phải port lại | Thấp | Commit message ghi rõ từng điểm custom |

---

## Phụ lục A — Lệnh hay dùng

Set biến môi trường:

```
NS=ragflow
```

```
POD=$(kubectl -n $NS get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
```

```
POD_MYSQL=$(kubectl -n $NS get pods --no-headers | grep -i mysql | awk '{print $1}' | head -1)
```

```
MYSQL_PW=$(kubectl -n $NS get secret ragflow-env-config -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
```

Hàm query MySQL (**không** dùng `2>/dev/null` — nó nuốt lỗi SQL):

```
QQ() { kubectl -n $NS exec $POD_MYSQL -- mysql -uroot -p"$MYSQL_PW" -D rag_flow -t -e "$1"; }
```

Kiểm tra app đã listen chưa:

```
kubectl -n $NS exec $POD -c ragflow -- curl -s -o /dev/null -w "http_code=%{http_code} time=%{time_total}s\n" http://127.0.0.1:9380/api/v1/users/me
```

Kiểm tra quyền ES:

```
kubectl -n $NS exec $POD -c ragflow -- curl -sk -u "aihub_prod:***" -o /dev/null -w "ES_GET_root=%{http_code}\n" https://10.211.145.107:8051/
```

Đọc file trong image bị crash (override entrypoint):

```
kubectl -n $NS run tmp-inspect --restart=Never --image=$IMG --overrides='{"spec":{"containers":[{"name":"tmp-inspect","image":"'$IMG'","imagePullPolicy":"IfNotPresent","command":["sleep","3600"]}]}}'
```

Kiểm tra node nào có image (chạy trên node):

```
sudo /usr/local/bin/ctr -n k8s.io images ls | grep -i ragflow
```

Dọn image:

```
sudo crictl rmi --prune
```

Verify chart trước khi deploy:

```
helm template test . -s templates/ragflow.yaml | grep -E "replicas:|nodePort:|serviceName:|nodeSelector" -A2
```

---

## Phụ lục B — Commit chart

| Commit | Nội dung |
|---|---|
| `615bca8` | Thêm chart v0.26.4 + port 6 tuỳ chỉnh (replicas, affinity, nodePort, codePatch+verify, tắt ES nội bộ, API_PROXY_SCHEME) |
| `e3d4af5` | Thêm `serviceName` vào 5 StatefulSet |
| `5170c52` | Khớp `storageClassName`/`serviceName` với prod + nodeSelector cho mysql/minio/redis |
| `411a3a9` | Giữ image minio cũ đã cache (air-gapped) |
| `28eb246` | Loại node07 khỏi affinity ragflow |

Branch: `worktree-update-investigate-notes`
