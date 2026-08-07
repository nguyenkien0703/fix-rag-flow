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

---

## 8. ROOT CAUSE CHỐT (2026-07-23, phát hiện từ câu hỏi của Kiên "có phải config match toàn bộ KB?")

### Bằng chứng cuối:
- Kiên đo lại CÙNG câu hỏi trên KB voffice: `_search duration = 12.66s` (khớp UI 15s, khác lần profile 3.27s
  trước đó — chênh do tải ES lúc đo khác nhau, KHÔNG mâu thuẫn với root cause dưới đây).
- Đọc code `rag/nlp/query.py` hàm `FulltextQueryer.question()`:
  - Dòng 52: `if not self.is_chinese(txt):` — tiếng Việt (Latin có dấu) LUÔN rơi vào nhánh này (is_chinese
    check ký tự CJK, rag_tokenizer.py:35).
  - Dòng 84-86 (nhánh non-Chinese): trả `MatchTextExpr(fields, query, 100, {"original_query": ...})`
    — **KHÔNG có key `minimum_should_match`** trong extra_options.
  - `es_conn.py:92`: `minimum_should_match = m.extra_options.get("minimum_should_match", 0.0)` → mặc định
    **0.0** khi thiếu key → dòng 94 convert thành **`"0%"`** gửi cho ES.
  - `minimum_should_match: "0%"` = ES tính document là match nếu khớp **ÍT NHẤT 1 TRONG CÁC CLAUSE OR**
    (mỗi từ khóa + đồng nghĩa + fine-grained token đều là 1 clause OR riêng, dòng 67 `q.append(...)`).

### ROOT CAUSE 1 CÂU:
**Với câu hỏi tiếng Việt, RagFlow KHÔNG set `minimum_should_match` (bug/thiếu sót ở nhánh non-Chinese của
`FulltextQueryer.question()`) → ES nhận `minimum_should_match="0%"` → document chỉ cần chứa 1 từ khóa bất kỳ
(kể cả từ phổ biến) là match → trên KB 141k, gần như TOÀN BỘ corpus bị coi là ứng viên match
(`total_hits>=10000`) → ES phải full-text SCORING hàng chục nghìn document mỗi query → chậm tuyến tính theo
số chunk KB và theo số từ khóa trong câu hỏi (câu dài = nhiều clause OR = match càng rộng).**

### Khớp MỌI triệu chứng đã quan sát:
- KB 500 chunk (2s) vs KB 141k (15s): cùng % corpus bị match rộng, nhưng scoring trên tập nhỏ nhanh hơn nhiều.
- Câu dài chậm hơn câu ngắn: nhiều từ khóa hơn = nhiều clause OR hơn = match set không hề thu hẹp
  (không có min_match để giới hạn) mà còn dễ RỘNG hơn.
- Dao động 3.3s-14s trong các lần đo: phụ thuộc tải ES + độ dài câu hỏi cụ thể lúc đo, cùng 1 cơ chế gốc.
- ES kNN/track_total_hits/embedding đều nhanh — khớp vì chúng KHÔNG liên quan minimum_should_match.

### Đối chứng nhanh (khuyến nghị đo xác nhận cuối, KHÔNG bắt buộc để chốt hướng fix):
Chạy lại `_search` với `minimum_should_match` ép "30%" hoặc "70%" cho query tiếng Việt y hệt → nếu
took giảm mạnh (từ ~10s+ xuống dưới 1s) → XÁC NHẬN 100%. (Có thể patch tạm bằng cách gọi ES trực tiếp
với query đã bắt được, sửa `minimum_should_match` trong JSON rồi replay — giống measure3.sh nhưng đổi field này.)

## 9. HƯỚNG FIX (đề xuất, CHƯA áp dụng — cần thảo luận rủi ro trước khi patch)
**F1 (fix gốc, đúng root cause):** Sửa `rag/nlp/query.py` hàm `question()`, nhánh non-Chinese (dòng 84-86):
thêm `"minimum_should_match": min_match` vào `extra_options` giống nhánh Chinese (dòng 170), dùng cùng
tham số `min_match` đã được truyền vào hàm (mặc định 0.6, search.py gọi với 0.3).
```python
# Hiện tại (dòng 84-86):
return MatchTextExpr(
    self.query_fields, query, 100, {"original_query": original_query}
), keywords
# Đề xuất:
return MatchTextExpr(
    self.query_fields, query, 100,
    {"minimum_should_match": min_match, "original_query": original_query}
), keywords
```
- Rủi ro: `min_match` quá cao có thể làm mất kết quả hợp lệ (câu hỏi dùng từ hiếm). RagFlow đã tự có cơ chế
  fallback giảm min_match khi total=0 (search.py:135-146) → an toàn để tăng min_match vì có lưới đỡ.
- Cách áp: patch source thật trong container qua postStart sed (theo ràng buộc deploy đã biết), KHÔNG build image.
- Cần xác định đúng số dòng trong file container trước khi viết sed (khác source GitHub tải về có thể lệch dòng).

**F2 (giảm đau nhanh, không sửa code):** không có — đây là bug logic, không có config bên ngoài để chỉnh
minimum_should_match theo request hiện tại.

**F3 (bổ trợ):** cân nhắc kèm min_match hợp lý (không quá cao) để tránh regression độ chính xác tìm kiếm —
nên test A/B trên vài câu hỏi thực tế trước khi rollout toàn bộ.

### Trạng thái: ROOT CAUSE ĐÃ CHỐT (code + số liệu khớp). Fix ĐỀ XUẤT xong, CHƯA viết patch cuối / CHƯA deploy.

---

## 10. PATCH ĐÃ DEPLOY (2026-07-24) — KHÔNG FIX ĐƯỢC, MỤC 8 SAI Ở KẾT LUẬN CUỐI

### Đã làm:
- Deploy patch mục 9 (F1) thật qua initContainer (thay postStart để tránh race điều kiện khởi động,
  xem nhánh worktree-fix-query-patch-initcontainer) — **XÁC NHẬN patch đã vào code chạy thật**:
  `grep minimum_should_match /ragflow/rag/nlp/query.py` trong pod → thấy dòng 85 đã có
  `"minimum_should_match": min_match`.
- Log ES thật xác nhận query gửi lên có `"minimum_should_match": "30%"` đúng vị trí (bên trong
  `query_string`, không phải sai chỗ).
- **Latency KHÔNG đổi: `_search` vẫn ~13s (UI), ES `_search` trực tiếp vẫn ~3.2-3.3s.**

### Đo kiểm chứng ES có ăn config không (để loại trừ nghi ngờ "config bị bỏ qua"):
Test trực tiếp lên ES với `track_total_hits: true, size: 0` (đếm CHÍNH XÁC, không bị chặn ở ngưỡng
10000 mặc định), quét `minimum_should_match` từ 0% → 100% trên CÙNG query thật đã bắt:
```
minimum_should_match=0%   -> total_hits_EXACT = 141,340 / 141,340 (100.0%)
minimum_should_match=30%  -> total_hits_EXACT = 141,340 / 141,340 (100.0%)
minimum_should_match=70%  -> total_hits_EXACT = 141,331 / 141,340 (~100.0%)
minimum_should_match=100% -> total_hits_EXACT = 140,469 / 141,340 (99.4%)
```
**KẾT LUẬN: ES CÓ ăn `minimum_should_match` đúng cấu hình** (không phải bug config bị bỏ qua/sai vị trí —
đã loại nghi ngờ này bằng đo trực tiếp). NHƯNG dù ép `minimum_should_match=100%` (bắt buộc khớp CẢ 4
mệnh đề OR cấp cao nhất), match set gần như không giảm — vẫn 99.4% toàn bộ corpus.

### ROOT CAUSE THẬT (đính chính mục 8): không phải "thiếu minimum_should_match"
Dump cấu trúc `query.bool.must[0].query_string.query` thật (câu hỏi "quy định về thời hạn thanh toán và
nghiệm thu hợp đồng xây dựng") cho thấy rag_tokenizer chỉ tách câu thành **4 mệnh đề OR cấp cao nhất**,
và một số mệnh đề trong đó chứa **hư từ / mảnh ký tự vô nghĩa đứng thành clause riêng**, ví dụ:
`(v à)^1.0`, `("v ệ")^1.0` — "và" là 1 trong những từ phổ biến nhất tiếng Việt, tự nó khớp gần như mọi
document trong kho. Vì minimum_should_match chỉ giới hạn SỐ LƯỢNG mệnh đề cần khớp (không sửa được nội
dung BÊN TRONG từng mệnh đề), nếu 1 mệnh đề đã tự thân match ~100% corpus, siết % không giúp gì — ép
khớp 4/4 mệnh đề vẫn kéo theo mệnh đề "rác" đó, match set không thu hẹp.

⟹ Bug thật nằm ở tầng **tokenize/query-build** (rag/nlp/query.py hoặc rag_tokenizer) sinh ra clause OR
chứa hư từ với boost ngang từ khóa thật, KHÔNG phải ở việc thiếu tham số minimum_should_match.
`minimum_should_match` (mục 8-9) là NGHI PHẠM ĐÃ LOẠI, không phải root cause.

### Hướng tiếp theo (CHƯA làm):
1. Đọc lại `FulltextQueryer.question()` phần build query_string (rag/nlp/query.py, cả 2 nhánh Chinese
   và non-Chinese) — tìm nơi các mệnh đề OR cấp cao nhất được ghép, xem có filter stopword/hư từ tiếng
   Việt trước khi đưa vào query không (nghi ngờ: KHÔNG có, vì "và" lọt qua).
2. Xem `rag_tokenizer.py` / danh sách stopword đang dùng có bao phủ hư từ tiếng Việt phổ biến
   ("và", "về", "của", "là", "có"...) không — nếu thiếu, đây là nguồn gây match rộng thật sự.
3. Cân nhắc: thêm bước lọc stopword tiếng Việt TRƯỚC khi build query_string, hoặc hạ boost các mệnh đề
   chứa hư từ, thay vì chỉ chỉnh minimum_should_match.
4. Patch minimum_should_match=30% đã deploy: giữ lại hay rollback? Vô hại (không gây regression, ES vẫn
   ăn đúng) nhưng KHÔNG giải quyết được vấn đề chính — cân nhắc giữ tạm vì không risk, chờ fix gốc ở
   bước 1-3.

### Trạng thái: Mục 8 (root cause "thiếu minimum_should_match") ĐÃ BỊ BÁC BỎ bằng đo. Cần điều tra lại
tầng tokenize/query-build. Fix minimum_should_match đã deploy nhưng KHÔNG giải quyết vấn đề chính.
