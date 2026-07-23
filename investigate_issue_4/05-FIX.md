# 05 — FIX Issue #4: retrieval chậm trên KB nhiều tài liệu

> Root cause: `investigate_issue_4/04-root-cause.md`. File này CHỈ chứa patch + lệnh deploy + verify.
> Ràng buộc deploy: KHÔNG build image (`pullPolicy: Never`). Fix code = patch file .py trong container qua
> lifecycle `postStart` (sed) trong `values.yaml`, rồi `helm upgrade` + `rollout restart`.

---

## 1. Thay đổi code (1 dòng logic, tại `rag/nlp/query.py`)

### Vị trí: hàm `FulltextQueryer.question()`, nhánh xử lý câu hỏi KHÔNG phải tiếng Trung (bao gồm tiếng Việt)

**Trước (dòng 84-86 trong source v0.24.0 — THIẾU minimum_should_match):**
```python
            return MatchTextExpr(
                self.query_fields, query, 100, {"original_query": original_query}
            ), keywords
```

**Sau (thêm `minimum_should_match: min_match`, giống hệt cách nhánh tiếng Trung đã làm ở dòng 170):**
```python
            return MatchTextExpr(
                self.query_fields, query, 100,
                {"minimum_should_match": min_match, "original_query": original_query}
            ), keywords
```

> `min_match` là tham số ĐÃ ĐƯỢC TRUYỀN VÀO hàm `question()` từ nơi gọi (`search.py:114` gọi với `min_match=0.3`
> = 30%), nhưng nhánh này trước giờ bỏ qua không dùng. Không cần thêm biến mới, chỉ cần đưa nó vào dict trả về.

### Vì sao chọn 30% (không phải số khác)
- `search.py:114`: `self.qryr.question(qst, min_match=0.3)` — đây là giá trị ĐANG được truyền cho retrieval
  chính (cả 2 nhánh Chinese/non-Chinese cùng nhận `min_match=0.3` từ nơi gọi). Sửa để nhánh Việt DÙNG giá trị
  này (thay vì bỏ qua) — không đổi con số 30% đã có sẵn trong hệ thống, chỉ sửa chỗ bị bỏ sót.
- RagFlow có sẵn lưới đỡ: nếu min_match=30% làm kết quả rỗng (`total==0`), `search.py:135-146` tự động
  fallback gọi lại với `min_match=0.1` (10%) — nên không lo mất kết quả hợp lệ do set quá cao.

---

## 2. Patch trong container (KHÔNG build image — dùng sed qua postStart hook)

### Bước 2.1 — Verify file THẬT trong pod khớp đúng dòng trước khi patch (BẮT BUỘC)
```bash
POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
echo "POD=$POD"

# Xem đúng nội dung 3 dòng cần sửa trong file THẬT của container (không phải source GitHub)
kubectl -n ragflow exec "$POD" -- sed -n '80,90p' /ragflow/rag/nlp/query.py
```
**Đối chiếu:** nội dung phải khớp với "Trước" ở mục 1. Nếu số dòng lệch (do version/patch khác trước đó),
dùng `grep -n 'original_query": original_query' /ragflow/rag/nlp/query.py` trong pod để tìm đúng dòng thật
rồi điều chỉnh lệnh sed ở bước 2.2 theo số dòng thật.

```bash
# Cách tìm nhanh, không phụ thuộc số dòng cố định:
kubectl -n ragflow exec "$POD" -- grep -n '{"original_query": original_query}' /ragflow/rag/nlp/query.py
```
→ Nếu ra ĐÚNG 1 dòng, đó là dòng cần sửa (nhánh non-Chinese, dòng 169 nhánh Chinese đã có
`minimum_should_match` nên không match chuỗi tìm ở trên).

### Bước 2.2 — Lệnh sed thay thế (dùng NGAY TRONG postStart hook, xem mục 3)
```bash
sed -i 's/{"original_query": original_query}/{"minimum_should_match": min_match, "original_query": original_query}/' /ragflow/rag/nlp/query.py
```
- Chuỗi khớp `{"original_query": original_query}` chỉ xuất hiện ĐÚNG 1 LẦN trong file (đã grep xác nhận ở
  2.1) → sed an toàn, không đụng nhầm dòng 169/235.

### Bước 2.3 — Test lệnh sed TRỰC TIẾP trên pod trước khi đưa vào values.yaml (khuyến nghị làm trước)
```bash
# Backup trước khi thử
kubectl -n ragflow exec "$POD" -- cp /ragflow/rag/nlp/query.py /ragflow/rag/nlp/query.py.bak

# Áp thử
kubectl -n ragflow exec "$POD" -- sed -i 's/{"original_query": original_query}/{"minimum_should_match": min_match, "original_query": original_query}/' /ragflow/rag/nlp/query.py

# Verify đã đổi đúng
kubectl -n ragflow exec "$POD" -- grep -n 'minimum_should_match' /ragflow/rag/nlp/query.py

# Restart pod để RagFlow load lại code đã patch (patch trực tiếp KHÔNG tự apply cho tới khi restart)
kubectl -n ragflow rollout restart deployment/ragflow -n ragflow   # sửa tên deployment nếu khác
```
> Đây là cách thử NGAY để verify hiệu quả fix trước khi cam kết vào values.yaml (dễ rollback: nếu lỗi,
> `cp /ragflow/rag/nlp/query.py.bak /ragflow/rag/nlp/query.py` rồi restart lại — vì patch nằm trong
> container hiện tại, pod restart thường sẽ dùng lại image gốc nên mất patch, cần làm lại qua postStart
> để patch tồn tại lâu dài — xem mục 3).

---

## 3. Đưa patch vào `values.yaml` (postStart hook — để patch KHÔNG mất khi pod restart/reschedule)

Tìm block `lifecycle.postStart` hiện có trong `values.yaml` (đã có tiền lệ patch `es_conn.py` timeout theo
memory dự án) và THÊM lệnh sed mới vào CÙNG chuỗi lệnh (không tạo hook riêng, tránh override lẫn nhau):

```yaml
# values.yaml (đoạn lifecycle.postStart hiện có — THÊM 1 dòng sed mới vào exec.command)
lifecycle:
  postStart:
    exec:
      command:
        - /bin/sh
        - -c
        - |
          sed -i 's/timeout=600/timeout=30/g' /ragflow/rag/utils/es_conn.py
          sed -i 's/{"original_query": original_query}/{"minimum_should_match": min_match, "original_query": original_query}/' /ragflow/rag/nlp/query.py
```

> Giữ nguyên các lệnh sed cũ đã có, chỉ APPEND thêm dòng mới — không xóa/đổi thứ tự các dòng hiện tại.

### Deploy
```bash
helm upgrade ragflow /home/app/app/ragflow-0.24.0/helm -n ragflow -f values.yaml
kubectl -n ragflow rollout restart deployment/ragflow   # sửa tên deployment/statefulset nếu khác
kubectl -n ragflow rollout status deployment/ragflow
```

---

## 4. VERIFY sau khi deploy

### V1 — Patch đã vào file chưa
```bash
POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
kubectl -n ragflow exec "$POD" -- grep -n 'minimum_should_match' /ragflow/rag/nlp/query.py
```
→ Phải thấy CẢ 2 dòng (nhánh Chinese gốc + nhánh Việt vừa patch).

### V2 — Đo lại đúng kịch bản đã dùng để chốt root cause (so sánh trước/sau)
Vào UI → Search → KB **voffice-docs-sum** (141k) → hỏi lại CHÍNH XÁC câu đã test:
```
quy định về thời hạn thanh toán và nghiệm thu hợp đồng xây dựng
```
**Kỳ vọng:** thời gian phản hồi giảm mạnh từ ~15s xuống dưới 1-2s.

### V3 — Xem log ES để xác nhận minimum_should_match đã đổi + total_hits giảm
```bash
kubectl -n ragflow logs -f "$POD" --since=1s | grep -iE "_search|duration"
```
Chạy lại query dài ở trên UI, kỳ vọng thấy `duration` giảm mạnh so với `12.66s`/`14.2s` đã đo trước đó.

Đối chứng bằng curl trực tiếp ES (không qua UI) — bắt query thật rồi replay như đã làm ở `measure3.sh`,
kiểm tra `total_hits` giảm từ `>=10000` xuống còn vài trăm/nghìn (tùy độ phổ biến từ khóa thật).

### V4 — Kiểm tra KHÔNG regression độ chính xác tìm kiếm
Thử lại vài câu hỏi thực tế khác (kể cả câu ngắn/dùng từ hiếm) trên CẢ 2 KB (lớn và nhỏ), xác nhận:
- Kết quả trả về vẫn đúng/liên quan (không bị rỗng do min_match quá cao).
- Nếu 1 câu hỏi cụ thể trả về rỗng bất thường, kiểm tra RagFlow có tự fallback về `min_match=0.1` không
  (cơ chế có sẵn ở `search.py:135-146`, dựa trên total=0).

### V5 — Đối chứng KB nhỏ (test_tải, 500 chunks) không bị ảnh hưởng xấu
Query lại câu tương tự trên KB nhỏ, xác nhận thời gian vẫn nhanh (~ms) và kết quả không đổi bất thường.

---

## 5. Rollback (nếu V2-V4 phát hiện vấn đề)
```bash
# Cách 1: sửa lại values.yaml — xóa dòng sed mới thêm ở mục 3 — rồi helm upgrade + rollout restart.
# Cách 2 (khẩn cấp, tại chỗ): restore file gốc trong pod hiện tại rồi restart
kubectl -n ragflow exec "$POD" -- cp /ragflow/rag/nlp/query.py.bak /ragflow/rag/nlp/query.py
kubectl -n ragflow rollout restart deployment/ragflow
```
> Vì RagFlow là service stateless (đọc/ghi qua ES/MySQL, không giữ state trong pod), rollback an toàn,
> không mất dữ liệu — patch chỉ ảnh hưởng CÁCH build query, không ghi/xóa gì trong ES.

---

## 6. Rủi ro & lưu ý
- **Không có staging** — môi trường hiện tại là thử nghiệm (theo bối cảnh đã ghi nhận ở Issue A) → nên:
  test trên 1 câu hỏi cụ thể trước, quan sát vài phút, rồi mới coi là ổn định.
- Báo trước các bên đang cắm API vào RagFlow trước giờ deploy (rollout restart có downtime ngắn).
- `minimum_should_match=30%` là số ĐANG CÓ SẴN trong hệ thống (dùng cho tiếng Trung + được truyền nhưng bỏ
  qua ở tiếng Việt) — không phải số mới tự nghĩ ra, nên rủi ro thấp hơn so với đặt 1 con số hoàn toàn mới.
- Nếu sau khi fix vẫn còn chậm đáng kể (không về dưới 1-2s), quay lại `04-root-cause.md` mục 6 (khoảng
  trống ES 3.3s vs UI 15s) để đo tiếp phần ngoài ES chưa được giải thích hết.
