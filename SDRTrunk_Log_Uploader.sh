#!/bin/bash

# Configuration
NODE=0 # Identifies which physical scanner recording node is sending data
REGION=0 # Identifies which geographical region / radio system the data is for
LOG_FILE_DIR="/home/user/SDRTrunk/event_logs"
STAGE_DIR="/tmp/SDRTrunk_staging"
STATE_FILE="/tmp/SDRTrunk_Log_Uploader.state"
API_URL="<your_URL>"

# ---------------------------------------------------------------------------
# AWK PROGRAM
# Field reference:
#   $1  = TIMESTAMP      -- static per event; captured once, reformatted for output
#   $2  = DURATION_MS    -- always changing; only the last (highest) value is kept
#   $3  = PROTOCOL       -- history-tracked
#   $4  = EVENT          -- history-tracked (expected static in practice)
#   $5  = FROM           -- history-tracked (known to change)
#   $6  = TO             -- history-tracked; raw value replaced with extracted talkgroup number
#   $7  = CHANNEL_NUMBER -- history-tracked
#   $8  = FREQUENCY      -- history-tracked
#   $9  = TIMESLOT       -- history-tracked
#   $10 = DETAILS        -- history-tracked (known to change)
#   $11 = EVENT_ID       -- record key; not emitted in JSON body
# ---------------------------------------------------------------------------
AWK_PROGRAM='
function escape_json(str) {
    gsub(/\\/, "\\\\", str)
    gsub(/"/, "\\\"", str)
    return str
}
{
    # FAIL-FAST FILTER: drop any event type we do not care about
    if ($4 != "Group Call" && $4 != "\"Group Call\"" &&
        $4 != "Encrypted Group Call" && $4 != "\"Encrypted Group Call\"") {
        next
    }

    # Strip wrapping quotes and carriage returns from all fields
    for (i = 1; i <= 11; i++) {
        gsub(/^"/, "", $i)
        gsub(/"$/, "", $i)
        gsub(/\r/, "", $i)
    }

    E_ID = $11
    if (!E_ID) next

    # Register event and record latest duration (last value wins)
    e_ids[E_ID] = 1
    duration[E_ID] = $2

    # Capture timestamp once on first line seen for this event
    if (!timestamp[E_ID]) {
        raw = $1
        timestamp[E_ID] = substr(raw,1,4) "-" substr(raw,6,2) "-" substr(raw,9,2) \
                          " " substr(raw,12,2) ":" substr(raw,15,2) ":" substr(raw,18,2)
    }

    # Talkgroup extraction: pull the numeric ID from inside parentheses in $6
    # e.g. "[WILDCARD] (5085)" -> "5085"
    if ($6 ~ /\([0-9]+\)/) {
        match($6, /\([0-9]+\)/)
        tg_val = substr($6, RSTART+1, RLENGTH-2)
        if (tg_val != "") dest_tg[E_ID] = tg_val
    }
    if (!dest_tg[E_ID]) dest_tg[E_ID] = "UNKNOWN"

    # History tracking for fields 3-10 (skip $1 timestamp and $2 duration)
    # For $6 (TO), store the extracted talkgroup number rather than the raw value
    for (i = 3; i <= 10; i++) {
        val = (i == 6) ? dest_tg[E_ID] : $i
        cnt = hist_cnt[E_ID, i]
        if (cnt == 0) {
            hist[E_ID, i, 0] = val
            hist_cnt[E_ID, i] = 1
        } else if (hist[E_ID, i, cnt-1] != val) {
            hist[E_ID, i, cnt] = val
            hist_cnt[E_ID, i]++
        }
    }
}
END {
    headers[3]="PROTOCOL"; headers[4]="EVENT";  headers[5]="FROM"
    headers[6]="TO";        headers[7]="CHANNEL_NUMBER"
    headers[8]="FREQUENCY"; headers[9]="TIMESLOT"; headers[10]="DETAILS"

    for (E_ID in e_ids) {
        ts = timestamp[E_ID]
        start_date = substr(ts,1,4) substr(ts,6,2) substr(ts,9,2)
        start_time = substr(ts,12,2) substr(ts,15,2) substr(ts,18,2)
        if (length(start_date) == 0) start_date = "00000000"
        if (length(start_time) == 0) start_time = "000000"

        out_file = stage "/N_" node "_R_" region "_[" dest_tg[E_ID] "]_" \
                   start_date "_" start_time ".json"

        printf "{\n" > out_file
        printf "  \"EVENT_ID\": \"%s\",\n", escape_json(E_ID) >> out_file
        printf "  \"NODE\": %d,\n", node >> out_file
        printf "  \"REGION\": %d,\n", region >> out_file
        printf "  \"TIMESTAMP\": \"%s\",\n", escape_json(ts) >> out_file
        printf "  \"DURATION_MS\": %d,\n", duration[E_ID] >> out_file

        for (i = 3; i <= 10; i++) {
            h = headers[i]
            cnt = hist_cnt[E_ID, i]
            is_last = (i == 10)

            if (cnt > 1) {
                printf "  \"%s\": [\n", h >> out_file
                for (j = 0; j < cnt; j++) {
                    printf "    \"%s\"%s\n", escape_json(hist[E_ID, i, j]), \
                           (j == cnt-1 ? "" : ",") >> out_file
                }
                printf "  ]%s\n", (is_last ? "" : ",") >> out_file
            } else {
                if (h == "FREQUENCY") {
                    printf "  \"%s\": %s%s\n", h, \
                           (hist[E_ID, i, 0] ? hist[E_ID, i, 0] : "0"), \
                           (is_last ? "" : ",") >> out_file
                } else {
                    printf "  \"%s\": \"%s\"%s\n", h, \
                           escape_json(hist[E_ID, i, 0]), \
                           (is_last ? "" : ",") >> out_file
                }
            }
        }
        printf "}\n" >> out_file
        close(out_file)
    }
}
'

# Ensure runtime directories exist
mkdir -p "$STAGE_DIR"
touch "$STATE_FILE"

# Read current state
STATE_CONTENT=$(cat "$STATE_FILE")
CURRENT_STATE_FILE="${STATE_CONTENT%%|*}"
LAST_PROCESSED_ID="${STATE_CONTENT##*|}"

# Gather and sort all available log files
AVAILABLE_FILES=($(ls "$LOG_FILE_DIR"/*.log 2>/dev/null | sort))

if [ ${#AVAILABLE_FILES[@]} -eq 0 ]; then
    echo "No log files found in $LOG_FILE_DIR"
    exit 0
fi

if [ -z "$CURRENT_STATE_FILE" ]; then
    CURRENT_STATE_FILE=$(basename "${AVAILABLE_FILES[0]}")
    LAST_PROCESSED_ID=""
fi

LATEST_ACTIVE_FILE=$(basename "${AVAILABLE_FILES[-1]}")

# -------------------------------------------------------------------------
# STAGE 1: Process Log Files in Sequence
# -------------------------------------------------------------------------
for TARGET_PATH in "${AVAILABLE_FILES[@]}"; do
    FILE_NAME=$(basename "$TARGET_PATH")

    if [[ "$FILE_NAME" < "$CURRENT_STATE_FILE" ]]; then
        continue
    fi

    echo "Processing log file: $FILE_NAME"
    START_LINE=1

    if [ "$FILE_NAME" = "$CURRENT_STATE_FILE" ] && [ -n "$LAST_PROCESSED_ID" ]; then
        # Resume from the FIRST line containing the last processed EVENT_ID
        # so that event is fully re-evaluated from its earliest available line
        FIRST_LINE_MATCH=$(grep -a -n -F "\"$LAST_PROCESSED_ID\"" "$TARGET_PATH" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
        if [ -n "$FIRST_LINE_MATCH" ]; then
            START_LINE=$FIRST_LINE_MATCH
        fi
    fi

    # Read data from START_LINE onward; scrub null bytes
    RAW_DATA=$(tail -n +"$START_LINE" "$TARGET_PATH" | tr -d '\0')
    if [ -z "$RAW_DATA" ]; then
        echo "No new entries found in $FILE_NAME."
        continue
    fi

    if [ "$FILE_NAME" = "$LATEST_ACTIVE_FILE" ]; then
        # Exclude the trailing (likely in-progress) event from this run
        LAST_LINE=$(tail -n 1 <<< "$RAW_DATA")
        TRAILING_ID=$(echo "$LAST_LINE" | awk -F',' '{print $11}' | tr -d '"\r\n')

        if [ -n "$TRAILING_ID" ]; then
            PROCESSABLE_DATA=$(echo "$RAW_DATA" | grep -v -F "\"$TRAILING_ID\"")
            LAST_PROC_LINE=$(tail -n 1 <<< "$PROCESSABLE_DATA")
            NEW_LAST_ID=$(echo "$LAST_PROC_LINE" | awk -F',' '{print $11}' | tr -d '"\r\n')
        else
            PROCESSABLE_DATA="$RAW_DATA"
            NEW_LAST_ID=""
        fi
    else
        PROCESSABLE_DATA="$RAW_DATA"
        LAST_LINE=$(tail -n 1 <<< "$RAW_DATA")
        NEW_LAST_ID=$(echo "$LAST_LINE" | awk -F',' '{print $11}' | tr -d '"\r\n')
    fi

    # -------------------------------------------------------------------------
    # STAGE 2: Parse and stage JSON files via inlined AWK program
    # -------------------------------------------------------------------------
    if [ -n "$PROCESSABLE_DATA" ]; then
        echo "$PROCESSABLE_DATA" | awk -F',' \
            -v stage="$STAGE_DIR" \
            -v node="$NODE" \
            -v region="$REGION" \
            "$AWK_PROGRAM"
    fi

    # Commit state at end of each file
    CURRENT_STATE_FILE="$FILE_NAME"
    LAST_PROCESSED_ID="$NEW_LAST_ID"
    echo "${CURRENT_STATE_FILE}|${LAST_PROCESSED_ID}" > "$STATE_FILE"
done

# -------------------------------------------------------------------------
# STAGE 3: Upload staged JSON files
# -------------------------------------------------------------------------
echo "Scanning staging queue for uploads..."
for json_file in "$STAGE_DIR"/*.json; do
    [ -e "$json_file" ] || continue

    RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d @"$json_file" "$API_URL")
    STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null)

    if [ "$STATUS" = "ok" ]; then
        rm "$json_file"
    else
        echo "Upload error for $(basename "$json_file"). Preserving in queue." >&2
    fi
done

echo "Execution batch completed successfully."
exit 0
