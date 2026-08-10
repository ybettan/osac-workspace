#!/usr/bin/env bash
#
# E2E test for agentless networking lab.
# Requires: ./setup-lab.sh completed (OSAC running, agents registered)
#
# Usage:
#   ./test-e2e.sh            Run E2E tests
#   ./test-e2e.sh destroy    Delete test clusters
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="${SCRIPT_DIR}/osac-installer"
PULL_SECRET="${INSTALLER_DIR}/values/agentless-net-lab/pull-secret.json"
MGMT_CLONE_NAME="agentless-lab-mgmt"
KUBECONFIG_PATH="$HOME/.kube/${MGMT_CLONE_NAME}.kubeconfig"
OSAC_NS="osac-e2e-ci"

CLUSTER_TEMPLATE="osac.templates.ocp_ci_small"
CLUSTER_NAMES=("cluster-1" "cluster-2")

# ---------- helpers ----------

info()  { echo "==> $*"; }

cluster_exists() {
    local name="$1"
    local result
    result=$(osac get cluster "$name" -o json 2>/dev/null)
    [ "$result" != "[]" ] && [ -n "$result" ]
}

cluster_id_by_name() {
    local name="$1"
    osac get clusters -o json | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    if c.get('name') == '${name}':
        print(c['id']); break
"
}

export KUBECONFIG="$KUBECONFIG_PATH"

# ---------- destroy ----------

if [ "${1:-}" = "destroy" ]; then
    info "Deleting test clusters..."
    for name in "${CLUSTER_NAMES[@]}"; do
        if cluster_exists "$name"; then
            osac delete cluster "$name"
            info "  Deleted $name"
        else
            echo "  $name does not exist — skipping"
        fi
    done

    info "Waiting for clusters to be fully removed..."
    for name in "${CLUSTER_NAMES[@]}"; do
        elapsed=0
        while cluster_exists "$name"; do
            sleep 15; elapsed=$((elapsed + 15))
            if [ "$elapsed" -ge 600 ]; then
                echo "WARNING: $name still exists after ${elapsed}s"
                break
            fi
        done
    done

    info "Done."
    exit 0
fi

# ---------- preflight checks ----------

info "Running preflight checks..."

if ! oc get deploy/fulfillment-grpc-server -n "$OSAC_NS" 2>/dev/null | grep -q "1/1"; then
    echo "ERROR: OSAC is not running. Run ./setup-lab.sh first."
    exit 1
fi

AGENT_COUNT=$(oc get agent -n hardware-inventory --no-headers 2>/dev/null | wc -l)
if [ "$AGENT_COUNT" -lt "${#CLUSTER_NAMES[@]}" ]; then
    echo "ERROR: Need at least ${#CLUSTER_NAMES[@]} agents, found ${AGENT_COUNT}"
    exit 1
fi

info "OSAC running, ${AGENT_COUNT} agents available"

# ---------- step 1: create clusters ----------

info "Creating clusters..."
CLUSTER_IDS=()
for name in "${CLUSTER_NAMES[@]}"; do
    if cluster_exists "$name"; then
        echo "  $name already exists — skipping creation"
        CLUSTER_ID=$(cluster_id_by_name "$name")
    else
        CREATE_OUT=$(osac create cluster \
            --template "$CLUSTER_TEMPLATE" \
            -f pull_secret="$PULL_SECRET" \
            --name "$name" 2>&1)
        CLUSTER_ID=$(echo "$CREATE_OUT" | grep -oP '[0-9a-f-]{36}' | head -1)
        echo "  Created $name (ID: $CLUSTER_ID)"
    fi
    CLUSTER_IDS+=("$CLUSTER_ID")
done

# ---------- step 1b: fix DNS for hosted cluster pods ----------
#
# Two DNS fixes needed after clusters are created:
#
# 1. The libvirt dnsmasq *.apps wildcard resolves to the management VM's
#    management NIC IP (192.168.162.x). After NMState, pods route via the
#    data NIC and can't reach that IP. Rewrite to the fabric IP (10.0.0.10).
#    This must happen AFTER agent boot (agents need *.apps on the mgmt net
#    to download the rootfs image during initial boot).
#
# 2. CoreDNS pods run inside OVN and forward DNS to the worker's
#    /etc/resolv.conf (192.168.162.1, libvirt dnsmasq). OVN traffic exits
#    via the data NIC default route, which has no path to the management
#    network. With hostNetwork, CoreDNS can reach the DNS server directly
#    on the management NIC (L2 adjacent).

MGMT_CLONE_NAME="agentless-lab-mgmt"
MGMT_LIBVIRT_NET="test-infra-net-${MGMT_CLONE_NAME}"
DNSMASQ_CONF="/var/lib/libvirt/dnsmasq/${MGMT_LIBVIRT_NET}.conf"
MGMT_FABRIC_IP="10.0.0.10"

info "Fixing DNS *.apps to resolve to fabric IP (${MGMT_FABRIC_IP})..."
if grep -q "address=/.apps\..*/${MGMT_FABRIC_IP}" "$DNSMASQ_CONF" 2>/dev/null; then
    echo "  Already fixed — skipping"
else
    sed -i "s|address=/.apps\.\(.*\)/.*|address=/.apps.\1/${MGMT_FABRIC_IP}|" "$DNSMASQ_CONF"
    if [ -f /var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid ]; then
        xargs kill < /var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid 2>/dev/null || true
        sleep 1
        DNSMASQ_BRIDGE=$(virsh net-info "$MGMT_LIBVIRT_NET" 2>/dev/null | awk '/^Bridge:/{print $2}')
        DNSMASQ_INTERFACE="$DNSMASQ_BRIDGE" /usr/sbin/dnsmasq \
            --conf-file="$DNSMASQ_CONF" --leasefile-ro \
            --dhcp-script=/usr/libexec/libvirt_leaseshelper
        pgrep -f "dnsmasq.*${MGMT_LIBVIRT_NET}" > "/var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid"
    fi
    echo "  Updated libvirt dnsmasq"
fi

# ---------- step 2: wait for clusters to be ready ----------
#
# While polling, patch CoreDNS to use hostNetwork on each hosted cluster
# once it becomes available. CoreDNS deploys after the worker joins, so
# we can't do this before the wait loop.

patch_coredns() {
    local order_name="$1"
    local hc_ns="${OSAC_NS}-${order_name}"
    local kc_secret="${order_name}-admin-kubeconfig"
    local guest_kc
    guest_kc=$(mktemp)

    oc get secret "$kc_secret" -n "$hc_ns" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$guest_kc" 2>/dev/null
    if [ ! -s "$guest_kc" ]; then
        rm -f "$guest_kc"
        return 1
    fi

    if ! KUBECONFIG="$guest_kc" oc get ds dns-default -n openshift-dns &>/dev/null 2>&1; then
        rm -f "$guest_kc"
        return 1
    fi

    KUBECONFIG="$guest_kc" oc patch daemonset dns-default -n openshift-dns \
        --type=strategic -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}' 2>/dev/null
    echo "  Patched CoreDNS hostNetwork on $order_name"
    rm -f "$guest_kc"
    return 0
}

info "Waiting for clusters to reach READY state (this may take 30-60 minutes)..."
COREDNS_PATCHED=""
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    id="${CLUSTER_IDS[$i]}"

    elapsed=0
    while true; do
        state=$(osac get cluster "$id" -o json | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('state',''))" 2>/dev/null) || true

        if [ "$state" = "CLUSTER_STATE_READY" ]; then
            info "$name is READY"
            break
        fi

        if [ "$state" = "CLUSTER_STATE_FAILED" ]; then
            echo "ERROR: $name FAILED"
            osac get cluster "$id" -o yaml
            exit 1
        fi

        # Start any VMs powered off by the assisted-installer (no BMC in lab)
        for vm in host-1 host-2 host-3; do
            if virsh domstate "$vm" 2>/dev/null | grep -q "shut off"; then
                virsh start "$vm" 2>/dev/null && echo "  Restarted $vm (powered off by installer)"
            fi
        done

        # Patch CoreDNS to hostNetwork once worker joins (one-shot per cluster)
        for ORDER_NAME in $(oc get clusterorder -n "$OSAC_NS" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null); do
            if ! echo "$COREDNS_PATCHED" | grep -qw "$ORDER_NAME"; then
                if patch_coredns "$ORDER_NAME"; then
                    COREDNS_PATCHED="$COREDNS_PATCHED $ORDER_NAME"
                fi
            fi
        done

        sleep 60; elapsed=$((elapsed + 60))
        echo "  ${elapsed}s — $name state: $state"

        if [ "$elapsed" -ge 3600 ]; then
            echo "ERROR: $name not ready after ${elapsed}s (state: $state)"
            exit 1
        fi
    done
done

info "All clusters ready"

# ---------- step 3: retrieve kubeconfigs ----------

info "Retrieving kubeconfigs..."
KUBECONFIG_DIR="/tmp/agentless-net-lab"
mkdir -p "$KUBECONFIG_DIR"
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    id="${CLUSTER_IDS[$i]}"
    osac get kubeconfig "$id" > "$KUBECONFIG_DIR/${name}.kubeconfig"
    echo "  $name: $KUBECONFIG_DIR/${name}.kubeconfig"
done

# ---------- step 4: validate clusters ----------

info "Validating clusters..."
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    NODE_COUNT=$(KUBECONFIG="$KC" oc get nodes --no-headers 2>/dev/null | wc -l)
    echo "  $name: $NODE_COUNT nodes"
    KUBECONFIG="$KC" oc get nodes -o wide 2>/dev/null
done

# ---------- step 5: test network isolation ----------

TEST_IMAGE="quay.io/openshift/origin-cli:4.17"

info "Deploying test pods..."
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    KUBECONFIG="$KC" oc run test-net --image="$TEST_IMAGE" \
        --restart=Never --command -- sleep 3600 2>/dev/null || true
done

info "Waiting for test pods to be ready..."
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    KUBECONFIG="$KC" oc wait pod/test-net --for=condition=Ready --timeout=120s
done

POD_IPS=()
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    ip=$(KUBECONFIG="$KC" oc get pod test-net -o jsonpath='{.status.podIP}')
    POD_IPS+=("$ip")
    echo "  $name test pod: $ip"
done

info "Testing self-connectivity (should pass)..."
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    if KUBECONFIG="$KC" oc exec test-net -- \
        curl -sk --connect-timeout 3 https://kubernetes.default.svc:443/healthz 2>&1 | grep -q "ok"; then
        echo "  $name: self-connectivity OK"
    else
        echo "ERROR: $name cannot reach its own API"
        exit 1
    fi
done

info "Testing cross-cluster isolation (should fail)..."
ISOLATED=true
for i in "${!CLUSTER_NAMES[@]}"; do
    name="${CLUSTER_NAMES[$i]}"
    KC="$KUBECONFIG_DIR/${name}.kubeconfig"
    for j in "${!CLUSTER_NAMES[@]}"; do
        [ "$i" = "$j" ] && continue
        other="${CLUSTER_NAMES[$j]}"
        other_ip="${POD_IPS[$j]}"
        if KUBECONFIG="$KC" oc exec test-net -- \
            curl -s --connect-timeout 3 "http://${other_ip}:8080" &>/dev/null; then
            echo "  ERROR: $name can reach $other ($other_ip) — isolation BROKEN"
            ISOLATED=false
        else
            echo "  $name cannot reach $other ($other_ip) — isolated OK"
        fi
    done
done

info "Cleaning up test pods..."
for i in "${!CLUSTER_NAMES[@]}"; do
    KC="$KUBECONFIG_DIR/${CLUSTER_NAMES[$i]}.kubeconfig"
    KUBECONFIG="$KC" oc delete pod test-net --ignore-not-found 2>/dev/null
done

if [ "$ISOLATED" = "false" ]; then
    echo "ERROR: Cross-cluster isolation test failed"
    exit 1
fi

info "E2E test complete."
