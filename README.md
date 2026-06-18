# Ollama Context Benchmark

A comprehensive benchmarking tool for Ollama language models that systematically evaluates performance across increasing context window sizes. This script measures critical metrics including load time, prompt evaluation rate, and generation speed, providing detailed insights into model performance under varying context lengths.

## 📊 What It Does

The script benchmarks Ollama models by running them through multiple iterations with progressively larger context windows, capturing comprehensive performance metrics at each step. It's designed to help you understand how your models behave as context size increases, which is crucial for production deployments and resource planning.

## ✨ Key Features

- **Progressive Context Testing** – Automatically increases `num_ctx` values per iteration to measure performance degradation or stability
- **Detailed Performance Metrics** – Captures total duration, load duration, prompt evaluation duration, generation duration, token counts, and tokens/second rates
- **Multi-Model Support** – Test multiple models in a single run with flexible selection options
- **Hardware Monitoring** – Displays GPU model, VRAM usage, CPU model, and RAM usage during benchmarks
- **Verbose Output Mode** – Shows complete model thinking and response output, useful for debugging and quality assessment
- **CUDA Driver Reload** – Option to reload CUDA drivers before testing to ensure consistent GPU state
- **Export Capability** – Save all benchmark results to a structured log file for later analysis
- **Real-time Status** – Live progress updates showing current iteration, model, and context size being tested

## 📈 Metrics Collected

| Metric | Description |
|--------|-------------|
| **Total Duration** | Complete request processing time |
| **Load Duration** | Time to load the model into memory |
| **Prompt Eval Duration** | Time to evaluate the prompt tokens |
| **Prompt Eval Rate** | Tokens per second during prompt processing |
| **Generation Duration** | Time to generate the response tokens |
| **Generation Rate** | Tokens per second during response generation |
| **VRAM/RAM Usage** | Memory consumption during inference |
| **Processing Unit** | Shows whether GPU or CPU is handling computation |

## 🚀 Requirements

- **Ollama** – Install via `curl -fsSL https://ollama.com/install.sh | sh`
- **Python 3** – For JSON parsing and time formatting
- **cURL** – For REST API communication with Ollama
- **jq** – For JSON processing (recommended)

## 📦 Installation

1. Clone the repository:
```bash
git clone https://github.com/speefak/ollama-context-benchmark.git
cd ollama-context-benchmark
```

2. Make the script executable:
```bash
chmod +x ollama-benchmark.sh
```

3. Ensure Ollama is running locally:
```bash
ollama serve
```

## 🎯 Usage Examples

### Basic Usage
```bash
# Test a single model with default settings
./ollama-benchmark.sh -m llama2:7b
```

### Advanced Examples
```bash
# Test multiple models with custom context settings
./ollama-benchmark.sh -m llama2:7b mistral:7b -cs 8192 -cr 10% -l 10

# Percentage-based increase with custom prompt
./ollama-benchmark.sh -m qwen2:7b -cs 4096 -cr 50% -p "Explain quantum computing" -l 8

# Absolute increase with export and verbose output
./ollama-benchmark.sh -m llama3:8b -cs 4096 -cr 1024 -l 5 -e /tmp/bench.txt -v

# Test all available models
./ollama-benchmark.sh -m a -cs 2048 -cr 25% -l 3

# Test models by index (from ollama list)
./ollama-benchmark.sh -m 1-3,6-8,10 -cs 8192 -cr 50% -l 6
```

## ⚙️ Options

| Option | Long Form | Description | Default |
|--------|-----------|-------------|---------|
| `-h` | `--help` | Show help message | - |
| `-m` | `--model` | Model(s) to test (see selection modes below) | Interactive selection |
| `-cs` | `--ctx-start` | Starting context size in tokens | 4096 |
| `-cr` | `--ctx-raise` | Increase per iteration (`50%` or `1024`) | 10% |
| `-p` | `--prompt` | Benchmark prompt text | "How does a LargeLanguageModel work..." |
| `-l` | `--loops` | Number of iterations | 10 |
| `-t` | `--timeout` | cURL timeout in seconds | 300 |
| `-v` | `--verbose` | Show thinking + response output | Disabled |
| `-rc` | `--reload-cuda` | Reload CUDA driver before testing | Disabled |
| `-smi` | `--show-model-info` | Display model information and exit | Disabled |
| `-e` | `--export` | Save output to text file | Auto-generate |

### Model Selection Modes

The `-m` option supports multiple selection methods:

1. **Exact Names**: `-m llama2:7b mistral:7b`
2. **All Models**: `-m a`
3. **Index Selection**: `-m 1-3,6-8,10` (from `ollama list` output)

## 📁 Output Structure

Benchmark results are saved to:
```
~/.ol-bench/YYYY-MM-DD-HHMM_ol-bench.log
```

### Sample Output
```
 GPU (VRAM)  : NVIDIA RTX 4090 (24.00 GiB)
 CPU (RAM)   : Intel Core i9-13900K (64.0 GiB)

 🚀 Starting Ollama Context Benchmark | 2026-06-18-0901
 Models      : llama2:7b
 Start ctx   : 4096
 Increase    : +10% per iteration
 Iterations  : 10
 Timeout     : 300s
 Prompt      : "How does a LargeLanguageModel work..."

─────┬───────────────────────────────────────────────────────────
 ct M | ct T  Model     num_ctx   RAM  /  SIZE   Processor  ...
─────┼───────────────────────────────────────────────────────────
 1/10 | 1/10  llama2:7b 4096      7.2 GB / 7.8 GB  65% GPU  ...
 2/10 | 2/10  llama2:7b 4505      8.1 GB / 7.8 GB  72% GPU  ...
...
```

## 🔍 Understanding the Results

- **ct M/ct T**: Current iteration / Total iterations | Current run / Total runs
- **Processor**: Shows if processing is handled by GPU or CPU, with utilization percentage
- **Prompt Rate**: How fast the model processes input tokens – higher is better
- **Eval Rate**: How fast the model generates output tokens – higher is better
- **RAM/Size**: Current memory usage compared to model size

## 🛠️ Troubleshooting

### Common Issues

1. **"No response (timeout)"** – Increase timeout with `-t` option or check if Ollama is running
2. **"ollama error: model not found"** – Verify model exists with `ollama list`
3. **Context token not applied** – Some models have maximum context limits; check model documentation
4. **CUDA not detected** – Use `-rc` to reload CUDA drivers or verify NVIDIA drivers are installed

### Verification Commands
```bash
# Check Ollama status
curl http://localhost:11434/api/tags

# View log file
cat ~/.ol-bench/2026-06-18-0901_ol-bench.log | head -n 10

# Filter for metric lines only
cat ~/.ol-bench/2026-06-18-0901_ol-bench.log | grep -E "^?[[:digit:]] "
```

## 📝 Notes

- The script automatically unloads models after each test to ensure clean state
- Models with very large context windows may require significant VRAM
- The verbose mode outputs both thinking and response content to the log file
- Results are automatically timestamped and stored in the `~/.ol-bench/` directory

## 🤝 Contributing

Contributions are welcome! Please submit issues and pull requests on GitHub.

## 📄 License

MIT License – See LICENSE file for details.

---

**Author**: speefak  
**Version**: 2.1.2  
**Created**: 2025  
**Last Update**: June 2026
