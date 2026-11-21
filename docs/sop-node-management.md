# SOP — Node Management

Standard operating procedures for managing compute nodes in the cluster.

---

## 1. Add a New Node

### 1.1 Identify Node Role

| Role | Hardware | Architecture |
|------|----------|-------------|
| Control Plane | MS-01 (i9-13900H) | amd64 |
| Worker (Blade) | ComputeBlade (RPi CM4) | arm64 |
| Worker (Intel) | Intel NUC (i3-8121U) | amd64 |
| Worker (GPU) | DGX Spark (GB10) | arm64 |

### 1.2 Prepare the Node

1. Flash Talos Linux to the node (see `bootstrap.md` §2)
2. Record MAC address, disk serial, and IP from DHCP reservation

### 1.3 Update `talos/topf.yaml`

Add the new node entry:

```yaml
  - host: "blade9"          # hostname
    ip: "10.200.15.39"      # static IP
    role: worker            # worker or control-plane
    schematicId: "de1619e16531ddff67ccb4ce636a5e3ba5197eb4fc0e8421f095ec50ce9d26a6"
    data:
      installDisk: ""
      installDiskSerial: "<serial>"
      macAddr: "<mac>"
      mtu: 1500
      encryptDisk: false
      kernelModules: []
```

For DGX Spark nodes:
```yaml
    schematicId: "@schematics/dgx.yaml"
    data:
      installDisk: "nvme0n1"
```

### 1.4 Create Node-Specific Configs

```bash
# Copy from an existing blade node as template
cp talos/node/blade1 talos/node/blade9

# Update the new directory with node-specific values
# (MAC, disk serial, hostname in sysfs if needed)
```

### 1.5 Generate & Apply Configs

```bash
just template configure          # regenerate all configs
just bootstrap talos             # apply to new node
```

### 1.6 Verify

```bash
kubectl get nodes
kubectl label node blade9 node.kubernetes.io/role=worker  # if needed
```

---

## 2. Drain & Cordon a Node

### 2.1 Standard Drain

```bash
kubectl cordon <node-name>
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30
```

### 2.2 GPU Node Drain

GPU nodes need special care:

```bash
# Ollama DaemonSet won't drain (runs as DaemonSet)
# Check for lingering pods
kubectl get pods -A -o wide | grep <node-name>

# LLMKube inference services use nodeSelector — they won't auto-move
# Manually scale or move them if needed
kubectl scale inferenceservice <model> --replicas=0 -n ai
kubectl scale inferenceservice <model> --replicas=1 -n ai --field-selector spec.template.spec.nodeName=<new-node>
```

### 2.3 Control Plane Drain

```bash
# Remove etcd membership
kubectl cordon <cp-node>
kubectl drain <cp-node> --ignore-daemonsets --delete-emptydir-data --force

# The remaining 2 control plane nodes maintain quorum (2 of 3)
```

---

## 3. Remove a Node

### 3.1 Drain First

```bash
kubectl drain <node-name> --ignore-daemonsets --force
```

### 3.2 Remove from Cluster

```bash
kubectl delete node <node-name>
```

### 3.3 Remove from Repository

```bash
# Remove from topf.yaml
vim talos/topf.yaml

# Remove node config directory
rm -rf talos/node/<node-name>

# Regenerate
just template configure
git add .
git commit -m "remove: <node-name>"
git push
```

---

## 4. Update Talos/Kubernetes Version

### 4.1 Check Renovate PRs

Renovate opens PRs for Talos and Kubernetes version bumps automatically. Review and merge the relevant PR.

### 4.2 Update Versions

If Renovate hasn't caught it:

```bash
# Update in topf.yaml (renovate comments guide the version)
# renovate: datasource=github-releases depName=siderolabs/talos
talosVersion: v1.14.7  # change this

# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.38.0  # change this
```

### 4.3 Upgrade Control Planes (One at a Time)

```bash
just template configure

# Apply config
talosctl apply-config --nodes <cp-ip>

# Upgrade
talosctl upgrade --nodes <cp-ip> --image quay.io/siderolabs/talos:<version>

# Wait for health
talosctl health --nodes <cp-ip> --wait-timeout=5m

# Verify node joined
kubectl get nodes
```

### 4.4 Upgrade Workers

```bash
# Apply config first (may need reboots for kernel changes)
talosctl apply-config --nodes <worker-ip>

# Upgrade
talosctl upgrade --nodes <worker-ip> --image quay.io/siderolabs/talos:<version>

# Wait for health
talosctl health --nodes <worker-ip> --wait-timeout=5m
```

### 4.5 Upgrade Kubernetes

```bash
# Upgrade kubelet on each node (Talos handles control-plane kube-apiserver)
talosctl upgrade-kubelet --nodes <all-nodes>
```

---

## 5. Node Troubleshooting

### 5.1 Node Not Joining Cluster

```bash
# Check Talos API access
talosctl --nodes <ip> get status

# Check if node is booted
talosctl --nodes <ip> health

# View node logs
talosctl --nodes <ip> logs

# Check network connectivity from another node
ping <node-ip>
```

### 5.2 Node Showing `NotReady`

```bash
kubectl describe node <node-name>

# Check kubelet
kubectl logs -n kube-system <coredns-pod>  # no, check node-level issues
journalctl -u kubelet --node <node-ip>  # if SSH access

# Common: CNI not ready yet, wait for Cilium
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl get pods -n kube-system -l k8s-app=cilium
```

### 5.3 Disk Issues

```bash
# Check disk usage on node
talosctl --nodes <ip> get blockdevices

# Check if disk is full (check pod events)
kubectl get events -A --field-selector reason=Evicted
```

### 5.4 Network Issues

```bash
# Check Cilium connectivity
kubectl exec -n kube-system ds/cilium -- cilium connectivity test --check-dns

# Trace network policy
kubectl exec -n kube-system ds/cilium -- cilium policy trace --selector app=<app-name>

# Check node network interfaces
talosctl --nodes <ip> get netif
```
