#!/usr/bin/env bash
#
# Run WITHOUT sudo: ./setup-lab.sh
# The script uses sudo internally only for containerlab commands.
#
# Usage:
#   ./setup-lab.sh            Deploy infra + runtime (full lab)
#   ./setup-lab.sh infra      Deploy infra only (admin setup, no tenant provisioning)
#   ./setup-lab.sh destroy    Tear down the lab
#
# Prerequisites:
#   pip install git+https://github.com/ybettan/network-runner.git
#
# TODO: network-runner PR pending at https://github.com/ansible-network/network-runner/pull/76
# If upstream remains inactive, absorb the role + providers into the
# ansible.l2 collection in osac-aap to eliminate the pip dependency.
#
# The ansible.l2 and ansible.l3 collections live in osac-aap.
# Override OSAC_AAP_DIR to point to a different clone.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="${SCRIPT_DIR}/ansible-net-lab.clab.yml"
LAB_NAME="ybettan-ansible-net-lab"
PREFIX="clab-${LAB_NAME}"
CONTAINERLAB="/home/ybettan/go/bin/containerlab"

SWITCHES=("${PREFIX}-leaf-1" "${PREFIX}-leaf-2")
NET_NODE="${PREFIX}-net-node"

# Ansible paths
OSAC_AAP_DIR="${OSAC_AAP_DIR:-${SCRIPT_DIR}/../osac-aap}"
NR_ROLES_PATH="$(python3 -c "import network_runner; import os; print(os.path.join(os.path.dirname(network_runner.__file__), '..', 'etc', 'ansible', 'roles'))")"
export ANSIBLE_ROLES_PATH="${NR_ROLES_PATH}"
export ANSIBLE_COLLECTIONS_PATH="${OSAC_AAP_DIR}/collections"

INVENTORY="${SCRIPT_DIR}/ansible/inventory.yml"
VARS="${SCRIPT_DIR}/ansible/vars/all.yml"

# ---------- helpers ----------

info()  { echo "==> $*"; }
ok()    { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }

run_play() {
    ansible-playbook -i "$INVENTORY" -e "@${VARS}" /dev/stdin <<EOF
$1
EOF
}

# ---------- destroy ----------

if [ "${1:-}" = "destroy" ]; then
    info "Destroying lab..."
    sudo ${CONTAINERLAB} destroy -t "$TOPO_FILE" --cleanup
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
    "${SCRIPT_DIR}/ansible/playbooks/configure_network.yml" \
    -e "@${VARS}"

# ---------- step 5: install packages on network node ----------

info "Preparing network node..."
docker exec "$NET_NODE" apk add --no-cache iptables iproute2 python3 openssh >/dev/null 2>&1
docker exec "$NET_NODE" ssh-keygen -A >/dev/null 2>&1
docker exec "$NET_NODE" sh -c "echo 'root:root' | chpasswd"
docker exec "$NET_NODE" sh -c "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
docker exec "$NET_NODE" /usr/sbin/sshd
echo "  Installed iptables + iproute2 + python3 + openssh (sshd running)"

# ---------- infra-only exit ----------

if [ "${1:-}" = "infra" ]; then
    info "Infra-only mode — admin setup complete. Skipping runtime provisioning."
    exit 0
fi

# ============================================================
# RUNTIME SIMULATION (what OSAC orchestration would do)
# ============================================================

# ---------- allocate VLANs via IPAM ----------

info "Allocating VLANs via IPAM..."

run_play '
---
- hosts: clab-ybettan-ansible-net-lab-net-node
  gather_facts: false
  tasks:
    - name: Allocate VLAN for tenant-a
      ansible.builtin.include_role:
        name: ansible.l3.ipam
        tasks_from: allocate_vlan
      vars:
        ipam_state_file: /etc/osac/network_state.json
        ipam_vlan_pool_start: "{{ vlan_range_start }}"
        ipam_vlan_pool_end: "{{ vlan_range_end }}"
        ipam_purpose: tenant-a

    - name: Allocate VLAN for tenant-b
      ansible.builtin.include_role:
        name: ansible.l3.ipam
        tasks_from: allocate_vlan
      vars:
        ipam_state_file: /etc/osac/network_state.json
        ipam_vlan_pool_start: "{{ vlan_range_start }}"
        ipam_vlan_pool_end: "{{ vlan_range_end }}"
        ipam_purpose: tenant-b
'

VLAN_A=$(docker exec "$NET_NODE" python3 -c "import json; print(json.load(open('/etc/osac/network_state.json'))['vlans']['tenant-a'])")
VLAN_B=$(docker exec "$NET_NODE" python3 -c "import json; print(json.load(open('/etc/osac/network_state.json'))['vlans']['tenant-b'])")
echo "  tenant-a: VLAN ${VLAN_A} (10.${VLAN_A}.0.0/24)"
echo "  tenant-b: VLAN ${VLAN_B} (10.${VLAN_B}.0.0/24)"

# ---------- step 6: provision tenant-a ----------

info "Provisioning tenant-a (VLAN ${VLAN_A})..."

run_play '
---
- hosts: switches
  gather_facts: false
  tasks:
    - name: Create tenant-a VLAN
      ansible.builtin.include_role:
        name: ansible.l2.vlan
        tasks_from: create
      vars:
        vlan_id: '"${VLAN_A}"'

    - name: Assign host-1 port (leaf-1:swp2)
      ansible.builtin.include_role:
        name: ansible.l2.port
        tasks_from: set_access_port
      vars:
        port_name: swp2
        vlan_id: '"${VLAN_A}"'
      when: inventory_hostname == "clab-ybettan-ansible-net-lab-leaf-1"

    - name: Assign host-2 port (leaf-2:swp2)
      ansible.builtin.include_role:
        name: ansible.l2.port
        tasks_from: set_access_port
      vars:
        port_name: swp2
        vlan_id: '"${VLAN_A}"'
      when: inventory_hostname == "clab-ybettan-ansible-net-lab-leaf-2"
'

# ---------- step 7: provision tenant-b ----------

info "Provisioning tenant-b (VLAN ${VLAN_B})..."

run_play '
---
- hosts: switches
  gather_facts: false
  tasks:
    - name: Create tenant-b VLAN
      ansible.builtin.include_role:
        name: ansible.l2.vlan
        tasks_from: create
      vars:
        vlan_id: '"${VLAN_B}"'

    - name: Assign host-3 port (leaf-2:swp3)
      ansible.builtin.include_role:
        name: ansible.l2.port
        tasks_from: set_access_port
      vars:
        port_name: swp3
        vlan_id: '"${VLAN_B}"'
      when: inventory_hostname == "clab-ybettan-ansible-net-lab-leaf-2"
'

# ---------- step 8: assign host IPs ----------

info "Assigning host IPs..."
for pair in "host-1:10.${VLAN_A}.0.10/24" "host-2:10.${VLAN_A}.0.20/24" "host-3:10.${VLAN_B}.0.20/24"; do
    host="${pair%%:*}"
    ip="${pair##*:}"
    container="${PREFIX}-${host}"
    docker exec "$container" ip addr flush dev eth1 2>/dev/null || true
    docker exec "$container" ip addr add "$ip" dev eth1
    echo "  ${host} -> ${ip}"
done

# ---------- step 9: create tenant routers on network node ----------

info "Creating tenant routers on network node..."

run_play '
---
- hosts: clab-ybettan-ansible-net-lab-net-node
  gather_facts: false
  tasks:
    - name: Create tenant-a router
      ansible.builtin.include_role:
        name: ansible.l3.router
        tasks_from: create
      vars:
        router_name: tenant-a
        router_vlan_id: '"${VLAN_A}"'
        router_internal_subnet: "10.'"${VLAN_A}"'.0.0/24"
        router_internal_gateway: "10.'"${VLAN_A}"'.0.1"
        router_trunk_interface: eth1
        router_external_ip: "10.254.0.2/30"
        router_external_peer_ip: "10.254.0.1/30"
        router_external_gateway: "10.254.0.1"

    - name: Create tenant-b router
      ansible.builtin.include_role:
        name: ansible.l3.router
        tasks_from: create
      vars:
        router_name: tenant-b
        router_vlan_id: '"${VLAN_B}"'
        router_internal_subnet: "10.'"${VLAN_B}"'.0.0/24"
        router_internal_gateway: "10.'"${VLAN_B}"'.0.1"
        router_trunk_interface: eth1
        router_external_ip: "10.254.0.6/30"
        router_external_peer_ip: "10.254.0.5/30"
        router_external_gateway: "10.254.0.5"
'

# ---------- step 10: configure SNAT ----------

info "Configuring SNAT..."

run_play '
---
- hosts: clab-ybettan-ansible-net-lab-net-node
  gather_facts: false
  tasks:
    - name: SNAT for tenant-a
      ansible.builtin.include_role:
        name: ansible.l3.snat
        tasks_from: create
      vars:
        snat_router_name: tenant-a
        snat_source_subnet: "10.'"${VLAN_A}"'.0.0/24"
        snat_veth_interface: v-tenant-a-i
        snat_external_subnet: "10.254.0.0/30"
        snat_external_interface: eth0

    - name: SNAT for tenant-b
      ansible.builtin.include_role:
        name: ansible.l3.snat
        tasks_from: create
      vars:
        snat_router_name: tenant-b
        snat_source_subnet: "10.'"${VLAN_B}"'.0.0/24"
        snat_veth_interface: v-tenant-b-i
        snat_external_subnet: "10.254.0.4/30"
        snat_external_interface: eth0
'

# ---------- step 11: configure DNAT ----------

info "Configuring DNAT..."

run_play '
---
- hosts: clab-ybettan-ansible-net-lab-net-node
  gather_facts: false
  tasks:
    - name: DNAT for API server (tenant-a)
      ansible.builtin.include_role:
        name: ansible.l3.dnat
        tasks_from: create
      vars:
        dnat_router_name: tenant-a
        dnat_public_ip: "10.254.0.2"
        dnat_public_port: 6443
        dnat_internal_ip: "10.'"${VLAN_A}"'.0.10"
        dnat_internal_port: 6443
'

# ---------- step 12: set default gateways on hosts ----------

info "Setting default gateways on hosts..."
docker exec "${PREFIX}-host-1" ip route replace default via "10.${VLAN_A}.0.1"
docker exec "${PREFIX}-host-2" ip route replace default via "10.${VLAN_A}.0.1"
docker exec "${PREFIX}-host-3" ip route replace default via "10.${VLAN_B}.0.1"
echo "  host-1, host-2 -> 10.${VLAN_A}.0.1 (tenant-a namespace)"
echo "  host-3 -> 10.${VLAN_B}.0.1 (tenant-b namespace)"

# ---------- step 13: wait + warm up ----------

info "Waiting for VLAN convergence (10s)..."
sleep 10

info "Warming up ARP..."
docker exec "${PREFIX}-host-1" ping -c 2 -W 3 10.100.0.20 &>/dev/null || true
docker exec "${PREFIX}-host-2" ping -c 2 -W 3 10.100.0.10 &>/dev/null || true
sleep 2

# ---------- step 14: verification ----------

info "Running verification tests..."
echo ""

errors=0

# tenant-a: host-1 <-> host-2 (same VLAN)
if docker exec "${PREFIX}-host-1" ping -c 3 -W 3 "10.${VLAN_A}.0.20" &>/dev/null; then
    ok "host-1 (tenant-a) -> host-2 (tenant-a)"
else
    fail "host-1 (tenant-a) -> host-2 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 "10.${VLAN_A}.0.10" &>/dev/null; then
    ok "host-2 (tenant-a) -> host-1 (tenant-a)"
else
    fail "host-2 (tenant-a) -> host-1 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

# cross-tenant isolation (different VLANs)
if docker exec "${PREFIX}-host-1" ping -c 2 -W 3 "10.${VLAN_B}.0.20" &>/dev/null; then
    fail "host-1 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 "10.${VLAN_B}.0.20" &>/dev/null; then
    fail "host-2 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

# net-node namespace connectivity
if docker exec "$NET_NODE" ip netns exec tenant-a ping -c 2 -W 3 "10.${VLAN_A}.0.10" &>/dev/null; then
    ok "net-node (tenant-a ns) -> host-1"
else
    fail "net-node (tenant-a ns) -> host-1 — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "$NET_NODE" ip netns exec tenant-b ping -c 2 -W 3 "10.${VLAN_B}.0.20" &>/dev/null; then
    ok "net-node (tenant-b ns) -> host-3"
else
    fail "net-node (tenant-b ns) -> host-3 — expected PASS"
    errors=$((errors + 1))
fi

# SNAT: hosts reach management network via net-node
if docker exec "${PREFIX}-host-1" ping -c 2 -W 3 172.20.20.1 &>/dev/null; then
    ok "host-1 (tenant-a) -> 172.20.20.1 (SNAT egress)"
else
    fail "host-1 (tenant-a) -> 172.20.20.1 (SNAT egress) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-3" ping -c 2 -W 3 172.20.20.1 &>/dev/null; then
    ok "host-3 (tenant-b) -> 172.20.20.1 (SNAT egress)"
else
    fail "host-3 (tenant-b) -> 172.20.20.1 (SNAT egress) — expected PASS"
    errors=$((errors + 1))
fi

echo ""
if [ "$errors" -eq 0 ]; then
    info "All tests passed!"
else
    info "${errors} test(s) FAILED"
    exit 1
fi
