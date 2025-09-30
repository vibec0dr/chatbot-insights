#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------
# Configuration
# -----------------------------------------
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-/home/eamonn/meili_drift}"
mkdir -p "$HOST_OUTPUT_DIR"

MONGO_CONTAINER="${MONGO_CONTAINER:-chat-mongodb}"
MONGO_DB="${MONGO_DB:-LibreChat}"
MEILI_URL="${MEILI_URL:-http://localhost:7700}"
MEILI_MASTER_KEY="${MEILI_MASTER_KEY:?Set MEILI_MASTER_KEY}"
LIMIT=10000

MONGO_MESSAGES_FILE="$HOST_OUTPUT_DIR/mongo_messages_ids.txt"
MEILI_MESSAGES_FILE="$HOST_OUTPUT_DIR/meili_messages_ids.txt"
MONGO_CONVOS_FILE="$HOST_OUTPUT_DIR/mongo_convos_ids.txt"
MEILI_CONVOS_FILE="$HOST_OUTPUT_DIR/meili_convos_ids.txt"
DRIFT_FILE="$HOST_OUTPUT_DIR/drift.txt"

echo "Output directory on host: $HOST_OUTPUT_DIR"

# -----------------------------------------
# Fetch MongoDB messages/conversations
# -----------------------------------------
echo "Fetching MongoDB messages (last 6 months, _meiliIndex: true)..."
docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet --eval '
  const sixMonthsAgo = new Date();
  sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
  db.messages.find({
    _meiliIndex: true,
    createdAt: { $gte: sixMonthsAgo }
  }, { messageId: 1 }).forEach(doc => print(doc.messageId));
' > "$MONGO_MESSAGES_FILE"
echo "MongoDB messages exported: $(wc -l < "$MONGO_MESSAGES_FILE")"

echo "Fetching MongoDB conversations (last 6 months, _meiliIndex: true)..."
docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet --eval '
  const sixMonthsAgo = new Date();
  sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
  db.conversations.find({
    _meiliIndex: true,
    createdAt: { $gte: sixMonthsAgo }
  }, { conversationId: 1 }).forEach(doc => print(doc.conversationId));
' > "$MONGO_CONVOS_FILE"
echo "MongoDB conversations exported: $(wc -l < "$MONGO_CONVOS_FILE")"

# -----------------------------------------
# Helper: Fetch Meilisearch IDs
# -----------------------------------------
fetch_meili_ids() {
  local index="$1"
  local id_field="$2"
  local out_file="$3"

  echo "Fetching Meilisearch $index..."
  TOTAL=$(curl -sSL -H "Authorization: Bearer $MEILI_MASTER_KEY" \
    "$MEILI_URL/indexes/$index/stats" | jq -r '.numberOfDocuments // 0')
  echo "Total Meili $index documents: $TOTAL"

  OFFSET=0
  > "$out_file"

  while [ "$OFFSET" -lt "$TOTAL" ]; do
    echo "Fetching $index documents $((OFFSET + 1)) to $((OFFSET + LIMIT))..."
    curl -sSL -H "Authorization: Bearer $MEILI_MASTER_KEY" \
      "$MEILI_URL/indexes/$index/documents?limit=$LIMIT&offset=$OFFSET&fields=$id_field" | \
      jq -r ".results[].${id_field}" >> "$out_file"
    OFFSET=$((OFFSET + LIMIT))
  done

  echo "Meilisearch $index exported: $(wc -l < "$out_file")"
}

# Fetch messages & conversations
fetch_meili_ids "messages" "messageId" "$MEILI_MESSAGES_FILE"
fetch_meili_ids "conversations" "conversationId" "$MEILI_CONVOS_FILE"

# -----------------------------------------
# Detect drift
# -----------------------------------------
echo "Detecting drift for messages..."
sort "$MONGO_MESSAGES_FILE" > "$HOST_OUTPUT_DIR/mongo_messages_sorted.txt"
sort "$MEILI_MESSAGES_FILE" > "$HOST_OUTPUT_DIR/meili_messages_sorted.txt"
comm -23 "$HOST_OUTPUT_DIR/mongo_messages_sorted.txt" "$HOST_OUTPUT_DIR/meili_messages_sorted.txt" > "$DRIFT_FILE"

echo "Detecting drift for conversations..."
sort "$MONGO_CONVOS_FILE" > "$HOST_OUTPUT_DIR/mongo_convos_sorted.txt"
sort "$MEILI_CONVOS_FILE" > "$HOST_OUTPUT_DIR/meili_convos_sorted.txt"
comm -23 "$HOST_OUTPUT_DIR/mongo_convos_sorted.txt" "$HOST_OUTPUT_DIR/meili_convos_sorted.txt" >> "$DRIFT_FILE"

echo "Drift detected: $(wc -l < "$DRIFT_FILE") documents"
echo "Drift file: $DRIFT_FILE"

# -----------------------------------------
# Optional: Show drifted documents
# -----------------------------------------
read -rp "Show details for drifted documents? (y/N): " SHOW_DETAILS
if [[ "$SHOW_DETAILS" =~ ^[Yy]$ ]]; then
  while read -r ID; do
    if grep -q "$ID" "$MONGO_MESSAGES_FILE"; then
      # It's a message
      docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet \
        --eval "printjson(db.messages.findOne({ messageId: '$ID' }))"
    else
      # It's a conversation
      docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet \
        --eval "db.conversations.findOne({ conversationId: '$ID' }, {conversationId:1, title:1, messages:1})"
    fi
  done < "$DRIFT_FILE"
fi


echo "Drift detection complete."
