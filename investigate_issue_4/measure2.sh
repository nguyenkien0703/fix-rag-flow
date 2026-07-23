#!/bin/bash
# ============================================================================
# measure2.sh — Xác nhận nghi phạm EMBEDDING cho Issue #4
# Mục đích: (1) KB lớn vs nhỏ dùng model embedding NÀO? (khác nhau -> giải thích chênh 40ms vs 30s)
#           (2) Đo trực tiếp thời gian encode câu hỏi từ log.
# Chạy trên node cluster. Đọc giải thích từng phần bên dưới.
# ============================================================================
set -u
POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
echo "POD=$POD"

echo
echo "=== [1] Model embedding của TỪNG KB (cột embd_id) — tìm MySQL password env ==="
MYSQL_POD=ragflow-mysql-0
PW=$(kubectl -n ragflow exec $MYSQL_POD -- sh -c 'echo $MYSQL_ROOT_PASSWORD 2>/dev/null || echo $MYSQL_PASSWORD 2>/dev/null')
echo "  (nếu rỗng, tự điền password MySQL vào lệnh dưới)"
kubectl -n ragflow exec $MYSQL_POD -- sh -c "mysql -uroot -p'$PW' rag_flow -N -e \
  'SELECT id, name, chunk_num, embd_id FROM knowledgebase ORDER BY chunk_num DESC LIMIT 12;'" 2>/dev/null

echo
echo "=== [2] Cấu hình model embedding trong RagFlow (loại: local vs API remote) ==="
echo "  --> Model có tên chứa host/URL hoặc là API (OpenAI, Ollama remote...) sẽ CHẬM khi encode."
kubectl -n ragflow exec $POD -- env | grep -iE "EMBED|EMBD|OLLAMA|OPENAI|HF|MODEL" | head -20

echo
echo "=== [3] Đo thời gian encode từ log: chạy 1 query DÀI trên UI KB lớn, RỒI chạy tiếp lệnh này ==="
echo "  Tìm khoảng thời gian giữa 'retrieval' bắt đầu và ES '_search' chạy = thời gian encode."
kubectl -n ragflow logs $POD --since=120s 2>/dev/null | grep -iE "encode|embedding|retrieval|_search|Dealer|get_vector|similarity" | tail -30
