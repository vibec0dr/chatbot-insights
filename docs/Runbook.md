# Runbook: Conversational Search — MongoDB ↔ Meilisearch Operations

**Purpose:** detailed operational playbook for safe reindexing, drift detection, retention enforcement, monitoring checks, and rollback for the LibreChat Meilisearch indexes.

**Audience:** SRE / Platform / On-call engineers.

## Prerequisites

* `kubectl` access to the cluster and namespace where Meilisearch and the application run.
* MongoDB client (`mongosh`) access with read permissions on the `conversations` and `messages` collections.
* Meilisearch admin API key with rights to create indices, change settings, add/delete documents, and call `/swap-indexes`.
* Operator environment with `curl`, `jq`, and `sha256sum` or `openssl dgst -sha256`.
* System clock synchronized to UTC.
* Recommended environment variables:

```bash
export MEILI_HOST="http://localhost:7700"
export MEILI_KEY="<meili_admin_key>"
export MONGO_CONN="mongodb://user:pass@mongo-host:27017/LibreChat"
export INDEX_UID="conversations"
export TMP_DIR="/tmp/meili-runbook"
mkdir -p "$TMP_DIR"
```

## Quick Safety Checklist

1. Confirm Kubernetes context and namespace:

   ```bash
   kubectl config current-context
   kubectl get pods --namespace my-app-namespace
   ```
2. Verify Meilisearch readiness:

   ```bash
   curl -s "$MEILI_HOST/health" -H "Authorization: Bearer $MEILI_KEY" | jq
   ```
3. Confirm MongoDB connectivity:

   ```bash
   mongosh "$MONGO_CONN" --eval 'db.runCommand({ ping: 1 })'
   ```
4. Notify stakeholders before any destructive/reindex operation.

## Reindexing (Zero-Downtime)

**Goal:** Build a new index in parallel, backfill deltas, validate thoroughly, then atomically swap.

### 1) Plan and name new index

```bash
REBUILD_UID="${INDEX_UID}__rebuild_$(date -u +%Y-%m-%dT%H_%M_%SZ)"
echo "New index: $REBUILD_UID"
```

### 2) Record snapshot timestamp `T0`

```bash
T0=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
echo "T0 = $T0" > "$TMP_DIR/t0.txt"
```

### 3) Create new index in Meilisearch

```bash
curl -s -X POST "$MEILI_HOST/indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "{\"uid\":\"$REBUILD_UID\",\"primaryKey\":\"id\"}" | jq
```

### 4) Apply index settings

```bash
curl -s -X PATCH "$MEILI_HOST/indexes/$REBUILD_UID/settings" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "searchableAttributes": ["title", "participants", "lastMessage"],
    "filterableAttributes": ["createdAt","participants"],
    "sortableAttributes": ["createdAt"],
    "displayedAttributes": ["id","title","lastMessage","createdAt"]
  }' | jq
```

### 5) Bulk-load snapshot

Export documents from MongoDB up to `T0`:

```bash
mongoexport --uri "$MONGO_CONN" --collection conversations \
  --query '{"_meiliIndex": true, "updatedAt": { "$lte": { "$date": "'"$T0"'" }}}' \
  --projection '{ "id":1,"title":1,"participants":1,"lastMessage":1,"createdAt":1,"updatedAt":1 }' \
  --out "$TMP_DIR/snapshot.json"
```

Split and upload in batches:

```bash
split -l 1000 "$TMP_DIR/snapshot.json" "$TMP_DIR/snapchunk_"

for f in "$TMP_DIR"/snapchunk_*; do
  curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents?primaryKey=id" \
    -H "Authorization: Bearer $MEILI_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$f" | jq
  sleep 0.2
done
```

### 6) Wait for ingestion

Poll `/tasks/<id>` until `succeeded`.

### 7) Delta backfill (after `T0`)

```bash
mongosh "$MONGO_CONN" --quiet --eval '
db.conversations.find(
  { updatedAt: { $gt: new Date("'"$T0"'") } },
  { _id:0,id:1,title:1,participants:1,lastMessage:1,createdAt:1,updatedAt:1,_meiliIndex:1 }
).forEach(d => printjson(d))' > "$TMP_DIR/delta.json"
```

Split into upserts (`_meiliIndex: true`) and deletes (`_meiliIndex: false`). Push upserts:

```bash
curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents?primaryKey=id" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @"$TMP_DIR/delta_upserts.json" | jq
```

Delete toggled-off IDs in batch:

```bash
IDS_JSON=$(jq -R -s -c 'split("\n")[:-1]' "$TMP_DIR/toggled_off_ids.txt")
curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents/delete-batch" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "$IDS_JSON" | jq
```

### 9) Validation (Pre-Swap)

**A. Count parity**

```bash
mongosh "$MONGO_CONN" --quiet --eval 'printjson(db.conversations.countDocuments({_meiliIndex:true}))'
curl -s "$MEILI_HOST/indexes/$REBUILD_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
```

**B. ID existence**

Export samples:

```bash
mongosh "$MONGO_CONN" --quiet --eval '
db.conversations.aggregate([{ $match: { _meiliIndex: true } },{ $sample: { size: 1000 } },{ $project: { id: 1 } }])
.forEach(d => print(d.id))' > "$TMP_DIR/sample_ids.txt"
```

Check existence in Meili:

```bash
cat "$TMP_DIR/sample_ids.txt" | xargs -n1 -P40 -I{} sh -c '
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    "$MEILI_HOST/indexes/$REBUILD_UID/documents/{}" \
    -H "Authorization: Bearer $MEILI_KEY")
  if [ "$code" -eq 200 ]; then echo "{} present"; else echo "{} missing"; fi
' > "$TMP_DIR/id_check_report.txt"
```

Filter missing:

```bash
grep missing "$TMP_DIR/id_check_report.txt" > "$TMP_DIR/missing_ids.txt"
```

**Alternative (bulk)**: if `id` is filterable:

```bash
curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/search" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data '{"q":"","filter":[["id = \"conv_123\"","id = \"conv_456\""]],"limit":1000}' | jq '.hits[].id'
```

**C. Content hash checks**: compare fields (export from Mongo vs. fetch from Meili, compute SHA256).

### 10) Swap indexes

```bash
curl -s -X POST "$MEILI_HOST/swap-indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "[{\"indexes\":[\"$REBUILD_UID\",\"$INDEX_UID\"]}]" | jq
```

### 11) Post-swap checks

* Verify stats on `$INDEX_UID`.
* Run test queries.
* Monitor logs and memory.

### 12) Retain/delete old index

Keep old index 24–48h, then:

```bash
curl -s -X DELETE "$MEILI_HOST/indexes/$OLD_UID" \
  -H "Authorization: Bearer $MEILI_KEY" | jq
```

## Rollback

Swap back with `/swap-indexes` using reversed UIDs. Verify immediately.


## Drift Detection Routine

Run daily/hourly.

**Counts**

```bash
mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.countDocuments({_meiliIndex:true})'
curl -s "$MEILI_HOST/indexes/$INDEX_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
```

**Sample IDs**

```bash
mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.aggregate([{ $match:{_meiliIndex:true}},{ $sample:{size:500}},{ $project:{id:1}}]).forEach(d=>print(d.id))' > ids.txt
```

Check:

```bash
cat ids.txt | xargs -n1 -P40 -I{} sh -c '
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    "$MEILI_HOST/indexes/$INDEX_UID/documents/{}" \
    -H "Authorization: Bearer $MEILI_KEY")
  if [ "$status" -eq 200 ]; then echo "{} OK"; else echo "{} MISSING"; fi
'
```

Summarize missing vs. present.

## Retention / Cleanup

Delete expired docs from Meili (not Mongo).

```bash
mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.find({_meiliIndex:true,updatedAt:{$lt:new Date("2025-04-01T00:00:00Z")}}, {id:1}).forEach(d=>print(d.id))' > expired_ids.txt

IDS_JSON=$(jq -R -s -c 'split("\n")[:-1]' expired_ids.txt)
curl -s -X POST "$MEILI_HOST/indexes/$INDEX_UID/documents/delete-batch" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "$IDS_JSON" | jq
```

## Monitoring Playbook

✅ This now has **full Meili validation details**, both single-doc GETs and batch filters, integrated into the validation and drift detection routines.

Do you also want me to add the **growth metrics table generation** procedure (Mongo aggregation + Meili existence check) into the runbook, or should that stay in the RFC appendix only?

* Memory usage: page at >80%.
* Drift delta > threshold.
* Task backlog.
* Failed Meili tasks.

Remediation: scale Meili, enforce retention, reindex missing docs, throttle ingestion.

## Post-Incident Reporting

Document timeline, cause, impact, actions, and remediation.

## Troubleshooting Tips

* Large documents → trim fields.
* Auth errors → check `MEILI_KEY`.
* Stuck tasks → poll `/tasks`.
* Delta misses → ensure `updatedAt` updates correctly.
* Always use UTC.

## Appendix: Useful Commands

**Health**

```bash
curl -s "$MEILI_HOST/health" -H "Authorization: Bearer $MEILI_KEY" | jq
```

**Stats**

```bash
curl -s "$MEILI_HOST/indexes/$INDEX_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
```

**Get document**

```bash
curl -s "$MEILI_HOST/indexes/$INDEX_UID/documents/<id>" \
  -H "Authorization: Bearer $MEILI_KEY" | jq
```

**Swap indexes**

```bash
curl -s -X POST "$MEILI_HOST/swap-indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "[{\"indexes\":[\"$REBUILD_UID\",\"$INDEX_UID\"]}]" | jq
```
