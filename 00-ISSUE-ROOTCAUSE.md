# ISSUE & ROOT CAUSE — RagFlow KB "Voffice doc sum" 502
> Tài liệu chốt. Mỗi khẳng định có CĂN CỨ (số liệu / số dòng code / output lệnh thật).
> Hệ thống: RagFlow v0.24.0 trên K8s Viettel. Doc engine = ES Lakehouse ngoài cluster (10.211.145.107:8051).
> Ngày điều tra: 2026-07-22.

═══════════════════════════════════════════════════════════════════
## 1. ISSUE (hiện tượng quan sát được)
═══════════════════════════════════════════════════════════════════
| # | Triệu chứng | Ai báo |
|---|-------------|--------|
| 1 | Click vào KB "Voffice doc sum" (nhiều tài liệu + metadata) → UI trắng, API chết, ~10-15' sau tự hồi | Cường/Đạt |
| 2 | Lâu không vào UI → vào lại bị như (1) | vận hành |
| 3 | Lâu không up file → up vào queue, ~10' sau mới xử lý | vận hành |
| 4 | Query 120k chunks ~30s; KB 500 chunks ~40ms | Kiên đo |

**MỤC TIÊU:** hết 502 khi mở KB Voffice, hiển thị danh sách file ngay. (Ưu tiên #1; #3,#4 xử lý sau.)

═══════════════════════════════════════════════════════════════════
## 2. ROOT CAUSE (1 câu)
═══════════════════════════════════════════════════════════════════
API list tài liệu (`GET /api/v1/datasets/{kb}/documents` → `DocumentService.get_list`)
phân trang đúng ở MySQL (30 doc/trang) NHƯNG bước gắn metadata gọi
`get_metadata_for_documents(None, kb_id)` — kéo TOÀN BỘ metadata của cả KB (~10k doc) từ ES
rồi parse JSON từng cái trong Python (~40s). Tổng request ~44s. RagFlow chạy Werkzeug single-process
nên 1 request 44s block cả server → 502. KB ít doc thì nhanh.

═══════════════════════════════════════════════════════════════════
## 3. CĂN CỨ — 3 TẦNG BẰNG CHỨNG ĐỘC LẬP
═══════════════════════════════════════════════════════════════════

### TẦNG A — LOG RUNTIME (output thật khi mở KB, đo trên container)
CĂN CỨ A1 — ES trả lời NHANH (loại giả thuyết "ES chậm"):
  `POST ragflow_doc_meta/_search [status:200 duration:4.865s]`  ← ES search 4.8s
  Health check ES ấm: `total=0.021s http=200`  ← ES khỏe 21ms
CĂN CỨ A2 — API tổng CHẬM 38-44s (số cuối access log = micro-giây):
  `GET /api/v1/datasets/{kb}/documents 200 ... 44368792`  → 44.37s
  `POST .../documents 200 ... 38864185`                    → 38.86s
  → Chênh ES(4.8s) vs API(44s) = ~40s tiêu ở tầng PYTHON, không phải ES.
CĂN CỨ A3 — ES query có size:10000 (kéo full):
  `ESConnection.search query: {"query":{"bool":{"filter":[{"terms":{"kb_id":["73932..."]}}]}}, "from":0, "size":10000}`
CĂN CỨ A4 — Browser nhận 502: Network tab tất cả request /documents,/list,/filter,/knowledge_graph = 502.

### TẦNG B — CODE (RagFlow v0.24.0, đã verify container khớp source: grep dòng 114/162 khớp)
CĂN CỨ B1 — document_service.py:114 (get_list) truyền None dù docs_list đã paginate:
  `metadata_map = DocMetadataService.get_metadata_for_documents(None, kb_id)`
  (docs_list = list(docs.dicts()) ở dòng 113 đã chỉ có ~30 doc, nhưng vẫn gọi None = full KB)
CĂN CỨ B2 — doc_metadata_service.py:772 PHỚT LỜ doc_ids, luôn kéo full:
  `results = cls._search_metadata(kb_id, condition={"kb_id": kb_id})`   ← hard-code, không dùng doc_ids
  Dòng 785: `if doc_ids_set is not None and doc_id not in doc_ids_set: continue`  ← chỉ lọc Python SAU khi kéo full
CĂN CỨ B3 — _search_metadata:152 mặc định `limit=10000` → chính là size:10000 ở A3.
CĂN CỨ B4 — ragflow_server.py:151 `app.run(host, port)` KHÔNG có threaded= → Werkzeug single-process
  → request 44s block cả server (giải thích vì sao click 1 KB cả UI chết).

### TẦNG C — DỮ LIỆU ES THẬT (mapping + document, đo trên container)
CĂN CỨ C1 — mapping index: field định danh là `id` (keyword) nhưng...
CĂN CỨ C2 — _source document THẬT chỉ có kb_id, KHÔNG có field `id`:
  Output: `{"_id":"4397566a63bd11f1a22d4f88f6ea65d6","_source":{"kb_id":"73932b965e5e11f192725fd51894c519"}}`
  → doc id nằm ở ES `_id`, KHÔNG trong _source → fix phải dùng `ids` query, KHÔNG `terms {id}`
  (nếu dùng terms{id} → không match → MẤT metadata mọi doc).
CĂN CỨ C3 — mỗi doc có ~15-20 field metadata (receiverId2, promulgateDate, documentId, status...) 
  → parse 10k doc × 20 field = lý do 40s Python.

═══════════════════════════════════════════════════════════════════
## 4. VÌ SAO KHỚP MỌI TRIỆU CHỨNG
═══════════════════════════════════════════════════════════════════
- TC1 (mở KB nhiều doc → 502): 10k metadata × parse = 44s > ngưỡng → 502. ✓
- TC4 (KB 500 chunks nhanh 40ms): 500 metadata parse = vài chục ms. ✓ (chậm tuyến tính theo #doc)
- "10-15' tự hồi": request chồng chất trên Werkzeug single-process, giãn dần khi hết tải. (cần xác nhận thêm)

═══════════════════════════════════════════════════════════════════
## 5. CÁC GIẢ THUYẾT ĐÃ BÁC BỎ (và căn cứ bác bỏ)
═══════════════════════════════════════════════════════════════════
| Giả thuyết | Bác bỏ vì |
|-----------|-----------|
| Stale connection (keepalive 7200s) | Log ES duration 3-5ms, KHÔNG timeout (A1) |
| Metadata parse error (promulgateDate) | Chỉ là nhiễu từ sync nền; upload trả 200 (feedback vận hành + log _bulk 200) |
| ES query nặng thuần | ES chỉ 4.8s; 40s ở Python (A2) |
| Timeout gateway/nginx cắt 8.7s | Không có ingress; NodePort L4; nginx pod 3600s. 8.7s = ES client timeout hạ 600→30 ở values.yaml:133 |

═══════════════════════════════════════════════════════════════════
## 6. GHI CHÚ VỀ "CITATION"
═══════════════════════════════════════════════════════════════════
Đây là codebase NỘI BỘ (RagFlow v0.24.0), không phải nguồn web → "citation" = đường dẫn file + số dòng.
- Source đối chiếu: github.com/infiniflow/ragflow tag v0.24.0 (tải về, đã verify khớp container qua grep dòng 114/162).
- Mọi số liệu ở TẦNG A và TẦNG C là OUTPUT LỆNH THẬT chạy trên pod ragflow-78dd4c855-shdq8 (có screenshot trong hội thoại).
