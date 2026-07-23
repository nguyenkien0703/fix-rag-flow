# TRACKING — Điều tra & Fix RagFlow (cập nhật liên tục)
> File trạng thái sống. Cập nhật mỗi khi có tiến triển. Ngày bắt đầu: 2026-07-22.
> Hệ thống: RagFlow v0.24.0 / K8s Viettel / doc engine = ES Lakehouse 10.211.145.107:8051 / pod ragflow-78dd4c855-shdq8.

═══════════════════════════════════════════════════════════════════
## ⏸️ ĐIỂM DỪNG 2026-07-23 — TỔNG KẾT ĐIỀU TRA ISSUE A (đọc mục này trước)
═══════════════════════════════════════════════════════════════════
**TRẠNG THÁI TỔNG:** Issue A (mở KB 502) — ĐÃ CHỐT root cause + verify sâu source. CHƯA viết patch cuối, CHƯA deploy.
Chuyển sang điều tra issue khác. Khi quay lại A: đọc mục này + "PHÁT HIỆN NGÀY 23/07" bên dưới.

### ✅ ROOT CAUSE (đã chốt, 3 tầng bằng chứng)
Mở KB → API kéo FULL ~142k metadata từ ES về parse JSON trong Python (~40s). RagFlow web chạy Flask
**đơn tiến trình** (`app.run` không `threaded`, `ragflow_server.py:151`) → 1 request nặng chiếm trọn server
→ request khác bị nginx trả **502 tức thì (upstream busy)**. KHÔNG phải lỗi code (không exception).

### 🔬 CÁC PHƯƠNG ÁN ĐIỀU TRA ĐÃ THỬ + KẾT QUẢ
| # | Giả thuyết / phương án | Kết quả | Bằng chứng |
|---|------------------------|---------|-----------|
| 1 | Stale connection (keepalive 7200s) | ❌ BÁC BỎ | ES duration 3-5ms, không timeout |
| 2 | Metadata parse error (promulgateDate) | ❌ BÁC BỎ | nhiễu sync nền; upload trả 200 |
| 3 | ES query nặng thuần | ❌ BÁC BỎ | ES chỉ 4.8s; 40s ở Python |
| 4 | Gateway/nginx timeout cắt 8.7s | ❌ BÁC BỎ | no ingress, NodePort L4; 8.7s = ES client timeout hạ 600→30 |
| 5 | Fetch-all metadata parse Python | ✅ XÁC NHẬN | ES 4.9s vs API 44s; size:10000; 142k×20 field |
| 6 | Server đơn tiến trình khuếch đại | ✅ XÁC NHẬN | app.run không threaded → 502 tức thì 34ms, lan cả KB khác |

### 🆕 PHÁT HIỆN NGÀY 23/07 (verify source thật, KHÁC tài liệu cũ — QUAN TRỌNG)
1. **F1-fix-final-research.md SAI** — bảo dùng condition={"id":[...]} (terms). Nhưng es_conn.py:182-185:
   insert metadata pop("id") bỏ field id khỏi _source, gán làm ES _id. → terms{id} KHÔNG match → mất metadata.
   ⟹ ĐÚNG phải dùng `ids` query trên _id (đúng như configmap-patch/03 hướng B). **CẦN ARCHIVE F1.**
2. **/filter (241) KHÔNG fix được bằng phân trang** — bản chất đếm facet toàn KB (truyền doc_ids của cả 142k).
   Dù patch es_conn đúng, ids với 142k id vẫn payload lớn. BẮT BUỘC chuyển sang **ES aggregation**.
   Tin tốt: es_conn.search() ĐÃ có sẵn param agg_fields (dòng 138-140). Nhưng metadata field ĐỘNG
   → phải dò tên field trước rồi mới aggregate → phần khó nhất, chưa có tiền lệ trong code.
3. **Còn 4 đường kéo-full CHƯA đụng** ngoài 4 patch: get_flatted_meta_by_kbs (686, limit 10000, chạy khi
   lọc metadata trên /list); get_by_kb_id bị gọi từ kb_app.py:619/688/757 với page=0 (build graph/raptor).
4. **ĐÍNH CHÍNH "mất data":** 3 hàm patch (162/241/772) CHỈ search (ĐỌC), không ghi/xóa ES.
   → Patch KHÔNG THỂ mất data khỏi ES. Rủi ro thật chỉ là "hiển thị thiếu tạm thời" nếu patch lọc sai
   (API trả metadata rỗng, ES còn nguyên, sửa+restart là hồi). Web stateless → rollback an toàn.

### 🌍 BỐI CẢNH MÔI TRƯỜNG (Kiên xác nhận 23/07 — đổi khẩu vị rủi ro)
- RagFlow đang là service THỬ NGHIỆM cho các bên cắm API tích hợp, CHƯA production thật.
- KHÔNG có staging/môi trường test — chỉ 1 môi trường này.
- ⟹ Rủi ro rollout THỰC TẾ THẤP (web stateless, data ở ES an toàn). "Bắt buộc có staging" là quá cứng.
  An toàn tối thiểu: backup file gốc + thử KB nhỏ trước + kubectl rollout undo sẵn + BÁO TRƯỚC các bên cắm API giờ deploy.

### 📌 ĐANG PENDING (chưa làm)
- [ ] Viết patch cuối 4 file (es_conn _meta_id/ids · 772 đẩy doc_ids · 162 paginate-trước · 241 ES aggregation).
      → 3 patch nháp ở configmap-patch/01,02,03 nhưng 03 đã chốt hướng B + CHƯA test. 241 (aggregation) chưa có patch.
- [ ] Cân nhắc thêm patch A "bật threaded/gunicorn" — verify Helm override được command khởi động qua ConfigMap không.
- [ ] Đóng gói ConfigMap → values.yaml mount đè → helm upgrade → **rollout restart** (bắt buộc).
- [ ] Verify: mở KB Voffice hết 502; log ES thấy ids ~50 thay size:10000; metadata hiển thị đúng; KB nhỏ không regression.
- [ ] Archive F1-fix-final-research.md (kết luận sai).

### 📎 SẢN PHẨM ĐÃ TẠO (23/07)
- Báo cáo sếp (artifact riêng tư): https://claude.ai/code/artifact/10b477f3-fe0d-439f-a401-f0feac87e763
- cau-hoi-cua-Kien.md — giải thích dive-deep process/thread/pod + facet + đính chính "mất data".
- SecondBrain: KnowledgeHub/Learning/Process-Thread-Pod-va-Faceted-Search.md (kiến thức nền).
- Source RagFlow v0.24.0 ĐÃ MOVE về repo: ./ragflow-0.24.0 (không còn ở /tmp).

---
**(Điểm dừng 22/07 cũ — giữ tham khảo):**
Root cause: `_search` metadata kéo FULL 142k doc → payload khổng lồ → Flask single-process bị chiếm
→ request khác bị nginx 502 (upstream busy). Chi tiết đầy đủ ở mục ISSUE A phía dưới.

**MAI LÀM (theo thứ tự):**
1. VIẾT PATCH FIX A (fix đầy đủ cả /list + /filter). 4 chỗ sửa:
   - `document_service.py:162` get_by_kb_id → khi return_empty_metadata=False, lấy metadata SAU paginate chỉ 50 doc.
   - `document_service.py:241` get_filter_by_kb_id → đếm facet bằng ES aggregation thay vì json.loads 142k.
   - `doc_metadata_service.py:772` get_metadata_for_documents → đẩy doc_ids xuống ES (dùng key _meta_id).
   - `es_conn.py` search() → thêm nhánh _meta_id → Q("ids", ...) GUARD theo tên index "ragflow_doc_meta" (hướng B đã chọn).
2. Đóng gói ConfigMap → sửa values.yaml mount đè → helm upgrade → **rollout restart pod** (BẮT BUỘC).
3. VERIFY: mở KB Voffice không còn 502; log ES thấy ids ~50 thay size:10000; metadata vẫn hiển thị đúng.
4. (Nếu còn thời gian) VẤN ĐỀ B retrieval 30s — đo có/không rerank.

**File cần đọc khi mở lại:**
- TRACKING.md (file này) — trạng thái tổng.
- 00-ISSUE-ROOTCAUSE.md — issue + root cause + căn cứ.
- configmap-patch/01,02,03 — nội dung patch (03 đã chọn hướng B guard).
- Source đã tải: /Users/macboook/.claude/jobs/637911d4/tmp/ragflow-0.24.0 (LƯU Ý: thư mục /tmp có thể bị xóa,
  nếu mất thì tải lại: curl -sL github.com/infiniflow/ragflow/archive/refs/tags/v0.24.0.tar.gz).

**Quyết định đã chốt:**
- Phạm vi fix A: ĐẦY ĐỦ cả /list + /filter (không làm nửa vời).
- es_conn guard: hướng B (guard theo tên index ragflow_doc_meta).
- Deploy: ConfigMap mount đè (KHÔNG build image), rollout restart.


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
- 2026-07-23: TỔNG KẾT A trước khi chuyển issue khác. Verify source: F1 SAI (phải ids không phải terms{id}); /filter buộc ES aggregation; còn 4 đường kéo-full khác; ĐÍNH CHÍNH patch chỉ ĐỌC ES nên không mất data. Bối cảnh: môi trường thử nghiệm, không staging → rủi ro rollout thấp. Tạo cau-hoi-cua-Kien.md + note SecondBrain + báo cáo sếp (artifact).
- 2026-07-22 CUỐI NGÀY: Dừng. Root cause A chốt xong. Mai viết patch (đầy đủ /list+/filter, guard hướng B) + deploy ConfigMap.
- 2026-07-22 18:42: CHỐT root cause A = payload metadata khổng lồ chiếm Flask single-process → 502 upstream busy. Không phải lỗi code (không exception). Sẵn sàng fix.
- 2026-07-22 18:27: KB Voffice = 142k doc (không phải 10k). 502 TỨC THÌ 34ms (khác 8.7s lần trước). Nghi server single-process bận → 502 ngay. Cần log full.
- 2026-07-22: Xác định A gọi 2 API (162+241). Sửa nhận định (trước tưởng get_list 114). Chờ đo duration.
- 2026-07-22: Điều tra B sơ bộ — nghi rerank 1024 candidate. Để TODO.
- 2026-07-22: Root cause A = fetch-all 10k metadata parse Python. Verify cạm bẫy _id vs _source.

═══════════════════════════════════════════════════════════════════
## CÂU HỎI ANH ĐÔNG (2026-07-22): tích hợp trace có nhìn được request RagFlow→ES→về không?
═══════════════════════════════════════════════════════════════════
### FACT (đọc từ source RagFlow v0.24.0):
1. RagFlow KHÔNG có tracing built-in được KÍCH HOẠT: grep opentelemetry|jaeger|zipkin|otel trong *.py = TRỐNG.
2. Thư viện ES: elasticsearch==8.19.3, elastic-transport==8.17.1 (bản 8.x → CÓ OTEL support built-in trong elastic-transport._otel).
3. opentelemetry-api/sdk/exporter-otlp CÓ trong uv.lock NHƯNG:
   - KHÔNG có trong pyproject.toml → là transitive dependency, RagFlow không chủ động dùng.
   - Code KHÔNG có TracerProvider/set_tracer_provider/OTLPSpanExporter/config nào → OTEL CHƯA được kích hoạt.
   → Span ES (nếu elastic-transport tạo) KHÔNG được export đi đâu vì thiếu TracerProvider.
4. Log duration ES (`ESConnection.search ... duration:4.9s`) KHÔNG phải RagFlow tự đo — là log của
   logger `elastic_transport.transport` (thư viện tự log mỗi HTTP request tới ES kèm duration).
   values.yaml có LOG_LEVELS "root=DEBUG" nên log này đang HIỆN.

### TRẢ LỜI 100%:
- CÓ THỂ trace được request RagFlow→ES→về. elastic-transport 8.x tự tạo span cho MỖI ES call NẾU config OTEL.
- NHƯNG hiện tại CHƯA trace được: OTEL lib có sẵn nhưng CHƯA kích hoạt (không TracerProvider/exporter).
- Để trace được cần TÍCH HỢP THÊM (không cần code nhiều):
  (1) opentelemetry-instrumentation-flask (auto span cho HTTP request vào Flask)
  (2) set TracerProvider + OTLPSpanExporter trỏ về collector (Jaeger/Tempo)
  (3) elastic-transport tự thêm span ES con → thấy được ES tốn bao nhiêu ms trong tổng 30s.
- CÁCH NHẸ HƠN (đã có sẵn, không cần tích hợp gì): 
  * Log duration đã CÓ SẴN (elastic_transport, LOG_LEVELS=DEBUG) → grep log là biết ES tốn mấy giây / tổng bao nhiêu.
  * ES ?profile=true → profile chi tiết 1 query. ES slowlog → log query chậm phía ES server.
