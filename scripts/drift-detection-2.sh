#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-/home/eamonn/meili_drift}"
mkdir -p "$HOST_OUTPUT_DIR"

MONGO_CONTAINER="${MONGO_CONTAINER:-chat-mongodb}"
MONGO_DB="${MONGO_DB:-LibreChat}"
MEILI_URL="${MEILI_URL:-http://localhost:7700}"
MEILI_MASTER_KEY="${MEILI_MASTER_KEY:?Set MEILI_MASTER_KEY}"

# Output files
MONGO_MESSAGES_FILE="$HOST_OUTPUT_DIR/mongo_messages_ids.txt"
MEILI_MESSAGES_FILE="$HOST_OUTPUT_DIR/meili_messages_ids.txt"
MONGO_CONVOS_FILE="$HOST_OUTPUT_DIR/mongo_convos_ids.txt"
MEILI_CONVOS_FILE="$HOST_OUTPUT_DIR/meili_convos_ids.txt"
DRIFT_FILE="$HOST_OUTPUT_DIR/drift.txt"

echo "Output directory on host: $HOST_OUTPUT_DIR"

# -------------------------------
# Fetch MongoDB messages
# -------------------------------
echo "Fetching MongoDB messages (last 6 months, _meiliIndex: true)..."
docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet --eval '
  const sixMonthsAgo = new Date();
  sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
  db.messages.find({ _meiliIndex: true, createdAt: { $gte: sixMonthsAgo } }, { messageId: 1 })
    .forEach(doc => print(doc.messageId));
' > "$MONGO_MESSAGES_FILE"
echo "MongoDB messages exported: $(wc -l < "$MONGO_MESSAGES_FILE")"

# -------------------------------
# Fetch MongoDB conversations
# -------------------------------
echo "Fetching MongoDB conversations (last 6 months, _meiliIndex: true)..."
docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet --eval '
  const sixMonthsAgo = new Date();
  sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
  db.conversations.find({ _meiliIndex: true, createdAt: { $gte: sixMonthsAgo } }, { conversationId: 1 })
    .forEach(doc => print(doc.conversationId));
' > "$MONGO_CONVOS_FILE"
echo "MongoDB conversations exported: $(wc -l < "$MONGO_CONVOS_FILE")"

# -------------------------------
# Helper: check primary key existence in Meilisearch
# -------------------------------
check_meili_exists() {
  local index="$1"
  local id="$2"
  curl -sSL -H "Authorization: Bearer $MEILI_MASTER_KEY" \
       "$MEILI_URL/indexes/$index/documents/$id"
}

# -------------------------------
# Fetch Meilisearch messages by primary key
# -------------------------------
echo "Checking Meilisearch messages..."
> "$MEILI_MESSAGES_FILE"
while read -r ID; do
  RESULT=$(check_meili_exists "messages" "$ID")
  if [[ "$RESULT" != "null" ]]; then
    echo "$ID" >> "$MEILI_MESSAGES_FILE"
  fi
done < "$MONGO_MESSAGES_FILE"
echo "Meilisearch messages exported: $(wc -l < "$MEILI_MESSAGES_FILE")"

# -------------------------------
# Fetch Meilisearch conversations by primary key
# -------------------------------
echo "Checking Meilisearch conversations..."
> "$MEILI_CONVOS_FILE"
while read -r ID; do
  RESULT=$(check_meili_exists "convos" "$ID")
  if [[ "$RESULT" != "null" ]]; then
    echo "$ID" >> "$MEILI_CONVOS_FILE"
  fi
done < "$MONGO_CONVOS_FILE"
echo "Meilisearch conversations exported: $(wc -l < "$MEILI_CONVOS_FILE")"

# -------------------------------
# Detect drift
# -------------------------------
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

# -------------------------------
# Show drifted documents summary
# -------------------------------
read -rp "Show summary of drifted documents? (y/N): " SHOW_DETAILS
if [[ "$SHOW_DETAILS" =~ ^[Yy]$ ]]; then
  while read -r ID; do
    # Try fetching as message first
    MSG=$(docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet \
      --eval "db.messages.findOne({ messageId: '$ID' }, { messageId:1, conversationId:1, text:1 })")
    if [ "$MSG" != "null" ]; then
      echo "Message drift: $MSG"
    else
      # Fetch as conversation
      CONVO=$(docker exec -i "$MONGO_CONTAINER" mongosh "$MONGO_DB" --quiet \
        --eval "db.conversations.findOne({ conversationId: '$ID' }, { conversationId:1, title:1, messages:1 })")
      echo "Conversation drift: $CONVO"
    fi
  done < "$DRIFT_FILE"
fi

echo "Drift detection complete."
