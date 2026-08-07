#!/bin/bash
# ============================================================================
# measure3.sh (v2) — Query RagFlow gui ES nang 1.18MB! Phan tich cai gi lam phinh to.
# Log in query bang str(dict) Python (nhay don) nen dung ast.literal_eval, khong phai json.load.
# ============================================================================
set -u
ES="https://10.211.145.107:8051"
AUTH='-u aihub_prod:j1#&VC64Zo'
INDEX="ragflow_22cdb01e486a11ec9749e86cfe939a"
POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
echo "POD=$POD"

echo "=== [A] Bat query that (lay tu dong log 'query:' — phan sau dau 'query: ') ==="
# Lay ca dong, cat phan sau 'query: ' (giu nguyen, khong grep brace vi nested)
kubectl -n ragflow logs $POD --since=150s 2>/dev/null \
  | grep "ESConnection.search" | grep "query:" | tail -1 \
  | sed -E 's/.*ESConnection\.search[^{]*query:[[:space:]]*//' > /tmp/rq_raw.txt
BYTES=$(wc -c < /tmp/rq_raw.txt)
echo "  -> $BYTES bytes"
[ "$BYTES" -lt 50 ] && { echo "  !! khong bat duoc, chay lai query tren UI roi chay ngay"; exit 1; }

echo
echo "=== [B] Phan tich CAU TRUC query — cai gi lam no phinh to 1.18MB? ==="
python3 <<'PY'
import ast, json
raw = open('/tmp/rq_raw.txt').read().strip()
# thu json truoc, roi ast (dict python nhay don)
try:
    d = json.loads(raw)
except Exception:
    try:
        d = ast.literal_eval(raw)
    except Exception as e:
        print("  parse fail:", str(e)[:100]); 
        print("  200 ky tu dau:", raw[:200]); raise SystemExit
json.dump(d, open('/tmp/rq.json','w'))
print("  keys:", list(d.keys()), " size:", d.get('size'))

def sz(o): return len(json.dumps(o, ensure_ascii=False))
# duyet tim cac nhanh nang nhat
def walk(o, path=""):
    out=[]
    if isinstance(o, dict):
        for k,v in o.items():
            out.append((f"{path}.{k}", sz(v), type(v).__name__, len(v) if isinstance(v,(list,dict,str)) else 1))
            out += walk(v, f"{path}.{k}")
    elif isinstance(o, list):
        out.append((f"{path}[]", sz(o), "list", len(o)))
    return out
rows = walk(d)
rows.sort(key=lambda x:-x[1])
print("  --- 12 nhanh NANG nhat (path | bytes | type | len) ---")
for p,b,t,l in rows[:12]:
    print(f"    {b:>9} B  len={l:<7} {t:<6} {p[:70]}")

# Dem knn / should / query_vector
q = d.get('query',{})
b = q.get('bool',{})
print("  bool.should len:", len(b.get('should',[])), " bool.must len:", len(b.get('must',[])), " bool.filter len:", len(b.get('filter',[])))
print("  has top-level knn:", 'knn' in d)
# tim query_vector dai
import re
s = json.dumps(d)
print("  so lan xuat hien 'query_vector':", s.count('query_vector'))
print("  so lan 'rank_feature':", s.count('rank_feature'))
PY

echo
echo "=== [C] Replay query THAT + profile ==="
python3 -c "import json;d=json.load(open('/tmp/rq.json'));d['profile']=True;json.dump(d,open('/tmp/rq_prof.json','w'))" 2>/dev/null && \
curl -sk $AUTH "$ES/$INDEX/_search" -H 'Content-Type: application/json' -d @/tmp/rq_prof.json \
 | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d: print('  ES ERROR:',str(d['error'])[:300]); sys.exit()
print('  TOOK_TONG_ms =', d['took'], ' total_hits =', d['hits']['total'])
for si,sh in enumerate(d.get('profile',{}).get('shards',[])[:2]):
  for se in sh.get('searches',[]):
    rows=[]
    def walk(q):
      rows.append((q.get('type','?'), q.get('time_in_nanos',0)//1000000))
      for c in q.get('children',[]): walk(c)
    for q in se.get('query',[]): walk(q)
    rows.sort(key=lambda x:-x[1])
    print(f'  shard{si} top query con:', [(t,f'{ms}ms') for t,ms in rows[:6]])
    for c in se.get('collector',[]): print('    collector',c.get('name'),c.get('time_in_nanos',0)//1000000,'ms')
"
