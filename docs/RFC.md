# RFC: Conversational Search with MongoDB and Meilisearch

## TL;DR

Our conversational search system drifts out of sync, grows without limits, risks exhausting RAM and crashing, and lacks effective observability.

## 1. Context and Problem Statement

LibreChat relies on MongoDB for storing all conversations and messages. Meilisearch provides the search layer, holding a secondary index of those documents optimized for fast queries. A document in MongoDB carries a `MeiliIndex` flag. When set to true, that document is expected to appear in Meilisearch. MongoDB is the canonical source of truth, while Meilisearch is a derivative, queryable projection.

This model is fragile at scale. Drift accumulates between the two systems. Some documents expected in Meilisearch are missing; others persist long after they should have been removed. Updates may be delayed or lost. Rebuilding an index exposes users to incomplete results because ingestion takes hours while new documents continue to arrive. By the time a rebuild completes, the index may already be out of date.

Growth compounds this fragility. Meilisearch stores its indexes in memory, and by default indexes all fields. As the dataset grows, memory pressure increases linearly until pods crash. With no lifecycle policies in place, the index expands unchecked.

Observability is weak. Meilisearch exposes statistics about its internal operations, but operators lack visibility into how many documents are eligible for indexing in MongoDB, how many are present in Meilisearch, or how quickly either is growing. Today, checks require manual shell access, ad hoc queries, and secret handling. This complexity discourages routine monitoring, leaving drift and growth unnoticed until failure.

Without intervention, the system will drift further out of sync, scale unpredictably, and crash under memory pressure. This RFC proposes a framework to restore reliability: timestamp-based drift reconciliation, lean schema configuration, zero-downtime indexing, lifecycle policies, growth monitoring, observability tooling, and operator runbooks.

## 2. Drift Detection

Drift is the divergence between MongoDB’s truth and Meilisearch’s index. It takes several forms: missing documents, stale documents, or documents incorrectly included. Preventing drift is central to reliable search.

Meilisearch does not store timestamps, so reconciliation must depend on MongoDB. The approach is timestamp-based delta capture. When reindexing, the system records the start time `T₀`. The snapshot load ingests all documents with `MeiliIndex: true` and `updatedAt <= T₀`. Once complete, the system queries MongoDB for documents with `updatedAt > T₀` and reconciles them into the new index. Documents that have been toggled off or deleted since `T₀` are explicitly removed. This ensures that the new index is consistent with MongoDB at the moment it becomes active.

Example MongoDB queries illustrate this pattern:

```javascript
// Snapshot query: load all documents eligible as of T₀
db.conversations.find({
  MeiliIndex: true,
  updatedAt: { $lte: ISODate("2025-10-02T12:00:00Z") }
})

// Delta query: capture changes since T₀
db.conversations.find({
  MeiliIndex: true,
  updatedAt: { $gt: ISODate("2025-10-02T12:00:00Z") }
})

// Identify documents toggled off since T₀
db.conversations.find({
  MeiliIndex: false,
  updatedAt: { $gt: ISODate("2025-10-02T12:00:00Z") }
})
```

Drift must also be monitored continuously. Counts provide a coarse signal:

```bash
curl -s "http://localhost:7700/indexes/conversations/stats" \
  -H "Authorization: Bearer $MEILI_KEY"
```

More robust checks sample document IDs from MongoDB and ensure they exist in Meilisearch. Strongest checks hash the searchable fields in MongoDB and compare them with what Meilisearch returns. These checks must run automatically and persist reports as immutable JSON, allowing operators to analyze drift trends over time.

## 3. Index Configuration and Schema

Meilisearch defaults to indexing every field. This is wasteful and unsustainable at scale. Only necessary fields should be searchable or filterable. For conversations, the key searchable fields are `title`, `participants`, and possibly `lastMessage`. Timestamps may be filterable but not indexed for text. For messages, `body` is the core searchable field, with `sender` and `timestamp` filterable if required.

Configuration is set via Meilisearch’s API. For example:

```bash
curl -X PATCH "http://localhost:7700/indexes/conversations/settings" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "searchableAttributes": ["title", "participants", "lastMessage"],
    "filterableAttributes": ["timestamp"]
  }'
```

Restricting fields keeps the index lean, reducing memory pressure and speeding queries. Because schema changes require full reindexing, they must be coupled with the zero-downtime strategy described below.

## 4. Zero-Downtime Indexing

Reindexing in place exposes users to disruption. To prevent this, indexing must follow a dual-index swap model.

The system creates a new index, for example `conversations_new`. At time `T₀`, it ingests all eligible documents. After ingestion, it reconciles deltas: all documents updated after `T₀` are upserted, and invalidated documents are removed. Once the new index is fully reconciled, it is validated. Validation checks counts, ID presence, and sampled content.

If validation succeeds, Meilisearch’s atomic swap API is used to replace the active index:

```bash
curl -X POST "http://localhost:7700/swap-indexes" \
  -H "Authorization: Bearer $MEILI_KEY" \
  -H "Content-Type: application/json" \
  --data '[
    { "indexes": ["conversations_new", "conversations"] }
  ]'
```

The swap is instantaneous and invisible to clients. The old index remains available for rollback. If validation fails, no swap occurs. This guarantees zero downtime, even for large reindexes.

## 5. Data Lifecycle and Retention

Indexes must be bounded. Meilisearch holds its data in memory, so unbounded growth guarantees a crash. Lifecycle policies constrain the active index without losing canonical data.

A simple retention rule might include only the last six months of data:

```javascript
db.conversations.find({
  MeiliIndex: true,
  updatedAt: { $gte: ISODate("2025-04-02T00:00:00Z") }
})
```

Older documents remain in MongoDB and can be archived elsewhere, but they are excluded from the active index. Lifecycle enforcement keeps indexes within memory budgets and ensures predictable operation.

## 6. Growth Metrics and Observability

To plan capacity and detect drift, growth must be measured systematically. MongoDB aggregations show how many documents are created daily:

```javascript
db.conversations.aggregate([
  { $match: { createdAt: { $gte: ISODate("2025-09-30T00:00:00Z") } } },
  { $group: {
      _id: { $dateToString: { format: "%Y-%m-%d", date: "$createdAt" } },
      count: { $sum: 1 }
    } }
])
```

Meilisearch provides counts and index size:

```bash
curl -s "http://localhost:7700/indexes/conversations/stats" \
  -H "Authorization: Bearer $MEILI_KEY"
```

Today, producing these metrics requires multiple tools and steps. A CLI observability tool should wrap these queries, hiding the complexity. With a single command, an operator could see growth, drift, and validation reports. These should be archived daily as immutable JSON to build a long-term record of system health.

## 7. Monitoring and Verification

Monitoring is essential for early warning. MongoDB must be checked for how many documents are eligible for indexing. Meilisearch must be checked for how many are actually indexed. Memory usage of the Meilisearch pods must be tracked continuously.

Verification routines confirm correctness. During rebuilds, validation ensures the new index is complete before swapping. In production, scheduled verification samples documents. For example, MongoDB may provide a random eligible document:

```javascript
db.conversations.aggregate([
  { $match: { MeiliIndex: true } },
  { $sample: { size: 1 } }
])
```

That ID can then be retrieved from Meilisearch to confirm presence. Any discrepancies must be logged and trigger alerts. These checks provide assurance that indexing remains reliable.

## 8. Operational Principles

Operations must be structured around clear, repeatable procedures. Reindexing must follow the dual-index pattern with validation and swap. Drift detection must be automated and archived. Rollback must be supported via old index retention. Lifecycle enforcement must run on schedule. Operators must have reliable, documented processes to execute these steps safely.

## Next Steps

Define lean schemas for conversations and messages. Implement the zero-downtime rebuild pipeline with timestamp-based delta capture. Build the observability CLI to expose drift and growth metrics. Enforce lifecycle policies to cap index size. Extend monitoring to cover MongoDB and Meilisearch with alerts. Draft and test operator runbooks for reindexing, drift remediation, and rollback. With these foundations, the system will scale predictably, resist drift, and remain stable under load.

## References

1. [Meilisearch: Indexes API](https://www.meilisearch.com/docs/reference/api/indexes)
2. [Meilisearch: Zero-downtime index deployment](https://www.meilisearch.com/blog/zero-downtime-index-deployment)
3. [Meilisearch: Asynchronous operations](https://www.meilisearch.com/docs/learn/async/asynchronous_operations)
4. [MongoDB Manual: Aggregation pipeline](https://www.mongodb.com/docs/manual/core/aggregation-pipeline/)
