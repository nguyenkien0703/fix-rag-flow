# Patch 3/3 — es_conn.py (GIẢI THÍCH DIVE DEEP)

═══════════════════════════════════════════════════════════════
## PHẦN 1 — VẤN ĐỀ FILE NÀY GIẢI (dễ hiểu)
═══════════════════════════════════════════════════════════════
Root cause: hàm lấy metadata KÉO CẢ 10K doc thay vì 30. Muốn nó chỉ kéo 30 doc của trang,
ta phải bảo Elasticsearch: "chỉ trả metadata của đúng 30 document có id này" = LỌC (filter).

Vấn đề: làm sao nói với ES "lọc theo 30 id này"? → đó là việc file 03 xử lý.

### ES lưu mỗi document 2 phần TÁCH BIỆT:
1. `_id`     = "số căn cước" ngoài bìa hồ sơ (ES giữ ở tầng hệ thống).
2. `_source` = nội dung bên trong (các field dữ liệu).

### ES có 2 cách LỌC khác nhau:
- Lọc field TRONG _source (vd kb_id) → dùng lệnh `terms`/`term`.
- Lọc theo `_id` (căn cước ngoài bìa) → PHẢI dùng lệnh riêng `ids`. `terms` KHÔNG lọc được `_id`.

═══════════════════════════════════════════════════════════════
## PHẦN 2 — VÌ SAO THÀNH RẮC RỐI
═══════════════════════════════════════════════════════════════
Đã đo (căn cứ C2): document metadata của RagFlow cất doc-id ở `_id`, KHÔNG cất trong _source.
Bằng chứng thật:
    {"_id":"4397566a...", "_source":{"kb_id":"73932..."}}
            ↑ id ở đây               ↑ ruột chỉ có kb_id, KHÔNG có id

Hệ quả:
- Lọc bằng `terms {id:[...]}` → ES tìm field "id" TRONG _source → KHÔNG có → trả rỗng
  → MẤT metadata mọi doc. ĐÂY LÀ CÁI BẪY.
- Phải lọc bằng `ids:[...]` → ES tra "căn cước ngoài bìa" _id → match đúng 30 doc.

═══════════════════════════════════════════════════════════════
## PHẦN 3 — RÀO CẢN CUỐI (vì sao patch dài dòng)
═══════════════════════════════════════════════════════════════
Hàm chung `search()` trong es_conn.py nhận 1 "danh sách điều kiện lọc" = `condition`,
rồi tự dịch sang lệnh ES. Hiện nó CHỈ biết dịch sang `terms`/`term`, CHƯA biết `ids`.
Và có dòng chặn (es_conn.py:58): `assert "_id" not in condition` = cấm truyền thẳng key "_id".

→ Không thể viết condition={"_id":[...]}. Giải pháp:
  1. Dùng tên key TRUNG GIAN = "_meta_id" (tránh cả "id" lẫn "_id").
  2. DẠY search() 1 câu: "nếu thấy key _meta_id → dịch sang lệnh ids của ES".

═══════════════════════════════════════════════════════════════
## PHẦN 4 — CODE THÊM (~4 dòng vào search(), sau dòng 62)
═══════════════════════════════════════════════════════════════
File: rag/utils/es_conn.py, trong hàm search(), ngay sau `for k, v in condition.items():`

    for k, v in condition.items():
        if k == "_meta_id":                                   # <<< THÊM: gặp key trung gian
            if v:
                bool_query.filter.append(
                    Q("ids", values=v if isinstance(v, list) else [v]))   # dịch sang ids query (gõ cửa _id)
            continue                                          # xong, bỏ qua phần dưới
        if k == "available_int":
            ... (GIỮ NGUYÊN phần cũ)

(codebase đã có tiền lệ nhánh đặc biệt: dòng 63-69 `if k == "available_int": ... continue`
 → thêm nhánh `if k == "_meta_id"` là ĐÚNG convention.)

═══════════════════════════════════════════════════════════════
## PHẦN 5 — *** CHỖ CẦN BẠN QUYẾT ĐỊNH (dễ hiểu) ***
═══════════════════════════════════════════════════════════════
Hàm search() KHÔNG chỉ dùng cho metadata — còn dùng cho INDEX CHUNK (nội dung tài liệu),
nơi cấu trúc _id khác. Khi ta dạy search() hiểu "_meta_id → ids", có cần GIỚI HẠN để câu đó
CHỈ chạy khi đang tra index metadata không?

  HƯỚNG (a) — KHÔNG giới hạn:
    Tin rằng chỉ code metadata mới truyền key "_meta_id". Index chunk không bao giờ gửi key này
    → tự nhiên an toàn. Gọn, ít code.
    Rủi ro: nếu tương lai ai đó lỡ dùng lại tên "_meta_id" ở chỗ khác → sai.

  HƯỚNG (b) — CÓ giới hạn theo tên index (KHUYẾN NGHỊ):
    Thêm điều kiện: chỉ dịch "_meta_id" khi tên index chứa "ragflow_doc_meta".
    An toàn tường minh. Thêm ~2 dòng:
        is_meta_idx = any("ragflow_doc_meta" in ix for ix in index_names)
        if k == "_meta_id" and is_meta_idx:
            ...
    Rủi ro: phụ thuộc index metadata luôn có tiền tố "ragflow_doc_meta" (đã thấy ĐÚNG: ragflow_doc_meta_22cdb...).

QUYẾT ĐỊNH CỦA BẠN (a/b): ______

### Vì sao là quyết định của bạn
Cả 2 đều chạy đúng HIỆN TẠI. Khác nhau ở mức phòng thủ trước sai sót TƯƠNG LAI.
(a) tin vào quy ước "không ai dùng lại _meta_id"; (b) không tin, kiểm tên index cho chắc.
Bạn là người vận hành lâu dài, biết team có hay đụng code này + quy ước đặt tên index ổn định không
→ bạn định được mức phòng thủ hợp lý. Mình recommend (b): an toàn hơn cho prod, chỉ tốn 2 dòng.
