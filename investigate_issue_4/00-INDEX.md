# Issue #4 — Truy vấn retrieval chậm ~30s trên dataset nhiều chunks

> Folder điều tra TÁCH BẠCH cho riêng Issue #4. Không trộn với Issue A (mở KB 502) / Issue #3 (up file chờ 10').
> Bắt đầu: 2026-07-23. Hệ thống: RagFlow v0.24.0 / K8s Viettel / doc engine = ES Lakehouse ngoài cluster.

## Triệu chứng (người dùng báo)
- Query trên dataset ~120k chunks → **~30s**.
- Query trên dataset ~500 chunks → **~40ms**.
- Chậm tuyến tính (hoặc tệ hơn) theo số chunks trong dataset.

## Mục lục folder
| File | Nội dung |
|------|----------|
| `00-INDEX.md` | File này — tổng quan + trạng thái |
| `01-code-analysis.md` | Phân tích luồng retrieval từ source v0.24.0, xác định các nghi phạm & LOẠI nghi phạm sai |
| `02-measurement-plan.md` | Kế hoạch đo TÁCH TẦNG — lệnh copy-paste để Kiên chạy trên cluster |
| `03-measurements.md` | Số liệu thật thu được (điền khi đo) |
| `04-root-cause.md` | Root cause chốt (điền sau khi có số liệu) |
| `05-fix-options.md` | Hướng xử lý + đánh giá rủi ro (điền sau khi chốt root cause) |

## Trạng thái điều tra
- [x] Phase 1-2: Đọc code, dựng luồng, loại nghi phạm sai (`01-code-analysis.md`)
- [ ] Phase 3: Đo tách tầng lấy số liệu thật (`02` → `03`)
- [ ] Chốt root cause (`04`)
- [ ] Hướng fix (`05`)

## Nguyên tắc (systematic-debugging)
**KHÔNG đề xuất fix khi chưa có bằng chứng số đo xác nhận root cause.** Tài liệu điều tra Issue B cũ mới ở
mức GIẢ THUYẾT (nghi rerank 1024 candidate) và — theo phân tích code mới — **giả thuyết đó nhiều khả năng SAI**
(xem `01-code-analysis.md`). Phải đo mới chốt.

## Đính chính nhận định cũ (quan trọng)
Tài liệu `TRACKING.md` (Issue B) ghi nghi phạm #1 = "rerank chạy tới 1024 candidate (search.py:350)".
Đọc lại code v0.24.0: **rerank chỉ chạy trên 30-64 chunks** (bị `RERANK_LIMIT` chặn), KHÔNG phải 1024.
`top=1024` chỉ là `topk`/`num_candidates` đẩy XUỐNG ES kNN — chi phí đó nằm ở ES, không ở Python rerank.
⟹ Nghi phạm thật dịch về **tầng ES** (kNN trên 120k vector + `track_total_hits` + BM25 match rộng).
