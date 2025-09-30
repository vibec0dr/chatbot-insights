# RFC: Meilisearch Index Consistency

## Potential causes of index inconsistency (fact-checked)

**Short summary:** In production we observe that some documents flagged as intended-for-indexing in MongoDB are not present in Meilisearch. This is not a Meilisearch bug per se, but a synchronization and operational one driven by the way indexing is performed and by concurrent changes.

**What Meilisearch provides and how that matters**

- Meilisearch processes write operations asynchronously and exposes a task API that reports per-task statistics (for example `details.receivedDocuments` and `details.indexedDocuments`). A succeeded task indicates the batch was processed, but it does _not_ prove there were no subsequent changes in the source-of-truth during a long reindex operation.
- Meilisearch exposes index statistics (`/indexes/<uid>/stats`) including `numberOfDocuments`, but the stats API does not support date-range queries; it’s therefore only a coarse tool for comparing totals against mongosh counts.
- Meilisearch supports an atomic index swap (`/swap-indexes`) so you can build a new index in the background and atomically cut it over to production — this is the recommended zero-downtime deployment pattern. However, building the new index and making it fully consistent with the live database are separate concerns.

**Root operational contributors to drift**

1. **Long reindex windows (snapshot vs live drift)**

   - At production scale a full reindex can take many hours; during that time the DB continues to receive new messages (~30k/day in our environment), updates, and deletions. Documents created or deleted _after_ the snapshot used to build the new index will not be present in that snapshot unless explicitly captured and applied as a delta. (Indexing timing depends on hardware and batching; Meilisearch docs describe how to tune ingestion, but the application must handle deltas.)

2. **Deletes/updates missed during the run**

   - If delete events occur while a long-running build is in progress and those deletes are not captured/applied, stale records can linger (or intended records can be absent) in the live index depending on swap timing and delta handling.

3. **Operational trigger semantics (how LibreChat signals Meilisearch)**

   - LibreChat uses `_meiliIndex` flags and a reset script; the product docs note that resetting those flags will cause documents to be reindexed on the next LibreChat startup or next sync check. In practice, operators frequently restart the app to trigger immediate reindex, which lengthens the window of change if delta capture is not implemented.

4. **App-level responsibility for delta/backfill**

   - Meilisearch provides swap-indexes and the task API, but it does not out-of-the-box capture application change streams during a long reindex. To guarantee parity you must capture changes that occur during the build window (a delta or backfill step) and apply them before swap (or immediately after swap onto the live index) to guarantee consistency.

**Operational note:** Meilisearch is implemented in Rust and is designed around asynchronous tasking and atomic index operations, but correctness at scale still requires application-level orchestration (snapshot → apply deltas → swap → verify).
