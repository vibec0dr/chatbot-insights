#!/usr/bin/env bash
set -euo pipefail

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "❌ Script failed with exit code $exit_code" >&2
    else
        echo "✅ Script finished successfully"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

check_meili() {
    local index="$1"
    local id="$2"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $MEILI_MASTER_KEY" \
        "$MEILI_URL/indexes/$index/documents/$id")

    if [[ "$status" -eq 200 ]]; then
        return 0
    else
        return 1
    fi
}

main() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 <start-time> <end-time>"
        exit 1
    fi

    local start_time end_time
    start_time=$(date -u -d "$1" +"%Y-%m-%dT%H:%M:%SZ")
    end_time=$(date -u -d "$2" +"%Y-%m-%dT%H:%M:%SZ")

    echo "Checking for missing documents between $start_time and $end_time"

    local temp_dir="$HOME/tmp/meili-reports"
    mkdir -p "$temp_dir"

    local messages_file="$temp_dir/mongo_messages.txt"
    local convos_file="$temp_dir/mongo_convos.txt"
    local report_file="$temp_dir/report.csv"

    ./ric-scripts/mongo-connect.sh <<EOF > "$messages_file"
use LibreChat;

db.messages.find({
    createdAt: { \$gte: ISODate("$start_time"), \$lt: ISODate("$end_time") }
}, { messageId: 1 }).forEach(doc => print(doc.messageId));

db.conversations.find({
    createdAt: { \$gte: ISODate("$start_time"), \$lt: ISODate("$end_time") }
}, { conversationId: 1 }).forEach(doc => print(doc.conversationId));
EOF

    echo "start_time,end_time,type,id" > "$report_file"

    while read -r id; do
        if ! check_meili "messages" "$id"; then
            echo "$start_time,$end_time,message,$id" >> "$report_file"
        fi
    done < "$messages_file"

    while read -r id; do
        if ! check_meili "conversations" "$id"; then
            echo "$start_time,$end_time,conversation,$id" >> "$report_file"
        fi
    done < "$convos_file"

    echo "Report complete: $report_file"
}

main "$@"
