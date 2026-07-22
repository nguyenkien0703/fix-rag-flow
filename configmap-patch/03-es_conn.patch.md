# Patch 3/3 — es_conn.py search() (chỗ KHÓ, cần bạn quyết định guard)

## Bối cảnh
- Metadata doc id nằm ở ES `_id`, KHÔNG có field `id` trong `_source` (đã verify: _source chỉ có kb_id).
- Muốn lọc theo doc ids ở ES → phải dùng `Q("ids", values=[...])` (nhắm _id), KHÔNG dùng `terms`.
- Patch 2 truyền key `_meta_id` xuống → es_conn cần nhận key này và map sang `ids` query.
- Codebase đã có tiền lệ nhánh đặc biệt: dòng 63-69 `if k == "available_int": ... continue`.

## Chèn nhánh mới vào vòng lặp (ngay sau dòng 62 `for k, v in condition.items():`)

```python
        for k, v in condition.items():
            if k == "_meta_id":                              # <<< THÊM MỚI
                if v:
                    bool_query.filter.append(
                        Q("ids", values=v if isinstance(v, list) else [v]))
                continue
            if k == "available_int":
                ... (giữ nguyên)
```

## *** CHỖ CẦN BẠN QUYẾT ĐỊNH (guard an toàn) ***
`ids` query nhắm `_id` — ĐÚNG cho metadata index (nơi _id == doc_id).
NHƯNG hàm search() này DÙNG CHUNG cho cả index chunk (ragflow_<tenant>), nơi cấu trúc _id khác.
Câu hỏi: có cần guard để nhánh `_meta_id` CHỈ chạy khi đang query metadata index không?

Cân nhắc 2 hướng (bạn hiểu hệ thống → chọn):

  (a) KHÔNG guard: tin rằng chỉ code metadata mới truyền key "_meta_id", nên tự nhiên
      an toàn (index chunk không bao giờ có key này trong condition).
      → Đơn giản. Rủi ro: nếu tương lai ai đó vô tình dùng key "_meta_id" ở chỗ khác.

  (b) CÓ guard theo tên index: chỉ map `ids` khi `index_names` chứa "ragflow_doc_meta".
      → An toàn tường minh. Thêm ~2 dòng:
        is_meta_idx = any("ragflow_doc_meta" in ix for ix in index_names)
        if k == "_meta_id" and is_meta_idx: ...
      Rủi ro: cần chắc tên index metadata luôn có tiền tố "ragflow_doc_meta".

Quyết định của bạn (viết vào đây): ___________________________________________

## Vì sao đây là quyết định của bạn
Bạn biết pattern dùng thật của team + quy ước đặt tên index. Hướng (a) gọn nhưng dựa
vào giả định "chỉ metadata dùng _meta_id"; hướng (b) chắc nhưng ràng vào tên index.
Đây là đánh đổi an-toàn-vs-đơn-giản mà kiến thức vận hành của bạn định hình đúng nhất.
