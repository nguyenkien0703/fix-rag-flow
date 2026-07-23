# Patch 1/3 — document_service.py dòng 114 (get_list)
Truyền doc_ids của TRANG hiện tại (docs_list đã paginate ở dòng 113) thay vì None.

TỪ (dòng 114):
        metadata_map = DocMetadataService.get_metadata_for_documents(None, kb_id)
THÀNH:
        metadata_map = DocMetadataService.get_metadata_for_documents([d["id"] for d in docs_list], kb_id)

Lưu ý: CHỈ sửa dòng 114 (trong get_list, sau paginate).
KHÔNG đụng dòng 162 (get_by_kb_id) — nó trước paginate và cần full-KB cho return_empty_metadata.
