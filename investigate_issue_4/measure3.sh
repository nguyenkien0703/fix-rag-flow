#!/bin/bash
# ============================================================================
# measure3.sh — Bắt QUERY THẬT của RagFlow (hybrid BM25+kNN+fusion+rank_feature)
#               rồi replay kèm ?profile=true để ES chỉ ra phần nào tốn 15s.
# LÝ DO: các probe trước đo BM25/kNN RIÊNG LẺ = nhanh, nhưng query THẬT là hybrid
#        gộp + rank_feature -> phải đo đúng query thật mới tái hiện 15s.
#
# CÁCH CHẠY:
#   1) Trên UI: vào Search, chạy câu "quy định về thời hạn thanh toán..." trên KB voffice-docs-sum (141k)
#   2) NGAY SAU ĐÓ (trong 2 phút) chạy: bash measure3.sh
# ============================================================================
set -u
ES="https://10.211.145.107:8051"
AUTH='-u aihub_prod:j1#&VC64Zo'
INDEX="ragflow_22cdb01e486a11ec9749e86cfe939a"   # KB voffice 141k
POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
echo "POD=$POD  INDEX=$INDEX"

echo "=== [A] Bắt query JSON thật RagFlow vừa gửi (dòng _search cuối, có knn/query_string) ==="
kubectl -n ragflow logs $POD --since=120s 2>/dev/null \
  | grep "ESConnection.search" | grep -oE '\{.*\}' | tail -1 > /tmp/ragflow_query.json
BYTES=$(wc -c < /tmp/ragflow_query.json)
echo "  -> lấy được $BYTES bytes"
if [ "$BYTES" -lt 50 ]; then
  echo "  !! KHÔNG bắt được query. Log có thể đã xoay. Chạy lại query trên UI rồi chạy ngay script này."
  echo "  !! Hoặc thử tăng --since. Dừng ở đây."
  exit 1
fi

# In cấu trúc query để hiểu nó gồm gì
python3 -c "import json;d=json.load(open('/tmp/ragflow_query.json'));print('  keys:',list(d.keys()));\
print('  has knn:', 'knn' in d);print('  size:',d.get('size'));\
q=d.get('query',{});print('  query top keys:',list(q.keys()));\
print('  num should/must:', len(q.get('bool',{}).get('should',[])), len(q.get('bool',{}).get('must',[])))"

echo
echo "=== [B] Replay query THẬT + profile=true -> phần nào tốn thời gian ==="
python3 -c "import json;d=json.load(open('/tmp/ragflow_query.json'));d['profile']=True;json.dump(d,open('/tmp/ragflow_query_prof.json','w'))"
curl -sk $AUTH "$ES/$INDEX/_search" -H 'Content-Type: application/json' -d @/tmp/ragflow_query_prof.json \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d: print('ERROR:',d['error']); sys.exit()
print('TOOK_TONG_ms =', d['took'])
print('total_hits =', d['hits']['total'])
shards=d.get('profile',{}).get('shards',[])
print('num_shards profiled =', len(shards))
for si,sh in enumerate(shards[:3]):
    for se in sh.get('searches',[]):
        # gom các query con theo type + thời gian
        rows=[]
        def walk(q):
            rows.append((q.get('type','?'), q.get('time_in_nanos',0)//1000000, str(q.get('description',''))[:60]))
            for c in q.get('children',[]): walk(c)
        for q in se.get('query',[]): walk(q)
        rows.sort(key=lambda x:-x[1])
        print(f'--- shard{si} top query con (ms) ---')
        for t,ms,desc in rows[:6]: print(f'   {ms:6d} ms  {t:22s} {desc}')
        coll=se.get('collector',[])
        for c in coll: print('   collector:',c.get('name'),c.get('time_in_nanos',0)//1000000,'ms')
    # aggregations profile
    for ag in sh.get('aggregations',[]):
        print('   AGG:',ag.get('type'),ag.get('time_in_nanos',0)//1000000,'ms',str(ag.get('description',''))[:50])
"
