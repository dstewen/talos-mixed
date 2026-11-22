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

### Ollama (iGPU — Intel Vulkan) ⚠️ Legacy — being replaced by vLLM
- **Location:** ms2 (single instance)
- **GPU:** Intel iGPU via Vulkan (`OLLAMA_INTEL_GPU: true`, `OLLAMA_VULKAN: 1`)
- **DRA:** Yes — claims `gpu` via ResourceClaimTemplate `ollama-gpu`
- **Replicas:** 1 (single Pod)
- **Models:** Hosted on 500GB Ceph PVC (`ollama-models-pvc`)
- **Inference method:** Vulkan + GGML on integrated graphics
- **Status:** Temporary — will be replaced by vLLM via llmkube (pattern already proven on Spark nodes)

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
- **Models served:** 20+ — mixed cloud APIs (Gemini, Groq) and local (Ollama via Rig, **legacy**)

### Immich Machine Learning
- **Location:** Nodes with Intel GPU (nuc1, nuc2)
- **GPU:** Intel GPU via DRA
- **Runtime:** OpenVINO-based machine learning (`immich-machine-learning:v3.4.1-openvino`)
- **Note:** Resource claim template references `gpu.intel.com` (via `components/gpu`)

### Stable Diffusion
- **ComfyUI:** Separate deployment, uses app-template (likely Intel iGPU via Vulkan)
- **OpenWebUI:** Runs on control-plane, no GPU claims — CPU inference via Ollama (**legacy**, will be replaced by vLLM)

## 3. Control Plane iGPU Value Analysis

### Current State of Control Plane (ms1, ms2, ms3)
- **Role:** Control-plane nodes (etcd, API server, scheduler, controller-manager)
- **iGPU:** Each has Intel integrated GPU (NUC-class hardware)
- **Taints:** `node-role.kubernetes.io/control-plane:NoSchedule` **TOLERATED** — taints are deleted in `talos/main/control-plane/00-cluster.yaml`
- **DRA driver:** `intel-gpu-resource-driver-xe` is affinity-bound to control-plane nodes
- **Ollama:** Single legacy instance on **ms2** only (Intel iGPU via Vulkan) — being replaced by vLLM

### Value of Enabling DRA on Control Plane Nodes

**What you already have:**
- Ollama: **1 legacy Pod on ms2 only** — consuming iGPU memory on one of three CP nodes
- The `intel-gpu-resource-driver-xe` helmrelease targets CP nodes (ms1–3) — **all three have DRA drivers but only ms2 uses the GPU**
- LiteLLM proxy: 3 replicas on CP nodes — pure CPU workload, no competition
- ms1 and ms3: iGPUs completely idle (DRA driver installed but no workloads claiming GPUs)
- vLLM: **Already proven on Spark nodes** via llmkube (`eugr/spark-vllm-b12x` image) — this is the serving runtime pattern to follow

**Potential additional value:**

| Use Case | Value | Complexity |
|----------|-------|------------|
| **vLLM inference on MS nodes (CPU)** | **HIGH** — ms1+ms3 have zero AI workloads; all 3 MS nodes idle (~12+ CPU cores total). Use llmkube to deploy vLLM instances for embedding/reranking alongside the Spark vLLM instances | Low — llmkube already configured on cluster, proven pattern on Spark |
| **vLLM iGPU inference on ms1+ms3** | **HIGH** — 2 unused iGPUs (ms1, ms3) with DRA drivers already installed. Use llmkube + llamacpp backend to serve quantized models (up to 7B) on Intel Xe iGPU with Vulkan, with load distribution and failover across ms1–3 | Medium — need llmkube Model/InferenceService CRDs for Intel GPU |
| **vLLM embedding/reranking on CP** | **HIGH** — Memini needs CPU inference for embed + rerank. CP nodes are ideal: idle CPU cores on ms1,ms3 + spare RAM on ms2. Deploy via llmkube (same infrastructure as Spark vLLM) | Low — llmkube already running, just add Model/InferenceService CRDs |

**Key insight:** The CP nodes are dramatically underutilized. ms1 and ms3 have **zero AI workloads** — no vLLM, no iGPU usage, no CPU inference. ms2 has only 1 legacy Ollama Pod (being phased out). vLLM via llmkube is already proven on Spark nodes. All 3 nodes have 96GB RAM at idle and DRA drivers installed. The most impactful change is deploying vLLM (via llmkube) across all 3 MS nodes — creating a 3-node inference pool with 3 iGPUs and 288GB RAM for memini models, replacing the legacy Ollama on ms2 and giving you 3 iGPUs + 288GB RAM for memini models, agent context models, and light workload inference.

**Recommendation:** Deploy vLLM (via llmkube) on ms1 and ms3 — CPU-only instances for embedding/reranking, and Intel Xe iGPU instances via Vulkan for the assessment model. This turns 3 idle CP nodes into a single 3-node vLLM pool, replacing the legacy Ollama on ms2 and giving you 3 iGPUs + 288GB RAM for memini models, agent context models, and light workload inference.

## 4. DRA Gaps & Opportunities

### Missing DRA Configuration
1. **No NVIDIA slicing** — NVIDIA DRA could use `nvidia.com/gpu` with MFA for GPU partitioning (e.g., 1/2 GPU per pod). Currently only whole-GPU allocation.
2. **No AMD GPU driver** — AMD GPU nodes are not in the cluster.
3. **NFD gap** — No NFD rule for NVIDIA GPU detection on spark nodes.

### GPU Node Summary

| Node | GPU Type | DRA Driver | Alloc Mode | Workloads |
|------|----------|-----------|------------|-----------|
| nuc1 | Intel i965 | intel-gpu-resource-driver | Whole | Immich ML |
| nuc2 | Intel i965 | intel-gpu-resource-driver | Whole | (idle) |
| ms1 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | LiteLLM |
| ms2 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | Ollama (legacy), LiteLLM |
| ms3 | Intel (Xe) | intel-gpu-resource-driver-xe | Whole | LiteLLM |
| spark1 | NVIDIA Blackwell | dra-driver-nvidia-gpu | Whole | LLMKube (vLLM) |
| spark2 | NVIDIA Blackwell | dra-driver-nvidia-gpu | Whole | LLMKube (vLLM) |
| blade1-8 | (varies) | N/A | N/A | No GPU workloads currently |

## 5. Memini & Lossless-Claw — Implementation

### Background

**Memini** is OpenClaw's long-term memory layer: it embeds messages into vectors, scores their salience with an LLM, stores them in SQLite, and injects relevant memories back into agent context. Requires 3 models.

**Lossless-Claw** is OpenClaw's context compression plugin: it monitors context window usage and when triggered, sends the full conversation to a summary model that outputs a compressed version. The agent continues seamlessly with the smaller context. Requires 1 model.

**Reference:** [joryirving/home-ops](https://github.com/joryirving/home-ops) has these deployed in production with their config in `openclaw.json`.

### Architecture Decision

| Component | Model | Size | Serving | Where | Why |
|-----------|-------|------|---------|-------|-----|
| **Embedding** | Qwen3-Embedding-0.6B | 0.6B | CPU (vLLM) | MS nodes (CP, 96GB RAM) | Purpose-built, tiny, 3 replicas for concurrency. No GPU needed. |
| **Reranker** | bge-reranker-v2-m3 | ~420M | CPU (vLLM) | MS nodes (CP, 96GB RAM) | Purpose-built, tiny, 3 replicas. No GPU needed. |
| **Assessment** | Qwen3.8-Flash-Next (non-thinking) | 35B | iGPU (vLLM + llamacpp) | MS nodes (CP, Intel Xe iGPU) | Semantic alignment with Qwen chat models. Deploy vLLM (via llmkube) to ms1–3 for a 3-node iGPU pool. Best for "is this worth remembering?" classification. |
| **Summary** | Gemma2-9B Q4 | ~4.5GB VRAM | CUDA (vLLM) | Gaming 3060 Ti (8GB) | Gemma produces better compression summaries than Qwen. Fits comfortably on 8GB VRAM. Lossless-claw needs compression quality, not semantic reasoning. |

**Why not Spark nodes?** They're running the big AI models via vLLM. Memini/lossless-claw are background utility tasks — running them on dedicated smaller hardware prevents competition for GPU resources.

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
  ├── Dependency: Deploy vLLM (via llmkube) to ms1–3 with Intel Xe iGPU Vulkan support
  ├── Dependency: Qwen3.8-Flash-Next model (move from Spark or deploy new instance)
  ├── Dependency: LiteLLMModel for assessment model
  └── Test: Can memini assess message salience and decide what to store?

Phase 3: Summary Model (Gemma2-9B, Gaming 3060 Ti)
  ├── Dependency: Phase 1 complete (embedding + reranker must work)
  ├── Dependency: Gemma2-9B Q4 model file (~4.5GB)
  ├── Dependency: vLLM instance on gaming rig (via llmkube or direct deployment)
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

### Step 3: Deploy vLLM via llmkube on ms1, ms3

Deploy vLLM (via llmkube) on ms1–3 using the same pattern as Spark nodes. Two deployment types:
- **CPU-only instances** — for embedding/reranker workloads (no GPU needed)
- **iGPU instances** (Intel Xe via Vulkan) — for assessment model

```yaml
# CPU vLLM instance for embedding/reranker (3 replicas across ms1–3)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-embedding  # CPU, 3 replicas
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vllm-embedding
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values: [ms1, ms2, ms3]
      containers:
      - name: vllm
        image: eugr/spark-vllm-b12x  # same image as Spark nodes
        env:
        - name: VLLM_CPU_ENABLE
          value: "true"  # CPU inference
        - name: MODEL_PATH
          value: "/models/qwen3-embedding-0.6b"
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
          limits:
            memory: "32Gi"
```

### Step 4: Create llmkube Model/InferenceService CRDs

For embedding and reranker models, create Model + InferenceService (CPU, targeting ms1–3):

### Step 5: OpenClaw Configuration

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
        "embed_base_url": "http://litellm.ai:4000/v1",
        "embed_model": "embed",
        "embed_dims": 1024,
        "embed_api_key_secret": "litellm-key-memini",
        "llm_base_url": "http://litellm.ai:4000/v1",
        "llm_model": "litellm/gemma4-26b-a4b-nvfp4-no-thinking",
        "llm_api_key_secret": "litellm-key-memini",
        "rerank": "http://litellm.ai:4000/v1",
        "rerank_model": "rerank",
        "rerank_api_key_secret": "litellm-key-memini"
      },
      "lossless-claw": {
        "enabled": true,
        "llm_model": "litellm/gemma2-9b"
      }
    },
    "slots": {
      "memory": "memini",
      "contextEngine": "lossless-claw"
    }
  }
}
```

---

## 6. Implementation History

This section documents the actual steps taken to deploy memini and lossless-claw, including issues encountered and their resolutions.

### Overview

Memini was deployed across 9 PRs between Nov 21–22, 2026. The implementation followed a phased approach: embedding → reranker → LiteLLMModel aliases → plugin configuration.

### PR #836–841: Embedding Infrastructure

**PR #836** `bot/preloader-embeddings` — Initial preloader Job for model pre-staging on PVC
**PR #837** `bot/preloader-embeddings-fix` — Fixed preloader configuration
**PR #838** `bot/preloader-embeddings-cli-extras` — Added CLI extras to preloader
**PR #839** `bot/preloader-embeddings-python-api` — Switched to Python API script with heredoc for YAML quoting
**PR #840** `bot/preloader-embeddings-init-only` — Restructured preloader to init-container-only
**PR #841** `bot/preloader-embeddings-init-only` — Final preloader fix

### PR #842–843: Embed InferenceService — Image Crash

**Issue:** The `ggml-org/llama.cpp:server` Docker image ships with Intel SYCL backend (`libggml-sycl.so`) which crashes at startup on CPU-only nodes:

```
terminate called after throwing an instance of 'std::runtime_error'
  what(): can not find preferred GPU platform
PLEASE submit a bug report to https://software.intel.com/en-us/support/priority-support
```

**Resolution (PR #843):** Switched from `server` to `server-vulkan` image. The vulkan image has no SYCL; gracefully falls back to CPU if no Vulkan ICD present.

**Files changed:** `embed-1.yaml`, `embed-2.yaml`, `model.yaml`, `preloader-embeddings.yaml`

### PR #845: llama.cpp Image Update

**Issue:** Needed updated llama.cpp image for better CPU compatibility
**Resolution:** Updated from `56df0a7` → `8248767`

### PR #852–856: Reranker — Image & Config Issues

**PR #852** `fix: rerank uses server-vulkan image (not server-intel)`
- **Issue:** `server-intel` image crashes on CPU-only nodes (SYCL backend)
- **Fix:** Switched rerank-1 and rerank-2 to `server-vulkan` image

**PR #853 / #854** `fix: rerank uses GGUF model (not safetensors)`
- **Issue:** Reranker model was using safetensors format but llama.cpp needs GGUF
- **Fix:** Switched to `bge-reranker-v2-m3-FP16.gguf` from gpustack's GGUF repo

**PR #855** `fix: memini-rerank uses server-vulkan image (not server-intel)`
- **Issue:** All three memini-rerank pods were using `server-intel` or plain `server` image — both crash at startup on CPU nodes
- **Fix:** Updated to `server-vulkan` image

**PR #856** `fix: remove OpenMP thread affinity from memini-rerank`
- **Issue:** `GOMP_CPU_AFFINITY=0-11` causes libgomp thread creation failure on 4-core nodes (NUCs)
- **Fix:** Removed the env vars — llama.cpp already uses `--threads 6` and `-mb 0`

### PR #861: LiteLLM Virtual Key Activation

**Issue:** Memini needs to authenticate to LiteLLM for embed/rerank/LLM model access
**Resolution (PR #861):** Added `litellmkey.yaml` to the memini kustomization so the `LiteLLMVirtualKey` CRD creates a `litellm-key-memini` secret with a virtual key for memini.

### PR #862: LiteLLMModel Aliases for embed/rerank

**Issue:** Memini references model names `embed` and `rerank` but llmkube auto-registered them with suffixed names (`embed-1`/`embed-2`, `rerank-1`/`rerank-2`) because llmkube appends `-N` suffixes when there are multiple InferenceServices for the same model.

**Resolution (PR #862):** Created headless services and `LiteLLMModel` aliases:
- `embed-headless.yaml` — headless service for embed-1/2 pool (selector: `embed-pool: true`)
- `rerank-headless.yaml` — headless service for rerank-1/2 pool (selector: `rerank-pool: true`)
- `models/embed.yaml` — `LiteLLMModel` wrapping `embed` endpoint with `/v1/embeddings`
- `models/rerank.yaml` — `LiteLLMModel` wrapping `rerank` endpoint

### PR #863: Flux Kustomization Missing Resources

**Issue:** PR #862 added `embed.yaml` and `rerank.yaml` `LiteLLMModel` CRDs, but they were not being applied by Flux because the `models/kustomization.yaml` explicitly enumerates files to deploy.

**Resolution (PR #863):** Added `embed.yaml` and `rerank.yaml` to `models/kustomization.yaml` resources list.

### PR #864: LiteLLMModel Schema Fix

**Issue:** PR #863 added the embed `LiteLLMModel` CRD but used an invalid field `spec.info.endpoint`. The `LiteLLMModel` CRD schema defines `spec.info.mode: embedding` instead.

**Resolution (PR #864):** Changed `endpoint: /v1/embeddings` → `mode: embedding`.

### PR #866: OpenClaw Plugin Configuration

**Issue:** Memini is an OpenClaw plugin (`clawhub:@eleboucher/memini`), not just a K8s service. Lossless-claw (`@martian-engineering/lossless-claw`) is an npm plugin for context compression. Neither were installed/configured in the openclaw-test deployment.

**Resolution (PR #866):**
- **HelmRelease:** Added `clawhub:@eleboucher/memini` and `@martian-engineering/lossless-claw` to the init container plugin install commands
- **ConfigMap:** Added `memini` and `lossless-claw` to `plugins.allow`, configured `memini` with `base_url: http://memini.llm:8080` and per-agent namespace isolation, set `plugins.slots.memory: "memini"` and `plugins.slots.contextEngine: "lossless-claw"`
- **Memini HelmRelease:** Updated `MEMINI_LLM_MODEL` from `muse-glimmer` to `gemma4-26b-a4b-nvfp4-no-thinking` (the `muse-glimmer` model doesn't exist)

### Key Issues Summary

| Issue | Cause | Resolution |
|-------|-------|------------|
| **llama.cpp crashes on CPU nodes** | `server` image ships SYCL backend (`libggml-sycl.so`) | Use `server-vulkan` image (no SYCL; falls back to CPU) |
| **Wrong model format for reranker** | Used safetensors but llama.cpp needs GGUF | Switch to `bge-reranker-v2-m3-FP16.gguf` |
| **Thread affinity failure on 4-core nodes** | `GOMP_CPU_AFFINITY=0-11` exceeds available cores | Remove env var; llama.cpp uses `--threads 6` |
| **Memini can't find embed/rerank models** | llmkube auto-suffixes names (`embed-1`, `rerank-1`) | Create headless services + `LiteLLMModel` aliases |
| **Flux not applying new CRDs** | `kustomization.yaml` explicit resource list not updated | Add `embed.yaml` and `rerank.yaml` to resources |
| **Invalid LiteLLMModel schema** | Used `endpoint: /v1/embeddings` instead of `mode: embedding` | Use correct `mode: embedding` field |
| **Memini not installed in OpenClaw** | Was only a K8s service, not an OpenClaw plugin | Install `clawhub:@eleboucher/memini` via init container |
| **Non-existent LLM model** | `MEMINI_LLM_MODEL: muse-glimmer` doesn't exist | Changed to `gemma4-26b-a4b-nvfp4-no-thinking` |

### Troubleshooting Checklist

For future deployments of llama.cpp models on Talos:

1. **Image:** Always use `server-vulkan`, NEVER `server` or `server-intel` (SYCL crash on CPU-only nodes)
2. **Model format:** GGUF for llama.cpp, safetensors for vLLM
3. **Thread affinity:** Don't set `GOMP_CPU_AFFINITY` on 4-core nodes — use `--threads N` flag instead
4. **Model source:** Must be `pvc://embeddings/...` (not `pvc://llmkube/...` — wrong PVC)
5. **Preloader:** Writes to PVC root (`/pvc/Qwen/...`), not `/models/...`
6. **ModelCache claimName:** Must be `embeddings`, not `llmkube`
7. **LiteLLMModel aliases:** Required when llmkube auto-suffixes model names (e.g., `embed-1`, `embed-2`) but the consumer expects bare names (`embed`)
8. **Flux kustomization:** Always check that new CRD files are added to the kustomization's `resources:` list
9. **LiteLLMModel schema:** Use `mode: embedding` or `mode: reranker`, NOT `endpoint: /v1/embeddings`