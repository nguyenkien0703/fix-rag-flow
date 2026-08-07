# 02 — Kế hoạch đo TÁCH TẦNG (lệnh cho Kiên chạy trên cluster)

> Nguyên tắc: mỗi bước đo TÁCH 1 tầng, để phân biệt nghi phạm. Chạy TUẦN TỰ, dán output vào `03-measurements.md`.
> Máy Claude trỏ minikube nên không tự chạy được — Kiên chạy, Claude phân tích.

---

## BƯỚC 0 — Xác định môi trường (chạy trước tiên)

```bash
# 0.1 Pod ragflow hiện tại (tên có thể đã đổi so với tài liệu cũ)
kubectl -n ragflow get pods -o wide

# 0.2 Lấy tên pod app vào biến (đổi selector nếu cần)
POD=$(kubectl -n ragflow get pods -l app=ragflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$POD" ] && POD=$(kubectl -n ragflow get pods --no-headers | grep -i 'ragflow-' | grep -vE 'es|minio|mysql|redis' | awk '{print $1}' | head -1)
echo "POD=$POD"

# 0.3 Xác nhận LOG_LEVELS có DEBUG (để thấy log duration của elastic_transport)
kubectl -n ragflow exec $POD -- env | grep -i log

# 0.4 Lấy 2 kb_id: 1 KB lớn (~120k chunks) + 1 KB nhỏ (~500 chunks) để so sánh
#     (lấy từ URL trên UI khi mở KB, hoặc hỏi MySQL)
kubectl -n ragflow exec ragflow-mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_PASSWORD" rag_flow -e "SELECT id,name,chunk_num,doc_num FROM knowledgebase ORDER BY chunk_num DESC LIMIT 10;"' 2>/dev/null
```

> Ghi lại: `POD=...`, `KB_BIG=<kb_id 120k>`, `KB_SMALL=<kb_id 500>`, tenant/index name.

---

## BƯỚC 1 — Đo ES `_search` duration khi query KB lớn (tách tầng ES vs Python)

**Mục tiêu:** biết trong ~30s thì ES chiếm bao nhiêu. Đây là phép tách tầng QUAN TRỌNG NHẤT.

### 1a. Bật tail log pod ở 1 terminal
```bash
kubectl -n ragflow logs -f $POD --since=1s | grep -iE "ESConnection|_search|duration|retrieval|took" 
```

### 1b. Ở terminal khác / UI: chạy ĐÚNG 1 query trên KB lớn
- Vào UI → mở KB lớn (120k) → tab **Retrieval testing** → nhập 1 câu hỏi thực tế → Testing.
- **Để trống ô Rerank model** (loại tầng rerank khỏi phép đo lần 1).
- Ghi lại thời gian tổng UI hiển thị (hoặc Network tab: request `/retrieval_test` mất bao lâu).

### 1c. Đọc log — tìm dòng dạng:
```
POST ragflow_<tenant>/_search [status:200 duration:XX.XXXs]   ← ES tốn bao nhiêu
```
**Phân nhánh kết luận:**
| Quan sát | Kết luận | Đi tiếp |
|----------|----------|---------|
| ES `_search duration ≈ tổng (vd 28s/30s)` | Bottleneck Ở ES → | BƯỚC 2 (profile ES) |
| ES nhanh (<2s) nhưng tổng vẫn ~30s | Bottleneck ở Python/embedding/rerank → | BƯỚC 4 (tách embedding/rerank) |
| Nhiều dòng `_search` cho 1 request | Có N+1 hoặc retry → | đếm & xem query nào lặp |

---

## BƯỚC 2 — Profile ES query (tách kNN vs BM25 vs track_total_hits)

**Chỉ chạy nếu BƯỚC 1 cho thấy ES là bottleneck.** Dùng `?profile=true` để ES tự chỉ ra phần nào tốn.

### 2a. Lấy raw ES query mà RagFlow gửi (từ log DEBUG)
```bash
# Log đã in query JSON: "ESConnection.search [...] query: {...}"
kubectl -n ragflow logs $POD --since=5m | grep -A2 "ESConnection.search" | grep "query:" | tail -1
```
→ copy phần JSON `{...}` sau `query:` — đây là body query thật.

### 2b. Gửi lại query đó tới ES kèm profile=true, so KB lớn vs nhỏ
```bash
# Thay <ES_HOST>, <ES_USER>, <ES_PASS>, <INDEX> cho đúng. Lấy từ:
kubectl -n ragflow exec $POD -- env | grep -iE "ES_HOST|ES_PORT|ES_USER|ES_PASS|ELASTIC"

# Dán query JSON vào file rồi thêm "profile": true
cat > /tmp/q.json <<'EOF'
<PASTE_QUERY_JSON_HERE>
EOF
# Thêm profile
python3 -c "import json;d=json.load(open('/tmp/q.json'));d['profile']=True;json.dump(d,open('/tmp/q.json','w'))"

curl -sk -u "<ES_USER>:<ES_PASS>" "https://<ES_HOST>:8051/<INDEX>/_search?pretty" \
  -H 'Content-Type: application/json' -d @/tmp/q.json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('took_ms=',d['took']);print('total_hits=',d['hits']['total']);\
import json as j;print(j.dumps(d.get('profile',{}).get('shards',[{}])[0].get('searches',[]),indent=2)[:3000])"
```
**Đọc kết quả profile:** phần `type` nào có `time_in_nanos` lớn nhất:
- `DenseVectorQuery` / kNN lớn → bottleneck kNN (HNSW/brute-force).
- `BooleanQuery`/`query_string` lớn → BM25 match rộng.
- `took` >> tổng thời gian các query con → phần collect/count (track_total_hits) tốn.

### 2c. Thử tách riêng để cô lập (chạy 3 biến thể trên KB lớn):
```bash
# (i) CHỈ kNN — bỏ query_string
# (ii) CHỈ BM25 — bỏ knn
# (iii) knn với track_total_hits=false
# So took_ms của 3 cái → cái nào chiếm 30s chính là thủ phạm.
```
> Nếu ngại sửa JSON tay, Claude sẽ viết sẵn 3 file query biến thể khi có query gốc + mapping.

---

## BƯỚC 3 — Kiểm tra index/mapping KB lớn (kNN brute-force? segment nhiều?)

```bash
ES="https://<ES_HOST>:8051" ; AUTH="-u <ES_USER>:<ES_PASS>"

# 3a. Mapping vector field — xem index type (hnsw?), dims, similarity
curl -sk $AUTH "$ES/<INDEX>/_mapping?pretty" | grep -A15 "_vec"

# 3b. Số lượng segment (nhiều segment = query chậm)
curl -sk $AUTH "$ES/_cat/segments/<INDEX>?v&h=index,shard,segments.count,docs.count,size" 2>/dev/null
curl -sk $AUTH "$ES/_cat/shards/<INDEX>?v" 2>/dev/null

# 3c. Số doc thật trong index lớn vs nhỏ
curl -sk $AUTH "$ES/<INDEX>/_count?pretty"

# 3d. ES version + có phải Elasticsearch chuẩn không (Lakehouse Viettel có thể là bản khác)
curl -sk $AUTH "$ES?pretty" | grep -iE "version|number|distribution"
```
**Đọc:** nếu vector field KHÔNG phải `dense_vector` index=true (hnsw), ES sẽ **brute-force** cosine trên 120k
vector mỗi query → giải thích scale tuyến tính 40ms→30s hoàn hảo. Đây là 1 khả năng RẤT đáng nghi.

---

## BƯỚC 4 — (chỉ nếu BƯỚC 1 cho ES nhanh) Tách embedding vs rerank vs Python

```bash
# 4a. So query có rerank vs không rerank trên KB lớn — nếu chênh nhiều thì rerank là thủ phạm
#     (nhưng phân tích code nói rerank chỉ 30-64 chunk → khả năng thấp)
# 4b. Grep thời gian encode_queries trong log (embedding model)
kubectl -n ragflow logs $POD --since=5m | grep -iE "encode|embedding|rerank|similarity"
```

---

## BƯỚC 5 — So sánh đối chứng: chạy CÙNG query trên KB nhỏ (500 chunks)
Lặp BƯỚC 1 với `KB_SMALL`. Kỳ vọng ES `_search` ~vài chục ms. Chênh lệch giữa 2 KB CHÍNH LÀ chi phí scale theo N
→ khẳng định tầng nào gây ra.

---

## Tổng kết cần thu về (điền `03-measurements.md`)
- [ ] Tổng thời gian request KB lớn: ___ s
- [ ] ES `_search duration` KB lớn: ___ s ; KB nhỏ: ___ s
- [ ] Profile: phần tốn nhất = ___ (kNN / BM25 / count)
- [ ] Mapping vector: index hnsw hay brute-force? = ___
- [ ] Số segment index lớn: ___
- [ ] Có rerank model bật không: ___
