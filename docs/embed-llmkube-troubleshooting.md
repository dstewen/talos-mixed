# Embedding InferenceService — Troubleshooting & Known Issues

## Root Cause: `ggml-org/llama.cpp:server` Crashes on CPU-Only Nodes

The `ggml-org/llama.cpp:server` Docker image bundles **all** GPU backends including Intel SYCL (`libggml-sycl.so`). When it starts, `ggml_backend_load_all_from_path()` loads every `.so` in `/app/` — including `libggml-sycl.so` — and the SYCL backend tries to initialize an Intel GPU. On nodes without Intel GPU devices (CPU-only nodes), this fails with:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  can not find preferred GPU platform
PLEASE submit a bug report to https://software.intel.com/en-us/support/priority-support
```

This happens **at startup** during backend initialization — before any env vars are checked.

### What Doesn't Work

| Attempt | Result |
|---------|--------|
| `GGML_SYCL=0` | Not recognized by llama.cpp |
| `GGML_NO_SYCL=1` | Not recognized by llama.cpp |
| `--backend 0` | Still crashes during backend load phase |
| Renaming `libggml-sycl.so` in a volume overlay | Container rootfs mounting issue |

### The Fix: Use `server-vulkan` Image

Switch from `server` to `server-vulkan`:

```yaml
image: ghcr.io/ggml-org/llama.cpp:server-vulkan
```

The `server-vulkan` image does **not** include the SYCL backend. If no Vulkan ICD is present on the host (as on Talos nodes), it gracefully falls back to CPU inference — no crash.

> **Reference:** [joryirving/home-ops](https://github.com/joryirving/home-ops) uses `server-vulkan` for iGPU embedding inference with the same pattern.

## Preloader PVC Path Gotcha

The preloader must write to the **root of the PVC** (`/Qwen/...`), not a subdirectory like `/models/Qwen/...`.

### What Doesn't Work

| Approach | Result |
|----------|--------|
| Mount PVC at `/` | OCI runtime error: "mountpoint is on the top of rootfs" |
| Write to `/models/Qwen/...` with mount at `/models` | InferenceService expects model at `/Qwen/...` (PVC root) — path mismatch |
| Model source `pvc://llmkube/...` | Points to wrong PVC (operator's shared cache) |

### Correct Pattern

```yaml
# Preloader: mount PVC at /pvc, write to /pvc/Qwen/...
volumes:
  - name: model-cache
    persistentVolumeClaim:
      claimName: embeddings
volumeMounts:
  - name: model-cache
    mountPath: /pvc
# Python: outdir = "/pvc/Qwen/Qwen3-Embedding-0.6B-GGUF"

# Model CRD: source references the embeddings PVC
spec:
  source: pvc://embeddings/Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf

# InferenceService: uses modelRef + modelCache.claimName: embeddings
```

## Full Troubleshooting Checklist

1. **Image**: Use `server-vulkan`, NOT `server` or `server-intel`
2. **Model source**: Must be `pvc://embeddings/...` (not `pvc://llmkube/...`)
3. **Preloader**: Writes to PVC root (`/pvc/Qwen/...`), not `/models/...`
4. **ModelCache claimName**: Must be `embeddings`, not `llmkube`
5. **No env var workaround**: `GGML_NO_SYCL=1` and `GGML_SYCL=0` are not supported

## Docker Image Reference

| Image | Backends | GPU Crash? |
|-------|----------|-----------|
| `server` | SYCL + CUDA + ROCm + Vulkan + CPU | ✅ Yes (SYCL) |
| `server-intel` | SYCL | ✅ Yes |
| `server-vulkan` | Vulkan + CPU | ❌ No (falls back to CPU) |
| `server-cuda` | CUDA + CPU | ❌ No (but needs nvidia-container-toolkit) |
| `server-rocm` | ROCm + CPU | ❌ No |
