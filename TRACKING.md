# TRACKING — Điều tra & Fix RagFlow (cập nhật liên tục)
> File trạng thái sống. Cập nhật mỗi khi có tiến triển. Ngày bắt đầu: 2026-07-22.
> Hệ thống: RagFlow v0.24.0 / K8s Viettel / doc engine = ES Lakehouse 10.211.145.107:8051 / pod ragflow-78dd4c855-shdq8.

═══════════════════════════════════════════════════════════════════
## ISSUE CẦN FIX HÔM NAY
═══════════════════════════════════════════════════════════════════
| ID | Issue | Ưu tiên | Trạng thái |
|----|-------|---------|-----------|
| A | Mở KB Voffice (142k doc) → UI trắng, API 502, 10-15' tự hồi | **P0 (làm trước)** | ✅ Root cause CHỐT, sẵn sàng fix |
| B | Retrieval query 120k chunks chậm ~30s (500 chunks thì 40ms) | P1 (làm sau) | 📋 Đã điều tra sơ bộ, để TODO |
| C | Up file lâu → chờ 10' mới xử lý (nghi stale connection sync) | P2 | ⏸️ Chưa đụng |

═══════════════════════════════════════════════════════════════════
## ISSUE A — Mở KB 502  [P0 — ĐANG LÀM]
═══════════════════════════════════════════════════════════════════
### Dấu hiệu nhận biết
- Click KB Voffice → Network tab: /list, /filter, /documents, knowledge_graph = 502 sau ~8.7s.
- UI khung còn, data trống. ~10-15' tự hồi.

### Root cause (ĐÃ XÁC ĐỊNH — 3 tầng bằng chứng)
- API mở KB kéo TOÀN BỘ ~10k metadata của KB từ ES → parse JSON 10k lần trong Python (~40s) → 502.
- Bằng chứng: ES search 4.8s vs API 44s (chênh 40s ở Python); ES query size:10000; _source doc chỉ có kb_id.

### Phương pháp đã thử & kết quả
| Phương pháp | Kết quả |
|-------------|---------|
| Nghi stale connection (keepalive 7200) | ❌ BÁC BỎ: ES duration 3-5ms |
| Nghi metadata parse error (promulgateDate) | ❌ BÁC BỎ: nhiễu sync nền, upload vẫn 200 |
| Nghi gateway timeout 8.7s | ❌ BÁC BỎ: no ingress, NodePort L4, nginx 3600s. 8.7s = ES client timeout hạ 600→30 ở values.yaml |
| Nghi query nặng ES | ❌ BÁC BỎ: ES 4.8s, 40s ở Python |
| Fetch-all metadata parse Python | ✅ XÁC NHẬN |

### Đã điều tra được (code, verify container khớp source v0.24.0)
- Mở KB (WEB UI) gọi 2 API SONG SONG, cả hai kéo full 10k:
  - `/list` (document_app.py:224) → `get_by_kb_id` (document_service.py:162) → full 10k
  - `/filter` (document_app.py:358) → `get_filter_by_kb_id` (document_service.py:241) → full 10k
- `get_list` (dòng 114) chỉ là route SDK, UI KHÔNG dùng → patch cũ sửa 114 VÔ DỤNG cho UI. (đã sửa nhận định)
- `get_metadata_for_documents` (772) luôn kéo full, lọc doc_ids chỉ bằng Python.
- Cạm bẫy: doc id ở ES `_id`, KHÔNG có field `id` trong _source → phải dùng `ids` query (không `terms{id}`).
- Cạm bẫy: /filter (241) bản chất phải đếm facet toàn KB → không phân trang được, cách đúng là để ES aggregation đếm.

### 🔬 ĐANG CHỜ ĐO (bước hiện tại)
- Log duration TỪNG API khi mở KB Voffice: /list vs /filter vs knowledge_graph — cái nào 44s?
  → quyết định fix cần đụng /list, /filter, hay cả hai.
- ĐÃ ĐO (2026-07-22 18:27): KB Voffice thực tế = **141779 files (~142k doc, 1GB)**, KHÔNG phải 10k.
  Network tab khi mở KB:
    detail?kb_id=... → 200, 995ms & 1.94s (chậm nhưng KHÔNG 502)
    list?kb_id=...&page_size=50&page=1 → **502 sau 34ms** (tức thì, KHÔNG phải 44s)
    knowledge_graph → 502 sau 70ms
    filter → 502 sau 38ms
  Log: metadata _search duration 4.924s (1 search); knowledge_graph search size:1024.
  ⚠️ PHÁT HIỆN MỚI: 502 lần này TỨC THÌ (34-70ms), KHÁC lần trước (8.7s). → KHÔNG phải request tự
     chạy 44s rồi timeout. Nghi: server Werkzeug single-process đang BẬN (chạy _search 4.9s + search khác)
     → request mới bị 502 ngay (upstream bận/đóng connection). CẦN đọc log full tìm nguyên nhân 502 tức thì.

### PHÂN TÍCH SỐ LIỆU 18:27 (fact vs giả thuyết — đọc kỹ)

**FACT (quan sát trực tiếp):**
1. KB Voffice = **141,779 files (~142k doc, 1GB)** — KHÔNG phải 10k. `size:10000` chỉ là limit trần của
   `_search_metadata`; thực tế KB có 142k doc → kéo full càng nặng hơn nhiều.
2. list/filter/knowledge_graph trả **502 nhưng RẤT NHANH (34-70ms)** — KHÔNG phải chậm 44s. 502 tức thì.
   Còn `detail` thì 200 nhưng chậm (995ms, 1.94s).
3. `list?kb_id=...&page_size=50&page=1` → UI xin đúng 50 doc/trang (phân trang UI HOẠT ĐỘNG). Vẫn 502.
4. Log: `ragflow_doc_meta/_search duration:4.924s` — 1 metadata search mất 4.9s. Với 142k doc, load full còn lâu hơn.

**GIẢ THUYẾT (chưa xác nhận — cần log full):**
- 502 lần này KHÔNG do request tự chạy 44s rồi timeout (vì nó 502 ngay 34ms).
- Server từ chối/không xử lý request ngay. 2 khả năng CHƯA phân biệt:
  (a) Flask ném exception NGAY khi xử lý (lỗi code với 142k doc) → Flask tự trả lỗi.
  (b) Flask single-process đang BẬN (chạy _search 4.9s + search khác) → nginx không nối được upstream → nginx trả 502.
- Phân biệt bằng log full: thấy Traceback/Exception lúc mở KB → (a); Flask im, nginx log 502 → (b).

### ✅ KẾT LUẬN CUỐI VẤN ĐỀ A (log 18:42 chốt — bác bỏ giả thuyết a, xác nhận b)

**Bằng chứng log 18:42:**
- `POST /v1/kb/list → 200, 20-21ms` (LẦN NÀY trả 200, không 502!). Cùng request `list` khi 502(34ms) khi 200(20ms)
  tùy thời điểm → dấu hiệu server bị chiếm theo lúc.
- KHÔNG có Traceback/Exception nào (dù grep ERROR|Exception) → **BÁC BỎ (a) Flask ném exception.**
- `ragflow_doc_meta/_search size:10000 duration:4.756s` + ảnh raw = khối text metadata KHỔNG LỒ (142k doc × nhiều field, hàng MB) được kéo về.

**ROOT CAUSE A (hoàn chỉnh):**
`_search` metadata kéo FULL (142k doc) → trả khối text khổng lồ → Flask **single-process** (app.run không threaded)
parse mất nhiều giây, BỊ CHIẾM → request list/filter/knowledge_graph mới đến bị nginx trả **502 (upstream busy)**.
KHÔNG phải lỗi code (không exception), mà là **quá tải single-process do payload metadata khổng lồ**.

**Khớp mọi mảnh:** 502 tức thì (process bận) · detail chậm 1.9s (chờ process) · 10-15' tự hồi (tải giảm) ·
KB 500 doc nhanh (payload nhỏ, process không bị chiếm).

**FIX A (không đổi hướng, nhưng hiểu đúng cơ chế):** giảm payload metadata = chỉ kéo metadata của doc trên trang
(50 doc) thay vì full 142k → process không bị chiếm lâu → hết 502. Cụ thể sửa get_by_kb_id(162)+get_filter(241)
+get_metadata_for_documents(772)+es_conn (ids query). [Bổ trợ dài hạn: cho server nhiều worker — vấn đề riêng.]

### Bước tiếp theo (sau khi có log)
1. Chốt API nào 44s → fix đúng chỗ.
2. Fix /list (get_by_kb_id 162): mở KB thường (return_empty_metadata=False) → lấy metadata sau paginate, chỉ 30 doc.
3. Fix /filter (get_filter_by_kb_id 241): chuyển đếm facet sang ES aggregation thay vì json.loads 10k.
4. Fix nền get_metadata_for_documents 772 + es_conn (dùng ids query, guard theo tên index — hướng b).
5. Đóng gói ConfigMap → helm upgrade → rollout restart → verify.

═══════════════════════════════════════════════════════════════════
## ISSUE B — Retrieval 120k chunks 30s  [P1 — TODO, đã điều tra sơ bộ]
═══════════════════════════════════════════════════════════════════
### Dấu hiệu
- Query dataset 120k chunks ~30s; dataset 500 chunks ~40ms. Chậm tuyến tính theo #chunks.

### Đã điều tra sơ bộ (code)
- API: chunk_app.py:347 /retrieval_test → rag/nlp/search.py:362 retrieval().
- Luồng: embedding query → ES kNN (HNSW, topk=1024, num_candidates=2048) → rerank.

### Nghi phạm (chưa xác nhận, cần đo)
1. **Rerank trên tới 1024 candidate** (search.py:350 rerank_by_model) — nếu bật rerank model, cross-encoder chạy 1024 text = 30s. NGHI PHẠM SỐ 1.
2. kNN pre-filtered HNSW trên 120k (es_conn.py:106) — nghi phụ.
3. (loại) aggregation size=1000000 — KHÔNG chạy ở retrieval (chỉ ở /filter).

### Bước tiếp theo (khi làm B)
- Đo: chạy retrieval CÓ và KHÔNG rerank_id → nếu bỏ rerank mà 30s→<1s thì root cause = rerank 1024 candidate.
- Bật ES ?profile=true đo riêng kNN.
- Log len(sres.ids) vào rerank + thời gian rerank_mdl.similarity.

═══════════════════════════════════════════════════════════════════
## ISSUE C — Up file chờ 10'  [P2 — chưa đụng]
═══════════════════════════════════════════════════════════════════
- Nghi: stale connection của tiến trình sync_data_source tới ES (keepalive 7200). Chưa điều tra sâu.

═══════════════════════════════════════════════════════════════════
## NHẬT KÝ (mới nhất trên cùng)
═══════════════════════════════════════════════════════════════════
- 2026-07-22 18:42: CHỐT root cause A = payload metadata khổng lồ chiếm Flask single-process → 502 upstream busy. Không phải lỗi code (không exception). Sẵn sàng fix.
- 2026-07-22 18:27: KB Voffice = 142k doc (không phải 10k). 502 TỨC THÌ 34ms (khác 8.7s lần trước). Nghi server single-process bận → 502 ngay. Cần log full.
- 2026-07-22: Xác định A gọi 2 API (162+241). Sửa nhận định (trước tưởng get_list 114). Chờ đo duration.
- 2026-07-22: Điều tra B sơ bộ — nghi rerank 1024 candidate. Để TODO.
- 2026-07-22: Root cause A = fetch-all 10k metadata parse Python. Verify cạm bẫy _id vs _source.
