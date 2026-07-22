# F1 — Patch fix gốc: chỉ kéo metadata của trang hiện tại (không phải 10k)

> File sửa: `api/db/services/document_service.py` → `DocumentService.get_by_kb_id`
> Và: `api/db/services/doc_metadata_service.py` → `get_metadata_for_documents`
> Mục tiêu: mở KB Voffice không còn kéo 10k metadata → hết chậm 44s → hết 502.

## Ý tưởng
Hiện tại (dòng 162) build `metadata_map` cho TOÀN BỘ KB TRƯỚC khi paginate.
Fix: dời xuống SAU paginate, chỉ kéo metadata của ~30 doc trên trang.
Nhánh `return_empty_metadata=True` giữ nguyên quét-full (nó cần biết mọi doc có metadata).

## Bước 1 — get_metadata_for_documents lọc theo doc_ids ở tầng ES
File doc_metadata_service.py, hàm dòng 759. Hiện nhận doc_ids nhưng BỎ QUA. Sửa:

    if doc_ids:
        condition = {"kb_id": kb_id, "doc_id": list(doc_ids)}   # list -> ES terms filter
    else:
        condition = {"kb_id": kb_id}
    results = cls._search_metadata(kb_id, condition=condition,
                                   limit=len(doc_ids) if doc_ids else 10000)
    # phần còn lại giữ nguyên

VERIFY: field trong metadata index tên `doc_id` hay `id`? Check bằng lệnh 8c (mapping) trước khi build.

## Bước 2 — get_by_kb_id: dời build metadata xuống sau paginate
Thay đoạn từ dòng 162 tới hết hàm:

    if return_empty_metadata:
        metadata_map = DocMetadataService.get_metadata_for_documents(None, kb_id)  # full như cũ
        doc_ids_with_metadata = set(metadata_map.keys())
        if doc_ids_with_metadata:
            docs = docs.where(cls.model.id.not_in(doc_ids_with_metadata))

    count = docs.count()
    if desc:
        docs = docs.order_by(cls.model.getter_by(orderby).desc())
    else:
        docs = docs.order_by(cls.model.getter_by(orderby).asc())
    if page_number and items_per_page:
        docs = docs.paginate(page_number, items_per_page)

    docs_list = list(docs.dicts())

    if return_empty_metadata:
        for doc in docs_list:
            doc["meta_fields"] = {}
    else:
        # FIX F1: chỉ kéo metadata cho doc trên trang
        page_doc_ids = [d["id"] for d in docs_list]
        metadata_map = DocMetadataService.get_metadata_for_documents(page_doc_ids, kb_id) if page_doc_ids else {}
        for doc in docs_list:
            doc["meta_fields"] = metadata_map.get(doc["id"], {})

    return docs_list, count

## *** CHỖ CẦN BẠN QUYẾT ĐỊNH (5-10 dòng) ***
Nếu UI gọi page_size cực lớn (vd 10000 để "load all") thì page_doc_ids lại = 10k -> chậm lại.
Câu hỏi: có nên safety-cap số metadata kéo mỗi lần? Xử lý page_size lớn bất thường sao?
Chèn vào đầu path else, Bước 2:

    page_doc_ids = [d["id"] for d in docs_list]
    # TODO(ban): quyet dinh safety cap:
    #   (a) khong cap - tin page_size hop ly (don gian)
    #   (b) cap cung: len > N thi chi keo N doc dau + log canh bao
    #   (c) ep page_size <= N o tang API (document_app.py)
    # ES terms gioi han ~65536; keo >1-2k metadata/lan da cham. N = ? ______

## Sau patch: build + deploy
1. Sửa 2 file. 2. Cân nhắc trả postStart timeout=30 về 600 (workaround không cần nữa).
3. Build image -> push -> helm upgrade -> verify.

## Verify
| V | Cách | Đạt nếu |
|---|------|---------|
| V1 | Log ES mở KB Voffice | KHÔNG còn _search size:10000; thay bằng terms doc_id ~30 |
| V2 | Đo API /documents | < 1s (thay 44s) |
| V3 | UI KB Voffice | Hiện file ngay, không 502 |
| V4 | Lọc empty metadata | Vẫn đúng (không vỡ return_empty_metadata) |
| V5 | KB 500 chunks | Không regression |
