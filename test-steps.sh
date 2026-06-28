#!/bin/bash
#
# Test agentless_net.steps playbook wrappers — control-plane and data-plane.
# Provisions two tenants via the steps roles, verifies network isolation,
# SNAT egress, management reachability, idempotency, and cleanup.
#
# Usage:
#   ./setup-lab.sh      # first, deploy the lab infrastructure
#   ./test-steps.sh     # then, run this test
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="${SCRIPT_DIR}/ansible/inventory.yml"
OSAC_COLLECTIONS="${SCRIPT_DIR}/osac-aap/collections/ansible_collections"
VENDOR_COLLECTIONS="${SCRIPT_DIR}/osac-aap/vendor/ansible_collections"
COLLECTIONS_PATH="${OSAC_COLLECTIONS}:${VENDOR_COLLECTIONS}"
CLUSTER_INFRA_PLAYBOOKS="${OSAC_COLLECTIONS}/agentless_net/steps/roles/cluster_infra/playbooks"
EXTERNAL_ACCESS_PLAYBOOKS="${OSAC_COLLECTIONS}/agentless_net/steps/roles/external_access/playbooks"

# Lab naming
LAB_NAME="ybettan-ansible-net-lab"
PREFIX="clab-${LAB_NAME}"
NET_NODE="${PREFIX}-net-node"

# Shared test parameters
IPAM_STATE_FILE="/etc/osac/network_state.json"
VLAN_POOL_START=100
VLAN_POOL_END=199
TRUNK_INTERFACE="eth1"
PUBLIC_IP_POOL_START="192.168.100.10"
PUBLIC_IP_POOL_END="192.168.100.50"

# Tenant-a parameters
TENANT_A="tenant-a"
TENANT_A_SUBNET_CIDR="10.100.0.0/24"
TENANT_A_SUBNET_GATEWAY="10.100.0.1"
TENANT_A_HOST1_IP="10.100.0.10"
TENANT_A_HOST2_IP="10.100.0.20"
METALLB_INGRESS_IP="10.100.0.246"

# Tenant-b parameters
TENANT_B="tenant-b"
TENANT_B_SUBNET_CIDR="10.101.0.0/24"
TENANT_B_SUBNET_GATEWAY="10.101.0.1"
TENANT_B_HOST3_IP="10.101.0.20"

export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_PATH}"

# ---------- helpers ----------

info()  { echo "==> $*"; }
ok()    { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }

errors=0

read_ipam_state() {
    ansible -i "${INVENTORY}" "${NET_NODE}" -m raw -a "cat ${IPAM_STATE_FILE}" 2>/dev/null \
        | python3 -c "import sys,re; text=sys.stdin.read(); match=re.search(r'\{.*\}', text, re.DOTALL); print(match.group() if match else '{}')"
}

run_playbook() {
    local description="$1"
    shift
    echo ""
    echo "========================================"
    echo "  ${description}"
    echo "========================================"
    ansible-playbook -i "${INVENTORY}" "$@"
    echo "  ✓ ${description}"
}

compute_veth_addresses() {
    local vlan_id="$1"
    local veth_index=$(( (vlan_id - VLAN_POOL_START) * 4 ))
    EXTERNAL_PEER_IP="10.254.0.$((veth_index + 1))/30"
    EXTERNAL_ROUTER_IP="10.254.0.$((veth_index + 2))/30"
    EXTERNAL_GATEWAY="10.254.0.$((veth_index + 1))"
    EXTERNAL_SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_interface('${EXTERNAL_PEER_IP}').network)")
    SNAT_VETH_NS="v$(echo -n "$2" | md5sum | cut -c1-11)i"
}

# ---------- cleanup on failure ----------

cleanup() {
    echo ""
    info "Cleaning up provisioned resources..."

    # Tenant-a external_access delete (best-effort)
    if [ -n "${TENANT_A_API_PUBLIC_IP:-}" ]; then
        run_playbook "Cleanup: Delete DNAT (API)" \
            -e dnat_router_name="${TENANT_A}" \
            -e dnat_public_ip="${TENANT_A_API_PUBLIC_IP}" \
            -e dnat_public_port=6443 \
            -e dnat_internal_ip="${TENANT_A_SUBNET_GATEWAY}" \
            -e dnat_internal_port=6443 \
            -e dnat_protocol=tcp \
            "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml" 2>/dev/null || true

        run_playbook "Cleanup: Release public IP (API)" \
            -e ipam_state_file="${IPAM_STATE_FILE}" \
            -e ipam_purpose="${TENANT_A}-api" \
            "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml" 2>/dev/null || true
    fi
    if [ -n "${TENANT_A_INGRESS_PUBLIC_IP:-}" ]; then
        run_playbook "Cleanup: Delete DNAT (ingress HTTP)" \
            -e dnat_router_name="${TENANT_A}" \
            -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
            -e dnat_public_port=80 \
            -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
            -e dnat_internal_port=80 \
            -e dnat_protocol=tcp \
            "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml" 2>/dev/null || true

        run_playbook "Cleanup: Delete DNAT (ingress HTTPS)" \
            -e dnat_router_name="${TENANT_A}" \
            -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
            -e dnat_public_port=443 \
            -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
            -e dnat_internal_port=443 \
            -e dnat_protocol=tcp \
            "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml" 2>/dev/null || true

        run_playbook "Cleanup: Release public IP (ingress)" \
            -e ipam_state_file="${IPAM_STATE_FILE}" \
            -e ipam_purpose="${TENANT_A}-ingress" \
            "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml" 2>/dev/null || true
    fi

    # Tenant-a cluster_infra delete
    if [ -n "${VLAN_A:-}" ]; then
        compute_veth_addresses "${VLAN_A}" "${TENANT_A}"
        run_playbook "Cleanup: Delete SNAT (tenant-a)" \
            -e snat_router_name="${TENANT_A}" \
            -e snat_source_subnet="${TENANT_A_SUBNET_CIDR}" \
            -e snat_veth_interface="${SNAT_VETH_NS}" \
            -e snat_external_subnet="${EXTERNAL_SUBNET}" \
            -e snat_external_interface=eth0 \
            "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_snat.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Delete router (tenant-a)" \
            -e router_name="${TENANT_A}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_router.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Reset port leaf-1:swp2" \
            -e port_name=swp2 \
            -l clab-${LAB_NAME}-leaf-1 \
            "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Reset port leaf-2:swp2" \
            -e port_name=swp2 \
            -l clab-${LAB_NAME}-leaf-2 \
            "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Delete VLAN (tenant-a)" \
            -e vlan_id="${VLAN_A}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/l2_delete_vlan.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Release VLAN (tenant-a)" \
            -e ipam_state_file="${IPAM_STATE_FILE}" \
            -e ipam_purpose="${TENANT_A}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/ipam_release_vlan.yaml" 2>/dev/null || true
    fi

    # Tenant-b cluster_infra delete
    if [ -n "${VLAN_B:-}" ]; then
        compute_veth_addresses "${VLAN_B}" "${TENANT_B}"
        run_playbook "Cleanup: Delete SNAT (tenant-b)" \
            -e snat_router_name="${TENANT_B}" \
            -e snat_source_subnet="${TENANT_B_SUBNET_CIDR}" \
            -e snat_veth_interface="${SNAT_VETH_NS}" \
            -e snat_external_subnet="${EXTERNAL_SUBNET}" \
            -e snat_external_interface=eth0 \
            "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_snat.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Delete router (tenant-b)" \
            -e router_name="${TENANT_B}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_router.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Reset port leaf-2:swp3" \
            -e port_name=swp3 \
            -l clab-${LAB_NAME}-leaf-2 \
            "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Delete VLAN (tenant-b)" \
            -e vlan_id="${VLAN_B}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/l2_delete_vlan.yaml" 2>/dev/null || true
        run_playbook "Cleanup: Release VLAN (tenant-b)" \
            -e ipam_state_file="${IPAM_STATE_FILE}" \
            -e ipam_purpose="${TENANT_B}" \
            "${CLUSTER_INFRA_PLAYBOOKS}/ipam_release_vlan.yaml" 2>/dev/null || true
    fi

    # Flush host IPs
    for host in host-1 host-2 host-3; do
        docker exec "${PREFIX}-${host}" ip addr flush dev eth1 2>/dev/null || true
    done
}

trap cleanup EXIT

echo "============================================================"
echo "  agentless_net.steps — Full Test (wrappers + data-plane)"
echo "============================================================"

# ---------------------------------------------------------------
# PHASE 1: cluster_infra — Create (tenant-a)
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 1: cluster_infra — Create (tenant-a)"

run_playbook "Allocate VLAN (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_vlan_pool_start="${VLAN_POOL_START}" \
    -e ipam_vlan_pool_end="${VLAN_POOL_END}" \
    -e ipam_purpose="${TENANT_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_allocate_vlan.yaml"

VLAN_A=$(read_ipam_state | python3 -c "import sys,json; print(json.load(sys.stdin)['vlans']['${TENANT_A}'])")
echo "  Allocated VLAN ID: ${VLAN_A}"
compute_veth_addresses "${VLAN_A}" "${TENANT_A}"
TENANT_A_EXTERNAL_PEER_IP="${EXTERNAL_PEER_IP}"
TENANT_A_EXTERNAL_ROUTER_IP="${EXTERNAL_ROUTER_IP}"
TENANT_A_EXTERNAL_GATEWAY="${EXTERNAL_GATEWAY}"
TENANT_A_EXTERNAL_SUBNET="${EXTERNAL_SUBNET}"
TENANT_A_SNAT_VETH_NS="${SNAT_VETH_NS}"

run_playbook "Create VLAN on switches (tenant-a)" \
    -e vlan_id="${VLAN_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_create_vlan.yaml"

run_playbook "Set access port leaf-1:swp2 (tenant-a, host-1)" \
    -e vlan_id="${VLAN_A}" \
    -e port_name=swp2 \
    -l clab-${LAB_NAME}-leaf-1 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_set_access_port.yaml"

run_playbook "Set access port leaf-2:swp2 (tenant-a, host-2)" \
    -e vlan_id="${VLAN_A}" \
    -e port_name=swp2 \
    -l clab-${LAB_NAME}-leaf-2 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_set_access_port.yaml"

run_playbook "Create L3 router (tenant-a)" \
    -e router_name="${TENANT_A}" \
    -e router_vlan_id="${VLAN_A}" \
    -e router_internal_subnet="${TENANT_A_SUBNET_CIDR}" \
    -e router_internal_gateway="${TENANT_A_SUBNET_GATEWAY}" \
    -e router_trunk_interface="${TRUNK_INTERFACE}" \
    -e router_external_ip="${TENANT_A_EXTERNAL_ROUTER_IP}" \
    -e router_external_peer_ip="${TENANT_A_EXTERNAL_PEER_IP}" \
    -e router_external_gateway="${TENANT_A_EXTERNAL_GATEWAY}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_router.yaml"

run_playbook "Create SNAT (tenant-a)" \
    -e snat_router_name="${TENANT_A}" \
    -e snat_source_subnet="${TENANT_A_SUBNET_CIDR}" \
    -e snat_veth_interface="${TENANT_A_SNAT_VETH_NS}" \
    -e snat_external_subnet="${TENANT_A_EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_snat.yaml"

# ---------------------------------------------------------------
# PHASE 2: cluster_infra — Create (tenant-b)
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 2: cluster_infra — Create (tenant-b)"

run_playbook "Allocate VLAN (tenant-b)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_vlan_pool_start="${VLAN_POOL_START}" \
    -e ipam_vlan_pool_end="${VLAN_POOL_END}" \
    -e ipam_purpose="${TENANT_B}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_allocate_vlan.yaml"

VLAN_B=$(read_ipam_state | python3 -c "import sys,json; print(json.load(sys.stdin)['vlans']['${TENANT_B}'])")
echo "  Allocated VLAN ID: ${VLAN_B}"
compute_veth_addresses "${VLAN_B}" "${TENANT_B}"
TENANT_B_EXTERNAL_PEER_IP="${EXTERNAL_PEER_IP}"
TENANT_B_EXTERNAL_ROUTER_IP="${EXTERNAL_ROUTER_IP}"
TENANT_B_EXTERNAL_GATEWAY="${EXTERNAL_GATEWAY}"
TENANT_B_EXTERNAL_SUBNET="${EXTERNAL_SUBNET}"
TENANT_B_SNAT_VETH_NS="${SNAT_VETH_NS}"

run_playbook "Create VLAN on switches (tenant-b)" \
    -e vlan_id="${VLAN_B}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_create_vlan.yaml"

run_playbook "Set access port leaf-2:swp3 (tenant-b, host-3)" \
    -e vlan_id="${VLAN_B}" \
    -e port_name=swp3 \
    -l clab-${LAB_NAME}-leaf-2 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_set_access_port.yaml"

run_playbook "Create L3 router (tenant-b)" \
    -e router_name="${TENANT_B}" \
    -e router_vlan_id="${VLAN_B}" \
    -e router_internal_subnet="${TENANT_B_SUBNET_CIDR}" \
    -e router_internal_gateway="${TENANT_B_SUBNET_GATEWAY}" \
    -e router_trunk_interface="${TRUNK_INTERFACE}" \
    -e router_external_ip="${TENANT_B_EXTERNAL_ROUTER_IP}" \
    -e router_external_peer_ip="${TENANT_B_EXTERNAL_PEER_IP}" \
    -e router_external_gateway="${TENANT_B_EXTERNAL_GATEWAY}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_router.yaml"

run_playbook "Create SNAT (tenant-b)" \
    -e snat_router_name="${TENANT_B}" \
    -e snat_source_subnet="${TENANT_B_SUBNET_CIDR}" \
    -e snat_veth_interface="${TENANT_B_SNAT_VETH_NS}" \
    -e snat_external_subnet="${TENANT_B_EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_snat.yaml"

# ---------------------------------------------------------------
# PHASE 3: external_access — Create (tenant-a)
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 3: external_access — Create (tenant-a)"

run_playbook "Allocate public IP — API (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_pool_start="${PUBLIC_IP_POOL_START}" \
    -e ipam_pool_end="${PUBLIC_IP_POOL_END}" \
    -e ipam_purpose="${TENANT_A}-api" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_allocate_ip.yaml"

run_playbook "Allocate public IP — ingress (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_pool_start="${PUBLIC_IP_POOL_START}" \
    -e ipam_pool_end="${PUBLIC_IP_POOL_END}" \
    -e ipam_purpose="${TENANT_A}-ingress" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_allocate_ip.yaml"

IPAM_STATE=$(read_ipam_state)
TENANT_A_API_PUBLIC_IP=$(echo "${IPAM_STATE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['public_ips']['${TENANT_A}-api'][0])")
TENANT_A_INGRESS_PUBLIC_IP=$(echo "${IPAM_STATE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['public_ips']['${TENANT_A}-ingress'][0])")
echo "  API public IP: ${TENANT_A_API_PUBLIC_IP}"
echo "  Ingress public IP: ${TENANT_A_INGRESS_PUBLIC_IP}"

run_playbook "Create DNAT — API port 6443 (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${TENANT_A_SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

run_playbook "Create DNAT — ingress HTTP (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=80 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=80 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

run_playbook "Create DNAT — ingress HTTPS (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=443 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

# ---------------------------------------------------------------
# PHASE 4: Host setup
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 4: Host setup (assign IPs + default gateways)"

for pair in "host-1:${TENANT_A_HOST1_IP}/24" "host-2:${TENANT_A_HOST2_IP}/24" "host-3:${TENANT_B_HOST3_IP}/24"; do
    host="${pair%%:*}"
    ip="${pair##*:}"
    container="${PREFIX}-${host}"
    docker exec "$container" ip addr flush dev eth1 2>/dev/null || true
    docker exec "$container" ip addr add "$ip" dev eth1
    echo "  ${host} -> ${ip}"
done

docker exec "${PREFIX}-host-1" ip route replace default via "${TENANT_A_SUBNET_GATEWAY}"
docker exec "${PREFIX}-host-2" ip route replace default via "${TENANT_A_SUBNET_GATEWAY}"
docker exec "${PREFIX}-host-3" ip route replace default via "${TENANT_B_SUBNET_GATEWAY}"
echo "  host-1, host-2 -> ${TENANT_A_SUBNET_GATEWAY} (tenant-a)"
echo "  host-3 -> ${TENANT_B_SUBNET_GATEWAY} (tenant-b)"

info "Waiting for VLAN convergence (10s)..."
sleep 10

info "Warming up ARP..."
docker exec "${PREFIX}-host-1" ping -c 2 -W 3 "${TENANT_A_HOST2_IP}" &>/dev/null || true
docker exec "${PREFIX}-host-2" ping -c 2 -W 3 "${TENANT_A_HOST1_IP}" &>/dev/null || true
sleep 2

# ---------------------------------------------------------------
# PHASE 5: Control-plane check
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 5: Control-plane — management network reachability"

for pair in "leaf-1:172.20.20.11" "leaf-2:172.20.20.12" "net-node:172.20.20.30" "host-1:172.20.20.20" "host-2:172.20.20.21" "host-3:172.20.20.22"; do
    name="${pair%%:*}"
    ip="${pair##*:}"
    if ping -c 2 -W 3 "$ip" &>/dev/null; then
        ok "${name} (${ip}) reachable via management network"
    else
        fail "${name} (${ip}) unreachable via management network"
        errors=$((errors + 1))
    fi
done

# ---------------------------------------------------------------
# PHASE 6: Data-plane verification
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 6: Data-plane verification"

# Intra-tenant: host-1 <-> host-2 (tenant-a, same VLAN)
if docker exec "${PREFIX}-host-1" ping -c 3 -W 3 "${TENANT_A_HOST2_IP}" &>/dev/null; then
    ok "host-1 (tenant-a) -> host-2 (tenant-a)"
else
    fail "host-1 (tenant-a) -> host-2 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 "${TENANT_A_HOST1_IP}" &>/dev/null; then
    ok "host-2 (tenant-a) -> host-1 (tenant-a)"
else
    fail "host-2 (tenant-a) -> host-1 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

# Cross-tenant isolation
if docker exec "${PREFIX}-host-1" ping -c 2 -W 3 "${TENANT_B_HOST3_IP}" &>/dev/null; then
    fail "host-1 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 "${TENANT_B_HOST3_IP}" &>/dev/null; then
    fail "host-2 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

# Router namespace connectivity
if docker exec "$NET_NODE" ip netns exec "${TENANT_A}" ping -c 2 -W 3 "${TENANT_A_HOST1_IP}" &>/dev/null; then
    ok "net-node (tenant-a ns) -> host-1"
else
    fail "net-node (tenant-a ns) -> host-1 — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "$NET_NODE" ip netns exec "${TENANT_B}" ping -c 2 -W 3 "${TENANT_B_HOST3_IP}" &>/dev/null; then
    ok "net-node (tenant-b ns) -> host-3"
else
    fail "net-node (tenant-b ns) -> host-3 — expected PASS"
    errors=$((errors + 1))
fi

# SNAT egress
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

# ---------------------------------------------------------------
# PHASE 7: Idempotency — re-run tenant-a creates
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 7: Idempotency — re-run tenant-a creates"

run_playbook "Allocate VLAN (idempotent)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_vlan_pool_start="${VLAN_POOL_START}" \
    -e ipam_vlan_pool_end="${VLAN_POOL_END}" \
    -e ipam_purpose="${TENANT_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_allocate_vlan.yaml"

run_playbook "Create VLAN on switches (idempotent)" \
    -e vlan_id="${VLAN_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_create_vlan.yaml"

run_playbook "Create L3 router (idempotent)" \
    -e router_name="${TENANT_A}" \
    -e router_vlan_id="${VLAN_A}" \
    -e router_internal_subnet="${TENANT_A_SUBNET_CIDR}" \
    -e router_internal_gateway="${TENANT_A_SUBNET_GATEWAY}" \
    -e router_trunk_interface="${TRUNK_INTERFACE}" \
    -e router_external_ip="${TENANT_A_EXTERNAL_ROUTER_IP}" \
    -e router_external_peer_ip="${TENANT_A_EXTERNAL_PEER_IP}" \
    -e router_external_gateway="${TENANT_A_EXTERNAL_GATEWAY}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_router.yaml"

run_playbook "Create SNAT (idempotent)" \
    -e snat_router_name="${TENANT_A}" \
    -e snat_source_subnet="${TENANT_A_SUBNET_CIDR}" \
    -e snat_veth_interface="${TENANT_A_SNAT_VETH_NS}" \
    -e snat_external_subnet="${TENANT_A_EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_snat.yaml"

run_playbook "Create DNAT API (idempotent)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${TENANT_A_SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

# ---------------------------------------------------------------
# PHASE 8: external_access — Delete (tenant-a)
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 8: external_access — Delete (tenant-a)"

run_playbook "Delete DNAT — API (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${TENANT_A_SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Delete DNAT — ingress HTTP (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=80 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=80 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Delete DNAT — ingress HTTPS (tenant-a)" \
    -e dnat_router_name="${TENANT_A}" \
    -e dnat_public_ip="${TENANT_A_INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=443 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Release public IP — API (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TENANT_A}-api" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml"

run_playbook "Release public IP — ingress (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TENANT_A}-ingress" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml"

# Clear external_access IPs so cleanup trap doesn't re-delete
TENANT_A_API_PUBLIC_IP=""
TENANT_A_INGRESS_PUBLIC_IP=""

# ---------------------------------------------------------------
# PHASE 9: cluster_infra — Delete (both tenants)
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 9: cluster_infra — Delete (both tenants)"

# Tenant-a
run_playbook "Delete SNAT (tenant-a)" \
    -e snat_router_name="${TENANT_A}" \
    -e snat_source_subnet="${TENANT_A_SUBNET_CIDR}" \
    -e snat_veth_interface="${TENANT_A_SNAT_VETH_NS}" \
    -e snat_external_subnet="${TENANT_A_EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_snat.yaml"

run_playbook "Delete L3 router (tenant-a)" \
    -e router_name="${TENANT_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_router.yaml"

run_playbook "Reset access port leaf-1:swp2" \
    -e port_name=swp2 \
    -l clab-${LAB_NAME}-leaf-1 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml"

run_playbook "Reset access port leaf-2:swp2" \
    -e port_name=swp2 \
    -l clab-${LAB_NAME}-leaf-2 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml"

run_playbook "Delete VLAN from switches (tenant-a)" \
    -e vlan_id="${VLAN_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_delete_vlan.yaml"

run_playbook "Release VLAN (tenant-a)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TENANT_A}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_release_vlan.yaml"

# Tenant-b
run_playbook "Delete SNAT (tenant-b)" \
    -e snat_router_name="${TENANT_B}" \
    -e snat_source_subnet="${TENANT_B_SUBNET_CIDR}" \
    -e snat_veth_interface="${TENANT_B_SNAT_VETH_NS}" \
    -e snat_external_subnet="${TENANT_B_EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_snat.yaml"

run_playbook "Delete L3 router (tenant-b)" \
    -e router_name="${TENANT_B}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_router.yaml"

run_playbook "Reset access port leaf-2:swp3" \
    -e port_name=swp3 \
    -l clab-${LAB_NAME}-leaf-2 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml"

run_playbook "Delete VLAN from switches (tenant-b)" \
    -e vlan_id="${VLAN_B}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_delete_vlan.yaml"

run_playbook "Release VLAN (tenant-b)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TENANT_B}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_release_vlan.yaml"

# Clear VLAN vars so cleanup trap doesn't re-delete
VLAN_A=""
VLAN_B=""

echo ""
if [ "$errors" -eq 0 ]; then
    echo "============================================================"
    echo "  All tests passed!"
    echo "============================================================"
else
    echo "============================================================"
    echo "  ${errors} test(s) FAILED"
    echo "============================================================"
    exit 1
fi
