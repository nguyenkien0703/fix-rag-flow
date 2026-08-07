# 01 — Phân tích luồng retrieval (từ source RagFlow v0.24.0)

> Mục tiêu: dựng chính xác luồng 1 query đi qua đâu, tốn ở đâu, để biết ĐO CÁI GÌ.
> Nguồn: `rag/nlp/search.py`, `rag/utils/es_conn.py`, `api/apps/chunk_app.py`, `rag/app/tag.py` trong `./ragflow-0.24.0`.

---

## 1. Luồng 1 query (retrieval_test / chat) — từ HTTP tới ES và về

```
POST /v1/chunk/retrieval_test          (chunk_app.py:347)
  └─ _retrieval()                       (chunk_app.py:368)
       ├─ [nếu meta_data_filter] get_flatted_meta_by_kbs(kb_ids)   ← có thể kéo full meta (chỉ khi bật filter)
       ├─ label_question()              (tag.py:125)   ← chỉ nặng nếu KB có tag_kb_ids (auto-tag); mặc định NO-OP
       └─ retriever.retrieval(...)      (search.py:362)   ◄── TRỌNG TÂM
            ├─ RERANK_LIMIT = max(30, ceil(64/size)*size)      → size ES lấy về = 30..64 (KHÔNG phải 1024)
            ├─ req.topk = top = 1024                            → đẩy xuống ES kNN làm num_candidates
            ├─ self.search(req, ...)    (search.py:74)
            │    ├─ get_vector(): emb_mdl.encode_queries(q)     ◄ (a) EMBEDDING QUERY — gọi model, ~vài chục ms
            │    └─ dataStore.search(...) → es_conn.search()    ◄ (b) ES HYBRID SEARCH — 1 HTTP call tới ES
            │         BM25 query_string + kNN(topn=1024, num_candidates=2048) + rank_feature
            │         track_total_hits=True, timeout=600s
            ├─ [rerank] rerank_by_model | rerank              ◄ (c) RERANK — CHỈ trên 30..64 chunks
            └─ trả chunks của trang (size 30)
       └─ retrieval_by_children(chunks)  (search.py:658)   ← chỉ chạy nếu chunk có mom_id; trên 30 chunks
```

**Số cần nhớ:** ES `_search` chỉ trả về **30..64 hit** (RERANK_LIMIT), nhưng kNN phải quét
`num_candidates = topn*2 = 2048` (es_conn.py:106-112) trên đồ thị HNSW của **toàn bộ 120k vector**.

---

## 2. NGHI PHẠM — xếp hạng theo phân tích code (chưa đo)

### Nghi phạm #1: ES kNN + `track_total_hits=True` trên 120k chunks
- `es_conn.py:154`: `track_total_hits=True` → buộc ES **đếm CHÍNH XÁC** tổng số hit khớp bool_query.
  Với BM25 `query_string` match rộng (nhiều token OR nhau) trên 120k chunk → phần đếm này O(số doc match),
  rất dễ tốn nhiều giây khi corpus lớn. Trên 500 chunk thì đếm nhoáng.
- `es_conn.py:106-112`: kNN với `num_candidates = topn*2 = 2048`. HNSW search chi phí ~O(log N) theo lý thuyết,
  NHƯNG kNN **pre-filtered** (có `filter=bool_query`) → ES có thể rơi vào chế độ quét tuyến tính nếu filter
  loại nhiều candidate hoặc nếu số segment lớn. Đây là chi phí scale theo N.
- **Đây là nghi phạm hàng đầu vì nó là điểm DUY NHẤT trong luồng scale theo tổng số chunks của KB.**

### Nghi phạm #2: BM25 `query_string` với nhiều keyword trên corpus lớn
- `search.py:114` `qryr.question(qst)` sinh nhiều keyword → `query_string` OR rộng.
- Trên 120k chunk, số posting phải duyệt lớn hơn hẳn 500 chunk.

### Nghi phạm #3: Mapping/refresh/segment của index ES cho KB lớn
- Nếu index KB lớn có nhiều segment chưa merge, mọi query đều chậm. Cần xem `_cat/segments`.

### ĐÃ LOẠI (bằng đọc code — không cần đo):
| Nghi phạm cũ | Vì sao LOẠI |
|--------------|-------------|
| **Rerank 1024 candidate (search.py:350)** | `RERANK_LIMIT=max(30,ceil(64/size)*size)` → rerank chỉ trên **30..64 chunks**. `top=1024` chỉ là num_candidates đẩy xuống ES, KHÔNG phải số text đưa vào cross-encoder. Cross-encoder trên 30-64 text = dưới 1s. |
| **aggregation size=1000000** | Chỉ chạy ở `/filter` (mở KB), KHÔNG ở retrieval. `agg_fields` không được truyền trong luồng retrieval. |
| **label_question auto-tag** | Chỉ nặng nếu KB cấu hình `tag_kb_ids`. Mặc định trống → NO-OP (tag.py:133 `if tag_kb_ids`). |
| **retrieval_by_children** | Chỉ chạy nếu chunk có `mom_id` (parent-child chunking), và trên 30 chunk đã page — không scale theo 120k. |
| **Python serialize chunks** | Chỉ serialize 30 chunk/trang. Không scale theo KB. |

---

## 3. Vì sao 500 chunk = 40ms còn 120k = 30s (giả thuyết cơ chế)
- Embedding query (a) + rerank (c) **KHÔNG đổi** theo số chunk KB (luôn ~cố định). ⟹ chúng KHÔNG giải thích được
  chênh lệch 40ms→30s.
- Chỉ (b) ES hybrid search scale theo N. ⟹ **~toàn bộ 30s nằm trong 1 HTTP call ES `_search`.**
- Nếu đo thấy ES `_search duration ≈ 30s` → xác nhận. Nếu ES nhanh (<1s) mà tổng vẫn 30s → phải soi lại Python
  (nhưng code không cho thấy chỗ nào Python scale theo N ở luồng này → khả năng thấp).

---

## 4. Điểm mấu chốt cần ĐO để chốt (dẫn sang `02-measurement-plan.md`)
1. **Bao nhiêu giây nằm ở ES `_search`** (log elastic_transport duration đã có sẵn, LOG_LEVELS=DEBUG).
2. **kNN vs BM25 vs track_total_hits** — cái nào tốn? → dùng ES `?profile=true`.
3. **kNN có bị brute-force không** → xem index mapping (`index.knn`, `element_type`, số segment).
4. Có phải chỉ 1 ES call không, hay nhiều call? → đếm số dòng `_search` trong log cho 1 request.
