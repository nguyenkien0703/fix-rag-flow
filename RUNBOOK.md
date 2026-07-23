# RUNBOOK — Fix RagFlow KB Voffice 502 (chậm 44s)
> ĐÂY LÀ TÀI LIỆU DUY NHẤT BẠN FOLLOW. Làm từ trên xuống. Mỗi bước: chạy CMD → dán KẾT QUẢ vào ô.
> Các file khác chỉ để tham khảo: F1-fix-final-research.md (phân tích), ragflow-debug-plan.md (nhật ký),
> ragflow-giai-thich-stale-connection.md (giải thích).

## BIẾN DÙNG CHUNG (set 1 lần mỗi khi mở terminal mới)
```
POD=ragflow-78dd4c855-shdq8
```
Kiểm pod còn sống:  `kubectl get pod -n ragflow $POD`
KẾT QUẢ: ____________________________________________

===================================================================
## GIAI ĐOẠN 0 — ĐÃ XONG (không cần làm lại, chỉ để biết)
===================================================================
- [x] Root cause: get_list (document_service.py:114) kéo TOÀN BỘ ~10k metadata/KB → parse Python ~40s → 502.
- [x] Verify: doc id ở ES `_id` (KHÔNG có field `id` trong _source) → phải dùng `ids` query.
- [x] Fix = sửa 3 file, deploy qua ConfigMap, BẮT BUỘC rollout restart pod.

===================================================================
## GIAI ĐOẠN 1 — QUYẾT ĐỊNH (bạn làm, không cần terminal)
===================================================================
### BƯỚC 1.1 — Đọc file 03-es_conn.patch.md, chọn hướng guard:
  (a) không guard — đơn giản
  (b) guard theo tên index "ragflow_doc_meta" — an toàn tường minh (khuyến nghị)
QUYẾT ĐỊNH CỦA BẠN (a/b): ______

===================================================================
## GIAI ĐOẠN 2 — LẤY FILE GỐC TỪ CONTAINER (bạn chạy)
===================================================================
### BƯỚC 2.1 — Copy 3 file gốc ra máy (để sửa)
```
kubectl cp ragflow/$POD:/ragflow/api/db/services/document_service.py    ./document_service.py
kubectl cp ragflow/$POD:/ragflow/api/db/services/doc_metadata_service.py ./doc_metadata_service.py
kubectl cp ragflow/$POD:/ragflow/rag/utils/es_conn.py                    ./es_conn.py
ls -la *.py
```
KẾT QUẢ (3 file có tải về không?): ____________________________________________

### BƯỚC 2.2 — Backup nguyên bản (để rollback)
```
mkdir -p _backup && cp document_service.py doc_metadata_service.py es_conn.py _backup/
ls _backup/
```
KẾT QUẢ: ____________________________________________

===================================================================
## GIAI ĐOẠN 3 — SỬA 3 FILE (theo 01/02/03; gửi mình để mình sửa hộ nếu muốn)
===================================================================
### BƯỚC 3.1 — Sửa document_service.py (theo 01-document_service.patch.md)
  Dòng 114: None → [d["id"] for d in docs_list]
ĐÃ SỬA? (y/n): ____

### BƯỚC 3.2 — Sửa doc_metadata_service.py (theo 02-doc_metadata_service.patch.md)
  Dòng 772: thêm _cond["_meta_id"] = list(doc_ids) khi có doc_ids
ĐÃ SỬA? (y/n): ____

### BƯỚC 3.3 — Sửa es_conn.py (theo 03-es_conn.patch.md + quyết định 1.1)
  Thêm nhánh if k == "_meta_id": Q("ids", values=...)
ĐÃ SỬA? (y/n): ____

### BƯỚC 3.4 — Kiểm syntax 3 file (không lỗi Python)
```
python3 -m py_compile document_service.py doc_metadata_service.py es_conn.py && echo "SYNTAX OK"
```
KẾT QUẢ: ____________________________________________

===================================================================
## GIAI ĐOẠN 4 — TẠO CONFIGMAP + SỬA values.yaml (mình sẽ đưa command chính xác ở đây sau khi bạn xong GĐ3)
===================================================================
### BƯỚC 4.1 — Tạo ConfigMap từ 3 file
CMD: (mình điền sau khi biết chart mount kiểu gì) ____
KẾT QUẢ: ____

### BƯỚC 4.2 — Thêm volumeMount vào values.yaml
(mình đưa đoạn yaml sau khi xem cấu trúc templates/) ____

### BƯỚC 4.3 — helm upgrade
```
cd /home/app/app/ragflow-0.24.0/helm
helm upgrade ragflow . -n ragflow -f values.yaml
```
KẾT QUẢ: ____________________________________________

### BƯỚC 4.4 — ROLLOUT RESTART (BẮT BUỘC — sed/mount không ăn nếu không restart)
```
kubectl rollout restart deployment ragflow -n ragflow   # hoặc statefulset, tùy chart
kubectl rollout status  deployment ragflow -n ragflow
```
KẾT QUẢ: ____________________________________________

===================================================================
## GIAI ĐOẠN 5 — VERIFY (bạn chạy, dán kết quả)
===================================================================
### V1 — Log ES khi mở KB Voffice: thấy "ids" ~30 thay vì size:10000
```
kubectl logs -n ragflow $POD --tail=100 | grep "ESConnection.search"
```
Rồi mở UI KB Voffice, xem log mới.
KẾT QUẢ (có "ids" ~30 không? còn size:10000 không?): ____________________________________________

### V2 — Đo API /documents mở KB Voffice
Mở UI KB Voffice, xem Network tab request /documents mất bao lâu.
KẾT QUẢ (giây): ______   (ĐẠT nếu < ~2s, trước đó 44s)

### V3 — UI hiện file + metadata ĐÚNG (QUAN TRỌNG: không mất metadata)
Mở KB Voffice, click 1 file, xem cột Metadata có dữ liệu không.
KẾT QUẢ (metadata còn hiển thị đúng không?): ____________________________________________

### V4 — KB 500 chunks không regression
Mở 1 KB nhỏ khác, vẫn nhanh như cũ?
KẾT QUẢ: ____________________________________________

===================================================================
## ROLLBACK (nếu hỏng ở bất kỳ bước nào)
===================================================================
```
# Gỡ mount khỏi values.yaml + helm upgrade, HOẶC:
kubectl rollout undo deployment ragflow -n ragflow
```
- File gốc còn trong _backup/ và trong image (pullPolicy Never).
KẾT QUẢ rollback: ____________________________________________
