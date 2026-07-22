# F1 — Fix cuối (sau research kỹ code thật, verify khớp container v0.24.0)

## PHÁT HIỆN QUAN TRỌNG: sed 1 dòng KHÔNG đủ
`get_metadata_for_documents` (doc_metadata_service.py:759) PHỚT LỜ doc_ids ở tầng ES:
- Dòng 772: `results = cls._search_metadata(kb_id, condition={"kb_id": kb_id})` → LUÔN kéo full 10k.
- Dòng 785: chỉ lọc doc_ids bằng PYTHON sau khi đã kéo + parse hết.
⟹ Chỉ sửa dòng 114 (đổi None→doc_ids) là VÔ DỤNG: vẫn kéo 10k từ ES + parse 10k JSON (~40s).

## es_conn.search HỖ TRỢ lọc terms (đã verify):
- es_conn.py:72-73: `if isinstance(v, list): bool_query.filter.append(Q("terms", **{k: v}))`
  → condition có value LIST → ES `terms` filter. Truyền `doc_id: [ids]` sẽ lọc đúng.
- es_conn.py:58: `assert "_id" not in condition` → chỉ cấm "_id", KHÔNG cấm "doc_id". An toàn.

## FIX ĐÚNG = sửa 2 chỗ (cả hai, thiếu 1 là vô dụng):

### Chỗ 1 — doc_metadata_service.py dòng 772 (chỗ cắt 40s):
TỪ:  results = cls._search_metadata(kb_id, condition={"kb_id": kb_id})
THÀNH: results = cls._search_metadata(kb_id, condition=({"kb_id": kb_id, "doc_id": list(doc_ids)} if doc_ids else {"kb_id": kb_id}), limit=(len(doc_ids) if doc_ids else 10000))

### Chỗ 2 — document_service.py dòng 114 (truyền 30 doc_ids của trang):
TỪ:  metadata_map = DocMetadataService.get_metadata_for_documents(None, kb_id)
THÀNH: metadata_map = DocMetadataService.get_metadata_for_documents([d["id"] for d in docs_list], kb_id)
(CHỈ dòng 114, KHÔNG đụng dòng 162 — 162 trước paginate, không có docs_list)

## 2 CẠM BẪY PHẢI XÁC NHẬN TRƯỚC KHI DEPLOY (subagent đang check):
1. FIELD NAME: metadata index dùng "doc_id" hay "id"? Sai tên → terms không match → MẤT metadata mọi doc.
   (bản GitHub _extract_doc_id ưu tiên doc.get("doc_id") → khả năng cao là "doc_id", nhưng phải verify index mapping thật)
2. postStart SED CÓ ĂN KHÔNG: module Python import vào memory lúc start. Sed file trên disk SAU khi
   process chạy → process cũ KHÔNG thấy. Có thể cần `kubectl rollout restart` sau sed, hoặc sed phải
   chạy trước khi ragflow_server.py import. (hook timeout=30 hiện có — kiểm nó ăn kiểu gì)

## Cách verify field name (chạy trên container):
kubectl exec -n ragflow $POD -- sh -c \
'curl -sk -u "aihub_prod:PASS" "https://10.211.145.107:8051/ragflow_doc_meta_22cdb01e486a11f1ac9749e86cfe939a/_mapping?pretty" | grep -A2 doc_id'

## VERIFY sau deploy:
V1: log ES → thấy terms doc_id ~30 thay size:10000
V2: API /documents mở KB Voffice < 1s
V3: UI KB Voffice hiện file + CÓ metadata đúng (không mất metadata)
V5: KB 500 chunks không regression

---

## CẠM BẪY 1 ĐÃ XÁC MINH (mapping thật trên container):
Index ragflow_doc_meta_... KHÔNG có field "doc_id". Field định danh document = **"id"** (type keyword, store true).
- Nếu fix dùng condition={"doc_id":[...]} → terms filter trên field KHÔNG tồn tại → trả rỗng → MẤT metadata mọi doc.
- PHẢI dùng condition={"id":[...]}.
- es_conn.py:58 assert "_id" not in condition → field "id" (không phải "_id") QUA được assert. An toàn.
- _extract_doc_id (GitHub dòng 100) có fallback doc.get("id") → đọc được field "id". OK.

## FIX ĐÚNG (cập nhật field name → "id"):
### Chỗ 1 — doc_metadata_service.py:772:
THÀNH: results = cls._search_metadata(kb_id, condition=({"kb_id": kb_id, "id": list(doc_ids)} if doc_ids else {"kb_id": kb_id}), limit=(len(doc_ids) if doc_ids else 10000))
### Chỗ 2 — document_service.py:114:
THÀNH: metadata_map = DocMetadataService.get_metadata_for_documents([d["id"] for d in docs_list], kb_id)

## CÒN VERIFY: thử terms {id:[...]} trên ES thật match không, trước khi đụng code.
