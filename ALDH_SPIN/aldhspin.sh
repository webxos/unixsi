#!/usr/bin/env bash
# ==============================================================================
# ALDH SPIN – Automated Linux Diagnosis Harness (Agent Spin Edition)
# ==============================================================================
# Usage: bash aldh_spin.sh [max_cycles]
#
# Continuously diagnoses your Debian system using Ollama and outputs a JSON
# graph to ~/Desktop/sys_diagnosis_graph.json.
#
# Configuration (edit these variables):
#   MODEL_NAME           - Ollama model (e.g., qwen2.5:0.5b)
#   OUTPUT_FILE          - final graph output (default: ~/Desktop/sys_diagnosis_graph.json)
#   CPU_THRESHOLD        - CPU% above which to throttle Ollama (default: 80)
#   MAX_CYCLES           - stop after this many cycles (0 = infinite)
#   WORKSPACE_BASE       - where to create workspace (default: ~/Desktop/ALDH_Workspace)
#   OLLAMA_MAX_TIMEOUT   - max seconds for Ollama generation (0 = infinite)
#   CURL_RETRIES         - number of retries for Ollama requests (default: 3)
#   CURL_RETRY_DELAY     - initial delay in seconds between retries (default: 2)
#   AUTO_PUSH            - set to "true" to enable automatic git push
#   CLEAN_WORKSPACE      - set to "true" to delete workspace on exit (default: false)
# ==============================================================================

# --- CONFIGURATION ------------------------------------------------------------
OLLAMA_URL="http://localhost:11434/api/generate"
MODEL_NAME="qwen2.5:0.5b"
OUTPUT_FILE="${HOME}/Desktop/sys_diagnosis_graph.json"
CPU_THRESHOLD=80
MAX_CYCLES=0                        # 0 = infinite
WORKSPACE_BASE="${HOME}/Desktop/ALDH_Workspace"
OLLAMA_MAX_TIMEOUT=6000             # 0 for infinite
CURL_RETRIES=3
CURL_RETRY_DELAY=2
AUTO_PUSH="false"
CLEAN_WORKSPACE="false"             # if true, deletes workspace on exit

# --- INTERNAL VARIABLES -------------------------------------------------------
CYCLE_COUNT=0
WORKSPACE_DIR=""
LOG_FILE=""
LAST_RESPONSE="Initial system scan initialized."

# --- REQUIREMENTS -------------------------------------------------------------
# jq is mandatory – exit early if missing
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ ERROR: 'jq' is required for JSON processing. Please install it:"
    echo "   sudo apt install jq   (Debian/Ubuntu)"
    echo "   brew install jq       (macOS)"
    exit 1
fi

# curl is mandatory – exit early if missing
if ! command -v curl >/dev/null 2>&1; then
    echo "❌ ERROR: 'curl' is required for HTTP requests to Ollama."
    echo "   sudo apt install curl   (Debian/Ubuntu)"
    echo "   brew install curl       (macOS)"
    exit 1
fi

# cpulimit is optional – warn but continue
if ! command -v cpulimit >/dev/null 2>&1; then
    echo "⚠️  WARNING: 'cpulimit' not found. CPU throttling will be disabled."
    echo "   Install with: sudo apt install cpulimit   (Debian/Ubuntu)"
fi

# awk is almost always present, but we check anyway (used for float comparison)
if ! command -v awk >/dev/null 2>&1; then
    echo "❌ ERROR: 'awk' is required for arithmetic comparisons."
    echo "   sudo apt install gawk   (Debian/Ubuntu)"
    exit 1
fi

# --- CLEANUP ------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [ "$CLEAN_WORKSPACE" = "true" ] && [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ]; then
        rm -rf "$WORKSPACE_DIR"
        echo "🧹 Workspace cleaned."
    fi
    echo -e "\n🛑 ALDH SPIN stopped after $CYCLE_COUNT cycles."
    exit $exit_code
}
trap cleanup SIGINT SIGTERM

# --- CHECK OLLAMA -------------------------------------------------------------
check_ollama() {
    local payload
    payload=$(jq -n --arg model "$MODEL_NAME" '{model:$model, prompt:"Hello", stream:false}')
    local http_code response_body
    response_body=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "\n%{http_code}" 2>/dev/null)
    http_code=$(echo "$response_body" | tail -n1)
    response_body=$(echo "$response_body" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo "❌ ERROR: Ollama returned HTTP $http_code" >&2
        echo "   Check that Ollama is running and the model exists." >&2
        exit 1
    fi
    local response_text
    response_text=$(echo "$response_body" | jq -r '.response' 2>/dev/null)
    if [ -z "$response_text" ] || [ ${#response_text} -lt 1 ]; then
        echo "❌ ERROR: Ollama did not return a valid response. Model '$MODEL_NAME' not found?" >&2
        echo "   Pull the model with: ollama pull $MODEL_NAME" >&2
        exit 1
    fi
    echo "✅ Ollama ready (model: $MODEL_NAME)"
}

# --- SETUP WORKSPACE ----------------------------------------------------------
setup_workspace() {
    # Create base directory if it doesn't exist
    if [ ! -d "$WORKSPACE_BASE" ]; then
        mkdir -p "$WORKSPACE_BASE" || {
            echo "❌ ERROR: Cannot create workspace base: $WORKSPACE_BASE"
            exit 1
        }
    fi

    # Create a unique workspace directory (with retries)
    local attempts=0
    while [ $attempts -lt 3 ]; do
        GEN_HASH=$((RANDOM % 900000 + 100000))
        TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
        WORKSPACE_DIR="${WORKSPACE_BASE}/ALDH_${GEN_HASH}_${TIMESTAMP}"
        if mkdir -p "$WORKSPACE_DIR" 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    if [ ! -d "$WORKSPACE_DIR" ]; then
        echo "❌ ERROR: Failed to create unique workspace directory after 3 attempts."
        echo "   Check disk space and permissions under $WORKSPACE_BASE"
        exit 1
    fi

    LOG_FILE="$WORKSPACE_DIR/aldh.log"
    touch "$LOG_FILE" || {
        echo "❌ ERROR: Cannot create log file at $LOG_FILE"
        exit 1
    }
    echo "[$(date)] ALDH SPIN started. Model: $MODEL_NAME" >> "$LOG_FILE"
    echo "📁 Workspace: $WORKSPACE_DIR"
    echo "📄 Graph output: $OUTPUT_FILE"

    # Ensure the output file can be written (create if missing, with fallback)
    local out_dir
    out_dir=$(dirname "$OUTPUT_FILE")
    if [ ! -d "$out_dir" ]; then
        mkdir -p "$out_dir" || {
            echo "❌ ERROR: Cannot create output directory: $out_dir"
            exit 1
        }
    fi
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo '{"nodes": [{"id": "system", "label": "Debian OS", "status": "OK"}], "edges": []}' > "$OUTPUT_FILE"
    elif [ ! -w "$OUTPUT_FILE" ]; then
        echo "❌ ERROR: Output file $OUTPUT_FILE exists but is not writable."
        exit 1
    fi

    # Git initialisation
    if command -v git >/dev/null; then
        cd "$WORKSPACE_DIR" || exit 1
        git init -q
        git config user.email "aldh@spin.local"
        git config user.name "ALDH SPIN"
        echo "# ALDH SPIN Workspace" > README.md
        echo "Started: $(date)" >> README.md
        git add README.md
        git commit -q -m "Initial commit"
        echo "✅ Git repository ready"
        if [ "$AUTO_PUSH" = "true" ]; then
            if git remote get-url origin >/dev/null 2>&1; then
                echo "🔗 Remote origin already configured."
            else
                echo "⚠️  AUTO_PUSH is enabled but no remote set. Add with: git remote add origin <url>"
                AUTO_PUSH="false"
            fi
        fi
        cd - > /dev/null || exit 1
    fi
}

# --- GIT COMMIT ---------------------------------------------------------------
git_commit() {
    if ! command -v git >/dev/null; then return; fi
    cd "$WORKSPACE_DIR" || return
    # Copy the current graph into workspace for versioning
    if [ -f "$OUTPUT_FILE" ]; then
        cp "$OUTPUT_FILE" "$WORKSPACE_DIR/graph_latest.json" 2>/dev/null
    fi
    git add .
    local msg="Cycle $CYCLE_COUNT - $(date '+%H:%M:%S')"
    if git commit -q -m "$msg"; then
        echo "📦 Committed: $msg"
        if [ "$AUTO_PUSH" = "true" ] && git remote | grep -q origin; then
            git push -q origin main 2>/dev/null || git push -q origin master 2>/dev/null && echo "🚀 Pushed to remote"
        fi
    fi
    cd - > /dev/null || return
}

# --- OLLAMA REQUEST (with retries and timeout) --------------------------------
ask_ollama() {
    local sys_prompt="$1"
    local user_prompt="$2"
    local full="${sys_prompt}\n\nUser: ${user_prompt}"

    local payload
    payload=$(jq -n \
        --arg model "$MODEL_NAME" \
        --arg prompt "$full" \
        '{model: $model, prompt: $prompt, stream: false}')

    local response exit_code attempt=1 delay=$CURL_RETRY_DELAY
    while [ $attempt -le $CURL_RETRIES ]; do
        response=$(curl -s --max-time "$OLLAMA_MAX_TIMEOUT" --connect-timeout 60 \
            -X POST "$OLLAMA_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        exit_code=$?
        if [ $exit_code -eq 0 ] && [ -n "$response" ]; then
            break
        fi
        echo "⚠️  Ollama request failed (attempt $attempt/$CURL_RETRIES, exit $exit_code). Retrying in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    if [ -z "$response" ] || [ $exit_code -ne 0 ]; then
        echo "⚠️  Ollama request failed after $CURL_RETRIES attempts." >&2
        return 1
    fi

    local result
    result=$(echo "$response" | jq -r '.response' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$result" ]; then
        echo "⚠️  Failed to parse JSON response (jq error)." >&2
        echo "Raw response: $response" >> "$LOG_FILE"
        return 1
    fi
    echo "$result"
    return 0
}

# --- GATHER SYSTEM STATS ------------------------------------------------------
gather_stats() {
    local cpu_load mem_free disk_usage ollama_cpu
    cpu_load=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    mem_free=$(free -m | awk '/Mem:/ {print $4}')
    disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    ollama_cpu=$(ps -C ollama -o %cpu= | awk '{sum+=$1} END {print sum+0}')
    echo "$cpu_load $mem_free $disk_usage $ollama_cpu"
}

# --- CPU THROTTLE CHECK (uses awk for float comparison, no bc needed) ---------
check_throttle() {
    local ollama_cpu="$1"
    # Compare using awk – returns 0 (true) if ollama_cpu > CPU_THRESHOLD
    if awk -v cpu="$ollama_cpu" -v thresh="$CPU_THRESHOLD" 'BEGIN {exit !(cpu > thresh)}'; then
        echo "WARNING: Ollama CPU usage is at ${ollama_cpu}%. Throttling via agent response delay. Focus heavily on optimizing resource nodes."
        if command -v cpulimit >/dev/null; then
            local ollama_pid
            ollama_pid=$(pgrep -o ollama)
            if [ -n "$ollama_pid" ]; then
                cpulimit -p "$ollama_pid" -l 50 &
                echo "🔧 Throttled Ollama (PID $ollama_pid) to 50% CPU"
            else
                echo "⚠️  Could not find Ollama process ID to throttle."
            fi
        else
            echo "⚠️  cpulimit not installed – throttling not applied."
        fi
        return 0   # alert triggered
    else
        return 1   # no alert
    fi
}

# --- MAIN DIAGNOSTIC CYCLE ----------------------------------------------------
run_cycle() {
    ((CYCLE_COUNT++))
    echo -e "\n----------------------------------------------------------------------"
    echo "🔄 DIAGNOSTIC CYCLE #$CYCLE_COUNT"
    echo "----------------------------------------------------------------------"

    # 1. Gather stats
    read -r cpu_load mem_free disk_usage ollama_cpu <<< "$(gather_stats)"
    echo "📊 CPU Load: ${cpu_load}%, Free Mem: ${mem_free}MB, Root Disk: ${disk_usage}%, Ollama CPU: ${ollama_cpu}%"

    # 2. Determine guardrail alert
    local guardrail_alert="Status Normal."
    if check_throttle "$ollama_cpu"; then
        guardrail_alert="WARNING: Ollama CPU usage is at ${ollama_cpu}%. Throttling applied. Focus heavily on optimizing resource nodes."
    fi

    # 3. Build prompts
    SYSTEM_PROMPT="You are a silent automated Debian diagnostic widget. Analyze the metrics and the previous state. Output ONLY a valid raw JSON object matching this schema: {\"nodes\": [{\"id\": \"node_id\", \"label\": \"description\", \"status\": \"OK|WARN|CRIT\"}], \"edges\": [{\"source\": \"id\", \"target\": \"id\", \"relation\": \"description\"}]}. Do not include markdown code blocks, do not include conversational text."

    USER_PROMPT="[PREVIOUS AGENT STATE]: $LAST_RESPONSE \n[CURRENT DEBIAN METRICS]: CPU Load: $cpu_load%, Free Mem: ${mem_free}MB, Root Disk: $disk_usage%. \n[HARDWARE GUARDRAIL]: $guardrail_alert \n[TASK]: Generate the next diagnostic graph layer based on these real-time errors or statuses."

    # 4. Query Ollama
    echo "🤖 Querying Ollama..."
    local response
    response=$(ask_ollama "$SYSTEM_PROMPT" "$USER_PROMPT")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "❌ Failed to get response from Ollama. Retaining previous graph."
        return 1
    fi

    # 5. Extract JSON (robustly) – try to find a valid JSON object
    local clean_json
    clean_json=$(echo "$response" | sed -n '/{/,/}/p' | tr -d '\n' | tr -s ' ')
    if echo "$clean_json" | jq empty >/dev/null 2>&1; then
        echo "$clean_json" > "$OUTPUT_FILE"
        echo "✅ Graph updated successfully."
        # Update last state for next cycle
        LAST_RESPONSE=$(echo "$clean_json" | jq -r '.nodes[].label' | tr '\n' ' ')
        # Also save a copy in workspace for Git
        cp "$OUTPUT_FILE" "$WORKSPACE_DIR/graph_cycle_${CYCLE_COUNT}.json" 2>/dev/null
        return 0
    else
        echo "❌ Invalid JSON generated by agent. Retaining previous graph."
        echo "Raw agent response (first 200 chars): ${response:0:200}..." >> "$LOG_FILE"
        LAST_RESPONSE="Error parsing previous structural graph layer. Resetting context focus."
        return 1
    fi
}

# --- MAIN ---------------------------------------------------------------------
main() {
    # Parse optional max_cycles
    if [ -n "$1" ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
        MAX_CYCLES="$1"
        echo "🔢 Will run for $MAX_CYCLES cycles."
    fi

    check_ollama
    setup_workspace

    echo "======================================================================"
    echo "🚀 ALDH SPIN is running. Press Ctrl+C to stop."
    echo "   📂 Workspace: $WORKSPACE_DIR"
    echo "   📄 Graph output: $OUTPUT_FILE"
    echo "   ⏳ Ollama timeout: ${OLLAMA_MAX_TIMEOUT}s (0 = infinite)"
    echo "   🔁 Curl retries: $CURL_RETRIES"
    if [ "$MAX_CYCLES" -gt 0 ]; then
        echo "   🔢 Will stop after $MAX_CYCLES cycles."
    else
        echo "   🔄 Will run indefinitely."
    fi
    echo "======================================================================"

    while true; do
        if [ "$MAX_CYCLES" -gt 0 ] && [ "$CYCLE_COUNT" -ge "$MAX_CYCLES" ]; then
            echo "✅ Reached maximum cycles ($MAX_CYCLES). Exiting."
            break
        fi

        run_cycle
        git_commit
        sleep 5
    done
    cleanup
}

# --- RUN ----------------------------------------------------------------------
main "$@"
