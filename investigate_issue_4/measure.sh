#!/bin/bash
# ============================================================================
# measure.sh — Đo nốt 2 nghi phạm còn lại cho Issue #4 (query retrieval chậm)
# Chạy TRÊN NODE cluster (nơi curl tới được ES Lakehouse). Chạy 1 lần, đọc bảng cuối.
#
# Đã loại trước đó: rerank (chỉ 30-64 chunk), BM25 full-text (156-262ms), track_total_hits.
# Còn nghi: (1) kNN HNSW trên 141k vector,  (2) embedding encode câu hỏi.
# Cách tách: đo kNN thuần + hybrid ở tầng ES. Nếu ES nhanh mà tổng RagFlow vẫn 14s -> embedding.
# ============================================================================
set -u
ES="https://10.211.145.107:8051"
AUTH='-u aihub_prod:j1#&VC64Zo'
INDEX="ragflow_22cdb01e486a11ec9749e86cfe939a"   # KB lớn 141,978 docs

# Hàm: chạy 1 query JSON, in took_ms (hoặc lỗi ES nếu có)
run() { # $1=nhãn  $2=file_json
  local took
  took=$(curl -sk $AUTH "$ES/$INDEX/_search" -H 'Content-Type: application/json' -d @"$2" \
    | python3 -c "import sys,json
d=json.load(sys.stdin)
if 'error' in d: print('ERROR:', d['error'].get('type'), '-', str(d['error'].get('reason'))[:120])
else: print(d['took'])" 2>/dev/null)
  printf "  %-38s took_ms= %s\n" "$1" "$took"
}

echo "=================================================================="
echo " ĐO TẦNG ES cho Issue #4  (index=$INDEX)"
echo "=================================================================="

# --- Nghi phạm 1: kNN HNSW thuần (vector ngẫu nhiên 1024-dim, num_candidates=2048 như RagFlow) ---
echo "[1] kNN HNSW thuần — số num_candidates giống RagFlow (topn*2=2048):"
python3 -c "import json,random
print(json.dumps({'knn':{'field':'q_1024_vec','query_vector':[round(random.random(),5) for _ in range(1024)],'k':30,'num_candidates':2048},'size':30,'track_total_hits':False}))" > /tmp/m_knn2048.json
run "kNN k=30 num_candidates=2048" /tmp/m_knn2048.json

# So sánh: num_candidates thấp hơn để xem kNN có scale theo num_candidates không
python3 -c "import json,random
print(json.dumps({'knn':{'field':'q_1024_vec','query_vector':[round(random.random(),5) for _ in range(1024)],'k':30,'num_candidates':100},'size':30,'track_total_hits':False}))" > /tmp/m_knn100.json
run "kNN k=30 num_candidates=100" /tmp/m_knn100.json

# --- Nghi phạm 1b: kNN có FILTER kb_id (RagFlow luôn filter theo kb_id -> pre-filter HNSW) ---
# Lấy 1 kb_id thật từ index để filter cho giống RagFlow
KBID=$(curl -sk $AUTH "$ES/$INDEX/_search" -H 'Content-Type: application/json' -d '{"size":1,"_source":["kb_id"]}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['hits']['hits'][0]['_source']['kb_id'])" 2>/dev/null)
echo "[1b] kNN + filter kb_id=$KBID (giống RagFlow — pre-filtered HNSW):"
python3 -c "import json,random,sys
kb='$KBID'
print(json.dumps({'knn':{'field':'q_1024_vec','query_vector':[round(random.random(),5) for _ in range(1024)],'k':30,'num_candidates':2048,'filter':{'term':{'kb_id':kb}}},'size':30,'track_total_hits':False}))" > /tmp/m_knnf.json
run "kNN num_candidates=2048 + filter kb_id" /tmp/m_knnf.json

echo
echo "=================================================================="
echo " ĐỌC KẾT QUẢ:"
echo "  - Nếu [1]/[1b] ra vài NGHÌN ms  -> thủ phạm = kNN HNSW (fix: chỉnh num_candidates / ef_search)."
echo "  - Nếu [1]/[1b] đều < 500ms       -> kNN vô can -> thủ phạm còn lại = EMBEDDING encode câu hỏi."
echo "     (khi đó: 14s nằm ở bước RagFlow gọi model embedding, KHÔNG ở ES — sẽ đo tiếp bằng log encode.)"
echo "=================================================================="
