# Quy trình deploy fix qua ConfigMap (KHÔNG build image, KHÔNG sed mong manh)

## Ý tưởng
Đóng gói 3 file .py ĐÃ SỬA thành ConfigMap, mount đè vào đúng path trong container qua values.yaml.
Sạch, tracking được (file .py nằm trong git chart), rollback = gỡ mount.

## CẠM BẪY đã xác minh (research):
1. Field metadata id ở ES `_id`, KHÔNG có field `id` trong _source → phải dùng `ids` query, KHÔNG `terms`.
2. es_conn.py:58 `assert "_id" not in condition` → dùng key trung gian `_meta_id`.
3. Werkzeug single-process → sed KHÔNG ăn cho process đang chạy → BẮT BUỘC rollout restart pod sau deploy.
4. Chỉ fix get_list (dòng 114), KHÔNG đụng get_by_kb_id (dòng 162 cần full-KB cho return_empty_metadata).

## Các bước (sau khi chốt patch 3):
1. Lấy 3 file gốc từ container ra:
   kubectl cp ragflow/POD:/ragflow/api/db/services/document_service.py ./document_service.py
   kubectl cp ragflow/POD:/ragflow/api/db/services/doc_metadata_service.py ./doc_metadata_service.py
   kubectl cp ragflow/POD:/ragflow/rag/utils/es_conn.py ./es_conn.py
2. Áp 3 patch vào 3 file (chỉnh tay theo 01/02/03).
3. Tạo ConfigMap từ 3 file (hoặc dùng chart nếu chart hỗ trợ extraVolumes).
4. Thêm vào values.yaml: volumeMount đè 3 file vào đúng path.
5. helm upgrade + kubectl rollout restart statefulset/deployment ragflow -n ragflow.

## VERIFY (V):
V1: kubectl logs | grep ESConnection.search → thấy query có "ids" ~30 values, KHÔNG còn size:10000 khi mở KB.
V2: đo API /documents mở KB Voffice → <1s (thay 44s).
V3: UI KB Voffice hiện file + metadata ĐÚNG (kiểm 1 doc có promulgateDate... hiển thị).  <<< QUAN TRỌNG: không mất metadata
V4: KB 500 chunks không regression.
V5: lọc "empty metadata" (nếu team dùng) vẫn đúng — nhưng nó đi qua get_by_kb_id, ta không đụng → an toàn.

## ROLLBACK nếu hỏng:
- Gỡ volumeMount khỏi values.yaml + helm upgrade + rollout restart → về file gốc trong image.
- Nếu container không start: kubectl rollout undo.
