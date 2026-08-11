# PLAN — Áp dụng patch `get_root_folder()` (Issue U1)

> **Trạng thái**: ✅ **ĐÃ DEPLOY THÀNH CÔNG** (10/08/2026 16:50, revision 62→63)
> **Đã kiểm chứng sau 12 GIỜ TẢI THẬT** (11/08) — xem mục 5b:
> query `parent_id = id` vắng mặt hoàn toàn khỏi top query; đường ghi trung bình **0.386s**;
> load avg node06 **7.98 → 3.86**.
> **Ngày soạn**: 10/08/2026
> **Issue gốc**: xem `TRACKING-upload-document-25s.md` (root cause + số liệu đo)
> **Phạm vi**: sửa **1 dòng** code RagFlow qua cơ chế `codePatch` có sẵn trong chart

---

## 0. Tóm tắt — đọc 30 giây

| Hạng mục | Nội dung |
|---|---|
| Sửa gì | `file_service.py:244` — đổi `parent_id == id` thành `name == "/"` |
| Vì sao | So 2 cột cùng dòng không dùng được index → full-scan 631.585 dòng → **18s/lần**, chạy **2 lần/upload** |
| Nhanh hơn bao nhiêu | **18.02s → 0.00s** (đo thật trên production, mục 3.5 TRACKING) |
| Cách áp dụng | `initContainer` + `sed` (cơ chế `codePatch` chart đã có sẵn, **không phải postStart**) |
| Tác động DB | ❌ **Không** — không đổi schema, không sửa dữ liệu, không đánh index |
| Đối tác có cần dừng đẩy dữ liệu? | ❌ **Không cần** |
| Downtime | ⚠️ Không phải "restart pod" — là **RollingUpdate** của Deployment 3 replicas. Xem mục 1b |
| Rollback | Sửa `values.yaml` bỏ block patch → `helm upgrade`. Image gốc không bị đụng |

---

## 1. Vì sao chọn `initContainer`, KHÔNG chọn `postStart`

*(Kiên hỏi 10/08: "chọn hướng là sed trong postStart hay initContainer?")*

Chart **đã chốt `initContainer` từ trước**, lý do ghi tại `values.yaml:187-190`. Đây là lựa
chọn đúng, giữ nguyên:

| Tiêu chí | `postStart` | `initContainer` ✅ |
|---|---|---|
| Thứ tự chạy | **Song song** với ENTRYPOINT — K8s không đảm bảo cái nào trước | Chạy xong (**exit 0**) mới tới container chính |
| Rủi ro chí mạng | Python có thể **đã import xong file cũ** trước khi sed kịp sửa → patch vô tác dụng nhưng pod vẫn `Running` | Không thể xảy ra — file đã patch chắc chắn có trên đĩa trước khi Python khởi động |
| Patch lỗi thì sao | Pod vẫn `Running` với code chưa patch, **không ai biết** | Pod dừng ở `Init:Error`, thấy ngay |

➡️ Với patch này, `postStart` đặc biệt nguy hiểm: nếu trượt âm thầm thì mình sẽ tưởng đã fix,
báo cáo là xong, trong khi upload vẫn 25s.

### Cơ chế `codePatch` hoạt động thế nào

Đọc từ `templates/ragflow.yaml:46-69` và `109-115`:

```
initContainer "ragflow-code-patch"           (dùng CHÍNH image ragflow)
  ├─ mkdir -p /patched/api/db/services/
  ├─ cp /ragflow/<file>  →  /patched/<file>     ← copy ra chỗ khác, KHÔNG sửa image gốc
  ├─ sed -i '<expr>' /patched/<file>            ← patch trên bản copy
  └─ grep -q '<verify>' /patched/<file>         ← không khớp → exit 1 → Init:Error
         │
         ▼  (emptyDir volume: code-patch-volume)
container chính "ragflow"
  └─ mountPath: /ragflow/<file>  subPath: <file>   ← mount đè bản đã patch lên file gốc
```

Ba điểm thiết kế đáng chú ý:

1. **Không sửa image gốc** — sed chạy trên bản copy trong `emptyDir`, rồi mount đè. Rollback chỉ
   cần bỏ block patch khỏi values, không cần build lại gì
2. **`verify` là lớp an toàn quan trọng nhất** — `sed` **không khớp vẫn trả exit 0**. Không có
   verify thì patch trượt âm thầm. Có verify thì `Init:Error`
3. **Dùng chính image ragflow làm initContainer** — không cần kéo thêm image nào (quan trọng vì
   cluster air-gapped, đã từng dính `ImagePullBackOff` khi migrate MySQL)

---

## 1b. `helm upgrade` thực chất làm gì — KHÔNG phải "restart pod"

*(Kiên bắt lỗi 10/08: "helm upgrade thì bản chất nó phải tạo ra pod mới theo replica chứ, sao
lại là restart pod? Pod mới chưa health OK thì pod cũ vẫn phục vụ request được mà, đúng không?")*

**Kiên đúng.** Bản nháp trước của plan này ghi "restart pod ragflow ~1-2 phút" là **sai** — đó là
cách diễn đạt mượn từ đợt migrate MySQL. MySQL là **StatefulSet `replicas: 1`** nên restart thật;
còn ragflow thì khác hẳn.

### Sự thật về workload ragflow (đọc từ chart)

| Thuộc tính | Giá trị | Nguồn |
|---|---|---|
| Kind | **Deployment** (không phải StatefulSet) | `templates/ragflow.yaml:3` |
| `replicas` | **3** | `values.yaml:130` |
| `strategy` | Để trống → K8s mặc định **RollingUpdate** (`maxUnavailable: 25%`, `maxSurge: 25%`) | `values.yaml:132` |

Nên `helm upgrade` sẽ: tạo **ReplicaSet mới** → dựng pod mới → chờ pod mới `Ready` → mới xoá pod
cũ, **lần lượt từng pod**. Không có thời điểm nào cả 3 pod cùng chết.

**Cơ chế kích hoạt rollout**: annotation `checksum/values: {{ .Values | toYaml | sha256sum }}`
(`ragflow.yaml:25`). Sửa `values.yaml` → checksum đổi → pod template đổi → K8s buộc tạo
ReplicaSet mới. Không có annotation này thì sửa values xong pod có thể không rollout.

### ⚠️ NHƯNG: chart này KHÔNG có readinessProbe

Đây là chỗ vế thứ hai của câu hỏi không đúng với thực tế chart. Đã grep toàn bộ `templates/`:
chỉ `infinity.yaml:85` và `opensearch.yaml:106` có probe. **`ragflow.yaml` không có
`readinessProbe` / `livenessProbe` / `startupProbe` nào.**

| Có readinessProbe | Không có (thực tế chart này) |
|---|---|
| Pod chỉ nhận traffic khi probe pass | Pod vào `Ready` **ngay khi container start** |
| Pod cũ giữ traffic tới khi pod mới thật sự phục vụ được | K8s tưởng pod mới OK → thêm vào Service endpoints + xoá pod cũ **trong khi Python còn đang khởi động** |

RagFlow khởi động lâu (load model, kết nối ES/MinIO/Redis/MySQL). Trong khoảng đó pod đã `Ready`
trên giấy tờ nhưng request vào sẽ **lỗi hoặc treo**.

➡️ Kết luận: *"pod mới chưa health OK thì pod cũ vẫn phục vụ"* — **đúng về nguyên tắc K8s**, nhưng
chart này **không có cơ chế biết thế nào là "health OK"**, nên không đảm bảo được.

**Yếu tố giảm nhẹ**: `maxUnavailable: 25%` của 3 replicas = 0.75 → làm tròn xuống **0** → K8s luôn
giữ đủ 3 pod cũ tới khi pod mới `Ready`. Nhưng vì `Ready` không phản ánh thực tế, nó chỉ **giảm**
chứ không loại bỏ rủi ro.

### Điểm tốt riêng của patch này

`initContainer` chạy **trước** container chính. Nếu `sed` không khớp → `Init:Error` → pod mới
**không bao giờ `Ready`** → RollingUpdate **dừng lại**, 3 pod cũ vẫn chạy nguyên.

➡️ **Patch sai thì hệ thống KHÔNG bị gián đoạn** — chỉ là không có gì thay đổi. Rủi ro thật nằm ở
hướng ngược lại: patch thành công, pod mới `Ready` sớm, request rơi vào lúc app chưa sẵn sàng.

### Việc nên làm

- [ ] Chọn **giờ thấp điểm** để apply (vì thiếu readinessProbe nên vẫn có khoảng chập chờn ngắn)
- [ ] 🔶 **Nợ kỹ thuật — nên thêm `readinessProbe` cho ragflow** (việc riêng, không gộp vào patch
      này để tách rủi ro). Có probe rồi thì mọi lần `helm upgrade` sau đều thật sự zero-downtime

---

## 2. Nội dung đã sửa trong chart

**File**: `helm_ragflow_v0.26.4/values.yaml`, mục `ragflow.codePatch.patches`

```yaml
- file: api/db/services/file_service.py
  expr: 's|(cls.model.parent_id == cls.model.id)|(cls.model.name == "/")|'
  verify: 'cls.model.name == "/"'
```

| Thành phần | Ý nghĩa |
|---|---|
| `file` | Đường dẫn tương đối từ `/ragflow/` trong container |
| `expr` | Biểu thức `sed`. Dùng dấu phân cách **`\|`** thay vì `/` vì chuỗi thay thế có chứa `"/"` — dùng `/` sẽ phải escape thành `\/`, dễ sai |
| `verify` | Chuỗi `grep` tìm sau khi patch. Chọn chuỗi **chưa tồn tại** trong file gốc |

Code trước/sau:

```python
# TRƯỚC (dòng 244) — so 2 cột CÙNG 1 DÒNG → không dùng được index → 18s
for file in cls.model.select().where((cls.model.tenant_id == tenant_id), (cls.model.parent_id == cls.model.id)):

# SAU — so cột với HẰNG SỐ → dùng được index → 0.00s
for file in cls.model.select().where((cls.model.tenant_id == tenant_id), (cls.model.name == "/")):
```

---

## 3. Đã kiểm chứng gì TRƯỚC khi sửa chart

Không sửa chart rồi mới thử — 4 việc dưới đây làm trước, tất cả đều pass:

| # | Kiểm chứng | Lệnh | Kết quả |
|---|---|---|---|
| 1 | `name = '/'` có trả đúng 1 dòng không (không trùng) | `SELECT name, COUNT(*) ... GROUP BY name` trên production | ✅ `/` = **1**, `.knowledgebase` = **1** |
| 2 | Nhanh hơn thật không | So `parent_id = id` vs `name = '/'` | ✅ **18.02s → 0.00s** |
| 3 | Chuỗi cần thay có duy nhất không | `grep -c "cls.model.parent_id == cls.model.id"` | ✅ **1** — sed không sửa nhầm chỗ khác |
| 4 | Chuỗi `verify` đã tồn tại sẵn chưa | `grep -c 'cls.model.name == "/"'` | ✅ **0** — verify thực sự có tác dụng |
| 5 | Cú pháp Python còn hợp lệ sau patch | `python3 -c "ast.parse(...)"` trên bản đã sed | ✅ **OK** |
| 6 | Chart render hợp lệ | `helm template` | ✅ Không lỗi YAML, script initContainer đúng |

⭐ **Điểm 4 hay bị bỏ qua**: nếu chuỗi verify đã có sẵn trong file gốc thì `grep -q` **luôn pass**,
kể cả khi `sed` trượt → lớp an toàn thành vô dụng. Chart đã dính đúng lỗi này một lần: comment
`values.yaml:198-200` ghi patch `minimum_should_match` **có thể đã thừa** vì code v0.26 có sẵn.

---

## 4. Các bước triển khai

> 📌 **Ghi chú thực thi** (10/08): Kiên đã báo khách hàng về downtime, bắt đầu chạy từ Bước 0.
> Release name: `ragflow`, namespace `ragflow`, revision hiện tại **62** (từ đợt migrate MySQL).
> Mọi lệnh `kubectl`/`helm` chạy trên **node04**.

### Bước 0 — Ghi lại hiện trạng để đối chiếu và để rollback (node04)

⭐ Bước này **quan trọng nhất cho việc rollback** — phải biết đang ở revision nào trước khi đổi.

```
helm list -n ragflow
```

| Thành phần | Ý nghĩa |
|---|---|
| `helm list` | Liệt kê các release đang cài |
| `-n ragflow` | Namespace `ragflow` |

Kỳ vọng: thấy release `ragflow`, cột `REVISION` = **62** (nếu khác thì ghi lại số thật).

Xem 3 pod ragflow hiện tại (để lát nữa đối chiếu pod nào là mới):

```
kubectl -n ragflow get pod -l app.kubernetes.io/component=ragflow -o wide
```

| Cờ | Ý nghĩa |
|---|---|
| `-l app.kubernetes.io/component=ragflow` | Lọc đúng pod ragflow (theo label chart đặt), bỏ qua mysql/minio/redis |
| `-o wide` | Hiện thêm cột IP + NODE — biết pod đang nằm trên node nào |

**Output thật (10/08, node04):**

```
NAME     NAMESPACE  REVISION  UPDATED                   STATUS    CHART          APP VERSION
ragflow  ragflow    62        2026-08-07 11:17:33 +0700 deployed  ragflow-0.1.1  dev

NAME                       READY  STATUS             RESTARTS  AGE    IP              NODE
ragflow-64745f4649-2ngtz   1/1    Running            0         9d     172.16.83.158   vrp-kubeengine06
ragflow-6db67c44bd-2c6rm   1/1    Running            0         14h    172.16.78.239   vrp-kubeengine05
ragflow-6db67c44bd-rvlhw   1/1    Running            0         14h    172.16.78.238   vrp-kubeengine05
ragflow-6db67c44bd-sqvrl   0/1    Init:ErrImagePull  0         7h19m  172.16.93.54    vrp-kubeengine07
```

**Đọc được gì:**

- ✅ `REVISION = 62` — đúng như dự đoán, khớp với đợt migrate MySQL
- 🔴 **4 pod chứ không phải 3** — có **rollout DỞ DANG từ 14h trước, chưa hoàn tất**:

| ReplicaSet | Số pod | Trạng thái |
|---|---|---|
| `64745f4649` (**cũ**) | 1 | `Running` 9 ngày — K8s **giữ lại** vì pod mới chưa đủ |
| `6db67c44bd` (**mới**) | 3 | 2 `Running`, **1 kẹt `Init:ErrImagePull`** |

- 🔴 **`Init:` — lỗi ở initContainer**, mà initContainer duy nhất là `ragflow-code-patch` (dùng
  cùng image với container chính). Node07 **không có image ragflow**, cluster air-gapped nên
  không kéo được → đúng kịch bản `ImagePullBackOff` đã gặp hồi migrate MySQL
- ✅ Đây chính là bằng chứng thực tế cho cơ chế `maxUnavailable = 0` mô tả ở mục 1b: pod mới
  không `Ready` → K8s **không dám xoá** pod cũ → hệ thống vẫn phục vụ bằng 3 pod `Running`, nên
  **không ai nhận ra** rollout đã kẹt 14 tiếng

⚠️ **Bài học**: `helm list` báo `STATUS: deployed` nhưng thực tế rollout **chưa xong**. Trạng thái
release ≠ trạng thái pod. Phải xem `get pod` mới biết.

### Bước 1 — Xem lại diff trước khi apply (máy local, KHÔNG phải node04)

⚠️ Lệnh này chạy ở **máy local** nơi có git repo, không phải node04:

```
git diff helm_ragflow_v0.26.4/values.yaml
```

| Thành phần | Ý nghĩa |
|---|---|
| `git diff <file>` | Xem thay đổi **chưa commit** của file đó |

✅ **Đã chạy 10/08**: diff sạch, chỉ **thêm 30 dòng** (block patch + comment), không sửa/xoá dòng
nào, **không đụng** `nodeSelector` của mysql/minio/redis. Đã commit `ad6235d`.

⚠️ **Lưu ý về đồng bộ file**: chart trên node04 phải có **đúng block patch mới** này. Nếu node04
lấy chart từ nơi khác (không phải repo git này), cần kiểm tra trước khi upgrade:

```
grep -n "file_service.py" <đường-dẫn-chart-trên-node04>/values.yaml
```

Kỳ vọng: ra 1 dòng `- file: api/db/services/file_service.py`. **Không ra dòng nào = chart trên
node04 chưa có patch**, upgrade sẽ không có tác dụng gì.

### Bước 2 — Ghi lại thời gian upload TRƯỚC khi patch (để đối chiếu)

Bật slow log nếu đã tắt (mất sau mỗi lần restart pod):

```
kubectl -n ragflow exec -it ragflow-mysql-0 -- mysql -uroot -pfini_rag_flow_helm -e "SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 0.1; SET GLOBAL log_output = 'TABLE';"
```

| Thành phần | Ý nghĩa |
|---|---|
| `slow_query_log = 'ON'` | Bật ghi query chậm |
| `long_query_time = 0.1` | Ngưỡng 0.1s — thấp, để bắt cả query nhỏ cộng dồn (mặc định 10s sẽ bỏ sót) |
| `log_output = 'TABLE'` | Ghi vào bảng `mysql.slow_log` để query được bằng SQL, thay vì ghi ra file |

⚠️ `SET GLOBAL` **mất khi pod MySQL restart**. Lần này upgrade pod **ragflow**, không phải mysql,
nên setting giữ nguyên.

**Output thật (10/08, node04):**

```
mysql> SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 0.1; SET GLOBAL log_output = 'TABLE';
Query OK, 0 rows affected (0.00 sec)
Query OK, 0 rows affected (0.00 sec)
Query OK, 0 rows affected (0.00 sec)

mysql> SELECT NOW() AS moc_truoc_khi_upgrade;
+-----------------------+
| moc_truoc_khi_upgrade |
+-----------------------+
| 2026-08-10 17:48:27   |
+-----------------------+
```

**Đọc được gì:**
- ✅ Cả 3 setting nhận thành công (`Query OK` × 3)
- ✅ MySQL version `8.0.39`, connection id `39711`
- ⭐ **Mốc `2026-08-10 17:48:27`** — dùng để lọc slow log sau upgrade. Bảng `mysql.slow_log` đang
  có 783.945 dòng cũ; không có mốc này thì **không phân biệt được** dòng full-scan mới với dòng cũ
- 💡 Lấy `NOW()` **của MySQL** chứ không phải giờ máy client — tránh lệch timezone khi so với cột
  `start_time` của slow log

**Kiểm tra đồng bộ chart trên node04 (đã chạy trước Bước 2):**

```
grep -n "file_service.py" values.yaml
grep -n "vrp-kubeengine07" values.yaml
```

```
199:      - file: api/db/services/file_service.py
150:                    - vrp-kubeengine07
```

**Đọc được gì:** ✅ Chart trên node04 có **cả hai** thay đổi — block patch (dòng 199) và
`nodeAffinity` chặn node07 (dòng 150). Một lần `helm upgrade` sẽ apply cả hai.

⭐ **Vì sao phải kiểm tra bước này**: values.yaml sửa ở repo git (máy local) và chart dùng để
upgrade (node04) là **2 nơi khác nhau**. Nếu node04 thiếu block patch, upgrade xong pod vẫn
`Running`, ta tưởng đã fix — nhưng upload vẫn 25s. Kiểm tra 10 giây rẻ hơn chẩn đoán nhầm.

### Bước 3 — Apply chart (node04)

Chạy **từ trong thư mục chart** trên node04 (giống hệt đợt migrate MySQL đã làm):

```
helm upgrade ragflow . -n ragflow -f values.yaml
```

| Thành phần | Ý nghĩa |
|---|---|
| `upgrade ragflow` | Nâng cấp release tên `ragflow` — **không** tạo release mới |
| `.` | Đường dẫn chart = thư mục hiện tại (phải đang đứng trong `helm_ragflow_v0.26.4/`) |
| `-n ragflow` | Namespace `ragflow` |
| `-f values.yaml` | Dùng file values này. **Bắt buộc có** — thiếu thì Helm dùng values mặc định của chart, mất hết cấu hình production |

Kỳ vọng output: `Release "ragflow" has been upgraded. Happy Helming!` và `REVISION: 63`.

**Output thật (10/08 16:50, node04):**

```
Release "ragflow" has been upgraded. Happy Helming!
NAME: ragflow
LAST DEPLOYED: Mon Aug 10 16:50:45 2026
NAMESPACE: ragflow
STATUS: deployed
REVISION: 63
```

**Đọc được gì:** ✅ Upgrade thành công, revision **62 → 63** đúng kỳ vọng. Không lỗi
`spec is immutable` (rủi ro đã lường trước với `storageClassName`).

⚠️ **Kiên chạy thêm** `kubectl -n ragflow rollout restart deployment/ragflow` (không có trong
plan) → `deployment.apps/ragflow restarted`. Lệnh này thêm annotation
`kubectl.kubernetes.io/restartedAt` vào pod template, **ép tạo thêm 1 ReplicaSet nữa**.
Không gây hại, nhưng làm output `get pod` rối hơn vì nhiều ReplicaSet chồng nhau.
Thực tế `helm upgrade` đã đủ để rollout (nhờ annotation `checksum/values`), không cần lệnh này.

### Bước 4 — Theo dõi initContainer chạy (node04)

⭐ **Đây là bước quan trọng nhất** — nếu patch trượt, pod dừng ở đây:

```
kubectl -n ragflow get pod -l app=ragflow -w
```

| Cờ | Ý nghĩa |
|---|---|
| `-l app=ragflow` | Lọc theo label, tránh liệt kê cả mysql/minio/redis |
| `-w` | `--watch` — theo dõi realtime, Ctrl+C để thoát |

Vì là Deployment 3 replicas rolling update, sẽ thấy **nhiều pod cùng lúc** — pod cũ
(`Running`) song song pod mới đang lên:

| Trạng thái thấy được | Nghĩa |
|---|---|
| Pod mới: `Init:0/1` → `PodInitializing` → `Running`, pod cũ `Terminating` dần | ✅ Patch thành công, rolling update chạy đúng |
| Pod mới: `Init:Error` / `Init:CrashLoopBackOff`, **pod cũ vẫn `Running` đủ 3** | 🔴 **Patch trượt** — sang Bước 4b. Điểm tốt: **hệ thống không gián đoạn**, 3 pod cũ vẫn phục vụ |

⚠️ Chart **không có readinessProbe** (mục 1b) → pod mới vào `Ready` ngay khi container start, chưa
chắc app đã sẵn sàng. Nên **đợi thêm ~1-2 phút** sau khi thấy `Running` rồi mới test, đừng test ngay.

**Output thật (10/08, node04):**

```
NAME                       READY  STATUS                       AGE    IP              NODE
ragflow-69dcc55b47-7j7p6   0/1    Init:ContainerStatusUnknown  6m27s  172.16.116.229  vrp-kubeengine08
ragflow-7645557fb6-2cqsl   1/1    Running                      78s    172.16.78.244   vrp-kubeengine05
ragflow-7645557fb6-spl9c   1/1    Running                      83s    172.16.78.243   vrp-kubeengine05
ragflow-7645557fb6-zvm5n   1/1    Running                      80s    172.16.83.133   vrp-kubeengine06
ragflow-minio-0            1/1    Running                      9d     172.16.93.37    vrp-kubeengine07
ragflow-mysql-0            1/1    Running                      3d5h   172.16.83.213   vrp-kubeengine06
ragflow-redis-0            1/1    Running                      9d     172.16.93.38    vrp-kubeengine07
```

**Đọc được gì — 3 xác nhận quan trọng:**

| Xác nhận | Bằng chứng |
|---|---|
| ✅ **`sed` khớp pattern** | 3 pod mới **qua được initContainer** → `Running`. Nếu trượt sẽ dừng ở `Init:Error` |
| ✅ **`nodeAffinity` có tác dụng** | **Không còn pod ragflow nào trên node07**. Pod kẹt `Init:ErrImagePull` 14h đã biến mất. Node07 giờ chỉ còn minio + redis — đúng chủ ý |
| ✅ **Rollout hoàn tất, ReplicaSet cũ đã dọn** | Cả 3 pod cùng hash `7645557fb6`; không còn `64745f4649` (9d) hay `6db67c44bd` (14h) |

⚠️ **Pod lỗi `Init:ContainerStatusUnknown` trên node08** — Kiên quyết định bỏ qua. Ghi rõ để
không hiểu nhầm về sau:
- Đây **không phải** `Init:Error` → **không phải bằng chứng patch trượt** (patch đã được chứng
  minh OK qua 3 pod `Running` kia)
- Không chiếm slot replica — Deployment đã đủ 3 pod `Running`
- Thuộc ReplicaSet `69dcc55b47` (sinh ra do lệnh `rollout restart` thừa), dọn sau bằng
  `kubectl -n ragflow delete pod ragflow-69dcc55b47-7j7p6` — không gấp
- ❓ Chưa điều tra nguyên nhân gốc trên node08

### Bước 4b — Nếu Init:Error, đọc log initContainer (node04)

```
kubectl -n ragflow logs <tên-pod> -c ragflow-code-patch
```

| Cờ | Ý nghĩa |
|---|---|
| `-c ragflow-code-patch` | Chỉ định **container nào** trong pod. Không có cờ này sẽ đọc log container chính (chưa chạy) |

Kỳ vọng thấy dòng: `PATCH FAILED: api/db/services/file_service.py khong khop pattern`

→ Nghĩa là chuỗi trong image thật khác với bản v0.26.4 đã đối chiếu. **Rollback ngay** (mục 6),
không sửa mò.

### Bước 5 — Xác minh patch đã thật sự vào code (node04)

Không tin pod `Running` là đủ — kiểm tra trực tiếp file trong container:

```
kubectl -n ragflow exec -it <tên-pod> -c ragflow -- grep -n 'cls.model.name == "/"' /ragflow/api/db/services/file_service.py
```

Kỳ vọng: ra **1 dòng**, số dòng khoảng 244.

Kiểm tra chuỗi cũ đã biến mất:

```
kubectl -n ragflow exec -it <tên-pod> -c ragflow -- grep -c "cls.model.parent_id == cls.model.id" /ragflow/api/db/services/file_service.py
```

Kỳ vọng: **0**.

**Output thật (10/08, node04, pod `ragflow-7645557fb6-2cqsl`):**

```
$ kubectl -n ragflow exec -it ragflow-7645557fb6-2cqsl -c ragflow -- grep -n 'cls.model.name == "/"' /ragflow/api/db/services/file_service.py
244:        for file in cls.model.select().where((cls.model.tenant_id == tenant_id), (cls.model.name == "/")):

$ kubectl -n ragflow exec -it ragflow-7645557fb6-2cqsl -c ragflow -- grep -c "cls.model.parent_id == cls.model.id" /ragflow/api/db/services/file_service.py
0
command terminated with exit code 1
```

**Đọc được gì:**
- ✅ **Chuỗi mới có mặt tại đúng dòng 244** — khớp chính xác vị trí đã đối chiếu trên source v0.26.4
- ✅ **Chuỗi cũ = 0** — đã biến mất hoàn toàn, `sed` thay chứ không phải thêm
- 💡 `command terminated with exit code 1` là **hành vi bình thường của `grep`** khi không tìm
  thấy dòng nào (grep coi "không khớp" là exit 1). Con số `0` in ra mới là kết quả — đây chính
  là điều mong muốn, **không phải lỗi**

➡️ **Patch đã thật sự vào code đang chạy**, không chỉ nằm trong values.yaml.

### Bước 6 — Đo kết quả thật: upload 1 file qua UI

Upload 1 file test qua giao diện, bấm giờ. Sau đó kiểm tra slow log:

```
kubectl -n ragflow exec -it ragflow-mysql-0 -- mysql -uroot -pfini_rag_flow_helm -e "SELECT start_time, query_time, rows_examined FROM mysql.slow_log WHERE rows_examined > 600000 ORDER BY start_time DESC LIMIT 5;"
```

| Kết quả | Nghĩa |
|---|---|
| **Không có dòng mới** sau thời điểm upload | ✅ Patch có tác dụng — không còn full-scan 631k dòng |
| Vẫn có dòng mới `rows_examined ~631585` | 🔴 Patch không tác dụng dù grep thấy — điều tra tiếp |

**Kết quả thật (10/08 18:04):**

> 🗣️ **Kiên**: *"tôi upload doc trên UI của ragflow thì nó nhanh lắm, nó trả về 200 nhanh vãi ấy,
> chắc tầm 10-20s của toàn bộ quá trình"*

**a) Slow log lọc theo `rows_examined > 600000` sau mốc:**

```
| start_time                 | query_time      | rows_examined |
| 2026-08-10 18:04:46.069960 | 00:00:08.784222 |       1938312 |
| 2026-08-10 18:04:36.004735 | 00:00:30.587626 |       2584468 |
| 2026-08-10 18:04:19.935846 | 00:00:20.705220 |       1938312 |
| 2026-08-10 18:04:13.364100 | 00:00:57.140018 |       1001349 |
| 2026-08-10 18:04:05.416126 | 00:00:19.514839 |       2584416 |
| 2026-08-10 18:04:03.578490 | 00:00:08.198019 |        646104 |
| 2026-08-10 18:03:59.229898 | 00:00:10.862413 |       1938312 |
| 2026-08-10 18:03:48.307564 | 00:00:32.585830 |       2584468 |
| 2026-08-10 18:03:42.510749 | 00:00:21.235912 |       1938312 |
| 2026-08-10 18:03:21.274120 | 00:00:11.259748 |       1938312 |
```

**Đọc được gì — dễ nhìn nhầm là thất bại, nhưng số liệu nói ngược lại:**

| Trước patch | Sau patch |
|---|---|
| `rows_examined = 631585` (**đúng bằng số dòng bảng `file`**) | `1938312`, `2584468`, `1001349`, `646104` |

- ✅ **KHÔNG còn dòng nào ~631.585** — con số đó là **chữ ký** của `get_root_folder` full-scan
  bảng `file`. Nó đã biến mất hoàn toàn
- ✅ Các số mới đều **lớn hơn và khác nhau** → là query khác, trên bảng khác (JOIN nhiều bảng)

**b) Gom nhóm top 8 query nặng nhất sau mốc:**

| # | Query (rút gọn) | Số lần | Tổng (s) | Là gì |
|---|---|---|---|---|
| 1 | `SELECT ... FROM mysql.slow_log WHERE rows_examined > 600000` | 2 | 161.5 | ⚠️ **Do chính ta** — câu đo ở mục (a). Bảng slow_log quá lớn |
| 2 | `SELECT t1.id, t1.thumbnail, t1.kb_id, t1.parser_id...` | 4 | 123.8 | Issue 7 — list document |
| 3 | `SELECT t1.id, t1.process_begin_at... FROM document` | 7 | 108.5 | Issue 7 |
| 4 | `SELECT t1.run, t1.suffix, t1.id FROM document INNER JOIN file2document` | 5 | 92.5 | Issue 7 |
| 5 | `SELECT COUNT(1) FROM (... LEFT OUTER JOIN user_ca...)` | 4 | 75.3 | Issue 7 |
| 6 | `SELECT COUNT(1) FROM (... INNER JOIN file AS t3)` | 5 | 52.4 | Issue 7 |
| 7 | `SELECT COALESCE(SUM(t1.size), 0) FROM document WHERE kb_id = ...` | 4 | 31.1 | Tính dung lượng KB |
| 8 | `SELECT GET_LOCK('init_database_tables', 60)` | 3 | 25.0 | Khởi động app |

⭐ **`get_root_folder` KHÔNG còn trong top 8.** Trước patch nó đứng **đầu bảng** với 783.945 lần /
838 giờ tích luỹ. Đây là bằng chứng mạnh nhất rằng patch đã có tác dụng thật.

**c) Hiện tượng "gỡ nút thắt lớn nhất thì nút thắt thứ hai lộ ra"**

Các query #2-#6 đều thuộc **Issue 7** (`get_filter_by_kb_id` — kéo cả KB về Python đếm thủ công).
Chúng **không hề chậm đi** — chỉ là trước đây bị `get_root_folder` (838 giờ) át hết nên không nhìn thấy.

Điểm phân biệt quan trọng:

| | Đường GHI (upload) | Đường ĐỌC (mở trang, list document) |
|---|---|---|
| Query thủ phạm | `get_root_folder` — ✅ **đã fix** | Issue 7 — 🔶 **còn nguyên** |
| Cảm nhận người dùng | ✅ Nhanh hẳn, trả 200 nhanh | ⚠️ Vẫn chậm |

➡️ Khớp đúng cảnh báo đã ghi khi soạn báo cáo sếp: *"nhanh ở tầng DB nhưng UI không cảm nhận
được vì API khác chặn"*. Giờ upload đã nhanh thật, nhưng **mở trang danh sách vẫn chậm** do Issue 7.

---

## 5. Kỳ vọng kết quả

| Chỉ số | Trước | Sau — **đo thật 10/08** |
|---|---|---|
| `get_root_folder` mỗi lần | 18.02s | ✅ **Không còn xuất hiện trong slow log** (ngưỡng 0.1s) |
| Số lần chạy mỗi upload | 2 | 2 (**không đổi** — cố ý chưa làm phương án bỏ lời gọi thừa) |
| Tổng thời gian tìm thư mục gốc | ~36s | ✅ **~0s** |
| Dòng `rows_examined = 631585` trong slow log | Đầu bảng, 783.945 lần | ✅ **Biến mất hoàn toàn** |
| Toàn bộ quá trình upload (Kiên đo qua UI) | — | ✅ **~10-20s, trả 200 nhanh** |

✅ **Trạng thái: FIXED** — có bằng chứng trực tiếp (chuỗi trong code + biến mất khỏi slow log +
cảm nhận thực tế qua UI).

⚠️ **Không quy toàn bộ mức cải thiện cho patch này.** Cùng đợt còn có: index
`idx_document_kb_create` (đánh trước đó), migrate MySQL sang node06, và `nodeAffinity` gỡ pod kẹt.
Điều **chứng minh được chắc chắn** là: query `parent_id = id` 18s **không còn tồn tại**.

⚠️ **Tổng 55s sẽ KHÔNG giảm hết** — 4 bước còn lại (LLM tóm tắt 10s, Update metadata 8s, Parse
chunk 6s, Check tồn tại 6s) chưa được trace, là việc riêng.

---

## 5b. ⭐ Kiểm chứng sau 12 GIỜ TẢI THẬT (11/08 sáng)

*(Kiên: "đã báo sếp và đối tác tiếp tục đẩy dữ liệu, cách đây 12 tiếng, giờ tự check xem tốc độ
cải thiện chưa thay vì hỏi feedback đối tác")*

Đây là phép đo **giá trị nhất** — hôm qua chỉ có 1 file test, giờ là tải sản xuất thật.
`mysql.slow_log` đã `TRUNCATE` sau khi patch → mọi dòng đều là dữ liệu **sau patch**.

### a) Top 6 query nặng nhất sau 12h

```sql
SELECT LEFT(CONVERT(sql_text USING utf8), 90) AS query, COUNT(*) AS so_lan, SUM(query_time) AS tong FROM mysql.slow_log GROUP BY LEFT(CONVERT(sql_text USING utf8), 90) ORDER BY SUM(query_time) DESC LIMIT 6\G
```

| # | Query | Số lần | Tổng (s) | Bảng |
|---|---|---|---|---|
| 1 | `SELECT COUNT(t1.id) FROM task INNER JOIN document` | 34.781 | **115.325** | task, document |
| 2 | `DELETE FROM pipeline_operation_log WHERE kb_id = '73932b965...'` | 78.508 | 22.808 | pipeline_operation_log |
| 3 | `SELECT t1.id, t1.process_begin_at, t1.parser_config, t1.progress_msg` | 40 | 811 | document |
| 4 | `INSERT INTO pipeline_operation_log (id, create_time, ...)` | 3.632 | 655 | pipeline_operation_log |
| 5 | `SELECT COUNT(1) FROM (... INNER JOIN file2document ...)` | 23 | 343 | document |
| 6 | `SELECT t1.id, t1.thumbnail, t1.kb_id, t1.parser_id, t1.pipeline_id` | 11 | 300 | document |

⭐ **KHÔNG có query nào trên bảng `file` với `parent_id = id`.** Sau 12 giờ tải thật, query từng
đứng **đầu bảng** (783.945 lần / 838 giờ) đã **hoàn toàn biến mất**. Đây là bằng chứng mạnh nhất.

### b) Đường GHI (thứ khách hàng quan tâm)

```sql
SELECT COUNT(*) AS so_query_cham, ROUND(AVG(query_time),3) AS trung_binh, MAX(query_time) AS cham_nhat FROM mysql.slow_log WHERE CONVERT(sql_text USING utf8) LIKE '%INSERT%document%' OR CONVERT(sql_text USING utf8) LIKE '%file2document%';
```

```
| so_query_cham | trung_binh | cham_nhat       |
|          3819 |      0.386 | 00:00:50.021119 |
```

**Đọc được gì:**
- ✅ **3.819 câu ghi, trung bình 0.386s** — với ngưỡng slow log 0.1s thì đây là con số rất tốt
  (phần lớn chỉ nhỉnh hơn ngưỡng một chút)
- 📊 So sánh: **trước patch mỗi upload phải trả 36s cho `get_root_folder` TRƯỚC KHI kịp ghi gì**
- ⚠️ `cham_nhat = 50s` là **giá trị ngoại lai**, không phải xu hướng (trung bình vẫn 0.386s).
  ❓ Chưa điều tra nguyên nhân

### c) Tải MySQL trên node06

```
top - 08:21:43  up 950 days,  load average: 3.86, 4.16, 4.04
PID    USER     %CPU   %MEM  COMMAND
20387  polkitd  237.5   6.5  mysqld
11420  root      62.5  11.2  python3
11404  root      50.0  10.0  python3
36590  root      43.8   3.0  litellm
```

| Thời điểm | `mysqld` %CPU | load avg |
|---|---|---|
| node07 **trước** migrate | 666.7% | 19.52 |
| node06 sau migrate, **rảnh** | 43.8% | 2.48 |
| node06 dưới tải đối tác, **trước** patch | 293.8% | 7.98 |
| **node06 sau patch, 12h tải** | **237.5%** | **3.86** |

**Đọc được gì** (so 2 dòng cuối — cùng là "đối tác đang đẩy dữ liệu"):
- CPU: 293.8% → **237.5%** (giảm ~19%)
- ⭐ **load avg: 7.98 → 3.86 — giảm hơn MỘT NỬA**. Load average đo số tiến trình **đang chờ**,
  phản ánh mức nghẽn. Trên máy 8 core: từ "gần bão hoà" xuống "còn dư địa thoải mái"

### c2) ⭐⭐ BẰNG CHỨNG MẠNH NHẤT — tải TĂNG 77% mà tài nguyên vẫn GIẢM

*(Kiên bổ sung 11/08 — thông tin quyết định)*

Ở bản nháp trước tôi phải dè dặt: *"không kết luận patch giảm 19% CPU vì cường độ đẩy dữ liệu
2 thời điểm có thể khác nhau"*. Kiên cho biết cường độ **đã tăng mạnh** → sự dè dặt đó biến
thành lập luận **mạnh hơn hẳn**:

| Chỉ số | **Trước** patch | **Sau** patch | Thay đổi |
|---|---|---|---|
| ⭐ **Tần suất đối tác đẩy** | 60 doc/phút | **106 doc/phút** | 🔺 **+77%** |
| CPU node06 | 61% | **35%** | 🔻 **-43%** |
| RAM node06 | 76% | **64%** | 🔻 -12 điểm |
| load average | 7.98 | **3.86** | 🔻 **-52%** |
| `mysqld` %CPU | 293.8% | 237.5% | 🔻 -19% |

➡️ **Trước: làm ÍT hơn mà tốn NHIỀU hơn. Sau: làm NHIỀU hơn 77% mà tốn ÍT hơn.**

**Hiệu năng trên mỗi document** (chỉ số phản ánh đúng nhất):

```
Trước: 61% CPU ÷ 60 doc/phút  = 1.02 đơn vị CPU/doc
Sau:   35% CPU ÷ 106 doc/phút = 0.33 đơn vị CPU/doc
                              → giảm ~68%
```

**Giải thích 2 hiện tượng đi kèm:**

| Hiện tượng | Cơ chế |
|---|---|
| **RAM giảm dù patch chỉ sửa câu SQL** | Full-scan 631.585 dòng buộc InnoDB nạp **toàn bộ** trang dữ liệu bảng `file` vào buffer pool mỗi lần chạy (2 lần/upload). Buffer pool bị chiếm bởi dữ liệu quét-một-lần-rồi-bỏ, đẩy trang hay dùng ra ngoài. Bỏ full-scan → buffer pool dùng đúng mục đích |
| **load avg giảm mạnh hơn CPU (52% vs 19%)** | Load average đếm cả tiến trình **chờ I/O**, không chỉ tiến trình đang tính. Full-scan sinh rất nhiều I/O đọc đĩa → hàng đợi dài. Phần lớn nghẽn trước đây là **CHỜ**, không phải **TÍNH** |

⭐ **Bài học đo lường**: khi so tài nguyên trước/sau một thay đổi, **phải biết cả cường độ tải**.
Nếu chỉ nhìn "CPU giảm 43%" mà không biết tải tăng 77%, sẽ **đánh giá thấp** mức cải thiện thật
(68% thay vì 43%). Ngược lại, nếu tải giảm mà không biết, sẽ **thổi phồng** kết quả.

### d) ⚠️ Bài học về cách đo — bộ lọc `rows_examined` đã hết tác dụng

```sql
SELECT COUNT(*) AS so_lan_fullscan_file FROM mysql.slow_log WHERE rows_examined BETWEEN 600000 AND 700000;
```

```
| so_lan_fullscan_file |
|                   40 |
```

Kỳ vọng ban đầu là **0**, ra **40** → thoạt nhìn tưởng patch hỏng. Nhưng đối chiếu mục (a):
query #3 có `so_lan = 40` — **khớp chính xác**. Đó là query trên bảng **`document`**, không phải
bảng `file`.

➡️ **Nguyên nhân**: bảng `document` đã lớn lên (395k+ dòng và đang tăng do đối tác đẩy dữ liệu),
nên `rows_examined` của nó rơi vào đúng khoảng 600k-700k. Bộ lọc này **không còn đặc trưng** cho
bảng `file` nữa.

⭐ **Bài học**: dùng `rows_examined` làm "chữ ký" nhận diện query chỉ đúng **tại một thời điểm**.
Bảng lớn dần thì chữ ký trùng nhau. Muốn chắc chắn phải lọc theo **nội dung câu SQL**
(`sql_text LIKE '%parent_id%'`), không phải theo số dòng quét.

### Kết luận sau 12h

| Câu hỏi | Trả lời |
|---|---|
| Query cũ có quay lại không? | ✅ **Không** — vắng mặt hoàn toàn khỏi top query sau 12h tải thật |
| Đường ghi có thông không? | ✅ **Có** — 3.819 lần, trung bình 0.386s |
| Tải MySQL có giảm không? | ✅ load avg **7.98 → 3.86**, CPU **61% → 35%**, RAM **76% → 64%** |
| ⭐ Trong khi tải thế nào? | 🔺 **TĂNG 77%** (60 → 106 doc/phút) |
| Hiệu năng thực trên mỗi doc | ✅ **Cải thiện ~68%** |
| Có cần hỏi feedback đối tác không? | ❌ **Không cần** — đã có số liệu thay cho cảm nhận |

### 🔴 Hai vấn đề MỚI lộ ra (trước bị che khuất)

| Vấn đề | Số liệu | Nhận xét |
|---|---|---|
| `SELECT COUNT(t1.id) FROM task INNER JOIN document` | **34.781 lần / 115.325s (~32 giờ)** | Thủ phạm nặng nhất hiện tại. **Chưa từng xuất hiện** trong mọi lần phân tích trước |
| `DELETE FROM pipeline_operation_log` | **78.508 lần** / 22.808s | Số lần rất lớn dù mỗi lần nhanh |

Cả hai thuộc luồng **parsing/task**, **không phải** upload → không ảnh hưởng việc vừa fix.
🔶 Ghi nhận làm việc riêng, chưa ưu tiên (theo phạm vi Kiên chốt: chỉ upload + retrieval).

---

## 6. Rollback

Nhanh, không mất dữ liệu, vì image gốc không bị sửa:

**Cách 0 — nhanh nhất, quay về revision cũ** (node04):

```
helm rollback ragflow 62 -n ragflow
```

| Thành phần | Ý nghĩa |
|---|---|
| `rollback ragflow` | Quay release `ragflow` về một revision trước đó |
| `62` | Số revision muốn quay về — **là revision trước khi apply patch** (ghi ở Bước 0). Nếu bỏ trống sẽ về revision liền trước |
| `-n ragflow` | Namespace |

Ưu điểm: một lệnh, không cần sửa file. Dùng khi cần gỡ gấp.

**Cách 1 — bỏ đúng patch này** (giữ patch `minimum_should_match`): xoá block
`- file: api/db/services/file_service.py` khỏi `values.yaml` → `helm upgrade` lại.
Dùng khi muốn giữ các thay đổi khác trong values, chỉ gỡ riêng patch này.

**Cách 2 — tắt toàn bộ cơ chế patch**: `codePatch.enabled: false` → `helm upgrade`.
⚠️ Cách này bỏ luôn patch `minimum_should_match` đang chạy — chỉ dùng khi nghi ngờ chính cơ chế.

Sau rollback, pod restart và dùng lại code gốc trong image. **Không cần đụng database.**

---

## 7. Rủi ro còn lại

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Chuỗi trong image production khác bản v0.26.4 đã đối chiếu | Thấp | `verify` bắt được → `Init:Error`, không chạy sai âm thầm |
| Về sau xuất hiện dòng trùng `name = '/'` do race condition | Thấp | Hiện `COUNT(*)` = 1. Code v0.26.4 có logic dedup cho `.knowledgebase` (dòng 79) → chuyện trùng **có thật** với thư mục khác, cần theo dõi định kỳ |
| Tenant mới chưa có root folder | Rất thấp | Code có sẵn nhánh tự tạo khi không tìm thấy (dòng 246-259), hành vi giữ nguyên |
| ❓ Chưa xác minh tên index cụ thể trên `file.name` | Thấp | Suy từ `0.00 sec` trên bảng 631k dòng. Chạy `SHOW INDEX FROM file` nếu muốn chắc |
| **Chart không có readinessProbe** → pod mới `Ready` sớm, request có thể rơi vào lúc app chưa khởi động xong | **Trung bình** | Chọn giờ thấp điểm; `maxUnavailable` làm tròn = 0 nên vẫn giữ đủ 3 pod cũ. Dài hạn: thêm probe (mục 1b) |
| Chưa test ở non-prod | **Trung bình** | Môi trường hiện không có non-prod tương đương. Bù lại bằng: verify + rollback nhanh + đo lại sau khi apply |

---

## 8. Việc chưa làm (cố ý)

- [ ] **Phương án (a) — bỏ lời gọi trùng lặp** (2 lần → 1 lần): Kiên chốt 10/08 **chưa làm**, vì
      sau patch này mỗi lần chỉ còn ~0.00s nên gọi 2 lần cũng không đáng kể. Giữ lại làm việc
      tối ưu về sau nếu cần
- [ ] **Phương án (b) — cache id thư mục gốc**: không cần nữa sau khi có (d)
- [ ] Báo issue lên upstream RagFlow (branch `main` vẫn còn lỗi này)
- [ ] Trace 4 bước còn lại của flow 55s
