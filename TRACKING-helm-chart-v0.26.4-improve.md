# TRACKING — Cải thiện Helm chart RAGFlow v0.26.4

> Bắt đầu 2026-08-21, sau khi xử lý xong disk pressure cụm vRP.
> Liên quan: `TRACKING-vrp-disk-pressure.md` (vụ disk là hệ quả một phần của các thiếu sót ở đây).

## 1. Bối cảnh

Kiên nêu 3 issue. Rà toàn bộ chart tìm thêm được 9 issue nữa. Đợt này làm **5 issue**
(3 của Kiên + PDB + strategy), phần còn lại ghi ở mục 4.

## 2. ✅ ĐÃ LÀM (đợt 1)

### 2.1 — `resources` request/limit (Kiên nêu)

**Vấn đề:** `values.yaml` để `resources:` **rỗng** cho ragflow, minio, mysql, redis, infinity.
(Chỉ elasticsearch/opensearch có, nhưng ES `enabled: false` nên vô dụng.)

⭐ **Hệ quả không chỉ là hiệu năng — đây là MỘT NGUYÊN NHÂN CỦA VỤ DISK vừa xử lý:**

```
Pod khong co requests
   └─> QoS class = BestEffort
        └─> node vao DiskPressure
             └─> kubelet evict BestEffort DAU TIEN
                  └─> ~20 pod litellm/signoz Evicted (co pod ton dong 24 ngay)
                       └─> moi pod Evicted de lai mot SNAPSHOT container khong duoc don
                            └─> gop vao 22G snapshots do duoc tren .51
                                 └─> disk day hon => vong lap tu nuoi
```

**Đã đặt:**
```yaml
resources:
  requests: {cpu: "2", memory: 4Gi, ephemeral-storage: 2Gi}
  limits:   {cpu: "4", memory: 8Gi, ephemeral-storage: 10Gi}
```

- `requests` ⟹ QoS lên **Burstable**, thoát khỏi nhóm bị evict đầu tiên.
- ⭐ `ephemeral-storage` ⟹ **lớp bảo vệ trực tiếp cho vấn đề disk**: pod ghi vượt 10Gi
  thì kubelet evict **riêng pod đó**, thay vì để cả node vào DiskPressure.
- Con số dựa trên node 8C/16G; 3 replicas × 2C/4Gi = 6C/12Gi đặt chỗ, vừa với cụm.
- ⚠️ **Nên đo `kubectl top pod` sau vài ngày và chỉnh theo p95 thực tế.**

### 2.2 — `readinessProbe` / `livenessProbe` / `startupProbe` (Kiên nêu — nguyên nhân 502)

**Vấn đề:** `ragflow.yaml` **không có probe nào**. Cơ chế 502 đúng như Kiên mô tả:

```
Pod start -> container chay -> k8s danh dau Ready NGAY (khong co gi de kiem)
   -> Service them pod vao Endpoints -> nginx forward request vao
      -> RAGFlow chua ket noi duoc MySQL/ES/Redis/MinIO -> 502
```

Nặng hơn khi rolling update: pod cũ bị giết ngay khi pod mới báo "Ready" (thực chất chưa
sẵn sàng) ⟹ **có thời điểm không pod nào phục vụ được**.

**Endpoint LẤY TỪ SOURCE `ragflow-0.26.4/` trong repo, không đoán:**

| Nguồn | Nội dung |
|---|---|
| `api/apps/restful_apis/system_api.py:229` | `@manager.route("/system/healthz")` |
| `api/apps/restful_apis/system_api.py:38` | `@manager.route("/system/ping")` |
| `api/apps/__init__.py:363` | `url_prefix = "/api/v1"` cho `restful_apis` |
| ⟹ | `/api/v1/system/healthz`, `/api/v1/system/ping` |

| Endpoint | Auth | Kiểm gì | Dùng |
|---|---|---|---|
| `/api/v1/system/healthz` | ❌ **không** `@login_required` | `run_health_checks()` → **db + redis + doc_engine + storage** | **readiness** |
| `/api/v1/system/ping` | ❌ không | trả `"pong"` — Flask còn sống | **liveness / startup** |
| `/api/v1/system/version` | ✅ **có `ApiKeyAuth`** | version | ❌ **không dùng được làm probe** |

`healthz` trả **200 nếu tất cả OK, 500 nếu bất kỳ cái nào hỏng**
(`system_api.py:229-232`) — đúng chuẩn readinessProbe, không cần xử lý thêm.

⭐ **VÌ SAO readiness dùng `healthz` còn liveness dùng `ping` — ranh giới quan trọng:**

| Probe | Câu hỏi | Nếu ES ngoài cụm chập chờn |
|---|---|---|
| **readiness** = `healthz` | "có phục vụ được không?" | Pod bị **rút khỏi Endpoints**, tự quay lại khi ES hồi. **Không restart.** ✅ |
| **liveness** = `ping` | "process có chết không?" | Không ảnh hưởng — ping vẫn trả pong ✅ |
| ❌ nếu liveness dùng `healthz` | | kubelet **GIẾT VÀ RESTART pod** dù lỗi nằm ở ES ⟹ **restart loop vô nghĩa**, làm tình hình tệ hơn 🔴 |

⟹ **Đừng gộp hai probe vào một endpoint.**

`startupProbe` (30×10s = tối đa 5 phút): trong lúc chưa pass, liveness/readiness **bị tạm dừng**
⟹ tránh vòng lặp giết-restart lúc boot. Cần thiết vì image 7-8GB, khởi động chậm.

### 2.3 — nginx `access_log` ăn disk (Kiên nêu)

**Vấn đề:** `ragflow_config.yaml:93` — `access_log /var/log/nginx/access.log main;`
Ghi **mọi request**, **không rotate**, **không giới hạn**. File nằm trong filesystem container
(ephemeral) ⟹ tính vào disk **node**.

(Trớ trêu: dòng 62 có `access_log off;` cho một location, nhưng dòng 93 bật global.)

**Đã sửa:** `access_log off;`, **giữ nguyên** `error_log`.

**Đánh đổi đã cân nhắc:** mất log request. Chấp nhận được vì access_log của RAGFlow
**không có field duration** — bài học phiên 2026-08-18: cột `270774` từng bị đọc nhầm thành
"270.8 giây", thực ra là **response size**. Giá trị debug thấp, chi phí disk là thật.
Muốn bật lại để điều tra: đổi thành `/dev/stdout` (kubelet tự rotate), **không** ghi ra file.

### 2.4 — PodDisruptionBudget (mình phát hiện)

**Vấn đề:** `redis.yaml` **CÓ** PDB, `ragflow.yaml` **KHÔNG**.
⟹ `kubectl drain` một node (bảo trì, nở disk, upgrade) có thể xóa **cả 3 pod ragflow cùng lúc**
nếu chúng tình cờ nằm chung node. `podAntiAffinity` chỉ là **`preferred`** (mềm) nên
**không bảo đảm** 3 pod ở 3 node khác nhau.

**Đã thêm:** `minAvailable: 2` với `replicas: 3` ⟹ drain lần lượt từng node vẫn còn 2 pod phục vụ.

⚠️ **Giới hạn cần biết:** PDB **chỉ chặn eviction CÓ CHỦ ĐÍCH** (drain, descheduler).
**KHÔNG chặn** được kubelet evict do DiskPressure/MemoryPressure — đó là eviction **cưỡng bức**
ở tầng node. Chống loại đó bằng `resources.requests` (mục 2.1).

### 2.5 — Rolling update `strategy` (mình phát hiện)

**Vấn đề:** `strategy:` để trống ⟹ mặc định `maxUnavailable: 25%`, `maxSurge: 25%`.
Với `replicas: 3`, 25% làm tròn lên = 1 ⟹ cho phép 1 pod chết trong lúc update.
Kết hợp với **không có readinessProbe** ⟹ 502 suốt quá trình deploy.

**Đã đặt:** `maxUnavailable: 0`, `maxSurge: 1` ⟹ tạo pod mới, **đợi nó Ready thật sự**
(qua `healthz`) rồi mới giết pod cũ.

**Đánh đổi:** update lâu hơn (tuần tự), cần đủ tài nguyên cho `replicas+1` pod trong lúc update.
Đổi lại: **không downtime**.

### 2.6 — Phụ: `terminationGracePeriodSeconds` + `emptyDir.sizeLimit`

- `terminationGracePeriodSeconds: 60` (mặc định k8s là 30s). Pod chạy `task_executor` đang
  xử lý file ingest ⟹ cắt giữa chừng để lại task dở dang. Redis đã có 60s từ trước.
- `emptyDir.sizeLimit: 256Mi` cho `code-patch-volume` — emptyDir mặc định **không giới hạn**,
  ghi bao nhiêu cũng tính vào disk node.

### 2.7 Verify

```
$ helm lint helm_ragflow_v0.26.4
1 chart(s) linted, 0 chart(s) failed

$ helm template test helm_ragflow_v0.26.4 | grep -A8 readinessProbe
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /api/v1/system/healthz
            port: 9380
          initialDelaySeconds: 20
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 5
```
Đã verify render đúng: `resources`, `readinessProbe`, `livenessProbe`, `startupProbe`,
`strategy` (maxUnavailable 0 / maxSurge 1), `PodDisruptionBudget` (minAvailable 2),
`emptyDir.sizeLimit: 256Mi`, `terminationGracePeriodSeconds: 60`, `access_log off`.

## 3. ⚠️ CẦN LÀM TRƯỚC KHI DEPLOY

- [ ] ⭐ **Verify endpoint trên pod THẬT** — source nói `/api/v1/system/healthz` không cần auth,
      nhưng phải xác nhận trên image **custom** đang chạy (image lệch upstream, đã có tiền lệ
      phát hiện `pyvi` chỉ nhờ đọc trong container):
      ```
      kubectl -n ragflow exec <pod> -c ragflow -- curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9380/api/v1/system/healthz
      ```
      Phải ra **200**. Nếu ra 401/404 ⟹ **dừng lại**, probe sai sẽ làm pod không bao giờ Ready
      ⟹ **toàn bộ dịch vụ sập**. Đây là rủi ro lớn nhất của đợt patch này.
- [ ] Kiểm cụm còn đủ tài nguyên cho `maxSurge: 1` (pod thứ 4 tạm thời) — `.51` vừa mới thoát
      DiskPressure, `.54` vẫn 84%.
- [ ] `helm diff upgrade` trước khi apply thật.

## 4. 📋 ISSUE CÒN LẠI (chưa làm, ghi để không quên)

| # | Vấn đề | Mức | Ghi chú |
|---|---|---|---|
| 6 | 🔴 **Secret plaintext trong `values.yaml`** | Cao | Password ES `j1#&VC64Zo`, MySQL, MinIO, Redis hardcode — **đã commit vào git**. Cộng nợ cũ: Bearer token trong history PR #8. ⟹ **Cần rotate + tách ra Secret/Vault** |
| 7 | `priorityClassName` không có | TB | Không phân biệt pod nào được giữ khi node cạn tài nguyên |
| 9 | `TZ: "Asia/Shanghai"` | TB | **Sai múi giờ VN** (+7 vs +8) ⟹ log lệch 1 giờ, gây khó khi đối chiếu sự cố theo thời gian |
| 10 | Không có `securityContext` cho ragflow | TB | Container chạy root. ES/opensearch/infinity **có**, ragflow **không** |
| 12 | 3 process trong 1 container | TB | `ragflow_server` + `task_executor` + `sync_data_source` chung pod — đã ghi trong root cause cũ (`TRACKING-api-retrieval-latency.md`). Tách ra deployment riêng ⟹ cô lập lỗi + scale độc lập |
| 13 | Các service khác cũng thiếu resources/probe | TB | minio, mysql, redis, infinity đều `resources:` rỗng. minio/mysql **không có probe nào**. Cùng vấn đề QoS BestEffort như ragflow |

## 5. Câu hỏi còn treo

1. `TZ: "Asia/Shanghai"` — đổi sang `Asia/Ho_Chi_Minh` được không, hay có ràng buộc gì?
2. Có muốn tách secret ra Vault/SealedSecret không, hay tạm chấp nhận và chỉ rotate?
3. `use_raptor` + `use_graphrag` đang bật trên KB 1.9M doc — nghiệp vụ có thực sự dùng không?
   (Từ `TRACKING-api-retrieval-latency.md`, vẫn chưa ai trả lời.)
