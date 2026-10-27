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
