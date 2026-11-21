# Documentation

Complete operations documentation for the `talos-mixed` Talos Kubernetes cluster.

---

## Quick Reference

| Doc | Purpose |
|-----|---------|
| [Bootstrap](bootstrap.md) | Fresh install from zero hardware to running cluster |
| [Rebuild](rebuild.md) | Full cluster reinstallation (hardware replacement, migration, fresh start) |
| [Disaster Recovery](disaster-recovery.md) | Data recovery, backup restore, RTO/RPO procedures |
| [SOP — Node Management](sop-node-management.md) | Adding, removing, updating, draining nodes |
| [SOP — Cluster Maintenance](sop-cluster-maintenance.md) | Flux, secrets, certs, Renovate, monitoring |
| [SOP — Storage & Backups](sop-storage-backup.md) | PVCs, backups, restores, storage troubleshooting |
| [Runbooks](runbooks.md) | Quick reference commands by domain |

---

## Cluster Architecture

### Nodes

| Group | Count | Hardware | Role | Arch |
|-------|-------|----------|------|------|
| Control Plane | 3 | MS-01 (i9-13900H) | `control-plane` | amd64 |
| Blade Workers | 8 | ComputeBlade (RPi CM4) | `worker` | arm64 |
| Intel Workers | 2 | Intel NUC (i3-8121U) | `worker` | amd64 |
| GPU Workers | 2 | DGX Spark (GB10) | `worker` | arm64 |

### Core Stack

| Layer | Tool | Version |
|-------|------|---------|
| OS | Talos Linux | v1.14.6 |
| K8s | Kubernetes | v1.37.2 |
| GitOps | FluxCD | (managed by flux-operator) |
| CNI | Cilium | (eBPF mode) |
| Ingress | Envoy Gateway | (Gateway API) |
| DNS | external-dns + k8s-gateway | (Cloudflare) |
| TLS | cert-manager | (Let's Encrypt) |
| Secrets | SOPS + Age + ExternalSecrets | |
| Templating | makejinja + TOPF | |

### Storage

| Type | Solution | Notes |
|------|----------|-------|
| Block | Ceph (Rook) | CSI, RBD |
| Object | Garage S3 | |
| Local | MinIO | VolSync source |
| NFS | NFS server | VolSync targets |
| Off-site | Backblaze B2 | VolSync targets |
| Local-path | OpenEBS | |
| iSCSI | Synology CSI | |

### AI Stack

| Component | Details |
|-----------|---------|
| llmKube | Inference services via llamacpp/vLLM |
| Ollama | Runtime on GPU nodes (Intel iGPU, NVIDIA DRA) |
| GPUs | Intel Xe/i915 (MS/NUC), NVIDIA Blackwell (Spark) |
| DRA | `gpu.intel.com`, `gpu.nvidia.com` (whole GPU allocation) |

---

## Workflow

### Daily

- Check Flux sync status (usually auto)
- Monitor GPU workload health
- Check backup completion

### Weekly

- Review Renovate PRs
- Check certificate validity
- Verify backup retention

### Monthly

- Review node resource usage
- Test a restore from VolSync
- Audit RBAC and network policies

### Quarterly

- Full DR drill
- Review Talos/Kubernetes version upgrades
- Storage capacity planning

---

## Key Commands

```bash
# Template/render config
just template configure

# Bootstrap cluster
just bootstrap talos      # Talos configs
just bootstrap apps       # Flux/Helm

# Flux operations
flux reconcile kustomization flux-system -n flux-system
flux get sources git -A
flux get kustomizations -A

# Node operations
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --force

# GPU
kubectl get resourceclaims -A
kubectl get inferenceservice -n ai

# Backups
kubectl get replicationsource -A
kubectl get backups -n database
```
