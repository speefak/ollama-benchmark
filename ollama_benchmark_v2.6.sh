#!/usr/bin/env bash
# ===========================================================================================================================
# Ollama Context Benchmark Script
# ===========================================================================================================================
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
#   -f,   --fast                Fast CPU/GPU load benchmark
#   -p,   --prompt     TEXT     Benchmark prompt
#   -l,   --loops      N        Number of iterations
#   -t,   --timeout    SEC      curl max-time in seconds
#   -e,   --export     FILE     Also save output to text file
#   -v,   --verbose             display thinking + response in terminal (also written to logfile)
#   -r,  --reload-cuda	        Reload CUDA driver"
#   -smi, --show-model-info     Show model information"
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
# Version:     2.6
# Created:     2026
# Last update: June 2026
#
#
# ===========================================================================================================================
# CONFIG
# ===========================================================================================================================

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
SEP="$(printf '%0.s─' {1..199})"			# Seperatorline lenght

DC_ROOT=$HOME/.ol-bench			      		# Working directory for logs and outputs
LOG_FILE="$DC_ROOT/$(date +%F-%H%M)_ol-bench.log"	# Log file

OLLAMA_MODEL_UNLOAD_DELAY=3
SHOW_CPU_GPU_LOAD_DELAY_DELAY=5

# ===========================================================================================================================
# FUNCTIONS
# ===========================================================================================================================

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
    echo "  -f,   --fast SEC                 Fast CPU/GPU load benchmark (Default: 10)"
    echo "  -p,   --prompt TEXT              Benchmark prompt (Default: \"$PROMPT_BENCHMARK\")"
    echo "  -l,   --loops N                  Number of iterations (Default: $MAX_ITER)"
    echo "  -t,   --timeout SEC              Requesttimeout in seconds (Default: $MAX_TIME)" 
    echo "  -v,   --verbose                  Show thinking + response outoput and save in log"
    echo "  -rc,  --reload-cuda              Reload CUDA driver"
    echo "  -smi, --show-model-info          Show model information"
    echo ""
    echo "Examples:"
    echo "  $0 -m qwen3:4b -cs 8192 -cr 10% -p \"Explain quantum physics\" -l 10 -t 300"
    echo "  $0 -m qwen3:4b -cs 4096 -cr 1024 -l 5 -e /tmp/bench.txt -v"
    exit 0
}
#----------------------------------------------------------------------------------------------------------------------------

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
#----------------------------------------------------------------------------------------------------------------------------

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
#----------------------------------------------------------------------------------------------------------------------------

truncate_model() {
    local name="$1"
    if [[ ${#name} -gt $MAX_MODEL_NAME_LENGTH ]]; then
        echo "${name:0:$((MAX_MODEL_NAME_LENGTH-2))}.."
    else
        echo "$name"
    fi
}
#----------------------------------------------------------------------------------------------------------------------------

print_line() {
        echo "$1" | tee -a "$LOG_FILE"
}
#----------------------------------------------------------------------------------------------------------------------------

printf_line() {
    local formatted
    formatted=$(printf "$@")
    echo "$formatted" | tee -a "$LOG_FILE"
}
#----------------------------------------------------------------------------------------------------------------------------

get_ollama_api_model_list() {
    SORT_COL=1

    while getopts "s:" opt; do
        case $opt in
            s) SORT_COL="$OPTARG" ;;
        esac
    done

    printf -- '%.0s-' {1..140}
    echo

    curl -s http://localhost:11434/api/tags | jq -r '.models[] | [.name,.size,.details.parameter_size] | @tsv' |
    while IFS=$'\t' read -r MODEL SIZE PARAMS; do

        MODEL_PATH=$(curl -s http://localhost:11434/api/show \
            -d "{\"model\":\"$MODEL\"}" |
            jq -r '.modelfile' |
            grep '^FROM' |
            awk '{print $2}')

        printf "%s\t%s\t%s\t%s\n" \
            "$MODEL" \
            "$SIZE" \
            "$PARAMS" \
            "$MODEL_PATH"

    done |  sort -t $'\t' -k"$SORT_COL","$SORT_COL" -n | awk -F'\t' '
        {
            printf "%-72s | %-10s | %-10s | %s\n", $1, $2, $3, $4
        }
    '
}
#----------------------------------------------------------------------------------------------------------------------------

print_ollama_api_model_list (){
    get_ollama_api_model_list -s${SHOW_MODEL_FILES} | tail -n +2 | awk '
    function trim(s) {
        gsub(/^ +| +$/, "", s)
        return s
    }

    function human(v) {
        if (v >= 1073741824)
            return sprintf("%.2f GB", v/1073741824)
        else if (v >= 1048576)
            return sprintf("%.2f MB", v/1048576)
        else if (v >= 1024)
            return sprintf("%.2f KB", v/1024)
        else
            return v " B"
    }

    {
        model[NR]=trim($1)

        rawsize=trim($3)
        size_bytes[NR]=rawsize + 0
        size[NR]=human(size_bytes[NR])

        param[NR]=trim($5)
        path[NR]=trim($7)

        if (length(model[NR]) > w1) w1=length(model[NR])
        if (length(size[NR]) > w2) w2=length(size[NR])
        if (length(param[NR]) > w3) w3=length(param[NR])
        if (length(path[NR]) > w4) w4=length(path[NR])
    }

    END {
        printf "%-*s | %*s | %*s | %s\n",
            w1, "MODEL",
            w2, "SIZE",
            w3, "PARAM",
            "PATH"

        total = w1 + w2 + w3 + w4 + 3*3
        line = ""
        for (i = 1; i <= total; i++) line = line "─"
        printf "%s\n", line

        for (i=1; i<=NR; i++) {
            printf "%-*s | %*s | %*s | %s\n",
                w1, model[i],
                w2, size[i],
                w3, param[i],
                path[i]
        }
        printf "%s\n", line
    }'
}

# ===========================================================================================================================
# ARGUMENT PARSING
# ===========================================================================================================================

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
      -smi|--show-model-files)
            SHOW_MODEL_FILES="$1"
            shift
            print_ollama_api_model_list
            exit
            ;;       
        -f|--fast)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                SHOW_CPU_GPU_LOAD_DELAY="${1:-5}"
            else
                SHOW_CPU_GPU_LOAD_DELAY=true
            fi
            shift
            ;;
        *)
            echo "Unknown option: $FLAG"; usage
            ;;
    esac
done

# ===========================================================================================================================
# SCRIPT
# ===========================================================================================================================

# Get hardwareinfo
GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader)
GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader)
CPU_MODEL=$(lscpu | grep "Model name" | awk -F': ' '{print $2}'| sed 's/^[[:space:]]*//')
CPU_RAM=$(awk '/^MemTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)

#----------------------------------------------------------------------------------------------------------------------------

# Check for dc_root directory
mkdir -p $DC_ROOT 2>/dev/null

#----------------------------------------------------------------------------------------------------------------------------

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

#----------------------------------------------------------------------------------------------------------------------------

# Check for context token raise mode
if [[ "$CTX_RAISE_MODE" == "percent" ]]; then
    CTX_RAISE_INFO="+${CTX_RAISE}% per iteration"
else
    CTX_RAISE_INFO="+${CTX_RAISE} Tokens per iteration"
fi

#----------------------------------------------------------------------------------------------------------------------------

# Print value header
print_line ""
print_line " GPU (VRAM)  : ${GPU_MODEL} (${GPU_VRAM})"
print_line " CPU (RAM)   : ${CPU_MODEL} (${CPU_RAM})"
print_line
print_line " 🚀 Starting Ollama Context Benchmark | $(date +%F-%H%M)"
print_line " Models      : ${MODELS[*]}"
print_line " Start ctx   : $START_CTX"
print_line " Increase    : $CTX_RAISE_INFO"
print_line " Iterations  : $MAX_ITER"
print_line " Timeout     : ${MAX_TIME}s"
print_line " Prompt      : \"$PROMPT_BENCHMARK\""
print_line " Logfile     : $LOG_FILE"
[[ "$VERBOSE_MODE" -eq 1 ]] && print_line " Verbose     : thinking + response will be displayed in terminal and logfile"
print_line ""

print_header_line() {
    printf_line "%7s | %7s | %-${MAX_MODEL_NAME_LENGTH}s | %6s / %-6s | %-15s | %4s / %-4s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s\n" \
        "iter M" "iter T" "Model" "ctx S" "ctx L" "  RAM  /  SIZE" "CPU" "GPU" "T Dur" "L Dur" "P Dur" "Prompt N" "Prompt Rate" "Eval N" "Eval Dur" "Eval Rate"
}

#----------------------------------------------------------------------------------------------------------------------------

# Show column header one time for non verbose output
if [[ $VERBOSE_MODE == 0 ]]; then
    print_line "$SEP"
    print_header_line
    print_line "$SEP"
fi 

#----------------------------------------------------------------------------------------------------------------------------

# Calculate total number of runs across all models and iterations
TOTAL_RUNS=$(( ${#MODELS[@]} * MAX_ITER ))
GLOBAL_RUN=0

#----------------------------------------------------------------------------------------------------------------------------

# Start model loop proccessing
for MODEL in "${MODELS[@]}"; do

    MODEL_SHORT=$(truncate_model "$MODEL")
    MODEL_SIZE=$(ollama list | awk -v model="$MODEL" '$1 == model {printf "%3s %s\n", $3, $4}')
    MODEL_ID=$(ollama list | awk -v model="$MODEL" '$1 == model {printf $2}')
    SAFE_MODEL=$(echo "$MODEL" | tr '/:' '__')
    ctx=$START_CTX
    iter=1
    
    # Clear skip model vars
    CONTEXT_LIMIT=
    RAM_LIMIT=
    PS_CONTEXT_CTX=
    
    # Start model benchmarks
    while [ $iter -le $MAX_ITER ]; do
        # show column header for each verbose output
    	if [[ "$VERBOSE_MODE" -eq 1 ]]; then    
             print_line "$SEP"
             print_header_line
        fi

	# Calculate counters
        ((GLOBAL_RUN++))
	ITER_M=$(printf "%3d/%-3d" "$iter" "$MAX_ITER")
	ITER_T=$(printf "%3d/%-3d" "$GLOBAL_RUN" "$TOTAL_RUNS")

	# skip benchmark when context threshold is reached
	if [[ $CONTEXT_LIMIT == true ]] || [[ $RAM_LIMIT == true ]]; then
	    ((iter++))
	    ollama stop "$MODEL"        
	    continue
	fi

	# print proccessing line
	printf "%7s | %7s | %-${MAX_MODEL_NAME_LENGTH}s | %6s / %6s | %15s | %4s / %-4s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s" \
        "$ITER_M" "$ITER_T" "$MODEL_SHORT" "$ctx" ""

	# Set Vars for fast benchmark	
	if [ -n "$SHOW_CPU_GPU_LOAD_DELAY" ]; then	
	    PROMPT_BENCHMARK=""
	    MAX_TIME=$SHOW_CPU_GPU_LOAD_DELAY_DELAY
	fi	
	
	# start ollama benchmark
        OUTPUT=$(curl -s --max-time "${MAX_TIME}" "${OLLAMA_API}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${MODEL}\",
                \"prompt\": \"${PROMPT_BENCHMARK}\",
                \"stream\": false,
                \"options\": { \"num_ctx\": ${ctx} }
            }")

        # get ollama ps values
	PS_LINE=$(ollama ps 2>/dev/null | grep "^${MODEL} ")
        PS_RAM_SIZE=$(awk '{print $3, $4}' <<< "$PS_LINE")
        PS_CONTEXT_CTX=$(awk '{print $7}' <<< "$PS_LINE")
        # Parse CPU/GPU usage — supports both formats:
        #   "26%/74% CPU/GPU"  (combined)
        #   "40% CPU"          (CPU only)
        #   "100% GPU"         (GPU only)
        read PS_CPU PS_GPU < <(awk '{
            for(i=1;i<=NF;i++) {
                # combined format: "26%/74%" followed by "CPU/GPU"
                if ($i ~ /^[0-9]+%\/[0-9]+%$/ && $(i+1) == "CPU/GPU") {
                    split($i, a, "/")
                    print a[1], a[2]
                    exit
                }
                # single format: "40%" followed by "CPU" or "GPU"
                if ($i ~ /^[0-9]+%$/) {
                    if ($(i+1) == "CPU")  { print $i, "N/A"; exit }
                    if ($(i+1) == "GPU")  { print "N/A", $i; exit }
                }
            }
        }' <<< "$PS_LINE")
        PS_CPU="${PS_CPU:-N/A}"
        PS_GPU="${PS_GPU:-N/A}"


        if [ -z "$OUTPUT" ] && [ -z "$SHOW_CPU_GPU_LOAD_DELAY" ]; then
            print_line "\033[2K\r ❌ No response (timeout after ${MAX_TIME}s or connection error)"
            continue
        fi

        ERROR=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if [ -n "$ERROR" ]; then
	    printf "\r\033[K%7s | %7s | %-${MAX_MODEL_NAME_LENGTH}s | %6s / %s\n" \
            "$ITER_M" "$ITER_T" "$MODEL_SHORT" "$ctx" "$ERROR ( $MODEL )" | tee -a "$LOG_FILE"
            RAM_LIMIT=true
            ((iter++))
            ollama stop "$MODEL"
            continue
        fi

	# Skip processing in fast bench mode
        if [ -z "$SHOW_CPU_GPU_LOAD_DELAY" ]; then
            TOTAL_NS=$(echo "$OUTPUT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_duration',0))")
            LOAD_NS=$(echo "$OUTPUT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('load_duration',0))")
            PROMPT_N=$(echo "$OUTPUT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_count',0))")
            PROMPT_NS=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_duration',1))")
            EVAL_N=$(echo "$OUTPUT"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))")
            EVAL_NS=$(echo "$OUTPUT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_duration',1))")
	fi

        TOTAL_DUR=$(parse_ns  "$TOTAL_NS")
        LOAD_DUR=$(parse_ns   "$LOAD_NS")
        PROMPT_DUR=$(parse_ns "$PROMPT_NS")
        EVAL_DUR=$(parse_ns   "$EVAL_NS")

        PROMPT_RATE=$(python3 -c "print(f'{${PROMPT_N}/(${PROMPT_NS}/1e9):.2f} t/s')" 2>/dev/null || echo "N/A")
        EVAL_RATE=$(python3   -c "print(f'{${EVAL_N}/(${EVAL_NS}/1e9):.2f} t/s')"    2>/dev/null || echo "N/A")

        # Check for LLM context limit
        if [[ -z "$PS_CONTEXT_CTX" ]] || [ "$ctx" -gt "$PS_CONTEXT_CTX" ]; then
            printf "\r\033[K%7s | %7s | %-${MAX_MODEL_NAME_LENGTH}s | %6s / %-24s | %4s / %-4s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s\n" \
            "$ITER_M" "$ITER_T" "$MODEL_SHORT" "$ctx" "Context Limit reached" \
            "" "" "" "" "" "" "" "" "" ""
            CONTEXT_LIMIT=true
            ollama stop "$MODEL"  
            continue
        fi

	# show benchmark results
        printf_line "\r%7s | %7s | %-${MAX_MODEL_NAME_LENGTH}s | %6s / %-6s | %15s | %4s / %-4s | %-7s | %-7s | %-7s | %-10s | %-12s | %-10s | %-10s | %s\n" \
            "$ITER_M" "$ITER_T" "$MODEL_SHORT" "$ctx" "$PS_CONTEXT_CTX" \
            "$PS_RAM_SIZE / $MODEL_SIZE" "$PS_CPU" "$PS_GPU" \
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

	# Unload LLM
	ollama stop "$MODEL"        

        sleep $OLLAMA_MODEL_UNLOAD_DELAY

    done

done

#----------------------------------------------------------------------------------------------------------------------------

print_line "$SEP"
print_line "✅ Benchmark completed."
[[ -n "$LOG_FILE" ]] && print_line "📄 Log file saved: $LOG_FILE"

#----------------------------------------------------------------------------------------------------------------------------

exit 0

# ===========================================================================================================================

#TODO Script header werte passen nicht wenn -f 1 option aktiv dann steht bei timeout 300 


# notice
# log filter : cat /home/speefak/.ol-bench/2026-06-18-0901_ol-bench.log | head -n 10 
#              cat /home/speefak/.ol-bench/2026-06-18-0901_ol-bench.log | grep -E "^?[[:digit:]] |^?#|^─+"

# wenn wert für PS_CONTEXT_CTX leer dann ggf timings -t oder -f erhöhen

#TODO option -f soll ohne zahl gehen - aktuel fehler


#TODO Option für benchmark reiehnfolge sortiert nach  modelname, model größe

#TODO Modelliste mit allen verfügbaren infos erstellen ???







