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
TOPO_FILE="${SCRIPT_DIR}/agentless-net-lab.clab.yml"
LAB_NAME="agentless-net-lab"
PREFIX="clab-${LAB_NAME}"
CONTAINERLAB="${CONTAINERLAB:-containerlab}"

SWITCHES=("${PREFIX}-leaf-1" "${PREFIX}-leaf-2")
NET_NODE="${PREFIX}-net-node"
UPSTREAM_ROUTER="${PREFIX}-upstream-router"

# mgmt-server
MGMT_CLONE_NAME="agentless-lab-mgmt"
MGMT_IMAGE="${MGMT_IMAGE:-quay.io/osac-project/cluster-flavors:caas-4-22}"
INSTALLER_DIR="${SCRIPT_DIR}/osac-installer"
PULL_SECRET="${INSTALLER_DIR}/values/agentless-net-lab/pull-secret.json"

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
INFRAENV_NAME="agentless-net-discovery"
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || true)"

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

# ---------- destroy ----------

if [ "${1:-}" = "destroy" ]; then
    info "Destroying lab..."

    # Destroy mgmt-server
    if command -v cluster-tool &>/dev/null; then
        cluster-tool destroy "$MGMT_CLONE_NAME" 2>/dev/null || true
        info "  Removed mgmt-server"
    fi

    # Destroy host VMs
    for vm in "${HOST_VMS[@]}"; do
        if virsh dominfo "$vm" &>/dev/null; then
            virsh destroy "$vm" 2>/dev/null || true
            virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
            info "  Removed VM $vm"
        fi
    done

    # Remove bridges
    for br in "${HOST_BRIDGES[@]}"; do
        if ip link show "$br" &>/dev/null; then
            sudo ip link set "$br" down 2>/dev/null || true
            sudo ip link delete "$br" 2>/dev/null || true
            info "  Removed bridge $br"
        fi
    done

    # Destroy containerlab
    sudo ${CONTAINERLAB} destroy -t "$TOPO_FILE" --cleanup

    # Clean up VM disks
    rm -rf "$VM_DIR"

    # Remove iptables FORWARD rules
    iptables -D FORWARD -s 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 192.168.0.0/16 -j ACCEPT 2>/dev/null || true

    info "Done."
    exit 0
fi

# ============================================================
# ADMIN SETUP (done once when the fabric is deployed)
# ============================================================

# ---------- step 1: deploy containerlab ----------

if docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-leaf-1$"; then
    info "Lab already running — skipping deploy"
else
    info "Deploying Containerlab topology..."
    sudo ${CONTAINERLAB} deploy -t "$TOPO_FILE"
fi

# ---------- step 2: wait for switches ----------

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

# ---------- step 3: fix sudo on switches ----------

info "Fixing sudo permissions on switches..."
for sw in "${SWITCHES[@]}"; do
    docker exec "$sw" bash -c \
        "echo 'cumulus ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cumulus && chmod 440 /etc/sudoers.d/cumulus"
    echo "  Fixed $sw"
done

# ---------- step 4: configure trunk ports (admin setup) ----------

info "Configuring trunk ports on switches..."
ansible-playbook \
    -i "$INVENTORY" \
    "${SCRIPT_DIR}/ansible/playbooks/configure_network.yml"

# ---------- step 5: install packages on network node ----------

info "Preparing network node..."
docker exec "$NET_NODE" apk add --no-cache iptables iproute2 python3 openssh frr >/dev/null 2>&1
docker exec "$NET_NODE" ssh-keygen -A >/dev/null 2>&1
docker exec "$NET_NODE" sh -c "echo 'root:root' | chpasswd"
docker exec "$NET_NODE" sh -c "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
docker exec "$NET_NODE" /usr/sbin/sshd
echo "  Installed iptables, iproute2, python3, openssh (sshd running), frr"

# ---------- step 6: configure BGP peering ----------

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

# ============================================================
# VM SETUP (host VMs)
# ============================================================

# ---------- step 8: create Linux bridges for host VMs ----------

info "Creating Linux bridges for host VMs..."
for i in "${!HOST_BRIDGES[@]}"; do
    br="${HOST_BRIDGES[$i]}"
    veth="${HOST_VETHS[$i]}"
    if ip link show "$br" &>/dev/null; then
        echo "  Bridge $br already exists — skipping"
    else
        sudo ip link add "$br" type bridge
        sudo ip link set "$veth" master "$br"
        sudo ip link set "$br" up
        echo "  Created $br with $veth attached"
    fi
done

# ---------- step 9: find containerlab management bridge ----------

CLAB_MGMT_BRIDGE=$(docker network inspect clab -f '{{range .Options}}{{.}}{{end}}' 2>/dev/null | grep -oP 'br-[a-f0-9]+' || \
    docker network inspect clab -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
if [ -z "$CLAB_MGMT_BRIDGE" ]; then
    CLAB_MGMT_BRIDGE="br-$(docker network inspect clab -f '{{.Id}}' | cut -c1-12)"
fi

if [ -z "$CLAB_MGMT_BRIDGE" ]; then
    echo "ERROR: Could not find containerlab management bridge" >&2
    exit 1
fi
info "Containerlab management bridge: $CLAB_MGMT_BRIDGE"

# ---------- step 10: create host KVM VMs (powered off) ----------

mkdir -p "$VM_DIR"

info "Creating host KVM VMs..."
for i in "${!HOST_VMS[@]}"; do
    vm="${HOST_VMS[$i]}"
    br="${HOST_BRIDGES[$i]}"

    if virsh dominfo "$vm" &>/dev/null; then
        echo "  VM $vm already defined — skipping"
        continue
    fi

    disk="$VM_DIR/${vm}.qcow2"
    qemu-img create -f qcow2 "$disk" "${VM_DISK_SIZE}G" >/dev/null 2>&1

    virt-install \
        --name "$vm" \
        --vcpus "$VM_VCPUS" \
        --memory "$VM_MEMORY" \
        --disk "$disk,format=qcow2" \
        --network "bridge=$br" \
        --osinfo detect=on,name=generic \
        --boot hd \
        --noautoconsole \
        --noreboot \
        --import >/dev/null 2>&1

    virsh destroy "$vm" 2>/dev/null || true
    echo "  Defined $vm (powered off): ${VM_VCPUS} vCPU, ${VM_MEMORY}MB RAM, ${VM_DISK_SIZE}GB disk"
done

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

# ---------- step 11: setup cluster-tool (one-time) ----------

if ! cluster-tool servers 2>/dev/null | grep -q "local"; then
    info "Setting up cluster-tool..."
    cluster-tool connect local --host local --data-path /var/lib/cluster-tool
    sudo cluster-tool setup client
fi

# ---------- step 12: pull snapshot flavor ----------

if cluster-tool flavors 2>/dev/null | grep -q "caas-4-22"; then
    info "Snapshot flavor 'caas-4-22' already pulled — skipping"
else
    info "Pulling mgmt-server snapshot..."
    cluster-tool pull "$MGMT_IMAGE"
fi

# ---------- step 13: boot mgmt-server ----------

MGMT_VM_NAME="test-infra-cluster-${MGMT_CLONE_NAME}-master-0"

if virsh dominfo "$MGMT_VM_NAME" &>/dev/null; then
    info "mgmt-server already running — skipping boot"
else
    info "Booting mgmt-server (this may take several minutes)..."
    cluster-tool boot --flavor caas-4-22 --name "$MGMT_CLONE_NAME" --pull-secret "$PULL_SECRET"
fi

# ---------- step 14: attach mgmt-server to containerlab bridge ----------

if virsh domiflist "$MGMT_VM_NAME" 2>/dev/null | grep -q "$CLAB_MGMT_BRIDGE"; then
    info "mgmt-server already attached to $CLAB_MGMT_BRIDGE — skipping"
else
    info "Attaching mgmt-server to containerlab management bridge..."
    virsh attach-interface "$MGMT_VM_NAME" bridge "$CLAB_MGMT_BRIDGE" --model virtio --live --persistent
fi

KUBECONFIG_PATH="$HOME/.kube/${MGMT_CLONE_NAME}.kubeconfig"
export KUBECONFIG="$KUBECONFIG_PATH"
OSAC_NS="osac-e2e-ci"
MGMT_LIBVIRT_NET="test-infra-net-${MGMT_CLONE_NAME}"

# ---------- step 14b: fix DNS forwarding for hosted clusters ----------
#
# cluster-tool creates the libvirt network with localOnly='yes' on the mgmt
# cluster's domain. This prevents the libvirt dnsmasq from forwarding DNS
# queries for subdomains (like hosted.*) to upstream resolvers. Worker VMs
# that use this dnsmasq cannot resolve guest cluster API hostnames created
# in Route 53. Flip to localOnly='no' so unknown subdomains are forwarded.

DNSMASQ_CONF="/var/lib/libvirt/dnsmasq/${MGMT_LIBVIRT_NET}.conf"
if virsh net-dumpxml "$MGMT_LIBVIRT_NET" 2>/dev/null | grep -q "localOnly='yes'"; then
    info "Fixing DNS forwarding on ${MGMT_LIBVIRT_NET}..."
    # Update the persistent libvirt network definition
    NET_XML=$(mktemp)
    virsh net-dumpxml "$MGMT_LIBVIRT_NET" > "$NET_XML"
    sed -i "s/localOnly='yes'/localOnly='no'/" "$NET_XML"
    virsh net-define "$NET_XML"
    rm -f "$NET_XML"
    # Patch the live dnsmasq config and restart the process (SIGHUP doesn't
    # reload the local=/ directive). The bridge stays up so VMs keep connectivity.
    sed -i '/^local=/d' "$DNSMASQ_CONF"
    DNSMASQ_PID=$(cat /var/run/libvirt/network/${MGMT_LIBVIRT_NET}.pid 2>/dev/null)
    if [ -n "$DNSMASQ_PID" ]; then
        kill "$DNSMASQ_PID" 2>/dev/null; sleep 1
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

# ---------- step 15: init osac-installer submodules ----------

if [ -d "$INSTALLER_DIR/base/osac-operator/.git" ]; then
    info "osac-installer submodules already initialized — skipping"
else
    info "Initializing osac-installer submodules..."
    git -C "$INSTALLER_DIR" submodule update --init --recursive
fi

# ---------- step 16: create agentless-net inventory ConfigMap ----------

info "Creating agentless-net inventory ConfigMap..."
KUBECONFIG="$KUBECONFIG" oc create configmap agentless-net-inventory \
    --from-file=inventory.yml="${SCRIPT_DIR}/ansible/inventory.yml" \
    -n "$OSAC_NS" \
    --dry-run=client -o yaml | \
    KUBECONFIG="$KUBECONFIG" oc apply -f -

# ---------- step 17: refresh OSAC ----------

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

# ---------- step 17b: patch DNS credentials ----------

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

# ---------- step 17c: validate OSAC ----------

info "Validating OSAC..."
KUBECONFIG="$KUBECONFIG" oc wait deploy/fulfillment-grpc-server -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
KUBECONFIG="$KUBECONFIG" oc wait deploy/osac-operator -n "$OSAC_NS" \
    --for=condition=Available --timeout=60s
info "OSAC is running:"
KUBECONFIG="$KUBECONFIG" oc get pods -n "$OSAC_NS" --no-headers | \
    awk '{print $3}' | sort | uniq -c | sort -rn

# ============================================================
# AGENT SETUP (register host VMs as CaaS agents)
# ============================================================

# ---------- step 18: register host type in fulfillment-service ----------

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

# ---------- step 19: create agent namespace and InfraEnv ----------

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

# ---------- step 20: boot host VMs with discovery ISO ----------

ISO_FILE="${VM_DIR}/discovery.iso"

if [ -f "$ISO_FILE" ]; then
    info "Discovery ISO already downloaded — skipping"
else
    info "Downloading discovery ISO..."
    curl -k -L --fail-with-body -o "$ISO_FILE" "$ISO_URL"
fi

info "Booting host VMs with discovery ISO..."
for vm in "${HOST_VMS[@]}"; do
    if virsh domstate "$vm" 2>/dev/null | grep -q "running"; then
        echo "  $vm already running — skipping"
        continue
    fi

    # Attach mgmt-server libvirt network (DHCP + DNS + route to cluster)
    if ! virsh domiflist "$vm" 2>/dev/null | grep -q "$MGMT_LIBVIRT_NET"; then
        virsh attach-interface "$vm" network "$MGMT_LIBVIRT_NET" --model e1000 --persistent
    fi

    # Attach ISO as CD-ROM with boot order hd,cdrom — first boot falls through
    # empty disk to ISO; after RHCOS install the VM boots from disk automatically
    # (same pattern as CI's setup-caas-agents.sh using --cdrom + --boot hd,cdrom).
    virt-xml "$vm" --add-device --disk "$ISO_FILE",device=cdrom,readonly=on,target.dev=hdc --define 2>/dev/null || true
    virt-xml "$vm" --edit --boot hd,cdrom --define

    virsh start "$vm"
    echo "  Started $vm"
done

# ---------- step 21: wait for agents to register, approve, and label ----------

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
            break
        fi
    done
done

info "Lab setup complete."
