set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# Global Module Variables (Sourced or hardcoded fallback matches)
CLUSTER := "main"
CLUSTERS := "main utility test"
ROOT_DIR := "."
# Handles path naming differences for Talos assets
TALOS_DIR := ROOT_DIR + "/talos/" + CLUSTER
BOOTSTRAP_DIR := "bootstrap"
# Direct context maps inside the kubernetes structure
CLUSTER_DIR := ROOT_DIR + "/kubernetes/clusters/" + CLUSTER
CLUSTER_APPS := ROOT_DIR + "/kubernetes/apps/" + CLUSTER

# ==============================================================================
# Native topf Operational Recipes
# ==============================================================================

[doc('Apply Talos config to all nodes (shows a diff and asks first)')]
[group('talos')]
apply:
    topf apply

[arg('mode', pattern='auto|reboot|no-reboot|staged|try')]
[doc('Apply Talos config to a node (shows a diff and asks first)')]
[group('talos')]
apply-node node mode='auto':
    topf apply --nodes-filter "^{{ node }}$" --mode "{{ mode }}"

[doc('Show pending config changes without applying them')]
[group('talos')]
diff:
    topf apply --dry-run

[doc('List all nodes and their current state')]
[group('talos')]
nodes:
    topf nodes

[doc('Render Talos machine configs to ./rendered')]
[group('talos')]
render:
    topf render --output ./rendered

[confirm("This will destroy your cluster and reset all nodes to maintenance mode — continue? [y/N]")]
[doc('Reset all nodes back to maintenance mode (DESTRUCTIVE)')]
[group('talos')]
reset:
    topf reset --confirm=false

[confirm("This will reset node " + node + " to maintenance mode — continue? [y/N]")]
[doc('Reset a single node back to maintenance mode (DESTRUCTIVE)')]
[group('talos')]
reset-node node:
    topf reset --nodes-filter "^{{ node }}$" --confirm=false

[doc('Upgrade Kubernetes')]
[group('talos')]
upgrade-k8s:
    talosctl --nodes "$(yq '[.nodes[] | select(.role == "control-plane")][0].ip' topf.yaml)" \
        upgrade-k8s --to "$(yq '.kubernetesVersion' topf.yaml)"

[doc('Upgrade Talos on all nodes, one at a time (asks first)')]
[group('talos')]
upgrade:
    topf upgrade

[doc('Upgrade Talos on a single node (asks first)')]
[group('talos')]
upgrade-node node:
    topf upgrade --nodes-filter "^{{ node }}$"

# ==============================================================================
# Advanced Cluster & Local Configuration Utility Recipes
# ==============================================================================

[doc('Bootstrap a Talos & Kubernetes cluster end-to-end [CLUSTER=main]')]
[group('bootstrap')]
cluster:
    op account get
    test -d {{ BOOTSTRAP_DIR }}/helmfile
    test -d {{ BOOTSTRAP_DIR }}/kustomize
    which kubectl helmfile minijinja-cli op talosctl yq

    echo "==> Configuring Nodes..."
    just --justfile {{ justfile() }} talos::_nodes

    echo "==> Bootstrapping Kubernetes Control Plane..."
    just --justfile {{ justfile() }} talos::_k8s

    echo "==> Fetching Initial Kubeconfig..."
    just --justfile {{ justfile() }} talos::_kubeconfig

    echo "==> Deploying Base Manifests and CRDs..."
    just --justfile {{ justfile() }} talos::_base

    echo "==> Syncing Initial Core Applications..."
    just --justfile {{ justfile() }} talos::_apps

[doc('Regenerate and validate the local talosconfig from 1Password secrets')]
[group('talos-config')]
rotate-talosconfig apply="false" node="" endpoint="" k8s_endpoint=("https://k8s." + CLUSTER + ".internal:6443"):
    op account get
    test -f {{ TALOS_DIR }}/machineconfig.yaml.j2
    test -f {{ TALOS_DIR }}/talosconfig
    which jq minijinja-cli op talosctl

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    NODE_VAL="{{ node }}"
    ENDPOINT_VAL="{{ endpoint }}"

    if [ -z "$NODE_VAL" ]; then NODE_VAL="$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output json | jq --raw-output '.nodes[0] // .endpoints[0]')"; fi
    if [ -z "$ENDPOINT_VAL" ]; then ENDPOINT_VAL="$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output json | jq --raw-output '.endpoints[0] // .nodes[0]')"; fi
    if [ -z "$NODE_VAL" ] || [ "$NODE_VAL" = "null" ] || [ -z "$ENDPOINT_VAL" ] || [ "$ENDPOINT_VAL" = "null" ]; then
        echo "Error: Unable to determine target node/endpoint dynamically." >&2
        exit 1
    fi

    CLUSTER={{ CLUSTER }} MACHINE_TYPE=controlplane SCHEMATIC="" minijinja-cli {{ TALOS_DIR }}/machineconfig.yaml.j2 | op inject > "$tmp_dir/controlplane.yaml"
    talosctl gen secrets --from-controlplane-config "$tmp_dir/controlplane.yaml" --output-file "$tmp_dir/secrets.yaml" --force
    talosctl gen config {{ CLUSTER }} {{ k8s_endpoint }} --with-secrets "$tmp_dir/secrets.yaml" --output-types talosconfig --output "$tmp_dir/talosconfig" --force
    talosctl --talosconfig "$tmp_dir/talosconfig" config endpoint "$ENDPOINT_VAL"
    talosctl --talosconfig "$tmp_dir/talosconfig" config node "$NODE_VAL"
    talosctl --talosconfig "$tmp_dir/talosconfig" --nodes "$NODE_VAL" get machinetypes

    if [ "{{ apply }}" = "true" ]; then
        backup="{{ TALOS_DIR }}/talosconfig.$(date +%Y%m%d%H%M%S).bak"
        cp {{ TALOS_DIR }}/talosconfig "$backup"
        cp "$tmp_dir/talosconfig" {{ TALOS_DIR }}/talosconfig
        echo "Successfully rotated local config. Backup saved to: $backup"
    else
        echo "Validation successful against node $NODE_VAL. Run with apply=true to commit changes."
    fi

[doc('Generate the context-bound kubeconfig manually using a shuffled endpoint')]
[group('kubernetes')]
kubeconfig:
    talosctl config info --talosconfig {{ TALOS_DIR }}/talosconfig
    test -f {{ TALOS_DIR }}/talosconfig
    which talosctl jq shuf
    TALOS_CONTROLLER="$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output json | jq --raw-output '.endpoints[]' | shuf -n 1)"
    talosctl kubeconfig --nodes "$TALOS_CONTROLLER" --force --force-context-name {{ CLUSTER }} {{ CLUSTER_DIR }}

[doc('Flatten and aggregate local kubectl configurations and merge target talosconfigs')]
[group('kubernetes')]
flatten:
    mkdir -p ~/.kube ~/.talos
    kubectl config view --flatten > ~/.kube/config
    cp {{ ROOT_DIR }}/talos/utility/talosconfig ~/.talos/config
    talosctl config merge {{ ROOT_DIR }}/talos/test/talosconfig --talosconfig ~/.talos/config
    talosctl config merge {{ ROOT_DIR }}/talos/main/talosconfig --talosconfig ~/.talos/config

# ==============================================================================
# OnePassword Distributed Secret Storage Management
# ==============================================================================

[doc('Validate local authenticated session presence to OnePassword')]
[group('onepassword')]
op:
    op account get

[doc('Export all locally compiled config structures safely into OnePassword secret vectors')]
[group('onepassword')]
push: op
    just --justfile {{ justfile() }} talos::flatten
    just --justfile {{ justfile() }} talos::push-clusters
    just --justfile {{ justfile() }} talos::push-combined

[doc('Push raw discrete cluster structures into structured 1Password schemas')]
[group('onepassword')]
push-clusters: op
    for cluster in {{ CLUSTERS }}; do
        CLUSTER_UPPER=$(echo "$cluster" | tr '[:lower:]' '[:upper:]')
        op item edit kubernetes KUBECONFIG_${CLUSTER_UPPER}[text]="$(cat {{ ROOT_DIR }}/kubernetes/clusters/$cluster/kubeconfig)" &>/dev/null
        op item edit kubernetes TALOSCONFIG_${CLUSTER_UPPER}[text]="$(cat {{ ROOT_DIR }}/talos/$cluster/talosconfig)" &>/dev/null
    done

[doc('Push integrated aggregated local states to OnePassword Vault structures')]
[group('onepassword')]
push-combined: op
    just --justfile {{ justfile() }} talos::flatten
    op item edit kubernetes KUBECONFIG[text]="$(cat ~/.kube/config)" &>/dev/null
    op item edit kubernetes KUBECONFIG_BASE64[text]="$(cat ~/.kube/config | base64 -w 0)" &>/dev/null
    op item edit kubernetes TALCONFIG[text]="$(cat ~/.talos/config)" &>/dev/null

[doc('Synchronize local context setups by importing configurations back from OnePassword')]
[group('onepassword')]
pull: op
    mkdir -p ~/.kube ~/.talos
    just --justfile {{ justfile() }} talos::pull-clusters
    op item get kubernetes --fields label=KUBECONFIG | tr -d '"' > ~/.kube/config
    op item get kubernetes --fields label=TALCONFIG | tr -d '"' > ~/.talos/config

[doc('Pull custom isolated cluster tracking profiles directly from remote vault infrastructure')]
[group('onepassword')]
pull-clusters: op
    for cluster in {{ CLUSTERS }}; do
        CLUSTER_UPPER=$(echo "$cluster" | tr '[:lower:]' '[:upper:]')
        mkdir -p {{ ROOT_DIR }}/kubernetes/clusters/$cluster {{ ROOT_DIR }}/talos/$cluster
        op item get kubernetes --fields label=KUBECONFIG_${CLUSTER_UPPER} | tr -d '"' > {{ ROOT_DIR }}/kubernetes/clusters/$cluster/kubeconfig
        op item get kubernetes --fields label=TALOSCONFIG_${CLUSTER_UPPER} | tr -d '"' > {{ ROOT_DIR }}/talos/$cluster/talosconfig
    done

# ==============================================================================
# Cluster Engine Pipeline Helpers (Internal Execution Targets)
# ==============================================================================

[private]
_nodes:
    talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info
    NODES=$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output yaml | yq -r '.nodes | join(" ")')
    for item in $NODES; do
        if ! out=$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig --nodes "$item" apply-config --insecure 2>&1); then
            if [[ "$out" == *"certificate required"* ]]; then
                echo "Talos already configured, skipping $item"
            else
                echo "$out" && exit 1
            fi
        fi
    done

[private]
_k8s:
    CONTROLLER=$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output yaml | yq -r '.endpoints[0]')
    until out=$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig --nodes "$CONTROLLER" bootstrap 2>&1 || true) && [[ "$out" == *"AlreadyExists"* ]]; do
        echo "Kubernetes bootstrap in progress, retrying in 5s..."
        sleep 5
    done

[private]
_kubeconfig:
    CONTROLLER=$(talosctl --talosconfig {{ TALOS_DIR }}/talosconfig config info --output yaml | yq -r '.endpoints[0]')
    talosctl --talosconfig {{ TALOS_DIR }}/talosconfig kubeconfig --nodes "$CONTROLLER" -f --force-context-name {{ CLUSTER }} {{ CLUSTER_DIR }}

[private]
_base:
    op account get
    test -f {{ BOOTSTRAP_DIR }}/kustomize/secrets.yaml.tpl
    test -f {{ BOOTSTRAP_DIR }}/helmfile/crds.yaml
    until kubectl --context {{ CLUSTER }} get nodes --no-headers 2>/dev/null | grep -q .; do
        echo "Waiting for nodes to register..."
        sleep 5
    done
    minijinja-cli {{ BOOTSTRAP_DIR }}/kustomize/secrets.yaml.tpl --cl-arg CLUSTER={{ CLUSTER }} | op inject | kubectl --context {{ CLUSTER }} apply --server-side --force-conflicts --filename -
    helmfile --file {{ BOOTSTRAP_DIR }}/helmfile/crds.yaml template \
        | yq ea -r -e 'select(.kind == "CustomResourceDefinition")' \
        | kubectl --context {{ CLUSTER }} apply --server-side --field-manager bootstrap --force-conflicts --filename -

[private]
_apps:
    test -f {{ BOOTSTRAP_DIR }}/helmfile/apps.yaml
    export CLUSTER="{{ CLUSTER }}"
    export CLUSTER_APPS="{{ CLUSTER_APPS }}"
    helmfile --kube-context {{ CLUSTER }} --file {{ BOOTSTRAP_DIR }}/helmfile/apps.yaml sync --hide-notes

### Architectural Design Matrix

### | Enhancement Feature | Original Taskfile State | Combined `mod.just` Implementation Strategy | Architectural Benefit |
### | :--- | :--- | :--- | :--- |
### | **BASH native blocks** | Multi-line string maps with backslash joins | Clean unescaped native code loops inside the recipes | Prevents syntax errors when mixing conditions, loops, and raw variables. |
### | **Task Module Scoping** | Sub-task inclusion macros (`task: :ns:subtask`) | Standard runtime path definitions (`just --justfile \{\{ justfile() \}\} talos::recipe`) | Explicit execution parameters pass down directly cleanly across nested scopes. |
### | **Namespace Isolation** | `internal: true` rules | `[private]` attribute headers | Hides multi-step engine bootstrap components completely from regular listings. |
### | **Operational Guarding** | `preconditions:` block evaluation loops | Sequential terminal check short-circuits (`which kubectl`, `test -f`) | Halts command chains gracefully instantly when a dependency is missing. |
