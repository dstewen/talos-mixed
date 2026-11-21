# Bootstrap — Fresh Cluster Install

Complete procedure for installing `talos-mixed` from zero to a running Kubernetes cluster.

> **Prerequisites:** At least one node flashed with Talos, network connectivity, and this repository cloned.

---

## 1. Hardware & Network Checklist

### 1.1 Nodes

| Group | Count | Type | Role | Notes |
|-------|-------|------|------|-------|
| **Control Plane** | 3 | MS-01 (i9-13900H) | `control-plane` | 96GB RAM, Intel iGPU |
| **Blade Workers** | 8 | ComputeBlade (RPi CM4) | `worker` | ARM64 |
| **Intel Workers** | 2 | Intel NUC (i3-8121U) | `worker` | Intel iGPU (Xe/i915) |
| **GPU Workers** | 2 | DGX Spark (GB10) | `worker` | 128GB unified mem, Blackwell GPU, ARM64 |

All nodes must be on the same L2 subnet. VLAN tagging is optional (see `cluster.toml` → `network.vlan_tag`).

### 1.2 Network

| Item | Value |
|------|-------|
| Node CIDR | `10.200.15.0/24` |
| Node CIDR example | `192.168.1.0/24` (your production value) |
| Kube API VIP | `10.200.15.254` (your production value) |
| Gateway VIPs | `internal`, `dns`, `external` — see `cluster.toml` |
| DNS servers | Cloudflare (1.1.1.1, 1.0.0.1) by default |
| NTP servers | Cloudflare anycast by default |

Each node needs a **static IP** configured in DHCP reservations or `/etc/NetworkManager/` on non-Talos systems.

### 1.3 Disk

Each node needs one boot disk (256GB+ recommended, NVMe preferred for Spark nodes). Disk serial numbers are recorded in `talos/topf.yaml` → `data.installDiskSerial`.

---

## 2. Flash Talos to Nodes

### 2.1 Flash the first node (for Talos config access)

```bash
talosctl apply-image \
  --image quay.io/siderolabs/talos:v1.14.6 \
  --nodes <node-ip>
```

Or use the installer ISO on physical nodes:

```bash
# Download the correct ISO for the architecture
# amd64: https://github.com/siderolabs/talos/releases/download/v1.14.6/talos-amd6.iso
# arm64: https://github.com/siderolabs/talos/releases/download/v1.14.6/talos-arm64.iso
# Spark (GB10 uses arm64 with special kernel args — handled by schematic)

# Write to USB
dd if=talos-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

After flashing, the node boots from disk. Access it:

```bash
talosctl --insecure get config --nodes <node-ip>
```

### 2.2 Flash all remaining nodes

Repeat for each node. You can flash multiple nodes simultaneously:

```bash
talosctl apply-image \
  --image quay.io/siderolabs/talos:v1.14.6 \
  --nodes node1-ip,node2-ip,node3-ip
```

---

## 3. Repository Setup

### 3.1 Clone and initialize

```bash
git clone <your-repo-url> talos-mixed
cd talos-mixed

# Initialize required files
just template init
```

This creates:
- `cluster.toml` — cluster configuration (copy from `cluster.sample.toml`)
- `$SOPS_AGE_KEY_FILE` — Age key for SOPS encryption
- `deploy.key` — SSH deploy key for Flux to clone your Git repo
- `flux-webhook-token.txt` — Webhook secret for instant Flux reconciliation

### 3.2 Edit `cluster.toml`

```toml
[network]
node_cidr = "10.200.15.0/24"
dns_servers = ["1.1.1.1", "1.0.0.1"]
default_gateway = "10.200.15.1"

[kubernetes]
pod_cidr = "10.42.0.0/16"
svc_cidr = "10.43.0.0/16"

[kubernetes.api]
addr = "10.200.15.254"  # Kube API VIP

[gateways]
internal = "10.200.15.250"
dns = "10.200.15.251"
external = "10.200.15.252"

[repository]
url = "ssh://git@github.com/yourname/talos-mixed.git"
branch = "main"
webhook_provider = "github"
```

### 3.3 Configure secrets

```bash
# Deploy SSH public key to Git hosting
cat deploy.key.pub

# Set up Cloudflare API token for DNS (external-secrets)
# Store in 1Password or your vault, then create ExternalSecret
```

---

## 4. Topology & Talos Config Generation

### 4.1 Edit `talos/topf.yaml`

This file defines every node. Update:
- `schematicId` for each node (from `topf secrets --confirm=false`)
- `macAddr`, `installDiskSerial`, `installDisk`, `ip`, `role`
- Spark nodes use `schematicId: "@schematics/dgx.yaml"` for NVIDIA drivers

### 4.2 Generate and apply Talos configs

```bash
# Generate Talos configs (creates secrets bundle)
topf secrets --confirm=false > /dev/null

# Render all templates
just template configure

# Apply configs to nodes (insecure mode — first-time bootstrap)
just bootstrap talos
```

This runs:
1. `topf apply --auto-bootstrap` — pushes Talos machine configs to all nodes
2. Nodes reboot and apply configs
3. `topf talosconfig` — generates your `talosconfig` file
4. `topf kubeconfig --validity 8760h` — generates `kubeconfig`

### 4.3 Wait for nodes to come up

```bash
# Watch nodes join
kubectl wait nodes --for=condition=Ready=False --all --timeout=600s

# Then wait for CNI to stabilize
kubectl wait nodes --for=condition=Ready=True --all --timeout=600s
```

---

## 5. Bootstrap Kubernetes

### 5.1 Apply CRDs

```bash
just bootstrap apps-crds
```

This applies all CRDs from Flux, Cilium, VolSync, llmkube, etc.

### 5.2 Apply namespaces and secrets

```bash
just bootstrap apps-namespaces
just bootstrap apps-secrets
```

This creates all namespaces and deploys:
- SOPS age key
- Deploy key secret
- Cluster secrets (Cloudflare API token, etc.)

### 5.3 Sync Helmfile

```bash
just bootstrap apps-helm
```

This runs `helmfile sync` which installs:
- Flux operator and instance
- Cilium CNI
- CoreDNS, Metrics Server, Spegel
- Cert-manager
- Envoy Gateway
- external-dns
- Cloudflare Tunnel
- All apps in every `kubernetes/apps/<category>/` directory

### 5.4 Verify

```bash
# Check all nodes are ready
kubectl get nodes -o wide

# Check Flux is syncing
flux get sources git -A
flux get kustomizations -A

# Check core services
kubectl get pods -A | grep -E 'cilium|coredns|flux|spegel|cert-manager'
```

---

## 6. Post-Bootstrap Tasks

### 6.1 Configure DNS

Point your home DNS resolver to the `k8s_gateway` VIP (`gateways.dns` in `cluster.toml`) for internal DNS resolution of cluster services.

### 6.2 Configure Cloudflare Tunnel (if using)

Set `ingress.mode = "cloudflare-tunnel"` in `cluster.toml` and ensure `cloudflare-tunnel.json` exists.

### 6.3 Configure Renovate

Renovate should already be deployed. Configure your Git hosting integration.

### 6.4 Verify GPU Setup (if applicable)

```bash
# Check Intel iGPU on NUC/MS nodes
kubectl get nodes -l intel.feature.node.kubernetes.io/gpu=true

# Check NVIDIA DRA on Spark nodes
kubectl get resourceclaims -A
kubectl get resourceclaimtemplates -A
```

---

## Troubleshooting

### Nodes stuck at `Ready=False`

```bash
# Check Talos health
talosctl health --nodes <ip> --wait-timeout=5m

# Check node events
kubectl describe node <node-name>

# Check if CNI is deployed
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

### Flux not syncing

```bash
# Check the GitRepository source
flux get sources git -n flux-system flux-system -o yaml

# Check the Kustomization
flux get kustomizations -A

# Force a sync
flux reconcile kustomization flux-system -n flux-system
```

### Talos config application fails

```bash
# Check the node's serial port or serial console
# For physical nodes, check the BIOS/boot order
# For VMs, ensure SecureBoot is disabled or use UKI

# Re-apply with verbose logging
talosctl apply-config --nodes <ip> --insecure -v 9
```

### Schema validation fails

```bash
# Diagnose the schema issue
uv run --locked --no-dev template/scripts/validate.py cluster.toml

# Regenerate the schema
just template schema
```
