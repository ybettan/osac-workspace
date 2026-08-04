#!/usr/bin/env bash
#
# Run WITHOUT sudo: ./setup-lab.sh
# The script uses sudo internally only for containerlab commands.
#
# Usage:
#   ./setup-lab.sh            Deploy lab infrastructure
#   ./setup-lab.sh destroy    Tear down the lab
#
# The agentless_net.l2, agentless_net.l3, and agentless_net.ipam collections live in osac-aap.
# The ansible_network.network_runner collection is vendored in osac-aap.
# Override OSAC_AAP_DIR to point to a different clone.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# mgmt-server
MGMT_CLONE_NAME="agentless-lab-mgmt"
MGMT_IMAGE="${MGMT_IMAGE:-quay.io/osac-project/cluster-flavors:caas-4-22}"
INSTALLER_DIR="${SCRIPT_DIR}/osac-installer"
PULL_SECRET="${INSTALLER_DIR}/values/agentless-net-lab/pull-secret.json"

# Containerlab
TOPO_FILE="${SCRIPT_DIR}/agentless-net-lab.clab.yml"
LAB_NAME="agentless-net-lab"
PREFIX="clab-${LAB_NAME}"
CONTAINERLAB="${CONTAINERLAB:-containerlab}"
SWITCHES=("${PREFIX}-leaf-1" "${PREFIX}-leaf-2")
NET_NODE="${PREFIX}-net-node"
UPSTREAM_ROUTER="${PREFIX}-upstream-router"

# BGP peering link (net-node:eth2 <-> upstream-router:eth1)
BGP_NET_NODE_IP="10.253.0.1/30"
BGP_UPSTREAM_IP="10.253.0.2/30"
BGP_NET_NODE_AS=65001
BGP_UPSTREAM_AS=65000

# Host VMs
VM_DIR="/var/lib/libvirt/images/${LAB_NAME}"
VM_VCPUS=4
VM_MEMORY=16384   # MB
VM_DISK_SIZE=100  # GB
HOST_VMS=("host-1" "host-2" "host-3")
HOST_BRIDGES=("br-host1" "br-host2" "br-host3")
HOST_VETHS=("leaf1-swp2" "leaf2-swp2" "leaf2-swp3")

# Agent registration
AGENT_RESOURCE_CLASS="ci-worker"
AGENT_NAMESPACE="hardware-inventory"
INFRAENV_NAME="infraenv"
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || true)"

# Ansible paths
OSAC_AAP_DIR="${OSAC_AAP_DIR:-${SCRIPT_DIR}/osac-aap}"
export ANSIBLE_COLLECTIONS_PATH="${OSAC_AAP_DIR}/collections:${OSAC_AAP_DIR}/vendor"
INVENTORY="${SCRIPT_DIR}/ansible/inventory.yml"

# ---------- helpers ----------

info()  { echo "==> $*"; }

MGMT_LIBVIRT_NET="test-infra-net-${MGMT_CLONE_NAME}"
MGMT_VM_NAME="test-infra-cluster-${MGMT_CLONE_NAME}-master-0"
KUBECONFIG_PATH="$HOME/.kube/${MGMT_CLONE_NAME}.kubeconfig"
export KUBECONFIG="$KUBECONFIG_PATH"
OSAC_NS="osac-e2e-ci"

resolve_mgmt_network() {
    MGMT_BRIDGE=$(virsh net-info "$MGMT_LIBVIRT_NET" | awk '/^Bridge:/{print $2}')
    MGMT_SUBNET_OCTET=$(virsh net-dumpxml "$MGMT_LIBVIRT_NET" | grep -oP "address='192\.168\.\K[0-9]+")
    MGMT_PREFIX="192.168.${MGMT_SUBNET_OCTET}"
    MGMT_CIDR="${MGMT_PREFIX}.0/24"
    MGMT_GW="${MGMT_PREFIX}.1"
    export MGMT_BRIDGE MGMT_CIDR MGMT_GW MGMT_PREFIX
}

# ---------- destroy ----------

if [ "${1:-}" = "destroy" ]; then
    info "Destroying lab..."

    # Destroy host VMs
    for vm in "${HOST_VMS[@]}"; do
        if virsh dominfo "$vm" &>/dev/null; then
            virsh destroy "$vm" 2>/dev/null || true
            virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
            info "  Removed VM $vm"
        fi
    done

    # Remove bridges (host VMs + mgmt data-plane)
    for br in "${HOST_BRIDGES[@]}" br-mgmt; do
        if ip link show "$br" &>/dev/null; then
            sudo ip link set "$br" down 2>/dev/null || true
            sudo ip link delete "$br" 2>/dev/null || true
            info "  Removed bridge $br"
        fi
    done

    # Destroy containerlab (needs MGMT_* env vars to parse clab.yml)
    if docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-"; then
        resolve_mgmt_network
        sudo MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_CIDR="$MGMT_CIDR" MGMT_GW="$MGMT_GW" MGMT_PREFIX="$MGMT_PREFIX" \
            ${CONTAINERLAB} destroy -t "$TOPO_FILE" --cleanup
        info "  Removed containerlab"
    fi

    # Clean up VM disks
    rm -rf "$VM_DIR"

    # Kill stale dnsmasq from DNS fix (may outlive libvirt network)
    pkill -f "dnsmasq.*${MGMT_LIBVIRT_NET}" 2>/dev/null || true

    # Destroy mgmt-server
    if command -v cluster-tool &>/dev/null; then
        cluster-tool destroy "$MGMT_CLONE_NAME" 2>/dev/null || true
        info "  Removed mgmt-server"
    fi

    # Remove iptables FORWARD rules
    iptables -D FORWARD -s 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 10.0.0.0/8 -j ACCEPT 2>/dev/null || true

    info "Done."
    exit 0
fi

# ============================================================
# MGMT-SERVER (OpenShift SNO from snapshot via cluster-tool)
# ============================================================

# Docker (used by containerlab) sets the iptables FORWARD chain policy to DROP.
# Libvirt (used by cluster-tool) creates NAT rules in nftables, but iptables
# and nftables are evaluated independently — Docker's DROP overrides libvirt's
# nftables ACCEPT, leaving VMs with no internet access.
# The 192.168.0.0/16 rule covers the management network (libvirt VMs).
# The 10.0.0.0/8 rule covers the VLAN data network (worker data NICs bridged
# to containerlab switches via br-host* bridges).
if iptables -S FORWARD 2>/dev/null | grep -q "\-P FORWARD DROP"; then
    if ! iptables -C FORWARD -s 192.168.0.0/16 -j ACCEPT 2>/dev/null; then
        info "Adding iptables FORWARD rules for libvirt VMs..."
        iptables -I FORWARD -s 192.168.0.0/16 -j ACCEPT
        iptables -I FORWARD -d 192.168.0.0/16 -j ACCEPT
        iptables -I FORWARD -s 10.0.0.0/8 -j ACCEPT
        iptables -I FORWARD -d 10.0.0.0/8 -j ACCEPT
    fi
fi

# ---------- step 1: setup cluster-tool (one-time) ----------

if ! cluster-tool servers 2>/dev/null | grep -q "local"; then
    info "Setting up cluster-tool..."
    cluster-tool connect local --host local --data-path /var/lib/cluster-tool
    sudo cluster-tool setup client
fi

# ---------- step 2: pull snapshot flavor ----------

if cluster-tool flavors 2>/dev/null | grep -q "caas-4-22"; then
    info "Snapshot flavor 'caas-4-22' already pulled — skipping"
else
    info "Pulling mgmt-server snapshot..."
    cluster-tool pull "$MGMT_IMAGE"
fi

# ---------- step 3: boot mgmt-server ----------

if virsh dominfo "$MGMT_VM_NAME" &>/dev/null; then
    info "mgmt-server already running — skipping boot"
else
    info "Booting mgmt-server (this may take several minutes)..."
    cluster-tool boot --flavor caas-4-22 --name "$MGMT_CLONE_NAME" --pull-secret "$PULL_SECRET"
fi

# ---------- step 4: resolve management network ----------

resolve_mgmt_network
info "Management network: ${MGMT_CIDR} on bridge ${MGMT_BRIDGE}"

# ---------- step 5: fix DNS forwarding for hosted clusters ----------
#
# Workers resolve DNS via two layers:
#   Layer 1: libvirt dnsmasq (192.168.X.1) — the workers' DNS server (set by DHCP)
#   Layer 2: NetworkManager dnsmasq (127.0.0.1) — libvirt dnsmasq's upstream
#
# Two fixes are needed so hosted cluster API hostnames (created in Route 53
# by the external_access AAP role) reach the workers correctly:
#
# Fix A (layer 1): cluster-tool creates the libvirt network with localOnly='yes'
# on the mgmt cluster's domain, which prevents the libvirt dnsmasq from
# forwarding *.hosted.<domain> queries to upstream. Flip to localOnly='no'.
#
# Fix B (layer 2): cluster-tool adds a NetworkManager dnsmasq wildcard
# (address=/<domain>/<public-ip>) that catches ALL subdomains — including
# *.hosted.<domain> — and returns the bare-metal host's public IP instead
# of forwarding to Route 53. Add a server= directive so *.hosted.<domain>
# queries bypass the wildcard and are forwarded to upstream DNS.

DNSMASQ_CONF="/var/lib/libvirt/dnsmasq/${MGMT_LIBVIRT_NET}.conf"
if grep -q "^local=/" "$DNSMASQ_CONF" 2>/dev/null; then
    info "Fixing DNS forwarding on ${MGMT_LIBVIRT_NET}..."
    NET_XML=$(mktemp)
    virsh net-dumpxml "$MGMT_LIBVIRT_NET" > "$NET_XML"
    sed -i "s/localOnly='yes'/localOnly='no'/" "$NET_XML"
    virsh net-define "$NET_XML"
    rm -f "$NET_XML"
    sed -i '/^local=/d' "$DNSMASQ_CONF"
    if [ -f /var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid ]; then
        xargs kill < /var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid 2>/dev/null || true
        sleep 1
        DNSMASQ_BRIDGE=$(virsh net-info "$MGMT_LIBVIRT_NET" 2>/dev/null | awk '/^Bridge:/{print $2}')
        DNSMASQ_INTERFACE="$DNSMASQ_BRIDGE" /usr/sbin/dnsmasq \
            --conf-file="$DNSMASQ_CONF" --leasefile-ro \
            --dhcp-script=/usr/libexec/libvirt_leaseshelper
        pgrep -f "dnsmasq.*${MGMT_LIBVIRT_NET}" > "/var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid"
    fi
else
    info "DNS forwarding (layer 1) already fixed — skipping"
fi

# Fix B: bypass cluster-tool wildcard for hosted cluster subdomains
NM_DNSMASQ_CONF="/etc/NetworkManager/dnsmasq.d/cluster-${MGMT_CLONE_NAME}.conf"
HOSTED_DOMAIN="hosted.test-infra-cluster-${MGMT_CLONE_NAME}.redhat.com"

if [ -f "$NM_DNSMASQ_CONF" ] && ! grep -q "server=/${HOSTED_DOMAIN}/" "$NM_DNSMASQ_CONF" 2>/dev/null; then
    info "Bypassing DNS wildcard for ${HOSTED_DOMAIN}..."
    echo "server=/${HOSTED_DOMAIN}/8.8.8.8" >> "$NM_DNSMASQ_CONF"
    systemctl restart NetworkManager
else
    info "DNS forwarding (layer 2) already fixed — skipping"
fi

# ---------- step 5c: enable IP forwarding on management VM ----------
#
# The hosted clusters' kube-apiserver pods run inside OVN on the management
# VM (br-ex, 192.168.180.x). MetalLB announces their VIPs on the management
# network (192.168.X.240-250) and iptables DNAT rules rewrite incoming
# packets to the pod IPs. But the kernel must forward these packets from
# the management NIC (enp1s0) into the OVN data network — which requires
# ip_forward=1. OVN disables it by default because OVN's own datapath
# doesn't need kernel forwarding.

info "Enabling IP forwarding on management VM..."
KUBECONFIG="$KUBECONFIG" oc debug node/"$(KUBECONFIG="$KUBECONFIG" oc get node -o jsonpath='{.items[0].metadata.name}')" \
    -- chroot /host bash -c '
    if [ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]; then
        sysctl -w net.ipv4.ip_forward=1
    else
        echo "ip_forward already enabled"
    fi
' 2>&1 | tail -3

# ============================================================
# OSAC REFRESH (bring snapshot cluster back to life)
# ============================================================

# ---------- step 6: init osac-installer submodules ----------

if [ -d "$INSTALLER_DIR/base/osac-operator/.git" ]; then
    info "osac-installer submodules already initialized — skipping"
else
    info "Initializing osac-installer submodules..."
    git -C "$INSTALLER_DIR" submodule update --init --recursive
fi

# ---------- step 7: remove stale APIService ----------
#
# The snapshot registers an APIService for console.osac.openshift.io backed by
# the osac-operator-console-proxy. The proxy isn't running until helm deploys
# the operator, but helm can't run until AAP reconciles, and the stale
# APIService blocks AAP's ansible proxy API discovery. Delete it to break
# the deadlock; helm recreates it when it deploys the operator.

KUBECONFIG="$KUBECONFIG" oc delete apiservice v1alpha1.console.osac.openshift.io \
    --ignore-not-found 2>/dev/null || true

# ---------- step 8: refresh OSAC ----------

if KUBECONFIG="$KUBECONFIG" oc get deploy/fulfillment-grpc-server -n "$OSAC_NS" 2>/dev/null | grep -q "1/1"; then
    info "OSAC already running — skipping refresh"
else
    info "Refreshing OSAC (this may take several minutes)..."
    (cd "$INSTALLER_DIR" && \
        KUBECONFIG="$KUBECONFIG" \
        VALUES_FILE=values/agentless-net-lab/values.yaml \
        INSTALLER_NAMESPACE="$OSAC_NS" \
        python3 scripts/refresh-after-snapshot.py)
fi

# ---------- step 9: patch DNS credentials ----------

DNS_CREDS="${HOME}/.config/osac/aws-dns-credentials"
if [ -f "$DNS_CREDS" ]; then
    info "Patching cluster-fulfillment-ig with DNS credentials..."
    # shellcheck source=/dev/null
    source "$DNS_CREDS"
    KUBECONFIG="$KUBECONFIG" oc patch secret cluster-fulfillment-ig -n "$OSAC_NS" --type merge \
        -p "{\"data\":{\"AWS_ACCESS_KEY_ID\":\"$(echo -n "$AWS_ACCESS_KEY_ID" | base64)\",\"AWS_SECRET_ACCESS_KEY\":\"$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64)\"}}"
else
    echo "  WARN: ${DNS_CREDS} not found — DNS (Route 53) will not work."
    echo "  Create the file with:"
    echo "    AWS_ACCESS_KEY_ID=..."
    echo "    AWS_SECRET_ACCESS_KEY=..."
fi

# ---------- step 9b: patch SSH key for NMState live apply ----------
#
# The cluster_infra role applies NMState config to discovery agents via SSH.
# The agents accept the InfraEnv's sshAuthorizedKey (our host's public key).
# Inject the matching private key so the AAP runner pod can SSH to agents.

SSH_PRIVATE_KEY="${HOME}/.ssh/id_rsa"
if [ -f "$SSH_PRIVATE_KEY" ]; then
    info "Patching cluster-fulfillment-ig with SSH key..."
    KUBECONFIG="$KUBECONFIG" oc patch secret cluster-fulfillment-ig -n "$OSAC_NS" --type merge \
        -p "{\"data\":{\"SERVER_SSH_KEY\":\"$(base64 -w0 < "$SSH_PRIVATE_KEY")\"}}"
else
    echo "  WARN: ${SSH_PRIVATE_KEY} not found — NMState live apply will not work."
fi

# ---------- step 10: validate OSAC ----------

info "Validating OSAC..."
KUBECONFIG="$KUBECONFIG" oc wait deploy/fulfillment-grpc-server -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
KUBECONFIG="$KUBECONFIG" oc wait deploy/osac-operator -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
info "OSAC is running:"
KUBECONFIG="$KUBECONFIG" oc get pods -n "$OSAC_NS" --no-headers | \
    awk '{print $3}' | sort | uniq -c | sort -rn

# ---------- step 10b: route kube-apiserver VIPs through fabric ----------
#
# MetalLB's configure-metallb.sh auto-configures the pool from the node's
# InternalIP (192.168.X.240-250 on the mgmt network). Override to use
# the native VLAN subnet so kube-apiserver traffic goes through the switch
# fabric instead of the management network.
# The mgmt VM data NIC IP and L2Advertisement are configured after step 14
# (the data NIC doesn't exist until br-mgmt is created).

info "Patching MetalLB to use fabric subnet..."
KUBECONFIG="$KUBECONFIG" oc patch ipaddresspool caas-address-pool -n metallb-system \
    --type=merge -p '{"spec":{"addresses":["10.0.0.240-10.0.0.250"]}}'
echo "  Pool: 10.0.0.240-10.0.0.250"

# ---------- step 11: patch AAP instance group for lab networking ----------
#
# The cluster-fulfillment runner pods need hostNetwork to reach containerlab
# nodes on the libvirt bridge (OVN egresses through br-ex which has no path
# to the management subnet).

AAP_TOKEN=$(KUBECONFIG="$KUBECONFIG" oc exec deploy/osac-operator -n "$OSAC_NS" -- \
    sh -c 'echo $OSAC_AAP_TOKEN' 2>/dev/null)
AAP_ROUTE=$(KUBECONFIG="$KUBECONFIG" oc get route osac-aap -n "$OSAC_NS" -o jsonpath='{.spec.host}')

info "Patching cluster-fulfillment instance group (hostNetwork + agentless-net inventory)..."
python3 -c "
import json, yaml, urllib.request, ssl, sys

token, route = sys.argv[1], sys.argv[2]
url = f'https://{route}/api/controller/v2/instance_groups/3/'
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
current = json.loads(urllib.request.urlopen(req, context=ctx).read())
spec = yaml.safe_load(current['pod_spec_override'])
changed = False

if not spec['spec'].get('hostNetwork'):
    spec['spec']['hostNetwork'] = True
    changed = True

for c in spec['spec'].get('containers', []):
    if c.get('name') == 'worker':
        mounts = c.get('volumeMounts', [])
        if not any(m.get('name') == 'agentless-net-inventory' for m in mounts):
            mounts.append({'name': 'agentless-net-inventory', 'mountPath': '/var/config/agentless-net', 'readOnly': True})
            changed = True

volumes = spec['spec'].get('volumes', [])
if not any(v.get('name') == 'agentless-net-inventory' for v in volumes):
    volumes.append({'name': 'agentless-net-inventory', 'configMap': {'name': 'agentless-net-inventory', 'optional': True}})
    changed = True

if changed:
    data = json.dumps({'pod_spec_override': yaml.dump(spec, default_flow_style=False)}).encode()
    req = urllib.request.Request(url, data=data, method='PATCH',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    urllib.request.urlopen(req, context=ctx)
    print('  Patched')
else:
    print('  Already patched — skipping')
" "$AAP_TOKEN" "$AAP_ROUTE"

# ---------- step 11b: patch AAP project to use fork ----------
#
# The snapshot's AAP project points to osac-project/osac-aap at a pinned
# commit. Override it to use the agentless-net branch from the fork which
# has the hostNetwork fix and agentless_net collection updates.
# Goes away once the changes are merged upstream.

AAP_PROJECT_GIT_URI="https://github.com/ybettan/osac-aap"
AAP_PROJECT_GIT_BRANCH="agentless-net"

info "Patching AAP project to ${AAP_PROJECT_GIT_URI} (${AAP_PROJECT_GIT_BRANCH})..."
python3 -c "
import json, urllib.request, ssl, sys

token, route, git_uri, git_branch = sys.argv[1:5]
url = f'https://{route}/api/controller/v2/projects/8/'
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
current = json.loads(urllib.request.urlopen(req, context=ctx).read())

if current['scm_url'] == git_uri and current['scm_branch'] == git_branch:
    print('  Already patched — skipping')
else:
    data = json.dumps({'scm_url': git_uri, 'scm_branch': git_branch}).encode()
    req = urllib.request.Request(url, data=data, method='PATCH',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    urllib.request.urlopen(req, context=ctx)
    # Trigger project sync
    sync_url = f'https://{route}/api/controller/v2/projects/8/update/'
    req = urllib.request.Request(sync_url, data=b'', method='POST',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    urllib.request.urlopen(req, context=ctx)
    print('  Patched and syncing')
" "$AAP_TOKEN" "$AAP_ROUTE" "$AAP_PROJECT_GIT_URI" "$AAP_PROJECT_GIT_BRANCH"

info "Waiting for AAP project sync..."
elapsed=0
while true; do
    status=$(python3 -c "
import json, urllib.request, ssl, sys
token, route = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
req = urllib.request.Request(
    f'https://{route}/api/controller/v2/projects/8/',
    headers={'Authorization': f'Bearer {token}'})
print(json.loads(urllib.request.urlopen(req, context=ctx).read()).get('status',''))
" "$AAP_TOKEN" "$AAP_ROUTE" 2>/dev/null)
    if [ "$status" = "successful" ]; then
        info "  AAP project synced"
        break
    fi
    if [ "$status" = "failed" ] || [ "$status" = "error" ]; then
        echo "  WARN: sync failed (${status}), retrying..."
        python3 -c "
import urllib.request, ssl, sys
token, route = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
req = urllib.request.Request(
    f'https://{route}/api/controller/v2/projects/8/update/',
    data=b'', method='POST',
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
urllib.request.urlopen(req, context=ctx)
" "$AAP_TOKEN" "$AAP_ROUTE" 2>/dev/null
    fi
    sleep 10; elapsed=$((elapsed + 10))
    if [ "$elapsed" -ge 120 ]; then
        echo "ERROR: AAP project sync not successful after ${elapsed}s (status: ${status})"
        exit 1
    fi
done

# ============================================================
# CONTAINERLAB (switch fabric + network nodes)
# ============================================================

# ---------- step 11: deploy containerlab ----------

if docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-leaf-1$"; then
    info "Lab already running — skipping deploy"
else
    info "Deploying Containerlab topology..."
    sudo MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_CIDR="$MGMT_CIDR" MGMT_GW="$MGMT_GW" MGMT_PREFIX="$MGMT_PREFIX" \
        ${CONTAINERLAB} deploy -t "$TOPO_FILE"
fi

# ---------- step 12: wait for switches ----------

wait_for_switch() {
    local sw="$1"
    local elapsed=0
    while ! docker exec "$sw" nv show system 2>/dev/null | grep -q "hostname" ; do
        sleep 3; elapsed=$((elapsed + 3))
        [ "$elapsed" -ge 90 ] && break
    done
    local mgmt_ip
    mgmt_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$sw")
    while ! sshpass -p cumulus ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 cumulus@"$mgmt_ip" true &>/dev/null; do
        sleep 3; elapsed=$((elapsed + 3))
        [ "$elapsed" -ge 120 ] && break
    done
}

info "Waiting for Cumulus switches to be ready (parallel)..."
for sw in "${SWITCHES[@]}"; do
    wait_for_switch "$sw" &
done
wait
info "All switches ready."

# ---------- step 13: fix sudo on switches ----------

info "Fixing sudo permissions on switches..."
for sw in "${SWITCHES[@]}"; do
    docker exec "$sw" bash -c \
        "echo 'cumulus ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cumulus && chmod 440 /etc/sudoers.d/cumulus"
    echo "  Fixed $sw"
done

# ---------- step 14: attach mgmt VM to switch fabric ----------

if ip link show br-mgmt &>/dev/null; then
    info "br-mgmt already exists — skipping"
else
    info "Creating br-mgmt and attaching mgmt VM to switch fabric..."
    sudo ip link add br-mgmt type bridge
    sudo ip link set leaf1-swp4 master br-mgmt
    sudo ip link set br-mgmt up
    virsh attach-interface "$MGMT_VM_NAME" bridge br-mgmt --model virtio --live --persistent
fi

# Assign native VLAN IP on the mgmt VM's fabric NIC and configure MetalLB
# to announce VIPs on it. Find the NIC by its MAC (br-mgmt bridge member).
FABRIC_MAC=$(virsh domiflist "$MGMT_VM_NAME" | grep br-mgmt | awk '{print $5}')
MGMT_NODE=$(KUBECONFIG="$KUBECONFIG" oc get nodes -o name | head -1 | cut -d/ -f2)
FABRIC_NIC=$(KUBECONFIG="$KUBECONFIG" oc debug "node/$MGMT_NODE" -- \
    nsenter -t 1 -n ip -o link show 2>&1 | grep "$FABRIC_MAC" | awk -F'[ :]+' '{print $2}')

info "Assigning native VLAN IP on mgmt VM data NIC ($FABRIC_NIC)..."
KUBECONFIG="$KUBECONFIG" oc debug "node/$MGMT_NODE" -- \
    nsenter -t 1 -n ip addr replace 10.0.0.10/24 dev "$FABRIC_NIC"
echo "  mgmt VM $FABRIC_NIC = 10.0.0.10/24 (native VLAN)"

KUBECONFIG="$KUBECONFIG" oc patch l2advertisement caas-l2-advertisement -n metallb-system \
    --type=merge -p "{\"spec\":{\"interfaces\":[\"$FABRIC_NIC\"]}}"
echo "  L2Advertisement: announcing on $FABRIC_NIC (fabric)"

# ---------- step 15: resolve inventory and configure trunk ports ----------


RESOLVED_INVENTORY=$(mktemp --suffix=.yml)
envsubst < "$INVENTORY" > "$RESOLVED_INVENTORY"

info "Configuring trunk ports on switches..."
ansible-playbook \
    -i "$RESOLVED_INVENTORY" \
    "${SCRIPT_DIR}/ansible/playbooks/configure_network.yml"

# ---------- step 16: install packages on network node ----------

info "Preparing network node..."
docker exec "$NET_NODE" apk add --no-cache iptables iproute2 python3 openssh frr >/dev/null 2>&1
docker exec "$NET_NODE" ssh-keygen -A >/dev/null 2>&1
docker exec "$NET_NODE" sh -c "echo 'root:root' | chpasswd"
docker exec "$NET_NODE" sh -c "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
docker exec "$NET_NODE" /usr/sbin/sshd
echo "  Installed iptables, iproute2, python3, openssh (sshd running), frr"

docker exec "$NET_NODE" ip addr replace 10.0.0.30/24 dev eth1
echo "  net-node:eth1 = 10.0.0.30/24 (native VLAN)"

# ---------- step 17: configure BGP peering ----------

info "Configuring BGP peering link..."
docker exec "$NET_NODE" ip addr replace "$BGP_NET_NODE_IP" dev eth2
docker exec "$NET_NODE" ip link set eth2 up
docker exec "$UPSTREAM_ROUTER" ip addr replace "$BGP_UPSTREAM_IP" dev eth1
docker exec "$UPSTREAM_ROUTER" ip link set eth1 up
echo "  net-node:eth2 = ${BGP_NET_NODE_IP}, upstream-router:eth1 = ${BGP_UPSTREAM_IP}"

info "Configuring FRR on net-node (AS ${BGP_NET_NODE_AS})..."
docker exec "$NET_NODE" sh -c "cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname net-node
log syslog informational

router bgp ${BGP_NET_NODE_AS}
 bgp router-id ${BGP_NET_NODE_IP%/*}
 no bgp ebgp-requires-policy
 neighbor ${BGP_UPSTREAM_IP%/*} remote-as ${BGP_UPSTREAM_AS}
 address-family ipv4 unicast
  redistribute static
 exit-address-family
EOF"
docker exec "$NET_NODE" sh -c "sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons"
docker exec "$NET_NODE" sh -c "/usr/lib/frr/frrinit.sh start" 2>/dev/null || true

info "Preparing upstream router..."
docker exec "$UPSTREAM_ROUTER" apk add --no-cache frr >/dev/null 2>&1
echo "  Installed frr on upstream-router"

info "Configuring FRR on upstream-router (AS ${BGP_UPSTREAM_AS})..."
docker exec "$UPSTREAM_ROUTER" sh -c "cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname upstream-router
log syslog informational

router bgp ${BGP_UPSTREAM_AS}
 bgp router-id ${BGP_UPSTREAM_IP%/*}
 no bgp ebgp-requires-policy
 neighbor ${BGP_NET_NODE_IP%/*} remote-as ${BGP_NET_NODE_AS}
 address-family ipv4 unicast
 exit-address-family
EOF"
docker exec "$UPSTREAM_ROUTER" sh -c "sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons"
docker exec "$UPSTREAM_ROUTER" sh -c "/usr/lib/frr/frrinit.sh start" 2>/dev/null || true

info "Waiting for BGP session to establish (10s)..."
sleep 10

# Enable IP forwarding on upstream router so it can route between mgmt and BGP links
docker exec "$UPSTREAM_ROUTER" sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Add static route on the host so that public IPs (used in tenant kubeconfigs)
# are routed through the lab fabric instead of the internet.
# The upstream router learns /32 routes from the net-node via BGP and forwards
# traffic to it over the peering link.
ip route replace 192.168.100.0/24 via "${MGMT_PREFIX}.40"
echo "  Added host route 192.168.100.0/24 via ${MGMT_PREFIX}.40 (upstream-router)"

# ---------- step 18: create inventory ConfigMap ----------

info "Creating agentless-net inventory ConfigMap..."
KUBECONFIG="$KUBECONFIG" oc create configmap agentless-net-inventory \
    --from-file=inventory.yml="$RESOLVED_INVENTORY" \
    -n "$OSAC_NS" \
    --dry-run=client -o yaml | \
    KUBECONFIG="$KUBECONFIG" oc apply -f -

rm -f "$RESOLVED_INVENTORY"

# ============================================================
# AGENT SETUP (register host VMs as CaaS agents)
# ============================================================

# ---------- step 19: register host type in fulfillment-service ----------

INTERNAL_API="https://$(KUBECONFIG="$KUBECONFIG" oc get route fulfillment-internal-api -n "$OSAC_NS" -o jsonpath='{.status.ingress[0].host}')"
TOKEN=$(KUBECONFIG="$KUBECONFIG" oc create token -n "$OSAC_NS" admin)

RESPONSE_BODY=$(mktemp)
HTTP_CODE=$(curl -sk -w "%{http_code}" -X POST "${INTERNAL_API}/api/private/v1/host_types" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"id\": \"${AGENT_RESOURCE_CLASS}\", \"title\": \"CI Worker\", \"description\": \"Worker nodes for CI testing\"}" \
    -o "${RESPONSE_BODY}") || true
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "201" ]]; then
    info "Host type '${AGENT_RESOURCE_CLASS}' created"
elif [[ "${HTTP_CODE}" == "409" ]]; then
    info "Host type '${AGENT_RESOURCE_CLASS}' already exists — skipping"
else
    echo "ERROR: Failed to create host type (HTTP ${HTTP_CODE})"
    cat "${RESPONSE_BODY}"
    rm -f "${RESPONSE_BODY}"
    exit 1
fi
rm -f "${RESPONSE_BODY}"

# ---------- step 20: create agent namespace and InfraEnv ----------

info "Creating agent namespace '${AGENT_NAMESPACE}'..."
KUBECONFIG="$KUBECONFIG" oc create namespace "$AGENT_NAMESPACE" --dry-run=client -o yaml | \
    KUBECONFIG="$KUBECONFIG" oc apply -f -

info "Creating pull-secret in ${AGENT_NAMESPACE}..."
KUBECONFIG="$KUBECONFIG" oc create secret generic pull-secret \
    -n "$AGENT_NAMESPACE" \
    --from-file=.dockerconfigjson="$PULL_SECRET" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | \
    KUBECONFIG="$KUBECONFIG" oc apply -f -

info "Creating CAPI provider role in ${AGENT_NAMESPACE}..."
export AGENT_NAMESPACE INFRAENV_NAME SSH_PUB_KEY
envsubst < "${SCRIPT_DIR}/manifests/capi-provider-role.yaml" | KUBECONFIG="$KUBECONFIG" oc apply -f -

info "Creating InfraEnv '${INFRAENV_NAME}' in ${AGENT_NAMESPACE}..."
envsubst < "${SCRIPT_DIR}/manifests/infraenv.yaml" | KUBECONFIG="$KUBECONFIG" oc apply -f -

info "Waiting for discovery ISO URL..."
elapsed=0
while true; do
    ISO_URL=$(KUBECONFIG="$KUBECONFIG" oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" \
        -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null) || true
    [ -n "$ISO_URL" ] && break
    sleep 5; elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge 300 ]; then
        echo "ERROR: Timed out waiting for ISO URL after ${elapsed}s"
        KUBECONFIG="$KUBECONFIG" oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" -o yaml 2>&1 || true
        exit 1
    fi
done
info "Discovery ISO URL ready"

# ---------- step 21: create bridges and boot host VMs ----------

mkdir -p "$VM_DIR"

ISO_FILE="${VM_DIR}/discovery.iso"
if [ -f "$ISO_FILE" ]; then
    info "Discovery ISO already downloaded — skipping"
else
    info "Downloading discovery ISO..."
    curl -k -L --fail-with-body -o "$ISO_FILE" "$ISO_URL"
fi

info "Creating bridges and booting host VMs..."
for i in "${!HOST_VMS[@]}"; do
    vm="${HOST_VMS[$i]}"
    br="${HOST_BRIDGES[$i]}"
    veth="${HOST_VETHS[$i]}"

    if virsh domstate "$vm" 2>/dev/null | grep -q "running"; then
        echo "  $vm already running — skipping"
        continue
    fi

    # Create bridge if needed
    if ! ip link show "$br" &>/dev/null; then
        sudo ip link add "$br" type bridge
        sudo ip link set "$veth" master "$br"
        sudo ip link set "$br" up
    fi

    # Create and boot VM directly with discovery ISO
    if ! virsh dominfo "$vm" &>/dev/null; then
        disk="$VM_DIR/${vm}.qcow2"
        qemu-img create -f qcow2 "$disk" "${VM_DISK_SIZE}G" >/dev/null 2>&1

        virt-install \
            --name "$vm" \
            --vcpus "$VM_VCPUS" \
            --memory "$VM_MEMORY" \
            --disk "$disk,format=qcow2" \
            --network "bridge=$br" \
            --network "network=$MGMT_LIBVIRT_NET,model=e1000" \
            --cdrom "$ISO_FILE" \
            --osinfo detect=on,name=generic \
            --boot hd,cdrom \
            --noautoconsole >/dev/null 2>&1

        echo "  Created and started $vm: ${VM_VCPUS} vCPU, ${VM_MEMORY}MB RAM, ${VM_DISK_SIZE}GB disk"
    else
        virsh start "$vm" 2>/dev/null || true
        echo "  Started $vm"
    fi
done

# ---------- step 22: wait for agents to register, approve, and label ----------

EXPECTED_AGENTS=${#HOST_VMS[@]}

info "Waiting for ${EXPECTED_AGENTS} agents to register (this may take 5-10 minutes)..."
elapsed=0
while true; do
    count=$(KUBECONFIG="$KUBECONFIG" oc get agent -n "$AGENT_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    [ "$count" -ge "$EXPECTED_AGENTS" ] && break
    sleep 30; elapsed=$((elapsed + 30))
    echo "  ${elapsed}s elapsed — ${count}/${EXPECTED_AGENTS} agents registered"
    if [ "$elapsed" -ge 900 ]; then
        echo "ERROR: Timed out waiting for agents after ${elapsed}s (${count}/${EXPECTED_AGENTS} registered)"
        KUBECONFIG="$KUBECONFIG" oc get agent -n "$AGENT_NAMESPACE" -o wide 2>&1 || true
        exit 1
    fi
done
info "All ${EXPECTED_AGENTS} agents registered"

info "Approving, labeling, and annotating agents..."
AGENT_MAC_MAP=$(KUBECONFIG="$KUBECONFIG" oc get agent -n "$AGENT_NAMESPACE" -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for agent in data['items']:
    name = agent['metadata']['name']
    inv = json.loads(agent['metadata']['annotations']['agent.agent-install.openshift.io/inventory'])
    mac = inv['interfaces'][0]['mac_address']
    print(f'{name} {mac}')
")

ANNOTATED_COUNT=0
for agent in $(KUBECONFIG="$KUBECONFIG" oc get agent -n "$AGENT_NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
    KUBECONFIG="$KUBECONFIG" oc patch agent/"$agent" -n "$AGENT_NAMESPACE" --type=merge \
        -p '{"spec":{"approved":true}}'
    KUBECONFIG="$KUBECONFIG" oc label agent/"$agent" -n "$AGENT_NAMESPACE" \
        "osac.openshift.io/resource_class=${AGENT_RESOURCE_CLASS}" --overwrite

    # Match agent to VM by data-plane MAC and annotate with host_uuid
    AGENT_MAC=$(echo "$AGENT_MAC_MAP" | awk -v a="$agent" '$1==a{print $2}')
    for vm in "${HOST_VMS[@]}"; do
        VM_MAC=$(virsh domiflist "$vm" | awk 'NR==3{print $5}')
        if [ "$AGENT_MAC" = "$VM_MAC" ]; then
            KUBECONFIG="$KUBECONFIG" oc annotate agent/"$agent" -n "$AGENT_NAMESPACE" \
                "osac.openshift.io/host_uuid=$vm" --overwrite
            echo "  Approved, labeled, and annotated $agent → $vm"
            ANNOTATED_COUNT=$((ANNOTATED_COUNT + 1))
            break
        fi
    done
done

if [ "$ANNOTATED_COUNT" -ne "$EXPECTED_AGENTS" ]; then
    echo "ERROR: Only ${ANNOTATED_COUNT}/${EXPECTED_AGENTS} agents got host_uuid annotation (MAC matching failed)"
    exit 1
fi

info "Lab setup complete."
