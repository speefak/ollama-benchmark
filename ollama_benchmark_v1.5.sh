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
#   - Optional export to file and verbose JSON logging
#
# Usage:
#   ./ollama-ctx-benchmark.sh [OPTIONEN]
#
#   -m,  --model      MODEL    Modell(e) zum Testen
#   -cs, --ctx-start  VALUE    Start-Kontextgröße in Tokens
#   -cr, --ctx-raise  VALUE    Erhöhung pro Durchgang (50% oder 1024)
#   -p,  --prompt     TEXT     Prompt für den Benchmark
#   -l,  --loops      N        Anzahl der Durchgänge
#   -t,  --timeout    SEC      curl max-time in Sekunden
#   -e,  --export     FILE     Ausgabe zusätzlich in Textdatei speichern
#   -v,  --verbose             Komplette Ollama-Antwort als JSON speichern
#   -h,  --help                Zeigt diese Hilfe an
#
# Examples:
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -cs 8192 -cr 10% -l 10
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -cs 4096 -cr 1024 -p "Erkläre Quantenphysik"
#   ./ollama-ctx-benchmark.sh -m qwen3:4b llama3:8b -cr 50% -l 5 -e /tmp/bench.txt -v
#
# Requirements:
#   - ollama   curl -fsSL https://ollama.com/install.sh | sh
#   - python3  (für JSON-Parsing und Zeitformatierung)
#   - curl
#
# Author:      speefak
# Version:     1.4
# Created:     2025
# Last update: June 2026
#
# =============================================================================
# CONFIG
# =============================================================================

#PROMPT_BENCHMARK="Hi"                 # Benchmark-Prompt
PROMPT_BENCHMARK="How does a LargeLanguageModel work (Language:DE, max 500 words)"                 # Benchmark-Prompt

OLLAMA_API="http://localhost:11434"   # Ollama REST API endpoint
MAX_TIME=300                          # curl max-time in Sekunden
START_CTX=4096                        # Start-Kontextgröße in Tokens
CTX_RAISE=10                          # Erhöhung pro Durchgang
CTX_RAISE_MODE="percent"              # "percent" oder "absolute"
MAX_ITER=10                           # Anzahl der Durchgänge
MODELS=()                             # Modelle (leer = interaktive Auswahl)
MAX_MODEL_NAME_LENGTH=25              # Maximale Länge für Modellnamen in Ausgabe
EXPORT_FILE=""                        # Exportdatei für Tabellenausgabe (leer = kein Export)
VERBOSE_MODE=0                        # 1 = komplette Ollama-Antwort in /tmp/ol-bench/ speichern
VERBOSE_DIR="/tmp/ol-bench"           # Verzeichnis für Verbose-Output

# =============================================================================
# SCRIPT
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONEN]"
    echo ""
    echo "Optionen:"
    echo "  -h,  --help              Zeigt diese Hilfe an"
    echo "  -m,  --model  MODEL      Modell(e) zum Testen"
    echo "  -cs, --ctx-start VALUE   Start-Kontextgröße in Tokens (Standard: $START_CTX)"
    echo "  -cr, --ctx-raise VALUE   Erhöhung pro Durchgang:"
    echo "                             -cr 50%   → +50% pro Schritt (prozentual)"
    echo "                             -cr 1024  → +1024 Tokens pro Schritt (absolut)"
    echo "  -p,  --prompt TEXT       Prompt für den Benchmark (Standard: \"$PROMPT_BENCHMARK\")"
    echo "  -l,  --loops N           Anzahl der Durchgänge (Standard: $MAX_ITER)"
    echo "  -t,  --timeout SEC       curl max-time in Sekunden (Standard: $MAX_TIME)"
    echo "  -e,  --export FILE       Ausgabe zusätzlich in Textdatei speichern"
    echo "  -v,  --verbose           Komplette Ollama-Antwort speichern unter $VERBOSE_DIR/<model>_<ctx>.json"
    echo ""
    echo "Beispiele:"
    echo "  $0 -m qwen3:4b -cs 8192 -cr 10% -p \"Erkläre Quantenphysik\" -l 10 -t 300"
    echo "  $0 -m qwen3:4b -cs 4096 -cr 1024 -l 5 -e /tmp/bench.txt -v"
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

truncate_model() {
    local name="$1"
    if [[ ${#name} -gt $MAX_MODEL_NAME_LENGTH ]]; then
        echo "${name:0:$((MAX_MODEL_NAME_LENGTH-2))}.."
    else
        echo "$name"
    fi
}

print_line() {
    if [[ -n "$EXPORT_FILE" ]]; then
        echo "$1" | tee -a "$EXPORT_FILE"
    else
        echo "$1"
    fi
}

printf_line() {
    local formatted
    formatted=$(printf "$@")
    if [[ -n "$EXPORT_FILE" ]]; then
        echo "$formatted" | tee -a "$EXPORT_FILE"
    else
        echo "$formatted"
    fi
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
    FLAG="$1"
    shift
    case $FLAG in
        -h|--help)
            usage
            ;;
        -m|--model)
            while [[ $# -gt 0 && "$1" =~ ^[^-] ]]; do
                MODELS+=("$1"); shift
            done
            ;;
        -cs|--ctx-start)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                START_CTX="$1"
            else
                echo "❌ Ungültiger Wert für -cs: $1"; usage
            fi
            shift
            ;;
        -cr|--ctx-raise)
            VALUE="$1"
            CLEAN_VALUE="${VALUE%\%}"
            if [[ "$CLEAN_VALUE" =~ ^[0-9]+$ ]]; then
                CTX_RAISE="$CLEAN_VALUE"
                if [[ "$VALUE" =~ %$ ]]; then
                    CTX_RAISE_MODE="percent"
                else
                    CTX_RAISE_MODE="absolute"
                fi
            else
                echo "❌ Ungültiger Wert für -cr: $VALUE"; usage
            fi
            shift
            ;;
        -p|--prompt)
            PROMPT_BENCHMARK="$1"
            shift
            ;;
        -l|--loops)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITER="$1"
            else
                echo "❌ Ungültiger Wert für -l: $1"; usage
            fi
            shift
            ;;
        -t|--timeout)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_TIME="$1"
            else
                echo "❌ Ungültiger Wert für -t: $1"; usage
            fi
            shift
            ;;
        -e|--export)
            EXPORT_FILE="$1"
            shift
            ;;
        -v|--verbose)
            VERBOSE_MODE=1
            ;;
        *)
            echo "Unbekannte Option: $FLAG"; usage
            ;;
    esac
done

# Export-Datei vorbereiten
if [[ -n "$EXPORT_FILE" ]]; then
    mkdir -p "$(dirname "$EXPORT_FILE")" 2>/dev/null
    # Header mit Zeitstempel
    echo "# Ollama Context Benchmark - $(date '+%Y-%m-%d %H:%M:%S')" > "$EXPORT_FILE"
    echo "" >> "$EXPORT_FILE"
fi

# Verbose-Verzeichnis vorbereiten
if [[ "$VERBOSE_MODE" -eq 1 ]]; then
    mkdir -p "$VERBOSE_DIR"
fi

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

if [[ "$CTX_RAISE_MODE" == "percent" ]]; then
    CTX_RAISE_INFO="+${CTX_RAISE}% pro Durchgang"
else
    CTX_RAISE_INFO="+${CTX_RAISE} Tokens pro Durchgang"
fi

print_line ""
print_line "🚀 Starte Ollama Context Benchmark"
print_line "Modelle     : ${MODELS[*]}"
print_line "Start ctx   : $START_CTX"
print_line "Erhöhung    : $CTX_RAISE_INFO"
print_line "Durchgänge  : $MAX_ITER"
print_line "Timeout     : ${MAX_TIME}s"
print_line "Prompt      : \"$PROMPT_BENCHMARK\""
[[ -n "$EXPORT_FILE"  ]] && print_line "Export      : $EXPORT_FILE"
[[ "$VERBOSE_MODE" -eq 1 ]] && print_line "Verbose     : $VERBOSE_DIR/<model>_<ctx>.json"
print_line ""

SEP="$(printf '%0.s-' {1..180})"

print_header() {
    printf_line "%-2s | %-${MAX_MODEL_NAME_LENGTH}s | %-8s | %-10s | %-16s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-10s | %s\n" \
        " #" "Model" "num_ctx" \
        "Size" "Processor" \
        "Total Dur" "Load Dur" \
        "Prompt N" "Prompt Dur" "Prompt Rate" \
        "Eval N" "Eval Dur" "Eval Rate"
    print_line "$SEP"
}

print_header

for MODEL in "${MODELS[@]}"; do

    ctx=$START_CTX
    iter=1

    while [ $iter -le $MAX_ITER ]; do
        echo -n "  Durchgang $iter | $MODEL | ctx=$ctx | läuft..."

        OUTPUT=$(curl -s --max-time "${MAX_TIME}" "${OLLAMA_API}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${MODEL}\",
                \"prompt\": \"${PROMPT_BENCHMARK}\",
                \"stream\": false,
                \"options\": { \"num_ctx\": ${ctx} }
            }")

        if [ -z "$OUTPUT" ]; then
            print_line "❌ Keine Antwort (Timeout nach ${MAX_TIME}s oder Verbindungsfehler)"
            break
        fi

        ERROR=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if [ -n "$ERROR" ]; then
            print_line "❌ Ollama Fehler: $ERROR"
            break
        fi

        # Verbose: komplette JSON-Antwort speichern
	if [[ "$VERBOSE_MODE" -eq 1 ]]; then
	    SAFE_MODEL=$(echo "$MODEL" | tr '/:' '__')
	    VERBOSE_FILE="${VERBOSE_DIR}/${SAFE_MODEL}_${ctx}.txt"
	    {
		# Bestimmte Felder in gewünschter Reihenfolge (ohne thinking und response)
		echo "$OUTPUT" | jq -r '
		    . as $o
		    | ["model", "created_at", "done", "done_reason", "total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration"] as $keys
		    | $keys[] as $k
		    | select($o[$k] != null)
		    | "\($k): \($o[$k])"
		' 2>/dev/null

		echo
		echo "context: ${ctx}"
		echo "prompt: $PROMPT_BENCHMARK"

		# thinking separat (wenn vorhanden)
		if echo "$OUTPUT" | jq -e '.thinking' >/dev/null 2>&1; then
		    echo
		    echo "thinking:"
		    echo "$OUTPUT" | jq -r '.thinking' 2>/dev/null | sed 's/\\n/\n/g'
		fi

		# response mit Leerzeile davor
		echo
		echo "response:"
		echo "$OUTPUT" | jq -r '.response' 2>/dev/null | sed 's/\\n/\n/g'
	    } > "$VERBOSE_FILE"
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

        # ollama ps Werte auslesen
        PS_LINE=$(ollama ps 2>/dev/null | grep -E "^${MODEL}\s")
        PS_SIZE=$(awk '{print $3, $4}' <<< "$PS_LINE")
        PS_PROC=$(awk '{
            for(i=1;i<=NF;i++) {
                if ($i ~ /^[0-9]+%/) {
                    val=$i
                    if ($(i+1) ~ /^(GPU|CPU)/) val=val" "$(i+1)
                    print val
                    exit
                }
            }
        }' <<< "$PS_LINE")

        MODEL_SHORT=$(truncate_model "$MODEL")

        printf_line "\r%2s | %-${MAX_MODEL_NAME_LENGTH}s | %-8s | %-10s | %-16s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-10s | %s\n" \
            "$iter" "$MODEL_SHORT" "$ctx" \
            "$PS_SIZE" "$PS_PROC" \
            "$TOTAL_DUR" "$LOAD_DUR" \
            "${PROMPT_N} tok" "$PROMPT_DUR" "$PROMPT_RATE" \
            "${EVAL_N} tok"  "$EVAL_DUR"   "$EVAL_RATE"

        if [[ "$CTX_RAISE_MODE" == "percent" ]]; then
            ctx=$(awk "BEGIN {print int($ctx * (1 + $CTX_RAISE/100) + 0.5)}")
        else
            ctx=$(( ctx + CTX_RAISE ))
        fi

        ((iter++))
        sleep 2.5
    done

done

print_line "$SEP"
print_line "✅ Benchmark abgeschlossen."
[[ -n "$EXPORT_FILE"  ]] && echo "📄 Export gespeichert: $EXPORT_FILE"
[[ "$VERBOSE_MODE" -eq 1 ]] && echo "📁 Verbose-Logs:      $VERBOSE_DIR/"
