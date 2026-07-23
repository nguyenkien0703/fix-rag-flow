# 03 — Số liệu đo thật (2026-07-23)

## BƯỚC 0 — Môi trường
```
DOC_ENGINE=elasticsearch
ES_HOST=10.211.145.107 : ES_PORT=8051  (ELASTICSEARCH_HOSTS=https://10.211.145.107:8051)
ES_USER=aihub_prod
LOG_LEVELS=root=DEBUG
INDEX=ragflow_22cdb01e486a11flac9749e86cfe939a   (KB lớn ~120k)
```

## BƯỚC 1 — ES _search duration (KB lớn, KHÔNG rerank)
| Query | Độ dài | ES `_search duration` |
|-------|--------|-----------------------|
| A "hợp đồng" (ngắn) | 1 từ | **1.544s** |
| B "quy định về thời hạn thanh toán và nghiệm thu hợp đồng xây dựng" (dài) | ~10 từ | **14.216s** |

- Network `/retrieval_test` tổng dao động **2.37s → 35.24s** (nhiều lần test).
- **Quan sát chốt của Kiên: query DÀI → chậm; query NGẮN → nhanh.** ⟹ chi phí scale theo SỐ KEYWORD, không theo vector.

## BƯỚC 3 — Mapping vector + segments
### Mapping: vector field OK — HNSW, KHÔNG brute-force
```
*_512_vec / *_768_vec / *_1024_vec / *_1536_vec : dense_vector, index:true, similarity:cosine
q_4096_vec : dense_vector, index:true, similarity:cosine, index_options{type:int8_hnsw, m:16, ef_construction:100}
question_tks : text, analyzer:whitespace, similarity:scripted_sim
```
⟹ kNN dùng HNSW đúng chuẩn → **LOẠI giả thuyết brute-force vector.**

### Segments index lớn: NHIỀU segment khổng lồ chưa merge
```
shard docs.count  size
0     45577        4.9gb     ← 1 segment 45k doc
0     2524         282.3mb
0     2408 / 2873 / 8704 / 1706 / 2799 ...  (nhiều segment lớn)
1     15370        1.6gb
1     30459        3.3gb     ← 1 segment 30k doc
1     3343 / 2573 / 2194 / 5665 / 1691 ...
```
⟹ full-text (BM25) phải quét posting trên các segment lớn; càng nhiều keyword càng nhiều posting.

## KẾT LUẬN TÁCH TẦNG
- ~toàn bộ thời gian nằm ở **1 ES `_search`** (1.5s→14s), KHÔNG ở Python/rerank/embedding.
- Chênh lệch do **độ dài query text** (số keyword) → thủ phạm = **BM25 `query_string` match rộng + `track_total_hits=True`** đếm toàn bộ match trên 120k.
- kNN HNSW: vô can (mapping đúng). Rerank: vô can (chỉ 30-64 chunk). → khớp `01-code-analysis.md`.

---
## BƯỚC 2b — Probe tách track_total_hits vs BM25 (2026-07-23) — LẬT GIẢ THUYẾT
Index đúng: `ragflow_22cdb01e486a11ec9749e86cfe939a` (141,978 docs, 15.4gb).
Query dài B, CHỈ BM25 query_string (không kNN):
| Biến thể | took_ms |
|----------|---------|
| (1) BM25 + track_total_hits=TRUE  | **262ms** (total=141,773 eq) |
| (2) BM25 + track_total_hits=FALSE | **156ms** |
| (3) BM25 + minimum_should_match=70%, tth=false | **89ms** |

### KẾT LUẬN LẬT:
- **BM25 full-text trên 141k = 156-262ms → BM25 VÔ CAN.**
- **track_total_hits chênh chỉ ~100ms → VÔ CAN.**
- ⟹ 14.2s của query dài KHÔNG do BM25. Phải do phần probe BỎ QUA: **kNN dense_vector + FusionExpr + rank_feature**,
  hoặc **embedding encode** câu dài. Cần lấy QUERY JSON THẬT của RagFlow (có knn) rồi profile.

---
## BƯỚC 2c — Đo kNN HNSW (2026-07-23) — CHỐT: ES VÔ CAN
| Biến thể | took_ms |
|----------|---------|
| kNN k=30 num_candidates=2048 | **6ms** |
| kNN k=30 num_candidates=100 | **4ms** |
| kNN num_candidates=2048 + filter kb_id | **4ms** |

### KẾT LUẬN CHỐT TẦNG ES:
- kNN HNSW trên 141k = **4-6ms**. BM25 = 156-262ms. ⟹ **TOÀN BỘ tầng ES ~200-300ms.**
- RagFlow báo query dài 14.2s ⟹ **~14s bị đốt NGOÀI ES.**
- Nghi phạm còn lại DUY NHẤT: **embedding encode câu hỏi** (get_vector → emb_mdl.encode_queries).

### ⚠️ MÂU THUẪN cần giải trước khi chốt:
Nếu là embedding thì tại sao KB nhỏ (500) nhanh 40ms? Cùng model thì encode 1 câu hỏi phải bằng nhau.
⟹ 2 khả năng: (a) KB lớn & KB nhỏ dùng MODEL EMBEDDING KHÁC NHAU (lớn=model chậm/remote API);
             (b) thời gian nằm ở chỗ chưa soi. → PHẢI đo trực tiếp thời gian encode, không suy diễn.

---
## BƯỚC 3 — Fact chốt lại (Kiên xác nhận 2026-07-23)
- Tất cả KB dùng CHUNG 1 model embedding: **qwen3-8b-embedding** (RagFlow -> LiteLLM cùng cluster khác ns -> model).
- **CÙNG câu hỏi** "quy định về thời hạn thanh toán và nghiệm thu hợp đồng xây dựng":
  - KB test_tải (500 file): **~2s**
  - KB voffice-docs-sum (141k file): **~15s**
  - Gọi thẳng Postman còn nhanh hơn.
- ⟹ **LOẠI embedding** (cùng câu hỏi = encode giống nhau, không thể gây chênh 2s vs 15s theo KB).
- ⟹ Chênh 2s vs 15s SCALE theo số chunk KB. ES đo riêng lẻ nhanh (BM25 156ms, kNN 6ms) NHƯNG
  probe dùng query TỰ CHẾ, không phải query hybrid THẬT của RagFlow (BM25+kNN+fusion+rank_feature).
- ⟹ BƯỚC 3b: bắt query THẬT từ log + profile=true (measure3.sh).

### Bài học phương pháp:
Đo bằng input MÔ PHỎNG (query tự chế) cho kết quả sai — phải bắt query THẬT RagFlow gửi mới tái hiện 15s.
