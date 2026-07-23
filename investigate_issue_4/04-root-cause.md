# 04 — Root Cause & Nhật ký điều tra Issue #4 (retrieval chậm)

> File tracking sống. Ghi: đã làm gì · thử phương pháp gì · kết quả · pending · khó khăn · dẫn chứng · hướng tiếp.
> Cập nhật 2026-07-23.

---

## 0. TÓM TẮT 1 PHÚT (đọc cái này trước)
- **Triệu chứng:** CÙNG câu hỏi → KB test_tải (500 file) ~2s, KB voffice-docs-sum (141k file) ~15s.
- **Đã LOẠI bằng đo:** rerank, kNN HNSW (4-6ms), embedding (cùng model mọi KB), track_total_hits.
- **Bằng chứng mới nhất (profile query THẬT):** ES took = **3.27s**, thời gian nằm ở **BooleanQuery/BoostQuery
  full-text scoring ~2.8s/shard** + `QueryPhaseCollector 2.4s`. `total_hits >= 10000` (match rất rộng).
- **CHƯA khép kín:** ES chỉ 3.3s nhưng UI 15s → còn **~12s ngoài ES** chưa định vị. → xem mục 6 (hướng tiếp).
- **Nghi phạm đang dẫn đầu:** (1) full-text BM25 scoring nặng do query nhiều mệnh đề + match rộng (ES-side 3.3s);
  (2) phần ~12s còn lại ở tầng RagFlow Python (single-process, xử lý sau khi ES trả) hoặc nhiều ES call.

---

## 1. TRIỆU CHỨNG (fact, Kiên xác nhận)
| Test | KB | #file | Thời gian |
|------|----|----|-----------|
| Cùng câu "quy định về thời hạn thanh toán và nghiệm thu hợp đồng xây dựng" | test_tải | 500 | **~2s** |
| Cùng câu đó | voffice-docs-sum | 141,978 | **~15s** |
| Gọi thẳng Postman | voffice | 141k | "còn nhanh hơn" (chưa đo số) |
| Query NGẮN ("hợp đồng") | voffice | 141k | nhanh hơn query dài |

⟹ Chậm **scale theo số chunk KB** VÀ **theo độ dài/độ phức tạp câu hỏi**.

---

## 2. CÁC NGHI PHẠM ĐÃ LOẠI (bằng đo, không đoán)
| Nghi phạm | Cách loại | Dẫn chứng |
|-----------|-----------|-----------|
| **Rerank 1024 candidate** (tài liệu cũ) | Đọc code | RERANK_LIMIT=max(30,ceil(64/size)*size) → rerank chỉ 30-64 chunk, không phải 1024 |
| **kNN brute-force** | Xem mapping | vector field = dense_vector int8_hnsw index:true → HNSW đúng chuẩn |
| **kNN HNSW chậm** | Đo trực tiếp | kNN k=30 num_candidates=2048 trên 141k = **4-6ms**; + filter kb_id = 4ms |
| **BM25 thuần** (probe tự chế) | Đo | query_string 3 field trên 141k = **156-262ms** |
| **track_total_hits=true** | Đo | chênh true vs false chỉ ~100ms (262 vs 156) |
| **Embedding encode** | Fact | mọi KB dùng CHUNG model qwen3-8b-embedding → cùng câu hỏi encode giống nhau, không thể gây 2s vs 15s theo KB |

---

## 3. BẰNG CHỨNG PROFILE QUERY THẬT (đo 2026-07-23, measure3.sh v2)
Bắt query hybrid THẬT RagFlow gửi ES (ESConnection.search ... query:), replay + profile=true:
```
keys: ['query','knn','from','size']  size=100
Nhánh payload lớn nhất: knn.query_vector (4096-dim) ~92KB  <- chỉ là KÍCH THƯỚC, không phải thời gian
TOOK_TONG_ms = 3267
total_hits = {'value':10000, 'relation':'gte'}   <- match >= 10000 doc
shard0 top query con: BoostQuery 2794ms, BooleanQuery 2789ms, BooleanQuery 2780ms, BoostQuery 1299ms, PhraseQuery 651ms
        collector QueryPhaseCollector 2447ms
shard1 top query con: BooleanQuery 2632ms, BoostQuery 2615ms, BooleanQuery 2606ms, BoostQuery 1132ms, PhraseQuery 569ms
        collector QueryPhaseCollector 2341ms
```
### Đọc profile:
- Thời gian ES thật = **3.27s**, KHÔNG nằm ở kNN (query_vector chỉ là payload lớn) mà ở
  **BooleanQuery/BoostQuery full-text scoring (~2.8s/shard) + QueryPhaseCollector (~2.4s)**.
- total_hits >= 10000 → query full-text match RẤT RỘNG → scoring nhiều doc.
- Vì sao khác probe BM25 (156ms)? → probe dùng query 3-field ĐƠN GIẢN; query THẬT có nhiều mệnh đề
  (query_string minimum_should_match + boost + PhraseQuery + rank_feature) → scoring đắt hơn nhiều.

---

## 4. KHOẢNG TRỐNG CHƯA GIẢI THÍCH (trung thực)
- **ES profile = 3.27s** nhưng **UI báo ~15s**. → còn **~12s NGOÀI ES** chưa định vị.
- Khả năng cho 12s này (CHƯA đo, cần bước 6):
  1. RagFlow gọi ES **nhiều lần** cho 1 query (retry, hoặc search 2 lần khi total=0 — search.py:136).
  2. Tầng Python single-process (app.run không threaded — đã biết từ Issue A) xử lý/serialize kết quả.
  3. retrieval_by_children gọi thêm ES .get() cho từng mom_id (search.py:672) nếu chunk có parent-child.
  4. Chênh giữa took (ES nội bộ) và thời gian client nhận (mạng RagFlow<->ES, TLS, transfer payload lớn).
  5. Thời điểm đo profile (3.27s) có thể là lúc ES ấm/ít tải; lúc UI test 15s có thể ES đang bận hơn — cần đo lại cùng thời điểm.

---

## 5. DẪN CHỨNG & FILE
- 01-code-analysis.md — phân tích luồng code, loại nghi phạm bằng đọc source.
- 02-measurement-plan.md — kế hoạch đo tách tầng.
- 03-measurements.md — TẤT CẢ số liệu raw (BM25, kNN, profile).
- measure.sh / measure2.sh / measure3.sh — script đo (v3 = bắt query thật + profile).
- Env: ES=10.211.145.107:8051, user=aihub_prod, INDEX voffice=ragflow_22cdb01e486a11ec9749e86cfe939a (141,978 docs, 15.4gb).
- Model embedding: qwen3-8b-embedding qua LiteLLM (cùng cluster, khác ns).

---

## 6. HƯỚNG XỬ LÝ TIẾP THEO (chưa fix — cần đo nốt 12s)
### Bước A — Định vị 12s còn lại (QUAN TRỌNG NHẤT):
- Đếm **số dòng _search trong log cho 1 query** → biết RagFlow gọi ES mấy lần.
- So duration (elastic_transport log, gồm mạng) vs took (ES nội bộ) → biết bao nhiêu là mạng/transfer.
- Log thời gian trước/sau retrieval() trong Python → biết Python chiếm bao nhiêu.

### Bước B — Nếu xác nhận full-text scoring 3.3s là đáng kể:
- Giảm độ rộng match: tăng min_match (search.py:114 đang min_match=0.3) → ít mệnh đề OR hơn.
- Xem query_string có nhồi quá nhiều keyword tiếng Việt fine-grained không (rag_tokenizer).

### Bước C — Nếu 12s ở Python single-process:
- Trùng gốc với Issue A: app.run không threaded → cân nhắc bật threaded/gunicorn (fix chung 2 issue).

### Ràng buộc fix (nhắc lại):
- Deploy chỉ qua values.yaml + helm, KHÔNG build image. Fix code = postStart sed patch file .py trong container.
- Môi trường thử nghiệm, không staging → rủi ro rollout thấp nhưng vẫn backup + báo trước bên cắm API.

---

## 7. NHẬT KÝ (mới nhất trên cùng)
- **2026-07-23 (16:10):** Profile query THẬT → ES took 3.27s, bottleneck = BooleanQuery/BoostQuery full-text
  scoring ~2.8s/shard + collector. total_hits>=10000. CHỐT: kNN vô can, full-text scoring là phần ES-side.
  PHÁT HIỆN khoảng trống: ES 3.3s != UI 15s → còn 12s ngoài ES cần đo.
- **2026-07-23 (15:xx):** Đo kNN (4-6ms) + BM25 (156-262ms) riêng lẻ = nhanh → nghi embedding.
  Kiên xác nhận mọi KB chung 1 model embedding + cùng câu hỏi vẫn 2s vs 15s → LOẠI embedding.
  Bài học: probe query TỰ CHẾ cho kết quả sai, phải bắt query THẬT.
- **2026-07-23 (14:xx):** Query ngắn ES=1.54s vs dài ES=14.2s (log elastic_transport). Nghi BM25.
  Mapping: vector HNSW đúng (loại brute-force). Segment index 141k nhiều/lớn.
- **2026-07-23 (13:xx):** Đọc code v0.24.0. Loại nghi phạm cũ "rerank 1024" (thực tế 30-64 chunk).
  Tách folder investigate_issue_4 riêng.
