# AI Workloads Analysis

## 1. DRA (Device Resource Allocation) — Current State

### Which Nodes Use DRA

| Driver | Nodes | Device Class | Architecture | Notes |
|--------|-------|-------------|-------------|-------|
| **Intel GPU Resource Driver** | nuc1, nuc2 | `gpu.intel.com` | amd64 | i965 driver (gen11) |
| **Intel GPU Resource Driver (Xe)** | ms1, ms2, ms3 (control-plane) | `gpu.intel.com` | amd64 | Xe driver on NUC-class nodes repurposed as CP |
| **NVIDIA DRA GPU Driver** | spark1, spark2 (DGX Spark) | `gpu.nvidia.com` | arm64 | Blackwell GPU via DRA driver helmrelease |
| **NVIDIA GPU Operator** | spark1, spark2 | (legacy device plugin) | arm64 | Device plugin disabled; replaced by DRA driver |

### DRA Allocation Method

**Intel GPUs — Whole GPU allocation only:**

Both `intel-gpu-resource-driver` and `intel-gpu-resource-driver-xe` use:
```yaml
devices:
  requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.intel.com
        adminAccess: true
        allocationMode: All   # <-- WHOLE GPU
```

The `allocationMode: All` means **entire GPU is allocated to a single pod** — no MFA (Multi-Function Accelerator) / GPU slicing supported. `adminAccess: true` is required because Intel GPU DRA uses privileged operations.

**NVIDIA GPUs — Whole GPU allocation:**

LLMKube's `llmkube-models-gpu` template:
```yaml
devices:
  requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        adminAccess: false   # <-- Standard, non-admin
        allocationMode: All  # <-- WHOLE GPU
```

The NVIDIA DRA driver (`dra-driver-nvidia-gpu`) has `gpuResourcesEnabledOverride: true` to expose GPU resources via DRA instead of the legacy device plugin. Also set to **whole GPU only**.

### NFD (Node Feature Discovery) Rules

Only one GPU-related NFD rule exists:
```yaml
# intel-gpu-device.yaml
matchFeatures:
  - feature: pci.device
    matchExpressions:
      class: ["0300", "0380", "a7a0"]
      vendor: ["8086"]
```
This labels nodes with `intel.feature.node.kubernetes.io/gpu: true` when an Intel PCI GPU (class 0300/0380, vendor 8086) is present. No NFD rule exists for NVIDIA GPU detection on the spark nodes.

## 2. AI Workloads — Current Deployment

### Ollama (iGPU — Intel Vulkan)
- **Location:** Deployed on all nodes with Intel GPUs (nuc1, nuc2, ms1, ms2, ms3)
- **GPU:** Intel iGPU via Vulkan (`OLLAMA_INTEL_GPU: true`, `OLLAMA_VULKAN: 1`)
- **DRA:** Yes — claims `gpu` via ResourceClaimTemplate `ollama-gpu`
- **Replicas:** 1 per node (DaemonSet-style via app-template)
- **Models:** Hosted on 500GB Ceph PVC (`ollama-models-pvc`)
- **Inference method:** Vulkan + GGML on integrated graphics

### LLMKube (NVIDIA GPU)
- **Location:** spark1, spark2 (DGX Spark arm64)
- **GPU:** NVIDIA Blackwell via DRA (`gpu.nvidia.com`)
- **Model format:** GGUF and safetensors (nvfp4 quantization)
- **Example model:** `gemma4-26b-a4b-nvfp4` — NVFP4 quantized, MTP speculative decoding, 262K context
- **Runtime:** vLLM with custom spark-image (`eugr/spark-vllm-b12x`)
- **GPU sharing:** None — whole GPU per inference service
- **Model cache:** 300GB CephFS shared cache

### LiteLLM Proxy
- **Location:** Control-plane nodes (ms1, ms2, ms3) — via `nodeAffinity: control-plane`
- **Replicas:** 3 (HA)
- **Database:** External PostgreSQL (postgres18, hosted on postgres18-rw.database.svc)
- **Routing:** Redis-based least-busy routing + fallback to local gemma4-26b-a4b-nvfp4
- **Models served:** 20+ — mixed cloud APIs (Gemini, Groq) and local (Ollama via Rig)

### Immich Machine Learning
- **Location:** Nodes with Intel GPU (nuc1, nuc2)
- **GPU:** Intel GPU via DRA
- **Runtime:** OpenVINO-based machine learning (`immich-machine-learning:v3.4.1-openvino`)
- **Note:** Resource claim template references `gpu.intel.com` (via `components/gpu`)

### Stable Diffusion
- **ComfyUI:** Separate deployment, uses app-template (likely Intel iGPU via Vulkan)
- **OpenWebUI:** Runs on control-plane, no GPU claims — CPU inference via Ollama

## 3. Control Plane iGPU Value Analysis

### Current State of Control Plane (ms1, ms2, ms3)
- **Role:** Control-plane nodes (etcd, API server, scheduler, controller-manager)
- **iGPU:** Each has Intel integrated GPU (NUC-class hardware)
- **Taints:** `node-role.kubernetes.io/control-plane:NoSchedule` **TOLERATED** — taints are deleted in `talos/main/control-plane/00-cluster.yaml`
- **DRA driver:** `intel-gpu-resource-driver-xe` is affinity-bound to control-plane nodes
- **Ollama:** Runs on CP nodes (1 replica per node, using Intel iGPU via Vulkan)

### Value of Enabling DRA on Control Plane Nodes

**What you already have:**
- Ollama workloads are already running on CP nodes, consuming iGPU memory
- The `intel-gpu-resource-driver-xe` helmrelease targets CP nodes only
- LiteLLM proxy runs on CP nodes (3 replicas) — pure CPU workload

**Potential additional value:**

| Use Case | Value | Complexity |
|----------|-------|-----------|
| **CPU inference on CP cores** | **HIGH** — 3x MS nodes = ~12+ CPU cores at idle, could run additional small models (7B params quantized) alongside existing Ollama iGPU workloads | Low — Ollama already configured |
| **Dedicated GPU inference pool on iGPU** | **MEDIUM** — 3x iGPUs could serve a pool of light models (embedding, reranking, small chat models) with better load distribution than current single-node ollama | Medium — need ResourceClaimTemplates per model |
| **GPU-accelerated vector search (pgvector)** | **LOW** — iGPU memory is limited; pgvector benefits more from GPU RAM | Low setup, low ROI |
| **Dedicated embedding/reranking** | **MEDIUM** — Run sentence-transformers on iGPU, reducing CPU load on worker nodes | Medium — need dedicated workloads |
| **LLMKube-style inference on iGPU** | **LOW** — iGPU RAM too limited for large model serving; best for small models | High setup, low ROI |

**Key insight:** The control plane nodes are already being used for inference via Ollama on iGPU. The biggest ROI would be adding **CPU inference** to these nodes — using the spare 96GB RAM and CPU cores to run additional quantized models via Ollama. This would complement the existing iGPU workloads and create a more distributed inference pool.

**Recommendation:** Add an `OLLAMA_NUM_GPUS: 0` or CPU-only Ollama instance alongside the Vulkan iGPU instances on CP nodes, or use a separate CPU-focused LLM runtime (like `litellm`'s local models) to leverage the CP nodes' CPU/RAM for inference work.

## 4. DRA Gaps & Opportunities

### Missing DRA Configuration
1. **No NVIDIA slicing** — NVIDIA DRA could use `nvidia.com/gpu` with MFA for GPU partitioning (e.g., 1/2 GPU per pod). Currently only whole-GPU allocation.
2. **No AMD GPU driver** — AMD GPU nodes are not in the cluster.
3. **NFD gap** — No NFD rule for NVIDIA GPU detection on spark nodes.

### GPU Node Summary

| Node | GPU Type | DRA Driver | Alloc Mode | Workloads |
|------|----------|-----------|------------|-----------|
| nuc1 | Intel i965 | intel-gpu-resource-driver | Whole | Ollama, Immich ML |
| nuc2 | Intel i965 | intel-gpu-resource-driver | Whole | Ollama |
| ms1 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | Ollama, LiteLLM |
| ms2 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | Ollama, LiteLLM |
| ms3 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | Ollama, LiteLLM |
| spark1 | NVIDIA Blackwell | dra-driver-nvidia-gpu | Whole | LLMKube (vLLM) |
| spark2 | NVIDIA Blackwell | dra-driver-nvidia-gpu | Whole | LLMKube (vLLM) |
| blade1-8 | (varies) | N/A | N/A | No GPU workloads currently |

## 5. Memini & Lossless-Claw — Implementation Plan

### Background

**Memini** is OpenClaw's long-term memory layer: it embeds messages into vectors, scores their salience with an LLM, stores them in SQLite, and injects relevant memories back into agent context. Requires 3 models.

**Lossless-Claw** is OpenClaw's context compression plugin: it monitors context window usage and when triggered, sends the full conversation to a summary model that outputs a compressed version. The agent continues seamlessly with the smaller context. Requires 1 model.

**Reference:** [joryirving/home-ops](https://github.com/joryirving/home-ops) has these deployed in production with their config in `openclaw.json`.

### Architecture Decision

| Component | Model | Size | Serving | Where | Why |
|-----------|-------|------|---------|-------|-----|
| **Embedding** | Qwen3-Embedding-0.6B | 0.6B | CPU (llama.cpp) | MS nodes (CP, 96GB RAM) | Purpose-built, tiny, 3 replicas for concurrency. No GPU needed. |
| **Reranker** | bge-reranker-v2-m3 | ~420M | CPU (llama.cpp) | MS nodes (CP, 96GB RAM) | Purpose-built, tiny, 3 replicas. No GPU needed. |
| **Assessment** | Qwen3.8-Flash-Next (non-thinking) | 35B | iGPU (llama.cpp) | MS nodes (CP, Intel Xe iGPU) | Semantic alignment with Qwen chat models. MS iGPUs already have DRA driver + Ollama. Best for "is this worth remembering?" classification. |
| **Summary** | Gemma2-9B Q4 | ~4.5GB VRAM | CUDA (llama.cpp) | Gaming 3060 Ti (8GB) | Gemma produces better compression summaries than Qwen. Fits comfortably on 8GB VRAM. Lossless-claw needs compression quality, not semantic reasoning. |

**Why not Spark nodes?** They're running the big AI models (vLLM). Memini/lossless-claw are background utility tasks — running them on dedicated smaller hardware prevents competition for GPU resources.

**Why Gemma for summarization?** Gemma2-9B is specifically strong at instruction-following and dense text compression. It produces more concise, higher-quality summaries per token than Qwen3.8-Flash, which is optimized for reasoning, not compression.

**Why Qwen for assessment?** Memini's assessment model needs to understand conversation semantics — "is this a fact worth keeping, or just chat?" Using a Qwen-family model gives better semantic alignment with the Qwen chat models your agents already use, and the assessment prompts are written for Qwen-style models.

### Implementation Order & Dependencies

```
Phase 1: Embedding + Reranker (CPU, MS nodes)
  ├── Dependency: Qwen3-Embedding-0.6B model file
  ├── Dependency: bge-reranker-v2-m3 model file
  ├── Dependency: LiteLLMModel CRDs for `embed` and `rerank`
  └── Dependency: OpenClaw memini plugin installed
  └── Test: Can memini embed messages and retrieve via similarity search?

Phase 2: Assessment Model (Qwen3.8-Flash, MS iGPU)
  ├── Dependency: Phase 1 complete (embedding + reranker must work)
  ├── Dependency: Qwen3.8-Flash-Next model on MS nodes via Ollama/llmkube
  ├── Dependency: LiteLLMModel for assessment model
  └── Test: Can memini assess message salience and decide what to store?

Phase 3: Summary Model (Gemma2-9B, Gaming 3060 Ti)
  ├── Dependency: Phase 1 complete (embedding + reranker must work)
  ├── Dependency: Gemma2-9B Q4 model file (~4.5GB)
  ├── Dependency: Inference service on gaming rig (Ollama recommended)
  ├── Dependency: LiteLLMModel for summary model
  └── Test: Can lossless-claw compress a 100k-token context into a summary?

Phase 4: OpenClaw Configuration
  ├── Dependency: All 4 models serving via LiteLLM
  ├── Dependency: `openclaw.json` updated with memini + lossless-claw config
  ├── Plugin installation: memini, lossless-claw
  └── Test: 9-agent setup with memini memory injection and lossless-claw compression
```

### Step 1: Prepare Model Files

```bash
# Qwen3-Embedding-0.6B Q8_0
wget -O /path/to/models/qwen3-embedding-0.6b-Q8_0.gguf \
  https://huggingface.co/Qwen/Qwen3-Embedding-0.6B/resolve/main/qwen3-embedding-0.6b-q8_0.gguf

# bge-reranker-v2-m3 Q8_0
wget -O /path/to/models/bge-reranker-v2-m3-Q8_0.gguf \
  https://huggingface.co/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/bge-reranker-v2-m3-Q8_0.gguf

# Qwen3.8-Flash-Next (non-thinking variant)
# Already running on Spark nodes — reuse the same weights with thinking disabled

# Gemma2-9B Q4 (for gaming rig)
wget -O /path/to/models/gemma2-9b-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF  # replace with actual Gemma2-9B quantized
```

### Step 2: Create LiteLLMModel CRDs (Phase 1)

```yaml
# kubernetes/apps/base/llm/litellm/models/embed.yaml
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMModel
metadata:
  name: embed
spec:
  modelName: embed
  params:
    model: openai/qwen3-embedding
    apiBase: http://qwen3-embedding.ai.svc.cluster.local:8080/v1
    apiKey: sk-llmkube-noauth
  info:
    mode: embedding
    maxInputTokens: 32768
    dimensions: 1024
```

```yaml
# kubernetes/apps/base/llm/litellm/models/rerank.yaml
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMModel
metadata:
  name: rerank
spec:
  modelName: rerank
  params:
    model: openai/bge-reranker-v2-m3
    apiBase: http://bge-reranker.ai.svc.cluster.local:8080/v1
    apiKey: sk-llmkube-noauth
  info:
    mode: reranker
    maxInputTokens: 8192
```

### Step 3: Create Inference Services (llmkube)

For each model, create a Model + InferenceService:

```yaml
# Model: qwen3-embedding (CPU, MS nodes)
---
apiVersion: inference.llmkube.dev/v1alpha1
kind: Model
metadata:
  name: qwen3-embedding
spec:
  source: /path/to/models/qwen3-embedding-0.6b-Q8_0.gguf
  format: gguf
  hardware:
    accelerator: cpu

---
apiVersion: inference.llmkube.dev/v1alpha1
kind: InferenceService
metadata:
  name: qwen3-embedding-1
spec:
  modelRef: qwen3-embedding
  runtime: llamacpp
  nodeSelector:
    kubernetes.io/hostname: ms1  # or spread across MS nodes
```

Repeat for `bge-reranker-v2-m3` (CPU) and `gemma2-9b` (CUDA on gaming rig).

### Step 4: OpenClaw Configuration

Update `openclaw.json` with memini and lossless-claw:

```json
{
  "agents": {
    "defaults": {
      "contextInjection": "continuation-skip",
      "memini": {
        "inject_recall_min_score": 0.85,
        "inject_labels": ["tier", "age"]
      }
    },
    "entries": {
      "main": {
        "tools": {
          "allow": ["memory_recall", "memory_list", "memory_remember", "memory_forget", "memory_briefing"]
        }
      },
      "planner": {
        "tools": {
          "allow": ["memory_recall", "memory_list", "memory_remember"]
        }
      },
      // ... repeat for all 9 agents
    }
  },
  "plugins": {
    "allow": ["memini", "lossless-claw", ...],
    "entries": {
      "memini": {
        "enabled": true,
        "embed_base_url": "http://litellm.llm:4000/v1",
        "embed_model": "embed",
        "embed_dims": 1024,
        "embed_api_key_secret": "litellm-key-memini",
        "llm_base_url": "http://litellm.llm:4000/v1",
        "llm_model": "litellm/qwen3.8-flash-next-chat",
        "llm_api_key_secret": "litellm-key-memini",
        "rerank": "http://litellm.llm:4000/v1",
        "rerank_model": "rerank",
        "rerank_api_key_secret": "litellm-key-memini"