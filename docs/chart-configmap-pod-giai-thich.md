# Chart → helm upgrade → ConfigMap → Pod — Giải thích từ số 0

> **Câu hỏi gốc của Kiên (12/08/2026)**: *"tôi thích cái chỗ chart -> helm upgrade -> config map
> -> pod, giờ tôi mới biết, mà sao bạn có thể biết được cái config map nữa chứ, tên ấy"*

> **Bối cảnh**: phiên debug lỗi 502 ngày 11-12/08/2026. Sửa file cấu hình nginx trong chart,
> chạy `helm upgrade`, pod đã tạo lại — **nhưng file trong pod vẫn là bản cũ**. Mất ~1 tiếng mới
> tìm ra vì sao.

---

## PHẦN 0 — Tiền đề: 4 thứ phải biết trước

Nếu chưa rõ 4 khái niệm này thì phần sau sẽ khó hiểu. Giải thích luôn tại đây, không link đi đâu.

### 0.1. Container không giữ được thay đổi

Container sinh ra từ một **image** — hình dung như cái khuôn đúc bánh. Mỗi lần đúc ra một chiếc
bánh giống hệt nhau.

Nếu bạn `exec` vào container rồi sửa file, thì khi container chết và được tạo lại, **mọi sửa đổi
biến mất** — vì nó lại được đúc từ khuôn cũ.

➡️ Nên muốn thay đổi cấu hình **bền vững**, không thể sửa trực tiếp trong container.

### 0.2. ConfigMap — nơi để cấu hình bên ngoài container

**ConfigMap** là một đối tượng của Kubernetes, dùng để chứa **nội dung file cấu hình dạng chữ**.

Ví von: container là **cái tủ đã đóng kín**, ConfigMap là **tờ giấy bạn dán từ bên ngoài vào**.
Đúc lại tủ mới thì tờ giấy vẫn còn, dán lại lên tủ mới.

Xem thử một ConfigMap thật:

```
kubectl -n ragflow get configmap
```

<details>
<summary><b>Bấm xem: giải nghĩa lệnh trên</b></summary>

```
kubectl -n ragflow get configmap
│       │           │   └─ loại đối tượng muốn xem (có thể viết tắt: cm)
│       │           └───── get: LIỆT KÊ ra màn hình. Chỉ đọc, không sửa gì
│       └───────────────── -n = namespace: xem trong "ngăn" tên ragflow
└───────────────────────── công cụ dòng lệnh nói chuyện với Kubernetes
```

| Thành phần | Ý nghĩa |
|---|---|
| `-n ragflow` | **Bắt buộc**. Không có cờ này, kubectl xem namespace `default` → không thấy gì |
| `get` | Liệt kê ngắn gọn. Muốn xem chi tiết thì dùng `describe` hoặc `-o yaml` |
| `configmap` | Viết tắt được thành `cm`: `kubectl -n ragflow get cm` |

</details>

**Output thật (12/08/2026, node04):**

```
NAME                    DATA   AGE
kube-root-ca.crt        1      89d
mysql-init-script       1      89d
nginx-config            3      89d
ragflow-service-config  1      89d
```

**Đọc được gì:**
- Có **4 ConfigMap**, trong đó `nginx-config` có `DATA = 3` → chứa **3 file** bên trong
- `AGE 89d` → tạo từ 89 ngày trước

### 0.3. Volume và mount — cách "dán tờ giấy" vào container

Chỉ tạo ConfigMap thôi thì container **không tự biết**. Phải nói rõ: *lấy nội dung này, đặt vào
đường dẫn kia bên trong container*. Việc đó gọi là **mount**.

Ví von: ConfigMap là **tờ giấy trong ngăn kéo**. Mount là hành động **dán tờ giấy đó lên đúng vị
trí trên cửa tủ**.

### 0.4. Helm và chart — bộ khuôn để sinh ra file YAML

Kubernetes chỉ hiểu file **YAML**. Viết tay mỗi lần thì mệt và dễ sai.

**Chart** là một thư mục chứa các **bản mẫu** (template). **Helm** là công cụ đọc bản mẫu đó, điền
giá trị vào, rồi sinh ra YAML hoàn chỉnh gửi lên Kubernetes.

Cấu trúc chart của mình:

```
helm_ragflow_v0.26.4/
├── Chart.yaml            ← tên + phiên bản chart
├── values.yaml           ← các GIÁ TRỊ để điền vào bản mẫu
└── templates/            ← ⭐ CÁC BẢN MẪU. Helm đọc HẾT thư mục này
    ├── ragflow.yaml          (định nghĩa Deployment - tức là pod)
    ├── ragflow_config.yaml   (định nghĩa ConfigMap)
    ├── mysql.yaml
    └── ...
```

⚠️ **Ghi nhớ dòng có dấu ⭐** — nó chính là nguyên nhân của lỗi ta gặp, sẽ nói ở PHẦN 3.

---

## PHẦN 1 — Bài toán gốc: vì sao mất 1 tiếng mới tìm ra?

### Hiện tượng

Trên giao diện RagFlow báo lỗi `502` khi mở trang Dataset. Nhưng lỗi này **rất khó chẩn đoán**:

| Quan sát | Con số thật đo được |
|---|---|
| Chỉ **một** API lỗi | `GET /api/v1/datasets` → **502** |
| Các API khác **cùng lúc đó** | `me`, `tenants`, `models`, `chats` → **200**, mất 31-61ms |
| Thời gian trả về lỗi 502 | **36ms** |
| Tính chất | **Ngắt quãng** — lúc thì 200, lúc thì 502 |

**Vì sao 3 điểm này gây khó?**

- *Chỉ 1 API lỗi* → không phải backend chết (chết thì mọi API đều lỗi)
- *502 sau 36ms* → không phải timeout. Timeout thì phải chờ hàng chục giây rồi mới báo lỗi
- *Ngắt quãng* → thử lại có khi thành công, dễ tưởng "đã hết"

### Đã đi vào 2 đường cụt

**Đường cụt 1 — nghi Service trỏ vào pod chết.** Kiểm tra:

```
kubectl -n ragflow get pod,svc,deploy,ep -o wide
```

<details>
<summary><b>Bấm xem: giải nghĩa lệnh trên</b></summary>

```
kubectl -n ragflow get pod,svc,deploy,ep -o wide
│                      │              │   └─ hiện THÊM cột: IP, NODE
│                      │              └───── ep = endpoints
│                      │                     (viết tắt của: pod, service, deployment, endpoints)
│                      └──────────────────── xem NHIỀU loại cùng lúc, ngăn bởi dấu phẩy
└─────────────────────────────────────────── namespace ragflow
```

| Thành phần | Viết đầy đủ | Cho biết gì |
|---|---|---|
| `pod` | pod | Các container đang chạy |
| `svc` | service | "Cổng vào" chung, phân phối request cho các pod |
| `deploy` | deployment | Bộ quản lý pod: giữ đủ số lượng, thay pod hỏng |
| `ep` | **endpoints** | ⭐ **Danh sách IP mà Service đang chuyển request tới** |
| `-o wide` | output wide | Thêm cột `IP` và `NODE` — biết pod nằm ở máy nào |

⭐ `endpoints` là thứ quan trọng nhất ở đây: nếu Service trỏ vào IP của pod đã chết thì cứ vài
request lại rơi vào pod hỏng → 502 ngắt quãng.

</details>

**Output thật:**

```
NAME                       READY  STATUS   AGE   IP              NODE
pod/ragflow-...-d754s      1/1    Running  12h   172.16.83.241   vrp-kubeengine06
pod/ragflow-...-hf622      1/1    Running  55m   172.16.78.251   vrp-kubeengine05
pod/ragflow-...-zvm5n      1/1    Running  22h   172.16.83.133   vrp-kubeengine06

deployment.apps/ragflow   READY 3/3   UP-TO-DATE 3   AVAILABLE 3

endpoints/ragflow   172.16.78.251:80, 172.16.83.133:80, 172.16.83.241:80
```

**Đọc được gì:** ✅ `endpoints` có **đúng 3 IP**, khớp chính xác 3 pod `Running`. Không có IP nào
của pod chết → **loại trừ giả thuyết này**.

**Đường cụt 2 — nghi response quá lớn làm tràn bộ đệm nginx.**

Suy luận lúc đó: kho tài liệu `Voffice-doc-sum` có 760.540 văn bản, nên API `datasets` trả về dữ
liệu rất lớn, nginx không chứa nổi → cắt kết nối.

Kiểm tra:

```
kubectl -n ragflow exec -it ragflow-7645557fb6-zvm5n -c ragflow -- grep -n "proxy_buffer\|proxy_busy\|client_max_body\|large_client_header" /etc/nginx/nginx.conf /etc/nginx/proxy.conf
```

<details>
<summary><b>Bấm xem: giải nghĩa lệnh trên</b></summary>

```
kubectl -n ragflow exec -it <pod> -c ragflow -- grep -n "..." <file1> <file2>
│                  │     │   │     │            │      │     │
│                  │     │   │     │            │      │     └─ chuỗi cần tìm, ngăn bởi \|  (HOẶC)
│                  │     │   │     │            │      └─────── -n: hiện SỐ DÒNG tìm thấy
│                  │     │   │     │            └────────────── lệnh chạy BÊN TRONG container
│                  │     │   │     └─────────────────────────── dấu -- : hết cờ của kubectl,
│                  │     │   │                                   phần sau là lệnh của container
│                  │     │   └───────────────────────────────── -c: chọn CONTAINER nào trong pod
│                  │     └───────────────────────────────────── -i: giữ luồng nhập
│                  │                                             -t: cấp bàn phím ảo (TTY)
│                  └─────────────────────────────────────────── exec: chạy lệnh trong pod
└────────────────────────────────────────────────────────────── namespace
```

| Cờ | Vì sao cần |
|---|---|
| `-c ragflow` | Pod này có **2 container** (`ragflow` và initContainer `ragflow-code-patch`). Không chỉ định thì kubectl in cảnh báo `Defaulted container...` |
| `-n` của grep | Hiện số dòng — để lát nữa sửa đúng chỗ |
| `\|` trong chuỗi grep | Nghĩa là **HOẶC**. `"a\|b"` = tìm dòng chứa `a` hoặc `b` |

</details>

**Output thật:**

```
/etc/nginx/nginx.conf:27:    client_max_body_size 128M;
/etc/nginx/proxy.conf:6:proxy_buffering off;
```

**Đọc được gì:** 🔴 `proxy_buffering off` nghĩa là nginx **không dùng bộ đệm** — nó chuyển thẳng dữ
liệu về cho trình duyệt. Giả thuyết "tràn bộ đệm" **không áp dụng được** → **giả thuyết SAI**.

> ⭐ **Bài học**: ghi lại cả giả thuyết sai. Nếu chỉ ghi cái đúng, lần sau người khác (hoặc chính
> mình) sẽ lại đi vào đúng đường cụt đó.

### Tìm ra manh mối thật

Điểm mấu chốt: **log của nginx KHÔNG nằm trong `kubectl logs`**.

`kubectl logs` chỉ đọc những gì chương trình in ra màn hình (stdout). Nginx thì ghi lỗi vào **file
riêng** bên trong container.

```
kubectl -n ragflow exec -it ragflow-7645557fb6-zvm5n -c ragflow -- tail -30 /var/log/nginx/error.log
```

<details>
<summary><b>Bấm xem: giải nghĩa <code>tail</code></b></summary>

| Cờ | Viết tắt của | Làm gì |
|---|---|---|
| `tail` | (đuôi) | In **phần CUỐI** của file. Log mới nhất luôn ở cuối |
| `-30` | | Lấy **30 dòng** cuối. Không có số thì mặc định 10 dòng |
| `head` | (đầu) | Lệnh ngược lại — in phần ĐẦU file |
| `-f` | **f**ollow | Theo dõi **liên tục**, có dòng mới là hiện ngay. Ctrl+C để thoát |

⭐ Vì sao dùng `tail` mà không phải `cat`? Vì file log có thể hàng chục nghìn dòng — `cat` in hết
sẽ tràn màn hình, nhất là qua VDI.

</details>

**Output thật — đây là chỗ lộ ra nguyên nhân:**

```
2026/08/11 16:24:58 [error] 49#49: *299678 connect() failed (111: Connection refused)
    while connecting to upstream, client: 172.16.93.0, server: _,
    request: "POST /api/v1/datasets/73932b965e11f192725fd51894c519/chunks HTTP/1.1",
    upstream: "http://[::1]:9380/api/v1/datasets/73932b965e11f192725fd51894c519/chunks",
    host: "10.208.137.54:8999"

2026/08/11 16:24:58 [warn] 49#49: *299678 upstream server temporarily disabled
    while connecting to upstream, ...
```

**Đọc được gì:** ⭐ `upstream: "http://[::1]:9380/..."` — chú ý **`[::1]`**.

---

## PHẦN 2 — Nguyên nhân: `localhost` là cái tên có HAI địa chỉ

### Tiền đề: IPv4 và IPv6 là hai hệ địa chỉ song song

Máy tính có 2 hệ thống đánh địa chỉ tồn tại **cùng lúc**:

| Hệ | "Địa chỉ nhà mình" | Hình dạng |
|---|---|---|
| **IPv4** — hệ cũ, phổ biến | `127.0.0.1` | 4 số, ngăn bởi dấu chấm |
| **IPv6** — hệ mới | `::1` | Dùng dấu hai chấm. Trong URL phải bọc ngoặc vuông: `[::1]` |

Cả hai **đều nghĩa là "chính máy này"** — nhưng là **hai đường đi khác nhau**.

> 🛑 **Gỡ mâu thuẫn bề mặt**: đọc câu trên dễ nghĩ *"đã cùng nghĩa là chính máy này thì sao lại
> khác nhau?"* — Nghe như tự phủ định. Mảnh ghép ở giữa là:

| | Thực tế |
|---|---|
| **Đích đến** (máy nào) | Chỉ có **MỘT** — chính máy này |
| **Con đường đi tới** (giao thức) | Có **HAI** — đường IPv4 và đường IPv6, tách biệt hoàn toàn |

Ví von: nhà bạn có **1 căn**, nhưng có **2 lối vào** — cổng trước và cổng sau. Người giao hàng đi
cổng sau, mà cổng sau **khoá**, thì vẫn không giao được, dù nhà đúng là nhà đó.

### Chuyện đã xảy ra

Cấu hình nginx ghi:

```nginx
proxy_pass http://localhost:9380;
```

<details>
<summary><b>Bấm xem: <code>proxy_pass</code> là gì?</b></summary>

Nginx ở đây đóng vai **người gác cổng kiêm chuyển tiếp**: nhận request từ trình duyệt, rồi chuyển
tiếp cho chương trình xử lý thật (Flask của RagFlow) chạy ở cổng 9380.

| Thuật ngữ | Bằng lời thường |
|---|---|
| `proxy_pass` | "Chuyển tiếp request này tới địa chỉ sau" |
| **upstream** | Từ nginx dùng để gọi **cái đứng sau nó** — ở đây là Flask. Trong log lỗi luôn thấy từ này |
| `:9380` | Số cổng Flask đang lắng nghe |

</details>

Chữ **`localhost`** là một cái **tên**, không phải địa chỉ. Máy phải tra tên đó ra địa chỉ — và
kết quả tra ra được **CẢ HAI**: `::1` (IPv6) và `127.0.0.1` (IPv4).

Nginx thử **IPv6 trước**:

```
Nginx:  "Cho tôi gặp [::1]:9380"
Flask:  (chỉ mở cửa IPv4, không nghe IPv6) → im lặng, cổng đóng
Hệ điều hành: "Connection refused" (111)
Nginx:  → trả 502 cho trình duyệt NGAY
        → đánh dấu "upstream temporarily disabled"
```

### Điều này giải thích trọn vẹn cả 3 điểm khó hiểu ban đầu

| Điểm khó hiểu | Giải thích |
|---|---|
| 502 sau **36ms** | Bị từ chối ngay ở bước bắt tay kết nối. Không phải chờ backend xử lý → nên rất nhanh |
| Lỗi **ngắt quãng** | Lần nào nginx thử IPv4 → thành công 200. Lần nào thử IPv6 → 502 |
| Chỉ vài API lỗi | Thực ra **không phải**. Log cho thấy cả `POST .../chunks`, `PUT .../documents` cũng dính — chỉ là trên giao diện bạn chỉ nhìn thấy cái `datasets` |

### Vì sao lại thiết kế `localhost` ra hai địa chỉ?

Không phải lỗi. Đây là **chủ ý** để hệ thống chuyển dần từ IPv4 sang IPv6 mà không phải sửa lại
mọi cấu hình: chương trình cứ ghi `localhost`, máy nào hỗ trợ IPv6 thì tự dùng IPv6.

Nhưng chủ ý đó chỉ đúng khi **cả hai đầu** đều hỗ trợ IPv6. Ở đây Flask chỉ mở IPv4 → hỏng.

➡️ **Quy tắc rút ra**: bên trong container, luôn ghi thẳng **`127.0.0.1`** thay vì `localhost`.
Ép dùng đúng một đường, không để máy tự chọn.

---

## PHẦN 3 — ⭐ Chuỗi Chart → helm upgrade → ConfigMap → Pod

Đây là phần Kiên hỏi. Sửa cấu hình xong, để nó tới được nginx trong pod phải đi qua **4 chặng** —
đứt bất kỳ chặng nào là thất bại **âm thầm**, không báo lỗi.

```
┌──────────────────────────────────────────────────────────────────────┐
│  CHẶNG 1 — FILE CHART trên đĩa                                       │
│  templates/ragflow_config.yaml   ← BẠN SỬA Ở ĐÂY                     │
└────────────────────────────┬─────────────────────────────────────────┘
                             │  helm upgrade  (đọc file, render ra YAML)
                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│  CHẶNG 2 — HELM gửi YAML lên Kubernetes                              │
│  Kiểm tra bằng:  helm get manifest ragflow -n ragflow                │
└────────────────────────────┬─────────────────────────────────────────┘
                             │  Kubernetes lưu lại
                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│  CHẶNG 3 — CONFIGMAP nằm trên cluster                                │
│  Kiểm tra bằng:  kubectl -n ragflow get configmap nginx-config -o yaml│
└────────────────────────────┬─────────────────────────────────────────┘
                             │  pod khởi động → mount vào
                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│  CHẶNG 4 — FILE THẬT trong container                                 │
│  /etc/nginx/conf.d/ragflow.conf   ← nginx ĐỌC CÁI NÀY                │
└──────────────────────────────────────────────────────────────────────┘
```

⭐ **Vì sao phải biết 4 chặng?** Vì khi "sửa rồi mà không ăn", bạn cần biết **đứt ở chặng nào** —
mỗi chặng có cách sửa khác hẳn nhau. Không biết thì chỉ còn cách đoán mò.

### Chặng 2 → 3: vì sao sửa ConfigMap lại làm pod tạo lại?

Đây là chỗ dễ hiểu nhầm nhất.

**Sự thật phũ phàng**: Kubernetes cập nhật ConfigMap **không tự động khởi động lại pod**. Pod cũ
vẫn chạy với nội dung cũ đã mount từ lúc nó sinh ra.

Chart này giải quyết bằng một mẹo — `templates/ragflow.yaml` dòng 24-27:

```yaml
      annotations:
        checksum/values: {{ .Values | toYaml | sha256sum }}
        checksum/config-env: {{ include (print $.Template.BasePath "/env.yaml") . | sha256sum }}
        checksum/config-ragflow: {{ include (print $.Template.BasePath "/ragflow_config.yaml") . | sha256sum }}
```

<details>
<summary><b>Bấm xem: giải nghĩa từng thành phần</b></summary>

| Thành phần | Ý nghĩa |
|---|---|
| `annotations` | "Nhãn ghi chú" gắn lên pod. Kubernetes **không xử lý** nội dung, chỉ lưu |
| `sha256sum` | Hàm băm: đọc một nội dung → sinh ra chuỗi 64 ký tự **đại diện**. Nội dung đổi 1 ký tự → chuỗi đổi hoàn toàn |
| `include ... "/ragflow_config.yaml"` | Đọc nội dung file template đó |
| `checksum/config-ragflow` | Tên nhãn — đặt gì cũng được, chỉ để người đọc hiểu |

**Cơ chế**: nội dung file ConfigMap đổi → `sha256sum` đổi → giá trị annotation đổi → **bản mô tả
pod đổi** → Kubernetes thấy khác bản đang chạy → **tạo pod mới**.

</details>

**Ví von**: giống như dán lên tủ một tờ giấy ghi *"phiên bản nội thất: ABC123"*. Bên trong đổi thì
đổi luôn mã trên giấy. Người quản lý (Kubernetes) chỉ nhìn mã trên giấy — thấy khác là đóng tủ mới.

> ⚠️ **Nếu chart KHÔNG có annotation này** thì sao? ConfigMap được cập nhật nhưng pod vẫn dùng bản
> cũ. Phải khởi động lại thủ công:
>
> ```
> kubectl -n ragflow rollout restart deployment/ragflow
> ```
>
> <details>
> <summary><b>Bấm xem: giải nghĩa</b></summary>
>
> `rollout restart` thêm một nhãn thời gian vào bản mô tả pod → bản mô tả đổi → Kubernetes tạo pod
> mới **lần lượt từng cái**, không chết cả loạt.
>
> Kiểm tra chart có annotation chưa: `grep -n checksum templates/*.yaml`
> </details>

### Chặng 3 → 4: file trong pod đến từ đâu?

`templates/ragflow.yaml` — hai đoạn cần đọc cùng nhau:

**Đoạn A: khai báo "lấy ConfigMap nào"** (dòng 123-129):

```yaml
      volumes:
        - name: nginx-config-volume      ← đặt BIỆT DANH
          configMap:
            name: nginx-config           ← ⭐ TÊN THẬT của ConfigMap
        - name: service-conf-volume
          configMap:
            name: ragflow-service-config
```

**Đoạn B: khai báo "đặt vào chỗ nào trong container"** (dòng 89-98):

```yaml
        volumeMounts:
          - mountPath: /etc/nginx/conf.d/ragflow.conf.python   ← đường dẫn trong container
            subPath: ragflow.conf.python                       ← lấy file nào trong ConfigMap
            name: nginx-config-volume                          ← dùng biệt danh ở đoạn A
```

<details>
<summary><b>Bấm xem: vì sao cần cả hai đoạn?</b></summary>

| Đoạn | Trả lời câu hỏi |
|---|---|
| `volumes` | "Nguồn dữ liệu ở đâu?" — chỉ ra ConfigMap tên `nginx-config` |
| `volumeMounts` | "Đặt vào chỗ nào trong container?" — đường dẫn `/etc/nginx/conf.d/...` |
| `name` (xuất hiện ở cả hai) | **Sợi dây nối** hai đoạn. Phải trùng nhau |

| Trường | Ý nghĩa |
|---|---|
| `mountPath` | Đường dẫn **bên trong container** |
| `subPath` | Chỉ lấy **một file** trong ConfigMap, không lấy cả thư mục. Không có `subPath` thì mọi file trong ConfigMap sẽ đổ vào `mountPath`, **xoá sạch** nội dung cũ ở đó |

⭐ Vì sao chart dùng `subPath`? Vì `/etc/nginx/conf.d/` còn chứa các file khác của image
(`ragflow.conf.golang`, `ragflow.conf.hybrid`...). Không có `subPath` là mất hết.

</details>

---

## PHẦN 4 — ⭐⭐ Trả lời trực tiếp: làm sao biết được TÊN ConfigMap?

> Câu hỏi nguyên văn: *"sao bạn có thể biết được cái config map nữa chứ, tên ấy"*

Không phải đoán, cũng không phải thuộc lòng. Có **3 cách truy ra**, dùng được cho **bất kỳ chart nào**.

### Cách 1 — Truy ngược từ pod (dùng khi chỉ có cluster, không có chart)

Đi từ **file thật trong container** ngược về nguồn:

**Bước 1**: xem pod đang mount những gì:

```
kubectl -n ragflow describe pod ragflow-65485c74b5-fdkg2 | grep -A6 "Volumes:"
```

<details>
<summary><b>Bấm xem: giải nghĩa</b></summary>

```
kubectl -n ragflow describe pod <tên-pod> | grep -A6 "Volumes:"
│                  │                        │    │
│                  │                        │    └─ -A6 = After 6: lấy dòng khớp + 6 DÒNG SAU
│                  │                        └────── lọc chỉ phần cần xem
│                  └─────────────────────────────── describe: in MỌI chi tiết của pod
└────────────────────────────────────────────────── namespace
```

| Cờ grep | Viết tắt của | Làm gì |
|---|---|---|
| `-A6` | **A**fter | Lấy dòng khớp + 6 dòng **sau** nó |
| `-B6` | **B**efore | Lấy dòng khớp + 6 dòng **trước** nó |
| `-C6` | **C**ontext | Lấy cả 6 dòng trước lẫn 6 dòng sau |

⭐ Vì sao dùng `-A6`? Vì `describe pod` in ra hàng trăm dòng. Phần `Volumes:` chỉ vài dòng ngay sau
tiêu đề đó.

</details>

**Output thật (12/08/2026):**

```
Volumes:
  nginx-config-volume:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      nginx-config           ← ⭐ ĐÂY, TÊN CONFIGMAP
    Optional:  false
  service-conf-volume:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      ragflow-service-config
```

**Đọc được gì:** ⭐ Kubernetes **tự khai báo** — `Type: ConfigMap`, `Name: nginx-config`. Không cần
mở chart.

### Cách 2 — Đọc từ chart (dùng khi có sẵn file)

```
grep -rn "kind: ConfigMap" -A4 templates/
```

<details>
<summary><b>Bấm xem: giải nghĩa</b></summary>

```
grep -rn "kind: ConfigMap" -A4 templates/
│    │ │                    │   └─ tìm trong cả THƯ MỤC này
│    │ │                    └───── lấy thêm 4 dòng sau (để thấy dòng `name:`)
│    │ └────────────────────────── -n: hiện số dòng
│    └──────────────────────────── -r: recursive, tìm trong mọi file con
└───────────────────────────────── tìm chuỗi trong file
```

| Cờ | Viết tắt của | Làm gì |
|---|---|---|
| `-r` | **r**ecursive | Tìm cả trong thư mục con. Không có cờ này, grep báo lỗi khi đưa vào thư mục |
| `-n` | **n**umber | Hiện số dòng |
| `-A4` | **A**fter 4 | Lấy 4 dòng sau — vì `name:` nằm dưới `kind:` vài dòng |
| `-i` | **i**gnore-case | (không dùng ở đây) bỏ qua hoa/thường |

</details>

**Output thật:**

```
templates/ragflow_config.yaml:3:kind: ConfigMap
templates/ragflow_config.yaml:5:  name: ragflow-service-config
templates/ragflow_config.yaml:17:kind: ConfigMap
templates/ragflow_config.yaml:19:  name: nginx-config          ← ⭐
```

**Đọc được gì:** một file `ragflow_config.yaml` chứa **2 ConfigMap** — điều rất dễ bỏ sót nếu chỉ
mở file đọc lướt phần đầu.

### Cách 3 — Đối chiếu Helm đã gửi gì (mạnh nhất khi debug)

```
helm get manifest ragflow -n ragflow | grep -n "proxy_pass"
```

<details>
<summary><b>Bấm xem: <code>helm get manifest</code> khác <code>helm template</code> thế nào?</b></summary>

| Lệnh | Nguồn dữ liệu | Trả lời câu hỏi |
|---|---|---|
| `helm template .` | File chart **trên đĩa** | "Nếu apply thì YAML sẽ như thế nào?" |
| `helm get manifest <tên>` | ⭐ **Bản Helm ĐÃ apply lên cluster** | "Helm thực sự đã gửi gì lên?" |

⭐ Khi debug "sửa rồi mà không ăn", **`get manifest` mới là cái đáng tin** — nó cho thấy thực tế
đã gửi gì, chứ không phải dự đoán.

</details>

**Output thật (12/08/2026) — và đây là chỗ lộ ra thủ phạm:**

```
 93:            proxy_pass http://127.0.0.1:9381;   ← bản ĐÃ SỬA
 98:            proxy_pass http://127.0.0.1:9380;
186:            proxy_pass http://localhost:9381;   ← bản CŨ, VẪN CÒN
191:            proxy_pass http://localhost:9380;
```

**Đọc được gì:** 🔴 **CẢ HAI giá trị cùng tồn tại** trong một bản manifest. Nghĩa là có **hai nơi**
cùng định nghĩa ConfigMap `nginx-config`.

---

## PHẦN 5 — 🔴 Thủ phạm: file `.bk` trong thư mục `templates/`

Xem kỹ manifest quanh dòng 186:

```
helm get manifest ragflow -n ragflow | sed -n '150,195p'
```

<details>
<summary><b>Bấm xem: giải nghĩa <code>sed -n '150,195p'</code></b></summary>

```
sed -n '150,195p'
│   │    │   │ └─ p = print: IN dòng đó ra
│   │    │   └─── dòng kết thúc
│   │    └─────── dòng bắt đầu
│   └──────────── -n: TẮT chế độ in mặc định (nếu không sẽ in cả file, dòng chọn in 2 lần)
└──────────────── công cụ xử lý văn bản theo dòng
```

| Cách viết | Kết quả |
|---|---|
| `sed -n '150,195p'` | In dòng 150 → 195 |
| `sed -n '186p'` | In đúng 1 dòng 186 |
| `sed -n '150,$p'` | In từ dòng 150 tới hết file (`$` = dòng cuối) |

⭐ Vì sao dùng `sed` mà không phải `head`/`tail`? Vì cần **khoảng giữa** file. `head -195 | tail -46`
cũng được nhưng dài dòng hơn.

</details>

**Output thật — dòng quan trọng nhất của cả phiên debug:**

```
---
# Source: ragflow/templates/ragflow_config.yaml.bk      ← ⭐⭐ ĐUÔI .bk
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config                                    ← TRÙNG TÊN!
data:
  ragflow.conf.python: |
    server {
        ...
        location ~ ^/api/v1/admin {
            proxy_pass http://localhost:9381;           ← bản cũ
        }
```

### Vì sao file `.bk` lại được dùng?

⭐ **Helm render MỌI file trong thư mục `templates/`** — không phân biệt đuôi.

| File | Nội dung | Thứ tự | Kết quả |
|---|---|---|---|
| `ragflow_config.yaml` | ✅ Đã sửa `127.0.0.1` | Render trước | Bị ghi đè |
| `ragflow_config.yaml.bk` | 🔴 Vẫn `localhost` | Render **sau** | ⭐ **THẮNG** |

Hai file cùng khai báo ConfigMap tên `nginx-config`. Kubernetes chỉ giữ được **một** đối tượng cho
mỗi tên → cái apply sau **đè lên** cái trước.

> 🛑 **Gỡ mâu thuẫn bề mặt**: đọc tới đây dễ thắc mắc *"vừa bảo manifest có CẢ HAI giá trị, giờ lại
> bảo chỉ giữ MỘT — sao mâu thuẫn?"* Mảnh ghép:

| | Số lượng |
|---|---|
| Trong **manifest** (bản mô tả Helm gửi lên) | **HAI** khối, vì là 2 file khác nhau |
| Trên **cluster** (kết quả sau khi apply) | **MỘT**, vì trùng tên nên cái sau đè cái trước |

Xác nhận bằng lệnh 0.2 lúc đầu: `kubectl get configmap` chỉ hiện **một** `nginx-config`.

### Vì sao đây là cái bẫy khó thấy?

**Helm không có khái niệm "file sao lưu".** Trong đầu người dùng, đổi tên thành `.bk` nghĩa là *"cất
đi, không dùng nữa"*. Nhưng Helm không hiểu quy ước đó — nó đọc hết.

Tệ hơn: **không có cảnh báo nào**. `helm upgrade` báo `Upgrade complete`, pod tạo lại bình thường,
mọi thứ trông như thành công. Chỉ có nội dung là sai.

⭐ **Vì sao Helm thiết kế thế?** Vì Helm không thể đoán được đuôi file nào là "rác". Người này dùng
`.bk`, người kia dùng `.old`, `.orig`, `.save`, `.20260811`... Thay vì đoán, Helm chọn quy tắc đơn
giản: **đọc hết**, trừ file bắt đầu bằng `_` (như `_helpers.tpl`).

➡️ Nhớ **lý do thiết kế** này thì suy ra được cách tắt file đúng, không cần thuộc lòng.

### Ba cách "tắt" một file template

| Cách | Lệnh | Đánh giá |
|---|---|---|
| **Chuyển ra ngoài** `templates/` | `mv templates/x.yaml.bk ../x.yaml.bk` | ✅ **Tốt nhất** — vẫn giữ file để tra lại |
| Đổi tên bắt đầu bằng `_` | `mv templates/x.yaml.bk templates/_x.yaml.bk` | ✅ Được — Helm bỏ qua file bắt đầu bằng `_` |
| Xoá hẳn | `rm templates/x.yaml.bk` | ⚠️ Mất luôn, không tra lại được |

### Cách sửa đã dùng

```
mv templates/ragflow_config.yaml.bk /home/app/app/ragflow_config.yaml.bk.backup
```

<details>
<summary><b>Bấm xem: giải nghĩa</b></summary>

| Thành phần | Ý nghĩa |
|---|---|
| `mv <cũ> <mới>` | **M**o**v**e — di chuyển/đổi tên. **Không xoá** dữ liệu |
| `/home/app/app/` | Thư mục **cha** của chart (chart nằm ở `/home/app/app/helm_ragflow_v0.26.4`) → ra ngoài `templates/` |

⭐ Dùng `mv` chứ không `rm` — file này tồn tại 89 ngày, có thể chứa thay đổi lịch sử cần đối chiếu.

</details>

Kiểm tra còn file lạ nào khác:

```
ls -la templates/ | grep -v "\.yaml$"
```

<details>
<summary><b>Bấm xem: giải nghĩa</b></summary>

```
ls -la templates/ | grep -v "\.yaml$"
│  │ │              │    │   │     └─ $ = KẾT THÚC dòng
│  │ │              │    │   └─────── \. = dấu chấm thật (không có \ thì . nghĩa là "ký tự bất kỳ")
│  │ │              │    └─────────── -v = invert: LOẠI BỎ dòng khớp
│  │ │              └──────────────── lọc
│  │ └───────────────────────────────  -l: mỗi file một dòng, có quyền + kích thước + ngày
│  └─────────────────────────────────  -a: hiện cả file ẩn (bắt đầu bằng dấu chấm)
└────────────────────────────────────  liệt kê file
```

⭐ Kết quả: chỉ hiện file **KHÔNG** kết thúc bằng `.yaml` — tức là các file khả nghi. Bình thường
chỉ nên còn `.`, `..`, và `_helpers.tpl`.

</details>

So sánh 2 file trước khi bỏ hẳn — quan trọng vì file `.bk` đã "cầm quyền" 89 ngày:

```
diff templates/ragflow_config.yaml /home/app/app/ragflow_config.yaml.bk.backup
```

<details>
<summary><b>Bấm xem: giải nghĩa <code>diff</code></b></summary>

| Ký hiệu trong output | Ý nghĩa |
|---|---|
| `<` | Dòng chỉ có ở file **thứ nhất** |
| `>` | Dòng chỉ có ở file **thứ hai** |
| `3c3` | Dòng 3 của file 1 **c**hanged thành dòng 3 của file 2 |
| (không output gì) | Hai file **giống hệt nhau** |

⭐ Vì sao cần bước này? Vì suốt 89 ngày, mọi thay đổi trong `ragflow_config.yaml` đều bị file `.bk`
ghi đè. Có thể còn thay đổi khác cũng đang bị vô hiệu hoá mà chưa ai biết.

</details>

---

## PHẦN 6 — KHÔNG hiểu chuỗi 4 chặng vs CÓ hiểu

### Kịch bản A — Không hiểu (chính là 1 tiếng đầu của phiên này)

```
Sửa file → helm upgrade → pod tạo lại → vẫn lỗi
   ↓
"Ủa sao vẫn còn thế? Tôi chạy upgrade rồi mà?"
   ↓
Chạy lại upgrade → vẫn lỗi → nghi log cũ → nghi pod cũ
   ↓
Đoán mò, mất ~1 tiếng
```

### Kịch bản B — Có hiểu

Kiểm tra **từng chặng**, mỗi chặng một lệnh, tìm ra chỗ đứt trong ~2 phút:

| Chặng | Lệnh kiểm tra | Kết quả thật hôm đó |
|---|---|---|
| 1. File chart | `grep -n "proxy_pass" templates/ragflow_config.yaml` | ✅ `127.0.0.1` |
| 2. Helm đã gửi | `helm get manifest ragflow -n ragflow \| grep -n "proxy_pass"` | 🔴 **CÓ CẢ HAI** ← đứt ở đây |
| 3. ConfigMap | `kubectl -n ragflow get configmap nginx-config -o yaml \| grep -n "proxy_pass"` | 🔴 `localhost` |
| 4. File trong pod | `kubectl -n ragflow exec -it <pod> -c ragflow -- grep -n "proxy_pass" /etc/nginx/conf.d/ragflow.conf` | 🔴 `localhost` |

⭐ **Chặng 1 đúng nhưng chặng 2 sai** → vấn đề nằm **giữa** hai chặng, tức là ở khâu Helm đọc file
chart. Từ đó suy ra ngay: có file khác cũng đang được đọc.

---

## PHẦN 7 — Liên hệ với những gì đã gặp trong dự án này

| Bài học hôm nay | Đã gặp ở đâu trước đây |
|---|---|
| Helm render **mọi** file trong `templates/` | Cùng họ với bài học đã ghi: *"`values.yaml` nhận **mọi** key, nhưng chỉ key mà template tham chiếu mới có tác dụng"* — cả hai đều là **Helm im lặng, không cảnh báo** |
| Sửa ConfigMap cần annotation `checksum` mới rollout | Giống cơ chế patch code `get_root_folder` — dựa vào `checksum/values` để pod tạo lại |
| Log nginx không nằm trong `kubectl logs` | Giống bài học đo hiệu năng: *slow log chỉ đo MySQL, không thấy gì ≠ không có vấn đề* — **công cụ nào đo được cái gì** |
| Giả thuyết "tràn buffer" sai, phải đo mới biết | Giống hệt lần trước: đoán 25s là do MinIO/thumbnail, đo ra mới biết là MySQL full-scan |
| `localhost` → IPv6 → từ chối | Cùng dạng với `Init:ImagePullBackOff` node07/node08: **cấu hình đúng trên giấy, sai trong thực tế môi trường** |

---

## PHẦN 8 — Bảng tra nhanh các lệnh của phiên này

| Mục đích | Lệnh |
|---|---|
| Xem mọi ConfigMap | `kubectl -n ragflow get configmap` |
| Xem nội dung 1 ConfigMap | `kubectl -n ragflow get configmap nginx-config -o yaml` |
| Biết pod mount ConfigMap nào | `kubectl -n ragflow describe pod <pod> \| grep -A6 "Volumes:"` |
| Xem Helm đã gửi gì lên cluster | `helm get manifest ragflow -n ragflow` |
| Xem lịch sử các lần upgrade | `helm history ragflow -n ragflow` |
| Render thử từ file (chưa apply) | `helm template test .` |
| Đọc log lỗi nginx | `kubectl -n ragflow exec -it <pod> -c ragflow -- tail -30 /var/log/nginx/error.log` |
| Xoá trống file log để đo lại từ đầu | `kubectl -n ragflow exec -it <pod> -c ragflow -- sh -c "> /var/log/nginx/error.log"` |
| Tìm file lạ trong templates | `ls -la templates/ \| grep -v "\.yaml$"` |
| Xem pod nào ở node nào | `kubectl -n ragflow get pod -o wide` |
| Xem Service trỏ vào IP nào | `kubectl -n ragflow get endpoints ragflow` |

---

## TÓM TẮT 1 PHÚT

**Lỗi**: nginx ghi `proxy_pass http://localhost:9380`. Chữ `localhost` tra ra **hai** địa chỉ —
`::1` (IPv6) và `127.0.0.1` (IPv4). Nginx thử IPv6 trước, Flask chỉ nghe IPv4 → bị từ chối → 502
**tức thì** (36ms) và **ngắt quãng**.

**Vì sao sửa mãi không ăn**: trong `templates/` có file `ragflow_config.yaml.bk`. Helm **render mọi
file** trong thư mục đó, kể cả đuôi `.bk`. Hai file cùng khai báo ConfigMap tên `nginx-config` →
cái render sau (bản `.bk` cũ) **ghi đè** bản đã sửa.

**Chuỗi 4 chặng cần nhớ**:
```
file chart  →  helm upgrade  →  ConfigMap trên cluster  →  file trong pod
    ↑              ↑                    ↑                        ↑
  grep      helm get manifest    kubectl get cm          kubectl exec grep
```
Mỗi chặng một lệnh kiểm tra. Đứt ở đâu thì cách sửa khác hẳn — biết chặng nào đứt là biết phải làm gì.

**Làm sao biết tên ConfigMap**: `describe pod | grep -A6 "Volumes:"` — Kubernetes tự khai báo
`Type: ConfigMap` và `Name: nginx-config`. Không cần đoán, không cần thuộc lòng.
