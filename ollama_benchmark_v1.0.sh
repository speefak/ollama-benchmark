#!/usr/bin/env bash
# =============================================================================
# Ollama Context Benchmark Script
# =============================================================================
#
# Benchmarks Ollama models across increasing context window sizes.
# Measures load time, prompt eval rate, and generation speed per context step.
#
# Features:
#   - Iteratively increases num_ctx per run and passes it via REST API
#   - Displays all timing metrics: total, load, prompt, eval durations & rates
#   - Supports multiple models in one run
#   - Configurable prompt, loop count, step size, and curl timeout
#
# Usage:
#   ./ollama-ctx-benchmark.sh [OPTIONEN]
#
#   -m, --model   MODEL    Modell(e) zum Testen
#   -c, --ctx     VALUE    Start-Kontext (z.B. 8192) oder Schrittgröße (z.B. 50 / 50%)
#   -p, --prompt  TEXT     Prompt für den Benchmark (Standard: siehe Config)
#   -l, --loops   N        Anzahl der Durchgänge (Standard: siehe Config)
#   -t, --timeout SEC      curl max-time in Sekunden (Standard: siehe Config)
#   -h, --help             Zeigt diese Hilfe an
#
# Examples:
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -c 8192 -l 10
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -c 50% -p "Erkläre Quantenphysik"
#   ./ollama-ctx-benchmark.sh -m qwen3:4b llama3:8b -c 50 -l 5 -t 300
#
# Requirements:
#   - ollama   curl -fsSL https://ollama.com/install.sh | sh
#   - python3  (für JSON-Parsing und Zeitformatierung)
#   - curl
#
# Colors (gum foreground codes):
#   Common 256-color references:
#     1  = red
#     2  = green
#     3  = yellow
#     4  = blue
#     6  = cyan
#   220  = gold/orange-yellow
#
# Author:      speefak
# Version:     1.0
# Created:     2025
# Last update: June 2026
#
# =============================================================================
# CONFIG
# =============================================================================

OLLAMA_API="http://localhost:11434"   # Ollama REST API endpoint
MAX_TIME=180                          # curl max-time in Sekunden
START_CTX=4096                        # Start-Kontextgröße in Tokens
CTX_RAISE=10                          # Prozentuale Erhöhung pro Durchgang
MAX_ITER=10                           # Anzahl der Durchgänge
PROMPT_BENCHMARK="hi"                 # Benchmark-Prompt
MODELS=()                             # Modelle (leer = interaktive Auswahl)

# =============================================================================
# SCRIPT
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONEN]"
    echo ""
    echo "Optionen:"
    echo "  -h, --help              Zeigt diese Hilfe an"
    echo "  -m, --model MODEL       Modell(e) zum Testen"
    echo "  -c, --ctx VALUE         Start-Kontext oder Erhöhung:"
    echo "                            -c 8192      → Start bei 8192 Tokens"
    echo "                            -c xx%       → +xx% pro Schritt"
    echo "  -p, --prompt TEXT       Prompt für den Benchmark (Standard: \"$PROMPT_BENCHMARK\")"
    echo "  -l, --loops N           Anzahl der Durchgänge (Standard: $MAX_ITER)"
    echo "  -t, --timeout SEC       curl max-time in Sekunden (Standard: $MAX_TIME)"
    echo ""
    echo "Beispiele:"
    echo "  $0 -m qwen3:4b -c 8192 -p \"Erkläre Quantenphysik\" -l 10 -t 300"
    echo "  $0 -m qwen3:4b -c 50%"
    exit 0
}

parse_ns() {
    python3 -c "
v=$1
if v < 1_000_000:
    print(f'{v/1000:.0f}µs')
elif v < 1_000_000_000:
    print(f'{v/1_000_000:.0f}ms')
else:
    print(f'{v/1_000_000_000:.2f}s')
" 2>/dev/null || echo "N/A"
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -m|--model)
            shift
            while [[ $# -gt 0 && ! $1 =~ ^- ]]; do
                MODELS+=("$1"); shift
            done
            continue ;;
        -c|--ctx)
            shift
            VALUE="$1"
            CLEAN_VALUE="${VALUE%\%}"
            if [[ "$VALUE" =~ %$ ]] || [[ "$CLEAN_VALUE" =~ ^[0-9]+$ && $CLEAN_VALUE -le 200 ]]; then
                CTX_RAISE="$CLEAN_VALUE"
            elif [[ "$CLEAN_VALUE" =~ ^[0-9]+$ ]]; then
                START_CTX="$CLEAN_VALUE"
            else
                echo "❌ Ungültiger Wert für -c: $VALUE"; usage
            fi
            shift; continue ;;
        -p|--prompt)
            shift; PROMPT_BENCHMARK="$1"; shift; continue ;;
        -l|--loops)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITER="$1"
            else
                echo "❌ Ungültiger Wert für -l: $1"; usage
            fi
            shift; continue ;;
        -t|--timeout)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_TIME="$1"
            else
                echo "❌ Ungültiger Wert für -t: $1"; usage
            fi
            shift; continue ;;
        *)
            echo "Unbekannte Option: $1"; usage ;;
    esac
    shift
done

# Modellauswahl (falls keine angegeben)
if [ ${#MODELS[@]} -eq 0 ]; then
    echo "📋 Verfügbare Ollama Modelle:"
    echo "========================================================================================"
    ollama list | tail -n +2 | nl -w2 -s') '
    echo "========================================================================================"

    while [ ${#MODELS[@]} -eq 0 ]; do
        echo -n "Wähle Modell(e) (z.B. 1 3 oder 1-5): "
        read -r SELECTION
        mapfile -t FULL_LINES < <(ollama list | tail -n +2)
        MODELS=()
        for sel in $SELECTION; do
            if [[ $sel =~ ^[0-9]+$ ]]; then
                idx=$((sel-1))
                [[ $idx -ge 0 && $idx -lt ${#FULL_LINES[@]} ]] && \
                    MODELS+=("$(echo "${FULL_LINES[$idx]}" | awk '{print $1}')")
            elif [[ $sel =~ ^[0-9]+-[0-9]+$ ]]; then
                start=$(echo $sel | cut -d- -f1)
                end=$(echo $sel | cut -d- -f2)
                for ((i=start; i<=end; i++)); do
                    idx=$((i-1))
                    [[ $idx -ge 0 && $idx -lt ${#FULL_LINES[@]} ]] && \
                        MODELS+=("$(echo "${FULL_LINES[$idx]}" | awk '{print $1}')")
                done
            fi
        done
        [ ${#MODELS[@]} -eq 0 ] && echo "❌ Ungültige Eingabe! Bitte erneut versuchen."
    done
fi

echo ""
echo "🚀 Starte Ollama Context Benchmark"
echo "Modelle     : ${MODELS[*]}"
echo "Start ctx   : $START_CTX"
echo "Erhöhung    : +${CTX_RAISE}% pro Durchgang"
echo "Durchgänge  : $MAX_ITER"
echo "Timeout     : ${MAX_TIME}s"
echo "Prompt      : \"$PROMPT_BENCHMARK\""
echo ""

SEP="$(printf '%0.s-' {1..180})"

print_header() {
    printf "%-10s | %-25s | %-8s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-10s | %s\n" \
        "Durchgang" "Model" "num_ctx" \
        "Total Dur" "Load Dur" \
        "Prompt N" "Prompt Dur" "Prompt Rate" \
        "Eval N" "Eval Dur" "Eval Rate"
    echo "$SEP"
}

for MODEL in "${MODELS[@]}"; do
    echo "=== Modell: $MODEL ==="
    print_header

    ctx=$START_CTX
    iter=1

    while [ $iter -le $MAX_ITER ]; do
        echo -n "  Durchgang $iter | ctx=$ctx | läuft..."

        OUTPUT=$(curl -s --max-time "${MAX_TIME}" "${OLLAMA_API}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${MODEL}\",
                \"prompt\": \"${PROMPT_BENCHMARK}\",
                \"stream\": false,
                \"options\": { \"num_ctx\": ${ctx} }
            }")

        if [ -z "$OUTPUT" ]; then
            echo -e "\r❌ Keine Antwort (Timeout nach ${MAX_TIME}s oder Verbindungsfehler)"
            break
        fi

        ERROR=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if [ -n "$ERROR" ]; then
            echo -e "\r❌ Ollama Fehler: $ERROR"
            break
        fi

        TOTAL_NS=$(echo "$OUTPUT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_duration',0))")
        LOAD_NS=$(echo "$OUTPUT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('load_duration',0))")
        PROMPT_N=$(echo "$OUTPUT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_count',0))")
        PROMPT_NS=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_duration',1))")
        EVAL_N=$(echo "$OUTPUT"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))")
        EVAL_NS=$(echo "$OUTPUT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_duration',1))")

        TOTAL_DUR=$(parse_ns  "$TOTAL_NS")
        LOAD_DUR=$(parse_ns   "$LOAD_NS")
        PROMPT_DUR=$(parse_ns "$PROMPT_NS")
        EVAL_DUR=$(parse_ns   "$EVAL_NS")

        PROMPT_RATE=$(python3 -c "print(f'{${PROMPT_N}/(${PROMPT_NS}/1e9):.2f} t/s')" 2>/dev/null || echo "N/A")
        EVAL_RATE=$(python3   -c "print(f'{${EVAL_N}/(${EVAL_NS}/1e9):.2f} t/s')"    2>/dev/null || echo "N/A")

        printf "\r%-10s | %-25s | %-8s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-10s | %s\n" \
            "$iter" "$MODEL" "$ctx" \
            "$TOTAL_DUR" "$LOAD_DUR" \
            "${PROMPT_N} tok" "$PROMPT_DUR" "$PROMPT_RATE" \
            "${EVAL_N} tok"  "$EVAL_DUR"   "$EVAL_RATE"

        ctx=$(awk "BEGIN {print int($ctx * (1 + $CTX_RAISE/100) + 0.5)}")
        ((iter++))
        sleep 2.5
    done

    echo "$SEP"
    echo ""
done

echo "✅ Benchmark abgeschlossen."
