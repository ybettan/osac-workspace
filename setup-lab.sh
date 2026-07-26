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

    # Remove mgmt VM data-plane bridge
    if ip link show br-mgmt &>/dev/null; then
        sudo ip link set br-mgmt down 2>/dev/null || true
        sudo ip link delete br-mgmt 2>/dev/null || true
        info "  Removed br-mgmt"
    fi

    # Destroy containerlab (needs MGMT_* env vars to parse clab.yml)
    if docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-"; then
        resolve_mgmt_network
        sudo MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_CIDR="$MGMT_CIDR" MGMT_GW="$MGMT_GW" MGMT_PREFIX="$MGMT_PREFIX" \
            ${CONTAINERLAB} destroy -t "$TOPO_FILE" --cleanup
        info "  Removed containerlab"
    fi

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
if iptables -S FORWARD 2>/dev/null | grep -q "\-P FORWARD DROP"; then
    if ! iptables -C FORWARD -s 192.168.0.0/16 -j ACCEPT 2>/dev/null; then
        info "Adding iptables FORWARD rules for libvirt VMs..."
        iptables -I FORWARD -s 192.168.0.0/16 -j ACCEPT
        iptables -I FORWARD -d 192.168.0.0/16 -j ACCEPT
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
# cluster-tool creates the libvirt network with localOnly='yes' on the mgmt
# cluster's domain. This prevents the libvirt dnsmasq from forwarding DNS
# queries for subdomains (like hosted.*) to upstream resolvers. Worker VMs
# that use this dnsmasq cannot resolve guest cluster API hostnames created
# in Route 53. Flip to localOnly='no' so unknown subdomains are forwarded.

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
    info "DNS forwarding already fixed — skipping"
fi

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

# ---------- step 10: validate OSAC ----------

info "Validating OSAC..."
KUBECONFIG="$KUBECONFIG" oc wait deploy/fulfillment-grpc-server -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
KUBECONFIG="$KUBECONFIG" oc wait deploy/osac-operator -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
info "OSAC is running:"
KUBECONFIG="$KUBECONFIG" oc get pods -n "$OSAC_NS" --no-headers | \
    awk '{print $3}' | sort | uniq -c | sort -rn

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

# ---------- step 15: resolve inventory and configure trunk ports ----------


RESOLVED_INVENTORY=$(mktemp)
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

# ---------- step 18: create inventory ConfigMap ----------

info "Creating agentless-net inventory ConfigMap..."
KUBECONFIG="$KUBECONFIG" oc create configmap agentless-net-inventory \
    --from-file=inventory.yml="$RESOLVED_INVENTORY" \
    -n "$OSAC_NS" \
    --dry-run=client -o yaml | \
    KUBECONFIG="$KUBECONFIG" oc apply -f -

rm -f "$RESOLVED_INVENTORY"

info "Lab setup complete."
