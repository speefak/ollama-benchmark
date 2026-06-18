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
#   ./ollama-ctx-benchmark.sh [OPTIONS]
#
#   -h,   --help                Show this help
#   -m,   --model      MODEL    Model(s) to test (-m a = all models, -m 1-3,6-8,10 = by index)
#   -cs,  --ctx-start  VALUE    Starting context size in tokens
#   -cr,  --ctx-raise  VALUE    Increase per iteration (50% oder 1024)
#   -p,   --prompt     TEXT     Benchmark prompt
#   -l,   --loops      N        Number of iterations
#   -t,   --timeout    SEC      curl max-time in seconds
#   -e,   --export     FILE     Also save output to text file
#   -v,   --verbose             display thinking + response in terminal (also written to logfile)
#   -r,  --reload-cuda	        Reload CUDA driver"
#   -smf, --show-model-files    Show model file path"
#
# Examples:
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -cs 8192 -cr 10% -l 10
#   ./ollama-ctx-benchmark.sh -m qwen3:4b -cs 4096 -cr 1024 -p "Explain quantum physics"
#   ./ollama-ctx-benchmark.sh -m qwen3:4b llama3:8b -cr 50% -l 5 -e /tmp/bench.txt -v
#
# Requirements:
#   - ollama   curl -fsSL https://ollama.com/install.sh | sh
#   - python3  (for JSON parsing and time formatting)
#   - curl
#
# Author:      speefak
# Version:     1.9
# Created:     2025
# Last update: June 2026
#
#
# =============================================================================
# CONFIG
# =============================================================================

#PROMPT_BENCHMARK="Hi"                 # Benchmark prompt
PROMPT_BENCHMARK="How does a LargeLanguageModel work (Language:DE, max 500 words)"                 # Benchmark prompt

OLLAMA_API="http://localhost:11434"   			# Ollama REST API endpoint
MAX_TIME=300                          			# curl max-time in seconds
START_CTX=4096                        			# Starting context size in tokens
CTX_RAISE=10                          			# Increase per iteration
CTX_RAISE_MODE="percent"              			# "percent" oder "absolute"
MAX_ITER=10                           			# Number of iterations
MODELS=()               	              		# Models (empty = interactive selection)
MAX_MODEL_NAME_LENGTH=25              			# Maximum model name length in output
VERBOSE_MODE=0                        			# 1 = thinking + response im Terminal ausgeben (ins Logfile mitgeschrieben)
SEP="$(printf '%0.s─' {1..180})"			# Seperatorline lenght

DC_ROOT=$HOME/.ol-bench			      		# Working directory for logs and outputs
LOG_FILE="$DC_ROOT/$(date +%F-%H%M)_ol-bench.log"	# Log file


# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h,   --help                     Show this help"
    echo "  -m,   --model MODEL MODEL ...    Model(s) to test
                                   -m a          → all available models
                                   -m 1-3,6-8,10 → models by index (ranges + commas)"
    echo "  -cs,  --ctx-start VALUE          Starting context size in tokens (Default: $START_CTX)"
    echo "  -cr,  --ctx-raise VALUE          Increase per iteration:"
    echo "                             	        -cr 50%   → +50% per step (percentage)"
    echo "                             	        -cr 1024  → +1024 tokens per step (absolute)"
    echo "  -p,   --prompt TEXT              Benchmark prompt (Default: \"$PROMPT_BENCHMARK\")"
    echo "  -l,   --loops N                  Number of iterations (Default: $MAX_ITER)"
    echo "  -t,   --timeout SEC              Requesttimeout in seconds (Default: $MAX_TIME)" 
    echo "  -v,   --verbose                  Show thinking + response outoput and save in log"
    echo "  -rc,  --reload-cuda              Reload CUDA driver"
    echo "  -smf, --show-model-files         Show model file path"
    echo ""
    echo "Examples:"
    echo "  $0 -m qwen3:4b -cs 8192 -cr 10% -p \"Explain quantum physics\" -l 10 -t 300"
    echo "  $0 -m qwen3:4b -cs 4096 -cr 1024 -l 5 -e /tmp/bench.txt -v"
    exit 0
}

reload_cuda() {
    echo "🔁 Restarting NVIDIA/CUDA driver..."
    sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null
    sudo modprobe nvidia
    sudo modprobe nvidia_uvm
    sudo modprobe nvidia_drm
    sudo modprobe nvidia_modeset
    sudo systemctl restart nvidia-persistenced
    echo "✅ CUDA stack restarted."
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
        echo "$1" | tee -a "$LOG_FILE"
}

printf_line() {
    local formatted
    formatted=$(printf "$@")
    echo "$formatted" | tee -a "$LOG_FILE"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    FLAG="$1"
    shift
    case $FLAG in
        -h|--help)
            usage
            ;;
        -m|--model)
            # Collect all non-flag tokens after -m
            _M_ARGS=()
            while [[ $# -gt 0 && "$1" =~ ^[^-] ]]; do
                _M_ARGS+=("$1"); shift
            done
            # Check for special modes
            if [[ ${#_M_ARGS[@]} -eq 1 && "${_M_ARGS[0]}" == "a" ]]; then
                # -m a → all available models
                mapfile -t _ALL_LINES < <(ollama list | tail -n +2)
                for _line in "${_ALL_LINES[@]}"; do
                    MODELS+=("$(echo "$_line" | awk '{print $1}')")
                done
            elif [[ ${#_M_ARGS[@]} -eq 1 && "${_M_ARGS[0]}" =~ ^[0-9,\-]+$ ]]; then
                # -m 1-3,6-8,10 → index/range selection (comma-separated)
                mapfile -t _ALL_LINES < <(ollama list | tail -n +2)
                IFS=',' read -ra _SEGMENTS <<< "${_M_ARGS[0]}"
                for _seg in "${_SEGMENTS[@]}"; do
                    if [[ "$_seg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        _s="${BASH_REMATCH[1]}"; _e="${BASH_REMATCH[2]}"
                        for (( _i=_s; _i<=_e; _i++ )); do
                            _idx=$(( _i - 1 ))
                            [[ $_idx -ge 0 && $_idx -lt ${#_ALL_LINES[@]} ]] && \
                                MODELS+=("$(echo "${_ALL_LINES[$_idx]}" | awk '{print $1}')")
                        done
                    elif [[ "$_seg" =~ ^[0-9]+$ ]]; then
                        _idx=$(( _seg - 1 ))
                        [[ $_idx -ge 0 && $_idx -lt ${#_ALL_LINES[@]} ]] && \
                            MODELS+=("$(echo "${_ALL_LINES[$_idx]}" | awk '{print $1}')")
                    else
                        echo "❌ Invalid index segment: $_seg"; usage
                    fi
                done
                if [[ ${#MODELS[@]} -eq 0 ]]; then
                    echo "❌ No models matched for index selection: ${_M_ARGS[0]}"; usage
                fi
            else
                # Normal mode: model names passed directly
                MODELS+=("${_M_ARGS[@]}")
            fi
            ;;
        -cs|--ctx-start)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                START_CTX="$1"
            else
                echo "❌ Invalid value for -cs: $1"; usage
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
                echo "❌ Invalid value for -cr: $VALUE"; usage
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
                echo "❌ Invalid value for -l: $1"; usage
            fi
            shift
            ;;
        -t|--timeout)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_TIME="$1"
            else
                echo "❌ Invalid value for -t: $1"; usage
            fi
            shift
            ;;
        -v|--verbose)
            VERBOSE_MODE=1
            ;;            
       -rc|--restart-cuda)
            reload_cuda
            ;; 
      -smf|--show-model-files)
            SHOW_MODEL_FILES=true
            ;;
        *)
            echo "Unknown option: $FLAG"; usage
            ;;
    esac
done


# =============================================================================
# SCRIPT
# =============================================================================

# Check for dc_root directory
mkdir -p $DC_ROOT 2>/dev/null

# Model selection (if none specified)
if [ ${#MODELS[@]} -eq 0 ]; then
    echo "📋 Available Ollama models:"
    print_line "$SEP"
    ollama list | tail -n +2 | nl -w2 -s') '
    print_line "$SEP"

    while [ ${#MODELS[@]} -eq 0 ]; do
        echo -n "Select model(s) (z.B. 1 3 | 1-5 | 1-3,6-8,10 | a=alle): "
        read -r SELECTION
        mapfile -t FULL_LINES < <(ollama list | tail -n +2)
        MODELS=()
        # 'a' → alle Modelle
        if [[ "$SELECTION" == "a" ]]; then
            for _line in "${FULL_LINES[@]}"; do
                MODELS+=("$(echo "$_line" | awk '{print $1}')")
            done
        else
            # Komma-getrennte Segmente (Ranges + Einzelwerte) sowie Leerzeichen-getrennte Tokens
            # Normalisierung: Leerzeichen → Komma, dann Split
            NORM_SEL="${SELECTION// /,}"
            IFS=',' read -ra _SEGS <<< "$NORM_SEL"
            for sel in "${_SEGS[@]}"; do
                [[ -z "$sel" ]] && continue
                if [[ $sel =~ ^[0-9]+$ ]]; then
                    idx=$((sel-1))
                    [[ $idx -ge 0 && $idx -lt ${#FULL_LINES[@]} ]] && \
                        MODELS+=("$(echo "${FULL_LINES[$idx]}" | awk '{print $1}')")
                elif [[ $sel =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
                    for ((i=start; i<=end; i++)); do
                        idx=$((i-1))
                        [[ $idx -ge 0 && $idx -lt ${#FULL_LINES[@]} ]] && \
                            MODELS+=("$(echo "${FULL_LINES[$idx]}" | awk '{print $1}')")
                    done
                else
                    echo "⚠️  Unbekanntes Segment ignoriert: $sel"
                fi
            done
        fi
        [ ${#MODELS[@]} -eq 0 ] && echo "❌ ❌ Invalid input! Please try again."
    done
fi


# Show models and model files / option -smf
if [[ -n $SHOW_MODEL_FILES ]]; then 
   for MODEL in "${MODELS[@]}"; do
       MODEL_FILE=$(curl -s http://localhost:11434/api/show -d "{\"model\": \"$MODEL\"}" | jq -r '.modelfile' | grep '^FROM' | awk '{print $2}')
       MODEL_FILE_LIST=$(echo -e "$MODEL_FILE_LIST \n $MODEL  $MODEL_FILE")
   done
   max_len=$(echo "$MODEL_FILE_LIST" | awk '{if(length($1)>max) max=length($1)} END{print max}')
   echo "$MODEL_FILE_LIST" | awk -v width="$max_len" '{printf " %*s | %-s\n", width, $1, $2}'
   exit
fi  


# Check for context token raise mode
if [[ "$CTX_RAISE_MODE" == "percent" ]]; then
    CTX_RAISE_INFO="+${CTX_RAISE}% per iteration"
else
    CTX_RAISE_INFO="+${CTX_RAISE} Tokens per iteration"
fi

# Print value header
print_line ""
print_line "🚀 Starting Ollama Context Benchmark | $(date +%F-%H%M)"
print_line "Models      : ${MODELS[*]}"
print_line "Start ctx   : $START_CTX"
print_line "Increase    : $CTX_RAISE_INFO"
print_line "Iterations  : $MAX_ITER"
print_line "Timeout     : ${MAX_TIME}s"
print_line "Prompt      : \"$PROMPT_BENCHMARK\""
print_line "Logfile     : $LOG_FILE"
[[ "$VERBOSE_MODE" -eq 1 ]] && print_line "Verbose     : thinking + response will be displayed in terminal and logfile"
print_line ""

print_header_line() {
    printf_line "%-10s | %-${MAX_MODEL_NAME_LENGTH}s | %-8s | %-15s | %-16s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s\n" \
        " iter" "Model" "num_ctx" "  RAM  /  SIZE" "Processor" "T Dur" "L Dur" "P Dur" "Prompt N" "Prompt Rate" "Eval N" "Eval Dur" "Eval Rate"
}

# Show column header one time for non verbose output
if [[ $VERBOSE_MODE == 0 ]]; then
    print_line "$SEP"
    print_header_line
    print_line "$SEP"
fi 

# Calculate total number of runs across all models and iterations
TOTAL_RUNS=$(( ${#MODELS[@]} * MAX_ITER ))
GLOBAL_RUN=0

# Start model loop proccessing
for MODEL in "${MODELS[@]}"; do
    ctx=$START_CTX
    iter=1
    
    MODEL_SIZE=$(ollama list | grep -w "$MODEL" | awk '{printf "%3s %s\n", $3, $4}')
    MODEL_ID=$(ollama list | grep -w "$MODEL" | awk '{printf $2}')
    
    # Start model benchmarks
    while [ $iter -le $MAX_ITER ]; do
        # show column header for each verbose output
    	if [[ "$VERBOSE_MODE" -eq 1 ]]; then    
             print_line "$SEP"
             print_header_line
        fi

        ((GLOBAL_RUN++))
	echo -n "  Iteration $iter / $GLOBAL_RUN / $TOTAL_RUNS | $MODEL | ctx=$ctx | running..."

        OUTPUT=$(curl -s --max-time "${MAX_TIME}" "${OLLAMA_API}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${MODEL}\",
                \"prompt\": \"${PROMPT_BENCHMARK}\",
                \"stream\": false,
                \"options\": { \"num_ctx\": ${ctx} }
            }")

        if [ -z "$OUTPUT" ]; then
            print_line "❌ No response (timeout after ${MAX_TIME}s or connection error)"
            break
        fi

        ERROR=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if [ -n "$ERROR" ]; then
            echo -ne "\033[2K\r ❌ ollama error: $ERROR ( $MODEL )\n" | tee -a "$LOG_FILE"
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

        # get ollama ps values
        PS_LINE=$(ollama ps 2>/dev/null | grep -E "^${MODEL}\s")
        PS_RAM_SIZE=$(awk '{print $3, $4}' <<< "$PS_LINE")
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
        SAFE_MODEL=$(echo "$MODEL" | tr '/:' '__')
	
	# show benchmark results
	ITER_LABEL="${iter}/${GLOBAL_RUN}/${TOTAL_RUNS}"
        printf_line "\r%-10s | %-${MAX_MODEL_NAME_LENGTH}s | %-8s | %15s | %-16s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s\n" \
            "$ITER_LABEL" "$MODEL_SHORT" "$ctx" \
            "$PS_RAM_SIZE / $MODEL_SIZE" "$PS_PROC" \
            "$TOTAL_DUR" "$LOAD_DUR" \
            "$PROMPT_DUR" "${PROMPT_N} tok" "$PROMPT_RATE" \
            "${EVAL_N} tok"  "$EVAL_DUR"   "$EVAL_RATE"
            
            
        # verbose mode: show thinking (if available) + response, write output in logfile
        if [[ "$VERBOSE_MODE" -eq 1 ]]; then

            # output thinking separately (if available)
            if echo "$OUTPUT" | jq -e '.thinking' >/dev/null 2>&1; then
                print_line ""
                print_line "thinking:"
                echo "$OUTPUT" | jq -r '.thinking' 2>/dev/null | sed 's/\\n/\n/g' | while IFS= read -r line; do
                    print_line "$line"
                done
            fi

            # output response
            print_line ""
            print_line "response:"
            echo "$OUTPUT" | jq -r '.response' 2>/dev/null | sed 's/\\n/\n/g' | while IFS= read -r line; do
                print_line "$line"
            done
            print_line ""
        fi

	# calculate context token for next loop 
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
print_line "✅ Benchmark completed."
[[ -n "$LOG_FILE" ]] && print_line "📄 Log file saved: $LOG_FILE"


exit 0



# notice
# log filter : cat /home/speefak/.ol-bench/2026-06-18-0901_ol-bench.log | head -n 10 
#              cat /home/speefak/.ol-bench/2026-06-18-0901_ol-bench.log | grep -E "^?[[:digit:]] |^?#|^─+"

#TODO to do, check for input context via json request and input context from ollama ps







