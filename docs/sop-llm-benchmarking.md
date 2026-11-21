# LLM Benchmarking SOP

## Overview

This SOP covers benchmarking procedures for all LLM serving backends in the cluster. Use these to:
- Compare hardware configurations (iGPU vs GPU vs CPU)
- Validate model performance before deploying to production
- Monitor performance regressions after updates
- Tune serving parameters (batch size, quantization, offloading)

---

## 1. Quick Throughput Comparison — Jory's Benchmark Script

**Use case:** Cross-comparison of any OpenAI-compatible endpoint (vLLM, Ollama, LiteLLM proxy)
**Prerequisites:** `pip install httpx`
**Location:** `repos-other-people/joryirving/home-ops/hack/llm-benchmark.py`

### Run

```bash
# Basic test — single concurrent request
python3 repos-other-people/joryirving/home-ops/hack/llm-benchmark.py \
  --base-url http://192.168.10.87:11434/v1 \
  --model qwen3.8-flash-next-chat \
  --max-tokens 256 \
  --iterations 3 \
  --concurrency 1

# Concurrency scaling — compare 1 vs 2 vs 4 concurrent slots
python3 repos-other-people/joryirving/home-ops/hack/llm-benchmark.py \
  --base-url http://192.168.10.87:11434/v1 \
  --model qwen3.8-flash-next-chat \
  --max-tokens 256 \
  --iterations 3 \
  --concurrency 1 2 4 8

# Against LiteLLM proxy (cluster-internal)
python3 repos-other-people/joryirving/home-ops/hack/llm-benchmark.py \
  --base-url http://192.168.10.87:4000/v1 \
  --model litellm/qwen3.8-flash-next-chat \
  --max-tokens 512 \
  --iterations 5 \
  --concurrency 1 2 4
```

### What it measures

| Metric | Description | Good target |
|--------|-------------|-------------|
| **TTFT** (Time to First Token) | Latency until first token appears | <1s for short prompts, <3s for long prompts |
| **Per-request tok/s** | Throughput per concurrent slot | Higher is better; drops under contention are normal |
| **Aggregate tok/s** | Total system throughput | Higher is better; scales with concurrency |
| **Concurrency scaling** | Performance change when adding slots | <20% per-request slowdown at moderate concurrency |

### Interpretation

- **Per-request slowdown** at high concurrency: normal — slots compete for GPU memory/bandwidth
- **Aggregate gain < 2x** at concurrency 2: model is memory-bound (not compute-bound)
- **Aggregate gain > 3x** at concurrency 2: model is compute-bound (good for batching)

---

## 2. vLLM Native Benchmark — Spark Nodes (Blackwell)

**Use case:** Full throughput/latency profiling of vLLM on Spark GPU
**Prerequisites:** vLLM installed (`pip install vllm`)

### Benchmark Throughput

```bash
# Basic throughput test
python -m vllm.entrypoints.api_server \
  --model google/gemma-4-26b-a4b-nvfp4 \
  --port 8000 \
  --gpu-memory-utilization 0.85 \
  --tensor-parallel-size 1 &

# Run benchmark (separate terminal)
python -m vllmbenchmarks.benchmark_throughput \
  --model google/gemma-4-26b-a4b-nvfp4 \
  --backend vllm \
  --dataset-name random \
  --random-input 1024 \
  --random-output 256 \
  --num-prompts 128 \
  --tokenizer "google/gemma-4-26b-a4b-nvfp4" \
  --request-rate inf
```

### Benchmark Serving (realistic traffic)

```bash
# Simulate real request patterns with arrival rates
python -m vllmbenchmarks.benchmark_serving \
  --model google/gemma-4-26b-a4b-nvfp4 \
  --backend vllm \
  --dataset-name sonnet \
  --num-prompts 100 \
  --request-rate 4 \
  --tokenizer "google/gemma-4-26b-a4b-nvfp4"
```

### What vLLM reports

| Metric | Description | Why it matters |
|--------|-------------|----------------|
| **Input throughput** (tok/s) | Prefill speed — how fast system processes prompt | GPU memory bandwidth |
| **Output throughput** (tok/s) | Decode speed — how fast system generates | GPU compute capacity |
| **E2E latency p50** | Median end-to-end latency | Typical user experience |
| **E2E latency p99** | Worst-case end-to-end latency | Tail latency / SLA |
| **TTFT p50/p99** | First-token latency distribution | Response time perception |

### Quantization comparison

```bash
# Run same benchmark with different quantizations to compare
python -m vllmbenchmarks.benchmark_throughput \
  --model <model> --backend vllm --dataset-name random \
  --random-input 1024 --random-output 256 --num-prompts 64 \
  --quantization fp8    # FP8 quantized
python -m vllmbenchmarks.benchmark_throughput \
  --model <model> --backend vllm --dataset-name random \
  --random-input 1024 --random-output 256 --num-prompts 64 \
  --quantization fp4    # FP4 quantized (if supported)
```

---

## 3. llama.cpp Benchmark — MS Nodes (iGPU)

**Use case:** Benchmark llama.cpp on Intel Xe iGPU (MS1–3)
**Prerequisites:** llama.cpp built with Vulkan support

### Built-in Benchmark

```bash
# Basic benchmark — measure load time, prompt eval, and generation speed
./llama-bench -m /path/to/model.gguf -ngl 35 -t 8

# iGPU-specific — test different GPU offload levels
./llama-bench -m /path/to/model.gguf -ngl 0 -t 8   # CPU only
./llama-bench -m /path/to/model.gguf -ngl 10 -t 8   # Partial offload
./llama-bench -m /path/to/model.gguf -ngl 99 -t 8   # Full offload (max VRAM)

# Compare different model sizes
./llama-bench -m qwen3-8b-Q8_0.gguf -ngl 35 -t 8 -np 4
./llama-bench -m qwen3-8b-Q4_0.gguf -ngl 35 -t 8 -np 4
```

### What llama-bench reports

| Metric | Description | Good target |
|--------|-------------|-------------|
| **Load time** | Model load from disk | <30s for 8B models |
| **Prompt eval** (tok/s) | How fast prompt is processed | >50 tok/s on iGPU |
| **Eval** (tok/s) | Generation speed | >10 tok/s on iGPU |

### Server benchmark

```bash
# Run llama-server and benchmark with client
./llama-server -m model.gguf -ngl 35 -c 4096 --host 0.0.0.0 --port 8088

# Then use Jory's script against it
python3 hack/llm-benchmark.py \
  --base-url http://<ms-ip>:8088/v1 \
  --model self-hosted \
  --concurrency 1 2 4
```

---

## 4. Accuracy Benchmarking — lm-eval-harness

**Use case:** Verify model quality before/after quantization changes
**Prerequisites:** `pip install lm-eval`

### Run against any OpenAI-compatible endpoint

```bash
# MMLU — 57-subject knowledge benchmark
lm-eval \
  --model openai \
  --model_args model=gpt-4o,base_url=http://192.168.10.87:4000/v1,api_key=sk-none \
  --tasks mmlu \
  --num_fewshot 5 \
  --batch_size auto

# Multiple benchmarks in one run
lm-eval \
  --model openai \
  --model_args model=self-hosted,base_url=http://192.168.10.87:4000/v1,api_key=sk-none \
  --tasks mmlu,truthfulqa,ifeval,gsm8k \
  --num_fewshot 5 \
  --batch_size auto

# Code generation — HumanEval
lm-eval \
  --model openai \
  --model_args model=self-hosted,base_url=http://192.168.10.87:4000/v1,api_key=sk-none \
  --tasks human_eval \
  --num_fewshot 0 \
  --batch_size auto
```

### Key benchmarks to run

| Benchmark | What it tests | Relevance |
|-----------|---------------|-----------|
| **MMLU** | General knowledge (57 subjects) | Model capability baseline |
| **IFEval** | Instruction following | Agent reliability |
| **HumanEval** | Code generation | Tool-calling agents |
| **GSM8K** | Math reasoning | Complex reasoning |
| **TruthfulQA** | Truthfulness/hallucination | Safe responses |

### Quantization accuracy check

```bash
# Compare original vs quantized model accuracy
lm-eval --model openai --model_args model=original --tasks mmlu
lm-eval --model openai --model_args model=q4_quantized --tasks mmlu

# Acceptable quality loss: <2% MMLU points, <5% HumanEval
```

---

## 5. GPU Utilization Monitoring

### Spark Nodes (NVIDIA)

```bash
# Real-time GPU metrics
nvidia-smi -l 1 --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv

# vGPU utilization (vLLM exposes metrics at /metrics)
# Check LiteLLM proxy metrics
curl http://192.168.10.87:4000/metrics | grep gpu

# NVIDIA Nsight Systems (deep profiling)
nsys profile --trace=cuda,nvtx --output=profile.nsys \
  python -m vllm.entrypoints.api_server --model <model>
```

### MS Nodes (Intel iGPU)

```bash
# Intel GPU metrics
watch -n 1 "cat /sys/class/drm/card0/gt_cur_freq_mhz; cat /sys/class/drm/card0/gt_busy_percentage"

# GPU memory usage
cat /sys/kernel/debug/dri/0/i915_gem_gtt_usage

# Intel MLC — memory bandwidth stress test
./mlc -s  # stress test
./mlc -w  # bandwidth test
```

---

## 6. Benchmarking Checklist

Before deploying a new model or changing serving config, run this checklist:

### Pre-deployment
- [ ] **Basic throughput test** (Jory's script) at concurrency 1, 2, 4
- [ ] **TTFT measurement** — is it acceptable for interactive use?
- [ ] **Memory usage** — does the model fit? What's the utilization?
- [ ] **Quantization check** — if quantized, run accuracy benchmark (MMLU + HumanEval)
- [ ] **Stability test** — 100+ requests over 30 minutes, check for OOM/crashes

### Post-deployment monitoring
- [ ] **Daily:** Check GPU utilization and memory
- [ ] **Weekly:** Re-run basic throughput benchmark to catch regressions
- [ ] **After updates:** Re-run full accuracy benchmark suite
- [ ] **After hardware changes:** Full comparison benchmark (new vs old config)

### Hardware comparison template

| Config | Model | Quantization | TTFT | tok/s (c=1) | tok/s (c=4) | Mem Usage | Accuracy (MMLU) |
|--------|-------|-------------|------|-------------|-------------|-----------|----------------|
| Spark + vLLM | gemma4-26b | nvfp4 | 0.8s | 45 | 120 | 24GB | 78.5 |
| MS1 iGPU + llama.cpp | qwen3-8b | Q4 | 1.2s | 12 | 28 | 6GB | 72.1 |
| MS2 Ollama (legacy) | qwen3-8b | Q8 | 1.5s | 10 | 22 | 8GB | 72.8 |

---

## 7. Scheduling Benchmarks

### When to benchmark
- **Before production deployment** of any new model
- **After model updates** (new weights, new quantization)
- **After serving config changes** (batch size, offload levels, parallelism)
- **Quarterly** — track performance trends over time
- **After hardware changes** (new nodes, driver updates)

### Standard test suite

Run these in order, save results to a timestamped file:

```bash
# 1. Quick smoke test (1 minute)
python3 hack/llm-benchmark.py --base-url <endpoint> --model <model> --concurrency 1

# 2. Full throughput (5 minutes)
python3 hack/llm-benchmark.py --base-url <endpoint> --model <model> --concurrency 1 2 4 8 --iterations 5

# 3. Accuracy (15-30 minutes)
lm-eval --model openai --model_args model=<model>,base_url=<endpoint> \
  --tasks mmlu,ifeval,human_eval --batch_size auto

# 4. Memory/stability (30+ minutes)
# Run continuous load test with Jory's script at max concurrency for 30 min
# Monitor for OOM, latency spikes, memory leaks
```

---

## Appendix: Quick Reference Commands

### Ollama (ms2 legacy)
```bash
# Built-in benchmark
ollama run <model> --benchmark

# Throughput benchmark
python3 hack/llm-benchmark.py --base-url http://ms2:11434/v1 --model <model> --concurrency 1 2
```

### vLLM (Spark + future MS nodes)
```bash
# Throughput
python -m vllmbenchmarks.benchmark_throughput --model <model> --backend vllm \
  --dataset-name random --random-input 1024 --random-output 256 --num-prompts 128

# Serving
python -m vllmbenchmarks.benchmark_serving --model <model> --backend vllm \
  --dataset-name sonnet --num-prompts 100 --request-rate 4

# Accuracy
lm-eval --model vllm --model_args pretrained=<model>,gpu_memory_utilization=0.9 \
  --tasks mmlu,human_eval --num_fewshot 5
```

### llama.cpp (MS nodes iGPU)
```bash
# Built-in bench
./llama-bench -m model.gguf -ngl 35 -t 8

# Server + Jory's script
./llama-server -m model.gguf -ngl 35 -c 4096 --port 8088
python3 hack/llm-benchmark.py --base-url http://<ip>:8088/v1 --model self-hosted --concurrency 1 2 4
```

### Accuracy (all endpoints)
```bash
lm-eval --model openai --model_args model=self-hosted,base_url=<endpoint>,api_key=none \
  --tasks mmlu,ifeval,human_eval,gsm8k,truthfulqa --batch_size auto
```
