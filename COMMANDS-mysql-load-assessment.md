# Lệnh tham khảo — MySQL load assessment

File này gộp lại **mọi lệnh có giải nghĩa cờ** đã dùng trong quá trình check tải MySQL RagFlow.
Mục đích: đọc lại khi cần, không phải lục lại chat. Xem thêm root cause/kết luận ở
`TRACKING-mysql-load-assessment.md`.

Quy ước: lệnh đơn giản không cờ (`ls`, `git status`...) không ghi vào đây.

---

## 1. Xem CPU thực trong pod MySQL

```
kubectl -n ragflow exec ragflow-mysql-0 -- top -bn1
```

| Cờ | Nghĩa |
|---|---|
| `-b` | batch mode — in ra text thường thay vì giao diện tương tác, dùng được khi pipe/redirect |
| `-n1` | chạy đúng 1 vòng lấy mẫu rồi thoát (mặc định `top` lặp vô hạn) |

**Lưu ý đã gặp**: image MySQL trong pod không có sẵn `top` (`executable file not found in $PATH`).
Không chạy được trong pod — phải chạy trên node thay thế (xem lệnh 2).

---

## 2. Xem CPU thực trên node (thay thế khi pod không có `top`)

```
top -bn1 -o %CPU | head -20
```

| Cờ | Nghĩa |
|---|---|
| `-b` | batch mode, in text thường |
| `-n1` | lấy 1 mẫu rồi thoát |
| `-o %CPU` | sắp xếp danh sách theo cột `%CPU` giảm dần |
| `\| head -20` | lấy 20 dòng đầu — gồm header (load average, cpu, mem) + ~12 tiến trình nặng nhất |

**Kết quả đã ghi nhận (node07, 2026-08-06)**:
- `mysqld` chiếm **666.7% CPU** (~6.7/8 core)
- `%Cpu(s): 80.0 us, 4.0 sy, 16.0 id, 0.0 wa` → CPU-bound, không phải I/O-bound (iowait=0)
- `load average: 19.52, 17.08, 16.20` trên node 8 core
- `buff/cache 8998700 KiB` (~8.6GB) — lý do iowait thấp dù buffer pool InnoDB chỉ 128MB:
  OS page cache đang gánh phần lớn I/O

---

## 3. Tra lý do một pod bị Evicted

```
kubectl -n ragflow get pod ragflow-64745f4649-g8pk7 -o jsonpath='{.status.message}{"\n"}{.status.reason}{"\n"}'
```

| Thành phần | Nghĩa |
|---|---|
| `-o jsonpath=...` | chỉ in đúng field cần, thay vì cả YAML dài |
| `.status.message` | câu giải thích của kubelet, dạng `The node was low on resource: ephemeral-storage` hoặc `... memory` |
| `.status.reason` | thường là `Evicted` |
| `{"\n"}` | chèn xuống dòng giữa 2 field cho dễ đọc |

Chọn pod tuổi 33h vì thuộc lứa bị đuổi sớm hơn. Pod Evicted vẫn giữ nguyên `.status` cho tới
khi bị xoá hẳn, nên vẫn tra được sau khi đã Evicted.

---

## 4. Xem sự kiện Evicted gần đây, toàn cluster

```
kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail -20
```

| Cờ | Nghĩa |
|---|---|
| `-A` | all namespaces — để biết là vấn đề riêng RagFlow hay cả node |
| `--field-selector reason=Evicted` | lọc phía server, chỉ lấy event có `reason` đúng bằng `Evicted` |
| `--sort-by=.lastTimestamp` | sắp theo thời gian tăng dần → cái mới nhất nằm cuối |
| `\| tail -20` | lấy 20 sự kiện gần nhất |

**Lưu ý**: event mặc định chỉ giữ 1 giờ trong etcd. Không ra gì ≠ không có eviction — có thể
event đã hết hạn. Khi đó dựa vào `.status.message` của pod (lệnh 3).
