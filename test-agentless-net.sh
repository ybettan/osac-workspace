#!/bin/bash
#
# Manual test script for agentless_net.steps playbook wrappers.
# Runs against the containerlab environment created by setup-lab.sh.
#
# Usage:
#   ./setup-lab.sh infra    # first, create the lab (infra only)
#   ./test-agentless-net.sh # then, run this script
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="${SCRIPT_DIR}/ansible/inventory.yml"
OSAC_COLLECTIONS="${SCRIPT_DIR}/osac-aap/collections/ansible_collections"
VENDOR_COLLECTIONS="${SCRIPT_DIR}/osac-aap/vendor/ansible_collections"
COLLECTIONS_PATH="${OSAC_COLLECTIONS}:${VENDOR_COLLECTIONS}"
CLUSTER_INFRA_PLAYBOOKS="${OSAC_COLLECTIONS}/agentless_net/steps/roles/cluster_infra/playbooks"
EXTERNAL_ACCESS_PLAYBOOKS="${OSAC_COLLECTIONS}/agentless_net/steps/roles/external_access/playbooks"

# Test parameters
IPAM_STATE_FILE="/etc/osac/network_state.json"
VLAN_POOL_START=100
VLAN_POOL_END=199
TEST_CLUSTER="test-cluster"
TRUNK_INTERFACE="eth1"
SUBNET_CIDR="10.100.0.0/24"
SUBNET_GATEWAY="10.100.0.1"
PUBLIC_IP_POOL_START="192.168.100.10"
PUBLIC_IP_POOL_END="192.168.100.50"

NET_NODE="clab-ybettan-ansible-net-lab-net-node"

export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_PATH}"

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

echo "============================================================"
echo "  agentless_net.steps — Manual Playbook Wrapper Test"
echo "============================================================"

# ---------------------------------------------------------------
# cluster_infra: CREATE
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 1: cluster_infra — Create"

run_playbook "Allocate VLAN" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_vlan_pool_start="${VLAN_POOL_START}" \
    -e ipam_vlan_pool_end="${VLAN_POOL_END}" \
    -e ipam_purpose="${TEST_CLUSTER}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_allocate_vlan.yaml"

# Read allocated VLAN ID
VLAN_ID=$(read_ipam_state | python3 -c "import sys,json; print(json.load(sys.stdin)['vlans']['${TEST_CLUSTER}'])")
echo "  Allocated VLAN ID: ${VLAN_ID}"

run_playbook "Create VLAN on switches" \
    -e vlan_id="${VLAN_ID}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_create_vlan.yaml"

run_playbook "Set access port (leaf-1:swp2)" \
    -e vlan_id="${VLAN_ID}" \
    -e port_name=swp2 \
    -l clab-ybettan-ansible-net-lab-leaf-1 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_set_access_port.yaml"

# Compute veth addresses
VETH_INDEX=$(( (VLAN_ID - VLAN_POOL_START) * 4 ))
EXTERNAL_PEER_IP="10.254.0.$((VETH_INDEX + 1))/30"
EXTERNAL_ROUTER_IP="10.254.0.$((VETH_INDEX + 2))/30"
EXTERNAL_GATEWAY="10.254.0.$((VETH_INDEX + 1))"

run_playbook "Create L3 router namespace" \
    -e router_name="${TEST_CLUSTER}" \
    -e router_vlan_id="${VLAN_ID}" \
    -e router_internal_subnet="${SUBNET_CIDR}" \
    -e router_internal_gateway="${SUBNET_GATEWAY}" \
    -e router_trunk_interface="${TRUNK_INTERFACE}" \
    -e router_external_ip="${EXTERNAL_ROUTER_IP}" \
    -e router_external_peer_ip="${EXTERNAL_PEER_IP}" \
    -e router_external_gateway="${EXTERNAL_GATEWAY}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_router.yaml"

SNAT_VETH_NS="v$(echo -n "${TEST_CLUSTER}" | md5sum | cut -c1-11)i"
EXTERNAL_SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_interface('${EXTERNAL_PEER_IP}').network)")

run_playbook "Create SNAT" \
    -e snat_router_name="${TEST_CLUSTER}" \
    -e snat_source_subnet="${SUBNET_CIDR}" \
    -e snat_veth_interface="${SNAT_VETH_NS}" \
    -e snat_external_subnet="${EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_snat.yaml"

# ---------------------------------------------------------------
# external_access: CREATE
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 2: external_access — Create"

run_playbook "Allocate public IP (API)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_pool_start="${PUBLIC_IP_POOL_START}" \
    -e ipam_pool_end="${PUBLIC_IP_POOL_END}" \
    -e ipam_purpose="${TEST_CLUSTER}-api" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_allocate_ip.yaml"

run_playbook "Allocate public IP (ingress)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_pool_start="${PUBLIC_IP_POOL_START}" \
    -e ipam_pool_end="${PUBLIC_IP_POOL_END}" \
    -e ipam_purpose="${TEST_CLUSTER}-ingress" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_allocate_ip.yaml"

# Read allocated IPs
IPAM_STATE=$(read_ipam_state)
API_PUBLIC_IP=$(echo "${IPAM_STATE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['public_ips']['${TEST_CLUSTER}-api'][0])")
INGRESS_PUBLIC_IP=$(echo "${IPAM_STATE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['public_ips']['${TEST_CLUSTER}-ingress'][0])")
echo "  API public IP: ${API_PUBLIC_IP}"
echo "  Ingress public IP: ${INGRESS_PUBLIC_IP}"

METALLB_INGRESS_IP="10.100.0.246"

run_playbook "Create DNAT (API port 6443)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

run_playbook "Create DNAT (ingress HTTP)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=80 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=80 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

run_playbook "Create DNAT (ingress HTTPS)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=443 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

# ---------------------------------------------------------------
# IDEMPOTENCY CHECK
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 3: Idempotency — Run creates again"

run_playbook "Allocate VLAN (idempotent)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_vlan_pool_start="${VLAN_POOL_START}" \
    -e ipam_vlan_pool_end="${VLAN_POOL_END}" \
    -e ipam_purpose="${TEST_CLUSTER}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_allocate_vlan.yaml"

run_playbook "Create VLAN on switches (idempotent)" \
    -e vlan_id="${VLAN_ID}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_create_vlan.yaml"

run_playbook "Create L3 router namespace (idempotent)" \
    -e router_name="${TEST_CLUSTER}" \
    -e router_vlan_id="${VLAN_ID}" \
    -e router_internal_subnet="${SUBNET_CIDR}" \
    -e router_internal_gateway="${SUBNET_GATEWAY}" \
    -e router_trunk_interface="${TRUNK_INTERFACE}" \
    -e router_external_ip="${EXTERNAL_ROUTER_IP}" \
    -e router_external_peer_ip="${EXTERNAL_PEER_IP}" \
    -e router_external_gateway="${EXTERNAL_GATEWAY}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_router.yaml"

run_playbook "Create SNAT (idempotent)" \
    -e snat_router_name="${TEST_CLUSTER}" \
    -e snat_source_subnet="${SUBNET_CIDR}" \
    -e snat_veth_interface="${SNAT_VETH_NS}" \
    -e snat_external_subnet="${EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_create_snat.yaml"

run_playbook "Create DNAT API (idempotent)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_create_dnat.yaml"

# ---------------------------------------------------------------
# external_access: DELETE
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 4: external_access — Delete"

run_playbook "Delete DNAT (API)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${API_PUBLIC_IP}" \
    -e dnat_public_port=6443 \
    -e dnat_internal_ip="${SUBNET_GATEWAY}" \
    -e dnat_internal_port=6443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Delete DNAT (ingress HTTP)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=80 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=80 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Delete DNAT (ingress HTTPS)" \
    -e dnat_router_name="${TEST_CLUSTER}" \
    -e dnat_public_ip="${INGRESS_PUBLIC_IP}" \
    -e dnat_public_port=443 \
    -e dnat_internal_ip="${METALLB_INGRESS_IP}" \
    -e dnat_internal_port=443 \
    -e dnat_protocol=tcp \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/l3_delete_dnat.yaml"

run_playbook "Release public IP (API)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TEST_CLUSTER}-api" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml"

run_playbook "Release public IP (ingress)" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TEST_CLUSTER}-ingress" \
    "${EXTERNAL_ACCESS_PLAYBOOKS}/ipam_release_ip.yaml"

# ---------------------------------------------------------------
# cluster_infra: DELETE
# ---------------------------------------------------------------
echo ""
echo ">>> PHASE 5: cluster_infra — Delete"

run_playbook "Delete SNAT" \
    -e snat_router_name="${TEST_CLUSTER}" \
    -e snat_source_subnet="${SUBNET_CIDR}" \
    -e snat_veth_interface="${SNAT_VETH_NS}" \
    -e snat_external_subnet="${EXTERNAL_SUBNET}" \
    -e snat_external_interface=eth0 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_snat.yaml"

run_playbook "Delete L3 router namespace" \
    -e router_name="${TEST_CLUSTER}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l3_delete_router.yaml"

run_playbook "Reset access port (leaf-1:swp2)" \
    -e port_name=swp2 \
    -l clab-ybettan-ansible-net-lab-leaf-1 \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_reset_port.yaml"

run_playbook "Delete VLAN from switches" \
    -e vlan_id="${VLAN_ID}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/l2_delete_vlan.yaml"

run_playbook "Release VLAN allocation" \
    -e ipam_state_file="${IPAM_STATE_FILE}" \
    -e ipam_purpose="${TEST_CLUSTER}" \
    "${CLUSTER_INFRA_PLAYBOOKS}/ipam_release_vlan.yaml"

echo ""
echo "============================================================"
echo "  All tests passed!"
echo "============================================================"
