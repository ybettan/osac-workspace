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

# Host VMs
VM_DIR="/var/lib/libvirt/images/${LAB_NAME}"
VM_VCPUS=4
VM_MEMORY=16384   # MB
VM_DISK_SIZE=100  # GB
HOST_VMS=("host-1" "host-2" "host-3")
HOST_BRIDGES=("br-host1" "br-host2" "br-host3")
HOST_VETHS=("leaf1-swp2" "leaf2-swp2" "leaf2-swp3")

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

info "Lab setup complete."
