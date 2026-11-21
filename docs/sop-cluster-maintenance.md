# SOP — Cluster Maintenance

Standard operating procedures for ongoing cluster maintenance, security, and lifecycle management.

---

## 1. Flux Sync & GitOps

### 1.1 Force a Reconcile

```bash
# For a specific namespace
flux reconcile kustomization flux-system -n flux-system

# For all
flux reconcile kustomization flux-system -n flux-system

# Force a specific Kustomization
flux reconcile kustomization <name> -n <namespace>
```

### 1.2 Check Sync Status

```bash
# All sources and kustomizations
flux get sources git -A
flux get kustomizations -A

# Recent Flux events
flux events --all-namespaces --sort-by=.lastTransitionTime | tail -20

# Flux logs
flux logs -n flux-system --tail=100
```

### 1.3 Rollback a HelmRelease

```bash
# Check HelmRelease history
kubectl get helmrelease <name> -n <namespace> -o jsonpath='{.status.history}'

# Trigger rollback
kubectl annotate helmrelease <name> \
  --type=json \
  -p='[{"op":"add","path":"/metadata/annotations/helm.toolkit.fluxcd.io~1rollback","value":"true"}]' \
  -n <namespace>
```

---

## 2. Secret Management (SOPS + Age)

### 2.1 Rotate Age Key

1. Generate new key: `age-keygen -o new-age.key`
2. Update `.sops.yaml` with the new public key
3. Re-encrypt all secrets:
   ```bash
   find talos/ bootstrap/ kubernetes/ -name '*.sops.yaml' -print0 \
     | xargs -0 -I{} sops --in-place --encrypt {}
   ```
4. Update `$SOPS_AGE_KEY_FILE` on all build boxes
5. Commit and push

### 2.2 Add a Secret

```bash
# Create the encrypted secret template
cp kubernetes/apps/<category>/<app>/app/secret.sops.yaml.new \
   kubernetes/apps/<category>/<app>/app/secret.sops.yaml

# Edit values (sops will auto-encrypt on save)
sops --in-place encrypt kubernetes/apps/<category>/<app>/app/secret.sops.yaml

# Apply (SOPS is handled by Flux via ExternalSecret or direct apply)
just template configure
```

### 2.3 Access a Decrypted Secret

```bash
sops decrypt kubernetes/apps/<category>/<app>/app/secret.sops.yaml
```

---

## 3. Certificate Management

### 3.1 Check Certificate Status

```bash
# All certificates in the cluster
kubectl get certificates -A

# Check for expiring certs (< 30 days)
kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

### 3.2 Renew Expired Certificates

Certificates managed by cert-manager auto-renew. If they're stuck:

```bash
# Check the Issuer/ClusterIssuer
kubectl get clusterissuer

# Check the certificate events
kubectl describe certificate <name> -n <namespace>

# Trigger renewal
kubectl annotate certificate <name> \
  --type=json \
  -p='[{"op":"add","path":"/metadata/annotations/cert-manager\.io/renew","value":"true"}]' \
  -n <namespace>
```

---

## 4. Renovate Management

### 4.1 Review Renovate PRs

Renovate opens PRs automatically (schedule: every weekend). Review and merge:

```bash
# Check Renovate bot PRs in the repo
gh pr list --label "renovate" --state open

# View specific PR
gh pr view <number>
```

### 4.2 Renovate Presets

Custom presets are in `.renovate/` and `.renovate.changelogs.json5`. The presets extend:

```json5
[
  "github>home-operations/renovate-presets#12.0.0",
  "github>home-operations/renovate-presets//apps/cnpg.json5#12.0.0",
  "github>home-operations/renovate-presets//apps/grafanaDashboards.json5#12.0.0",
  "github>home-operations/renovate-presets//apps/llamacpp.json5#12.0.0",
  "github>home-operations/renovate-presets//apps/talosFactory.json5#12.0.0",
  // Custom
  "github>dstewen/talos-mixed//.renovate/changelogs.json5",
  "github>dstewen/talos-mixed//.renovate/packageRules.json5",
]
```

### 4.3 Manually Trigger Renovate

```bash
# Via API (GitHub)
gh api repos/<owner>/<repo>/git/refs/heads/main

# Or force a Renovate run by pushing an empty commit
git commit --allow-empty -m "chore: trigger renovate"
git push
```

---

## 5. Monitoring & Observability

### 5.1 Check Monitoring Health

```bash
# Prometheus
kubectl get pods -n monitoring -l app=prometheus

# Grafana dashboards
kubectl get grafanadashboards -A | wc -l

# Alertmanager
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager
```

### 5.2 Check Resource Usage

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -A --sort-by=cpu

# PVC storage usage
kubectl get pvc -A -o custom-columns=NAME:.metadata.name,SIZE:.spec.resources.requests.storage,STATUS:.status.phase
```

### 5.3 KRR (Kubernetes Resource Recommender)

KRR analyzes actual usage and recommends resource requests/limits:

```bash
# Check KRR status
kubectl get pods -n ai -l app.kubernetes.io/name=krr

# View recommendations
kubectl get krrrecommendations -A
```

---

## 6. Storage Maintenance

### 6.1 Ceph Health

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd df
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph pg stat
```

### 6.2 Garage S3

```bash
# Check Garage nodes
kubectl get pods -n storage -l app.kubernetes.io/name=garage

# Check S3 bucket health
# Access via Garage CLI or S3 compatible tools
```

### 6.3 MinIO

```bash
kubectl get pods -n storage -l app.kubernetes.io/name=minio
# Check via MinIO console UI
```

---

## 7. AI Workload Maintenance

### 7.1 LLMKube Model Updates

```bash
# List models
kubectl get models -n ai

# List inference services
kubectl get inferenceservice -n ai

# Check model health
kubectl describe model <model-name> -n ai
```

### 7.2 Ollama Model Updates

```bash
# Pull new model
kubectl exec -n ai -it <ollama-pod> -- ollama pull <model-name>

# Check running models
kubectl exec -n ai -it <ollama-pod> -- ollama list
```

### 7.3 GPU Resource Health

```bash
# Intel iGPU
kubectl get resourceclaims -A
kubectl get cdidevices -A

# NVIDIA DRA
kubectl get resourceclaims -A -n ai
kubectl describe node spark1 | grep -i gpu
```

---

## 8. Security Audits

### 8.1 RBAC Audit

```bash
kubectl auth can-i --list -A | grep -A5 "Resource: .*$"
kubectl get roles,rolebindings -A | wc -l
```

### 8.2 Network Policy Audit

```bash
kubectl get networkpolicies -A | wc -l
kubectl exec -n kube-system ds/cilium -- cilium policy get
```

### 8.3 Image Vulnerability Check

```bash
# Check Trivy scan results (if deployed)
kubectl get trivyanalyses -A

# Manual image scan
kubectl describe pod <pod> -n <namespace> | grep -A2 "Image:"
```
