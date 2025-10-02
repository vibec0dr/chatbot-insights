# Runbook: Conversational Search — MongoDB ↔ Meilisearch Operations

**Purpose:** detailed operational playbook for safe reindexing, drift detection, retention enforcement, monitoring checks, and rollback for the LibreChat Meilisearch indexes.

**Audience:** SRE / Platform / On-call engineers.

**Prerequisites**

* kubectl access to the cluster and namespace where Meilisearch and the application run.
* MongoDB client (mongo shell or mongosh) access with read access to the conversations/messages collections.
* Meilisearch admin API key with rights to create indices, change settings, add/delete documents, and call `/swap-indexes`.
* `curl`, `jq`, and `sha256sum` (or `openssl dgst -sha256`) installed on the operator machine or a utility pod.
* Time synchronized to UTC (e.g., `timedatectl` shows UTC or conversion applied to timestamps).
* Recommended environment variables set for convenience:

  ```bash
  export MEILI_HOST="http://localhost:7700"
  export MEILI_KEY="<meili_admin_key>"
  export MONGO_CONN="mongodb://user:pass@mongo-host:27017/LibreChat"
  export INDEX_UID="conversations"
  export TMP_DIR="/tmp/meili-runbook"
  mkdir -p "$TMP_DIR"
  ```

---

## Quick safety checklist before any reindex or destructive operation

1. Confirm you are on the correct Kubernetes context and namespace:

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
   mongosh "$MONGO_CONN" --eval 'db.runCommand({ping:1})'
   ```
4. Notify stakeholders / post a short maintenance note in relevant Slack or ops channel (mention expected window and rollback plan).

---

## Reindexing (Zero-Downtime) — Full Procedure

**Goal:** Build a new index in parallel, catch up deltas by timestamp, validate, then swap atomically. No downtime.

### 1) Plan & name the new index

Pick a unique index UID for the rebuild and document it. Use timestamps for traceability.

Example naming:

```
conversations__rebuild_2025-10-02T12_00_00Z
```

Set variables:

```bash
REBUILD_UID="${INDEX_UID}__rebuild_$(date -u +%Y-%m-%dT%H_%M_%SZ)"
echo "New index: $REBUILD_UID"
```

### 2) Record the snapshot timestamp `T0`

Take a precise UTC timestamp to define the snapshot boundary.

```bash
T0=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
echo "T0 = $T0" > "$TMP_DIR/t0.txt"
```

Log `T0` to your incident/maintenance tracker.

### 3) Create the new index in Meilisearch

Create index with the same primaryKey as the current one.

```bash
curl -s -X POST "$MEILI_HOST/indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "{\"uid\":\"$REBUILD_UID\",\"primaryKey\":\"id\"}" | jq
```

If the index already exists, fail and resolve before continuing.

### 4) (Optional) Apply index settings (searchable/filterable)

Set the desired minimal searchable/filterable attributes before bulk load to avoid reindexing post-load.

Example:

```bash
curl -s -X PATCH "$MEILI_HOST/indexes/$REBUILD_UID/settings" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "searchableAttributes": ["title", "participants", "lastMessage"],
    "filterableAttributes": ["createdAt", "participants"],
    "sortableAttributes": ["createdAt"],
    "displayedAttributes": ["id","title","lastMessage","createdAt"]
  }' | jq
```

Confirm settings applied:

```bash
curl -s "$MEILI_HOST/indexes/$REBUILD_UID/settings" -H "Authorization: Bearer $MEILI_KEY" | jq
```

### 5) Bulk-load snapshot from MongoDB (batched)

Stream documents in batches from MongoDB to Meilisearch. Use projection to only include fields you index.

Example `mongosh` command to export JSON lines (use `--quiet` where supported):

```bash
# Adjust batch size as appropriate (1k-10k). Use a cursor/skip pattern or a streaming export.
mongosh "$MONGO_CONN" --quiet --eval '
const cursor = db.conversations.find(
  { MeiliIndex: true, updatedAt: { $lte: new Date("'"$T0"'") } },
  { _id:0, id:1, title:1, participants:1, lastMessage:1, createdAt:1, updatedAt:1 } // projection
).batchSize(1000);
while(cursor.hasNext()){
  printjson(cursor.next());
}' > "$TMP_DIR/snapshot.jsonl"
```

**Note:** For large exports, prefer a paged reader to avoid memory blow. If you have `mongoexport`, use it:

```bash
mongoexport --uri "$MONGO_CONN" --collection conversations --query '{"MeiliIndex": true, "updatedAt": {"$lte": { "$date": "'"$T0"'" }}}' --projection '{ "id": 1, "title": 1, "participants":1, "lastMessage":1, "createdAt":1, "updatedAt":1 }' --out "$TMP_DIR/snapshot.json"
```

Then bulk push to Meilisearch in batches. Example using `jq` to chunk and `curl` to push:

```bash
# Recommended batch size
BATCH_SIZE=1000
split -l $BATCH_SIZE "$TMP_DIR/snapshot.json" "$TMP_DIR/snapchunk_"

for f in "$TMP_DIR"/snapchunk_*; do
  echo "Uploading $f ..."
  curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents?primaryKey=id" \
    -H "Authorization: Bearer $MEILI_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$f" | jq
  # Optionally: poll the task id and wait for completion before sending next batch, to limit memory
  sleep 0.2
done
```

**Recommendations:**

* Tune `BATCH_SIZE` by document size and Meili throughput.
* Use task responses from Meilisearch and poll `GET /tasks/<id>` to ensure batches processed. If many batches are queued, throttle ingestion.

### 6) Wait for snapshot ingestion to drain

If Meili returns async task IDs, poll them to completion. Example simple polling loop (replace `<task_id>` parsing as needed):

```bash
# Example: after each batch you capture "taskUid", then poll until status is "succeeded"
# Generic example for a single task:
TASK_ID="<task_id_from_response>"
until [ "$(curl -s "$MEILI_HOST/tasks/$TASK_ID" -H "Authorization: Bearer $MEILI_KEY" | jq -r '.status')" == "succeeded" ]; do
  echo "Waiting for task $TASK_ID ..."
  sleep 2
done
```

You can also monitor Meili's overall indexing queue and memory.

### 7) Delta backfill: query MongoDB for documents updated since `T0`

Once the bulk snapshot load finishes, capture all changes since `T0` and upsert them into the new index.

Delta query example:

```bash
mongosh "$MONGO_CONN" --quiet --eval '
const cursor = db.conversations.find(
  { updatedAt: { $gt: new Date("'"$T0"'") } },
  { _id:0, id:1, title:1, participants:1, lastMessage:1, createdAt:1, updatedAt:1, MeiliIndex:1 }
).batchSize(1000);
while(cursor.hasNext()){
  printjson(cursor.next());
}' > "$TMP_DIR/delta.json"
```

Filter/transform client-side to only upsert documents with `MeiliIndex: true`, and for `MeiliIndex: false` prepare a delete list.

Upsert delta documents to Meilisearch:

```bash
# Upsert
curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents?primaryKey=id" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @"$TMP_DIR/delta_upserts.json" | jq
```

### 8) Remove invalidated documents since `T0`

Compute list of documents toggled off or deleted since `T0` and remove them from `REBUILD_UID` before swap.

```bash
# Example to get ids that were toggled off
mongosh "$MONGO_CONN" --quiet --eval '
db.conversations.find({ MeiliIndex: false, updatedAt: { $gt: new Date("'"$T0"'") } }, { id: 1 }).forEach(d => print(d.id))' > "$TMP_DIR/toggled_off_ids.txt"
```

Remove by batch:

```bash
# Remove by ids, Meili supports batch deletion by id list
IDS_JSON=$(jq -R -s -c 'split("\n")[:-1]' "$TMP_DIR/toggled_off_ids.txt")
curl -s -X POST "$MEILI_HOST/indexes/$REBUILD_UID/documents/delete-batch" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "$IDS_JSON" | jq
```

If some documents were deleted from MongoDB, ensure you compute their ids via logs/audit or compare snapshots; then delete those ids from Meili too.

### 9) Validation (pre-swap)

Perform three levels of validation: counts, id existence for sampled batches, and content hash check for samples.

**A. Count parity**

* Get MongoDB count of eligible docs (as of now or as of T_end if you record it).

  ```javascript
  db.conversations.countDocuments({ MeiliIndex: true })
  ```

  or via mongosh:

  ```bash
  mongosh "$MONGO_CONN" --quiet --eval 'printjson(db.conversations.countDocuments({ MeiliIndex: true }))'
  ```
* Get Meilisearch index stats:

  ```bash
  curl -s "$MEILI_HOST/indexes/$REBUILD_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
  ```

Allow small transient differences during delta ingestion. Your target is that after backfill, counts should match or be within an acceptable delta (e.g., <0.1% or an agreed threshold).

**B. ID existence check (batched)**
Sample IDs from MongoDB and confirm presence in Meili.

Mongo sample:

```bash
mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.aggregate([{ $match: { MeiliIndex: true } }, { $sample: { size: 1000 } }, { $project: { id: 1 } }]).forEach(d => print(d.id))' > "$TMP_DIR/sample_ids.txt"
```

Query Meili for batch presence (example with loop):

```bash
while read id; do
  curl -s "$MEILI_HOST/indexes/$REBUILD_UID/documents/$id" -H "Authorization: Bearer $MEILI_KEY" | jq -e '.id' >/dev/null || echo "missing $id"
done < "$TMP_DIR/sample_ids.txt" > "$TMP_DIR/missing_ids.txt"
```

If `missing_ids.txt` is non-empty, those are candidate drift items to reprocess.

**C. Content hash check (stronger)**
Choose fields that are indexed and compute a canonical hash on MongoDB side then fetch from Meili and hash fields, compare.

Mongo side example to compute sha256 of searchable fields (done in a script):

```javascript
// pseudocode; implement via export script that concatenates fields and computes SHA256
```

Simpler approach: export sample documents from MongoDB and corresponding documents from Meili and run a diff on the fields.

Example flow:

1. Export 100 sample docs from MongoDB to `mongo_sample.json`.
2. Fetch same IDs from Meili into `meili_sample.json`.
3. Run script to compare `title`, `lastMessage`, etc., field-by-field. Flag mismatches.

If mismatches exist, re-process those documents into the index and re-validate.

### 10) Swap indexes atomically

Once validation passes, perform the atomic swap.

```bash
curl -s -X POST "$MEILI_HOST/swap-indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "[ { \"indexes\": [\"$REBUILD_UID\", \"$INDEX_UID\"] } ]" | jq
```

Confirm swap success by querying stats for the active `INDEX_UID`.

### 11) Post-swap checks

* Query the new live `INDEX_UID` stats and ensure counts are consistent.
* Run a few sample searches to confirm expected behavior.
* Monitor logs for errors and memory usage closely for the following 15–30 minutes.

### 12) Retain or delete old index

Keep the previous index for a configured retention window (e.g., 24–48h) to enable quick rollback. After retention, delete old index to reclaim space:

```bash
# Delete index by UID
curl -s -X DELETE "$MEILI_HOST/indexes/$REBUILD_UID" \
  -H "Authorization: Bearer $MEILI_KEY" | jq
```

---

## Rollback Procedure (if swap or post-swap problems detected)

If after swap you detect major errors (missing documents, widespread incorrect content, systemic query failures), follow this rollback:

1. Immediately notify stakeholders and set the maintenance flag.
2. Swap back using `swap-indexes` (swap the UIDs reversed). Example:

```bash
# Swap back: replace old with new (reverse the earlier swap)
curl -s -X POST "$MEILI_HOST/swap-indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data "[ { \"indexes\": [\"$INDEX_UID\", \"$REBUILD_UID\"] } ]" | jq
```

3. Confirm that the original index now answers queries correctly by running sanity searches and verifying counts.
4. Investigate root cause (logs, failed tasks, task statuses).
5. If cause is fixable (malformed documents, projection issues), fix the loader/export scripts and retry reindex from scratch with a fresh `REBUILD_UID`.
6. If the cause is resource exhaustion, increase capacity or prune index per lifecycle policy before retry.

---

## Drift Detection Routine (scheduled job / CLI)

Run this as a daily or hourly job depending on traffic.

### A. Count comparison

1. Query MongoDB for number of eligible docs:

   ```bash
   mongosh "$MONGO_CONN" --quiet --eval 'printjson(db.conversations.countDocuments({MeiliIndex:true}))'
   ```
2. Query Meili stats:

   ```bash
   curl -s "$MEILI_HOST/indexes/$INDEX_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
   ```
3. Compute difference and alert if delta > configured threshold.

### B. Sample ID check

1. Fetch a sample of IDs from MongoDB (size configurable, e.g., 500).
2. Check their existence in Meili as shown under validation.
3. If missing rate > threshold, create a remediation job to reindex missing ids.

### C. Hash/sample content verification (weekly)

1. Take a sample of documents (e.g., 1000) stratified by age and size.
2. Compare searchable fields (title, lastMessage) between Mongo and Meili.
3. Flag mismatches for remediation.

All outputs should be logged and uploaded to a reports S3 bucket with metadata: timestamp, run duration, sample size, counts, missing ids.

---

## Retention / Cleanup Job (routine)

If you enforce "last N months" retention, run a periodic job to eject expired documents from Meili (not from MongoDB).

Example to delete by query of ids older than `RETENTION_CUTOFF`:

1. Generate list of ids older than cutoff:

   ```bash
   mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.find({ MeiliIndex: true, updatedAt: { $lt: new Date("'"$RETENTION_CUTOFF"'") } }, { id:1 }).forEach(d => print(d.id))' > "$TMP_DIR/expired_ids.txt"
   ```
2. Batch delete them from Meili:

   ```bash
   IDS_JSON=$(jq -R -s -c 'split("\n")[:-1]' "$TMP_DIR/expired_ids.txt")
   curl -s -X POST "$MEILI_HOST/indexes/$INDEX_UID/documents/delete-batch" \
     -H "Authorization: Bearer $MEILI_KEY" \
     -H "Content-Type: application/json" \
     --data "$IDS_JSON" | jq
   ```
3. Verify new Meili stats and log results.

**Important:** Do not delete from MongoDB. Only remove from Meili. MongoDB remains canonical.

---

## Monitoring Playbook (what to observe and when to page)

**Critical metrics**

* Meili memory usage vs pod limit (page at 80% memory). `kubectl top pod` or cluster monitoring.
* Meili numberOfDocuments (index stats) growth rate.
* Drift delta (Mongo flag count - Meili doc count) (page if > threshold, e.g., > 1% or > 10k).
* Task backlog / indexing latency in Meilisearch.
* Failed Meili tasks or health check errors.

**Who to page**

* On-call SRE for the service if memory > 80% or Meili pod OOMs.
* Index owner / product engineer if drift > critical threshold or consistent validation failures.
* Platform team if persistent task backlog indicates cluster/network issues.

**Immediate remediation steps on alert**

* For memory alerts: scale Meilisearch (more RAM), enforce retention to remove oldest documents, or temporarily throttle ingestion.
* For drift alerts: run the drift detection routine, reindex missing documents, escalate if missing document counts are large.
* For task backlog: check Meili logs, increase `max-indexing-threads` or pause ingestion, or increase pod resources.

---

## Post-Incident reporting

After any failure (OOM, bad swap, mass drift), produce a post-mortem that includes:

* Timeline of events (T0 snapshot, ingestion start/end, swap time).
* Root cause analysis.
* Number of documents affected.
* Actions taken and time to recovery.
* Remediation steps and preventive changes (e.g., lower default searchable attributes, add automated retention).

---

## Troubleshooting tips / common pitfalls

* **Large documents cause memory spikes**: trim displayed/indexed fields and check for huge `lastMessage` contents.
* **Auth failures with Meilisearch API**: ensure `MEILI_KEY` is valid and has admin privileges.
* **Stuck tasks**: query Meili task endpoints and inspect error messages. Retrying batches with smaller size often helps.
* **Delta misses**: ensure your `updatedAt` is updated on every write that should affect the index; if not, introduce a reliable `updatedAt` update in app logic.
* **Timezone surprises**: use UTC everywhere and log `T0` in ISO-8601 UTC format.
* **High ingestion load -> query latency**: throttle bulk uploads or increase Meili cluster nodes/memory.

---

## Example scripts / automation suggestions

* Build a CLI `indexctl` that exposes commands:

  * `indexctl reindex conversations --retention-days=180`
  * `indexctl validate conversations --sample-size=1000`
  * `indexctl drift conversations --report /tmp/report.json`
* CLI should encapsulate auth, pagination, batching, and retries.
* Schedule drift detection as a cron job (or K8s CronJob) and upload reports to S3.

---

## When to call for help

* Pod restarted due to OOM and immediate memory increase trends persist after retention enforcement.
* Reindex validation failing with >1% missing documents after retries.
* Swap succeeded but user-visible queries return inconsistent or very incorrect results across many IDs.
* Repeated failures to delete expired documents from Meili due to API errors.

---

## Appendix: Useful commands summary

Check Meili health:

```bash
curl -s "$MEILI_HOST/health" -H "Authorization: Bearer $MEILI_KEY" | jq
```

Get Meili index stats:

```bash
curl -s "$MEILI_HOST/indexes/$INDEX_UID/stats" -H "Authorization: Bearer $MEILI_KEY" | jq
```

Fetch document by id:

```bash
curl -s "$MEILI_HOST/indexes/$INDEX_UID/documents/<id>" -H "Authorization: Bearer $MEILI_KEY" | jq
```

Swap indexes:

```bash
curl -s -X POST "$MEILI_HOST/swap-indexes" -H "Authorization: Bearer $MEILI_KEY" -H "Content-Type: application/json" --data "[{ \"indexes\": [\"$REBUILD_UID\",\"$INDEX_UID\"] }]" | jq
```

Mongo sample:

```bash
mongosh "$MONGO_CONN" --quiet --eval 'db.conversations.aggregate([{ $match: { MeiliIndex: true } },{ $sample: { size: 1 } }])'
```
