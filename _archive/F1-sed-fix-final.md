# F1 — Fix cuối: sed 1 dòng vá get_list (dòng 114) qua postStart hook

## Đã verify (tracking thật trên container):
- Image v0.24.0 = source GitHub v0.24.0 (dòng 114, 162 khớp).
- Log 44s = `GET /api/v1/datasets/{kb}/documents` → `doc.py:608` → `DocumentService.get_list` → **dòng 114**.
- Dòng 114 nằm SAU `docs_list = list(docs.dicts())` (dòng 113) → biến docs_list đã có ~30 doc/trang.
- Dòng 162 (get_by_kb_id, web route /document/list) — KHÔNG phải cái 44s, KHÔNG đụng tới.

## Fix (đổi dòng 114):
TỪ:
    metadata_map = DocMetadataService.get_metadata_for_documents(None, kb_id)
THÀNH:
    metadata_map = DocMetadataService.get_metadata_for_documents([d["id"] for d in docs_list], kb_id)

→ chỉ kéo metadata của ~30 doc trên trang thay vì toàn bộ ~10k. get_metadata_for_documents đã
  hỗ trợ lọc doc_ids (khi truyền list) — CẦN VERIFY hàm này thực sự dùng doc_ids để lọc ở ES
  hay chỉ lọc Python (nếu chỉ lọc Python thì vẫn kéo full → phải sed thêm dòng 772).

## Lệnh sed (theo SỐ DÒNG để không đụng dòng 162):
sed -i '114s/get_metadata_for_documents(None, kb_id)/get_metadata_for_documents([d["id"] for d in docs_list], kb_id)/' /ragflow/api/db/services/document_service.py

## RỦI RO & rollback:
- Nếu hàm get_metadata_for_documents vẫn kéo full (chỉ lọc Python) → fix KHÔNG đủ, cần sed thêm dòng 772.
- postStart sed chạy SAU khi container start. Python có thể đã import module → cần restart process
  hoặc pod để ăn. CẦN kiểm: hook timeout=30 hiện có ăn ngay hay phải restart?
- Rollback: bỏ dòng sed khỏi values.yaml + helm upgrade + rollout restart.

## VERIFY sau khi áp:
V1: kubectl logs | grep _search → thấy terms doc_id ~30 thay vì size:10000
V2: đo API /documents mở KB Voffice → <1s
V3: UI KB Voffice hiện file, không 502
V5: KB 500 chunks không regression
