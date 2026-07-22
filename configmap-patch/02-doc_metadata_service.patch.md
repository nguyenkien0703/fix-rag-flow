# Patch 2/3 — doc_metadata_service.py dòng 772 (get_metadata_for_documents)
Đẩy doc_ids vào condition để ES lọc, thay vì kéo full rồi lọc Python.
Dùng key đặc biệt "_meta_id" (KHÔNG phải "id" vì id không có trong _source;
KHÔNG phải "_id" vì es_conn dòng 58 assert cấm "_id").

TỪ (dòng 772):
            results = cls._search_metadata(kb_id, condition={"kb_id": kb_id})
THÀNH:
            _cond = {"kb_id": kb_id}
            if doc_ids:
                _cond["_meta_id"] = list(doc_ids)
            results = cls._search_metadata(kb_id, condition=_cond)

→ es_conn (patch 3) sẽ nhận "_meta_id" và map sang ES `ids` query trên _id.
Phần còn lại của hàm (lọc Python dòng 785) GIỮ NGUYÊN — nó vô hại, chỉ là lớp lọc thừa giờ đã đúng 30 doc.
