# Runbooks & SOPs

Operational procedures for managing the Talos Kubernetes cluster. Organized by domain — each can be extracted into a reusable OpenClaw skill.

---

## 1. Node Management

> **See also:** [SOP — Node Management](sop-node-management.md) for detailed procedures.

### 1.1 Add a New Node

**Skill name:** `talos-add-node`

**Trigger:** New hardware needs to join the cluster.

**Procedure:**

1. **Identify the node's role:**
   - Worker: add to `talos/topf.yaml` nodes list
   - Control-plane: add to `talos/topf.yaml` with `role: control-plane`

2. **Create Talos node config files:**
   ```bash
   # Copy the template directory
   cp -r talos/node/blade1 talos/node/<new-node-name>
   # Edit the new directory: update system description, MAC addresses, disk serial
   ```

3. **Configure Talos node features:**
   - If GPU node: add `31-igpu-node-label.yaml` with `node.kubernetes.io/gpu: "true"`
   - If storage node: add `65-VolumeConfig.yaml` and `66-UserVolumeConfig.yaml`

4. **Update Topology:**
   ```bash
   just template configure
   ```

5. **Provision the node:**
   ```bash
   talosctl apply-config --nodes <node-ip> --insecure
   # Or use the provisioning script
   ```

6. **Verify:**
   ```bash
   kubectl get nodes
   kubectl label node <name> node-role.kubernetes.io/worker=worker
   ```

**Notes:**
- Control-plane nodes need the `65-talos-api-access.yaml` config
- Storage nodes need Ceph OSD configuration
- Each node schematic (`schematicId`) is architecture-specific

### 1.2 Drain & Cordon a Node

**Skill name:** `talos-drain-node`

**Procedure:**

```bash
# Cordon the node
kubectl cordon <node-name>

# Drain with force (for Talos nodes that may have eviction issues)
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30

# Verify all pods moved
kubectl get pods -A -o wide | grep <node-name>
```

**For GPU nodes specifically:**
- Ollama pods are DaemonSet-style (1 per node) — they won't be drained
- LLMKube inference services have explicit `nodeSelector: hostname: <name>` — will be moved manually
- Always check for any workload with `nodeAffinity` targeting the node

### 1.3 Update a Node's Talos Version

**Skill name:** `talos-update-version`

**Procedure:**

1. Check Renovate PRs for `talosVersion` and `kubernetesVersion` bumps
2. Review the changelog:
   ```bash
   curl -s https://api.github.com/repos/siderolabs/talos/releases/tags/v<new-version> | jq .body
   ```
3. Update `talos/topf.yaml` (and sub-versions if diverged)
4. Run `just template configure` to regenerate configs
5. Apply to one node at a time (control-plane first, then workers):
   ```bash
   talosctl upgrade --nodes <node-ip> --image quay.io/siderolabs/talos:<version>
   ```
6. Wait for the node to come back online:
   ```bash
   talosctl health --nodes <node-ip> --wait-timeout=5m
   ```
7. Verify:
   ```bash
   kubectl get nodes -o wide
   ```

---

## 2. GPU & AI Workload Management

### 2.1 Scale LLMKube Inference Service

**Skill name:** `llmkube-scale`

**Procedure:**

```bash
# List available models
kubectl get models -n ai

# List inference services
kubectl get inferenceservice -n ai

# Scale a specific model
kubectl scale inferenceservice <model-name> \
  --replicas=<N> \
  -n ai

# For GPU models, scale per-node (nodeSelector is set)
# Check GPU node capacity:
kubectl get nodes -l kubernetes.io/arch=arm64 -o wide
```

**GPU Capacity Planning:**
- spark1 and spark2 each have a full Blackwell GPU via DRA
- Each `allocationMode: All` means one full GPU per inference service
- Max concurrent models per node: 1 (whole GPU allocation)
- To run multiple models, add more GPU nodes or implement GPU slicing

### 2.2 Add a Model to Ollama

**Skill name:** `ollama-add-model`

**Procedure:**

```bash
# Identify which Ollama node has capacity
kubectl get pods -n ai -l app.kubernetes.io/name=ollama -o wide

# exec into the Ollama pod
kubectl exec -n ai -it <ollama-pod> -- ollama pull <model-name>

# Or via the Ollama service endpoint
curl http://ollama.<domain>:11431/api/pull -d '{"name":"<model>"}'
```

**Notes:**
- Models are shared across nodes via the 500GB Ceph PVC at `/models`
- Model caching is via `flashinfer` and `vllm` local caches on spark nodes
- Ollama pods have 32GB memory limit and 2000m CPU request

### 2.3 Troubleshoot DRA GPU Claim Failure

**Skill name:** `dra-gpu-troubleshoot`

**Symptoms:** Pod stuck in `Pending` with `Insufficient gpu.intel.com` or similar.

**Procedure:**

1. **Check ResourceClaimTemplate:**
   ```bash
   kubectl get resourceclaimtemplates -A
   kubectl describe resourceclaimtemplate <name> -n <namespace>
   ```

2. **Check DRA driver health:**
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=intel-gpu-resource-driver
   kubectl get pods -n kube-system -l app.kubernetes.io/name=intel-gpu-resource-driver-xe
   ```

3. **Check CDI (Container Device Interface) devices:**
   ```bash
   kubectl get cdidevices -A
   ls /dev/dri/  # on the node
   ```

4. **Check NFD labels:**
   ```bash
   kubectl get nodes -l intel.feature.node.kubernetes.io/gpu=true
   kubectl describe node <name> | grep -A5 "Labels:"
   ```

5. **Check GPU node taints:**
   ```bash
   kubectl describe node <name> | grep -A5 "Taints:"
   ```

6. **If Ollama pods not getting GPU:**
   - Verify `OLLAMA_INTEL_GPU: true` and `OLLAMA_VULKAN: 1` env vars
   - Check `/dev/dri` is mounted (hostPath in ollama helmrelease)
   - Verify `GGML_VK_VISIBLE_DEVICES: 0` is set

---

## 3. Database Operations

### 3.1 Scale a CNPG Cluster

**Skill name:** `cnpg-scale`

**Procedure:**

```bash
# Edit the cluster spec
kubectl edit cluster <cluster-name> -n database

# Change `spec.instances` (e.g., 3 → 5)
# CNPG will automatically provision additional replicas

# Verify
kubectl get pods -l app.kubernetes.io/name=postgres18 -n database
```

**Constraints:**
- Must have enough nodes to spread across (anti-affinity requires different hostnames)
- Storage must have capacity for additional PVCs

### 3.2 Rotate Superuser Password

**Skill name:** `cnpg-rotate-password`

**Procedure:**

```bash
# CNPG auto-rotates the superuser password every 24h by default
# Check rotation status:
kubectl get secret cloudnative-pg-secret -n database -o jsonpath='{.metadata.creationTimestamp}'

# Force rotation by re-applying the secret:
kubectl apply -f kubernetes/apps/database/cloudnative-pg/app/secret.sops.yaml

# Apps pick up the new password automatically via the init-db container
# No service interruption needed
```

### 3.3 Restore from Backup

**Skill name:** `cnpg-restore`

**Procedure:**

```bash
# List available backups
kubectl get scheduledbackup -n database

# To restore a cluster:
# 1. Create a new Cluster resource with bootstrap.recovery enabled
# 2. Set the source to the backup's externalCluster
# 3. Flux will reconcile and restore

# Example: restore postgres18 from barman
kubectl edit cluster postgres18 -n database
# Uncomment and set:
# bootstrap:
#   recovery:
#     source: source
#     recoveryTarget:
#       backupID: "20260222T085923"
```

---

## 4. Flux/GitOps Operations

### 4.1 Force Flux to Sync

**Skill name:** `flux-force-sync`

**Procedure:**

```bash
# Trigger a reconcile for a specific Kustomization
flux reconcile kustomization <kustomization-name> -n flux-system

# Trigger a reconcile for all
flux reconcile source git flux-system -n flux-system

# Check status
flux get kustomizations -A
flux get sources git -A
```

### 4.2 Rollback a HelmRelease

**Skill name:** `flux-helm-rollback`

**Procedure:**

```bash
# List HelmRelease history
kubectl get helmreleases -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.history}|{"\n"}{end}'

# Annotate the HelmRelease to trigger a rollback
kubectl annotate helmrelease <release-name> \
  --type=json \
  -p='[{"op":"add","path":"/metadata/annotations/helm.toolkit.fluxcd.io~1rollback","value":"true"}]' \
  -n <namespace>

# Or manually edit:
kubectl edit helmrelease <name> -n <namespace>
# Change spec.chartRef to the previous version's OCIRepository tag
```

### 4.3 Add a New App

**Skill name:** `flux-add-app`

**Procedure:**

```bash
# 1. Create the HelmRelease directory
mkdir -p kubernetes/apps/<category>/<app-name>/app
mkdir -p kubernetes/apps/<category>/<app-name>

# 2. Create the HelmRelease manifest
# Use the app-template chart (most common pattern)
# Copy from a similar existing app

# 3. Create the KS (Kustomization) file
# Use an existing KS as template

# 4. Add to category kustomization (if not auto-registered)
# kubernetes/apps/<category>/kustomization.yaml

# 5. Create ExternalSecret for the app
# kubernetes/apps/<category>/<app-name>/app/externalsecret.yaml

# 6. Run template
just template configure

# 7. Commit and push
git add kubernetes/apps/<category>/<app-name>/
git commit -m "add: <app-name>"
git push
```

---

## 5. Storage Operations

### 5.1 Expand a PVC

**Skill name:** `pvcs-expand`

**Procedure:**

```bash
# For OpenEBS hostpath PVCs:
kubectl patch pvc <pvc-name> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'

# For Ceph RBD PVCs:
# These typically auto-expand via the StorageClass reclaimPolicy
kubectl get storageclass
```

**Constraints:**
- OpenEBS hostpath can be expanded in-place if the underlying disk has capacity
- Ceph RBD expansion requires the `rbd.csi.ceph.com` driver

### 5.2 Check Storage Health

**Skill name:** `storage-health-check`

**Procedure:**

```bash
# Ceph health
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# PVC status
kubectl get pvc -A | awk '{if ($5 != "100%") print $0}'

# OpenEBS volume status
kubectl get pv | grep openebs

# NFS server health
curl http://192.168.10.15/api/2.0/storage/status.json
```

---

## 6. Backup & Disaster Recovery

### 6.1 Trigger On-Demand Backup

**Skill name:** `cnpg-backup-now`

**Procedure:**

```bash
# For CNPG clusters with barman-cloud plugin:
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: backup-now-$(date +%s)
  namespace: database
spec:
  template:
    spec:
      containers:
        - name: backup
          image: ghcr.io/cloudnative-pg/postgresql:18.6
          command: ["pg_basebackup"]
          args: ["--wal-method=stream"]
      restartPolicy: Never
EOF
```

### 6.2 Verify Backup Integrity

**Skill name:** `backup-verify`

**Procedure:**

```bash
# Check backup status
kubectl get scheduledbackup -A
kubectl get backups -n database -o wide

# Verify barman archive
kubectl -n database exec -it deploy/onepassword-connect -- barman check minio-pg18
```

---

## 7. Networking

### 7.1 Debug Ingress/HTTPRoute

**Skill name:** `network-debug-route`

**Procedure:**

```bash
# List HTTPRoutes
kubectl get httproute -A

# Check Envoy Gateway pods
kubectl get pods -n network -l app.kubernetes.io/name=envoy-gateway

# Debug a specific route:
kubectl get httproute <name> -n <namespace> -o yaml

# Check Envoy listener status:
kubectl port-forward svc/envoy-gateway 9901:9901 -n network
curl http://localhost:9901/listeners
```

### 7.2 Debug Cilium Network Policy

**Skill name:** `cilium-debug-policy`

**Procedure:**

```bash
# Check policy enforcement
kubectl exec -n <namespace> <pod> -- curl http://<target-service>:<port>

# View Cilium policy verdicts
kubectl exec -n kube-system ds/cilium -- cilium policy trace --selector app=<app-name>

# Check connectivity
kubectl exec -n <namespace> <pod> -- ping <target-ip>
```

---

## 8. Security

### 8.1 Rotate API Keys

**Skill name:** `api-key-rotate`

**Procedure:**

1. Generate new key in 1Password
2. Update ExternalSecret in the app's namespace
3. Flux will propagate the new secret
4. Restart the app to pick up new credentials:
   ```bash
   kubectl rollout restart deploy/<app-name> -n <namespace>
   ```

### 8.2 Audit RBAC

**Skill name:** `rbac-audit`

**Procedure:**

```bash
# List all roles and rolebindings
kubectl get roles,rolebindings -A | wc -l
kubectl get roles,rolebindings -A | grep -v default | grep -v kube-system

# Check for wildcard permissions
kubectl auth can-i --list -A | grep -A5 "Resource: .*$"

# Check service account tokens
kubectl get serviceaccounts -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .secrets[*]}{.name}{"\n"}{end}{end}'
```
