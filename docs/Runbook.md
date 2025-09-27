# Runbook: Chatbot Indexing Metrics Collection

**Purpose**  
Collect daily/weekly/monthly metrics from MongoDB and MeiliSearch, export into CSV/Google Sheets, and calculate drift between documents flagged for indexing vs. documents actually indexed.

---

## 1. MongoDB Metrics

### 1.1. Daily message counts

```bash
mongosh <<'EOF'
use chatbot
db.messages.aggregate([
  {
    $group: {
      _id: { $dateToString: { format: "%Y-%m-%d", date: "$createdAt" } },
      count: { $sum: 1 }
    }
  },
  { $sort: { "_id": 1 } }
]).forEach(printjson)
EOF
```

➡️ Output: JSON with `{ "_id": "YYYY-MM-DD", "count": N }`.  
Use `jq` to convert to CSV:

```bash
mongosh --quiet --eval '...' | jq -r '.[] | [.["_id"], .count] | @csv'
```

---

### 1.2. Conversation counts

```bash
mongosh <<'EOF'
use chatbot
db.conversations.aggregate([
  {
    $group: {
      _id: { $dateToString: { format: "%Y-%m-%d", date: "$createdAt" } },
      count: { $sum: 1 }
    }
  },
  { $sort: { "_id": 1 } }
]).forEach(printjson)
EOF
```

➡️ Same `jq -r` trick for CSV.

---

### 1.3. Flagged for indexing

```bash
mongosh --quiet --eval '
use chatbot;
db.messages.countDocuments({ _meiliIndex: true });
'
```

---

### 1.4. First & last document timestamps

```bash
# First message
mongosh --quiet --eval '
use chatbot;
db.messages.find({}, { createdAt: 1 }).sort({ createdAt: 1 }).limit(1);
'

# Most recent message
mongosh --quiet --eval '
use chatbot;
db.messages.find({}, { createdAt: 1 }).sort({ createdAt: -1 }).limit(1);
'
```

---

## 2. MeiliSearch Metrics

### 2.1. Index statistics

```bash
curl -s http://<meili-host>:7700/indexes/messages/stats | jq
```

Useful fields:

- `.numberOfDocuments` → total docs indexed
- `.isIndexing` → true/false

Convert to CSV:

```bash
curl -s http://<meili-host>:7700/indexes/messages/stats \
| jq -r '[.numberOfDocuments, .isIndexing] | @csv'
```

---

### 2.2. Index info (last update time)

```bash
curl -s http://<meili-host>:7700/indexes/messages | jq
```

Check `.createdAt` and `.updatedAt`.

---

### 2.3. Task status

```bash
curl -s "http://<meili-host>:7700/tasks?status=failed" | jq '.results | length'
curl -s "http://<meili-host>:7700/tasks?status=succeeded" | jq '.results | length'
```

---

## 3. Cross-Checking Drift

After collecting Mongo and MeiliSearch values, compute:

```
drift_count = (mongo_flagged - meili_numberOfDocuments)
drift_pct   = (drift_count / mongo_flagged) * 100
```

➡️ This can be done in Google Sheets once the CSV is imported.

---

## 4. Export to CSV

Example: Gather all metrics into one line per day.

```bash
DATE=$(date +%F)
MONGO_TOTAL=$(mongosh --quiet --eval 'db.messages.countDocuments()')
MONGO_FLAGGED=$(mongosh --quiet --eval 'db.messages.countDocuments({ _meiliIndex: true })')
MEILI_COUNT=$(curl -s http://<meili-host>:7700/indexes/messages/stats | jq '.numberOfDocuments')

echo "$DATE,$MONGO_TOTAL,$MONGO_FLAGGED,$MEILI_COUNT" >> chatbot_metrics.csv
```

➡️ Now `chatbot_metrics.csv` grows one row per run. You can upload it into Google Sheets easily.

---

## 5. Suggested Columns in Google Sheet

| Date | Mongo Total Docs | Mongo `_meiliIndex` | Meili Indexed Docs | Drift Count | Drift % | First Doc Date | Last Doc Date | Failed Tasks | Succeeded Tasks |
| ---- | ---------------- | ------------------- | ------------------ | ----------- | ------- | -------------- | ------------- | ------------ | --------------- |

---

## 6. Frequency

- **Daily**: append one line to CSV (Section 4).
- **Weekly/Monthly**: aggregate within Mongo/Google Sheets.
- **Quarterly/Yearly**: optional roll-ups for trend analysis.

---

✅ This runbook provides a **manual but systematic pipeline**:

- Run commands → CSV → Google Sheets → charts.
- No extra coding required.
