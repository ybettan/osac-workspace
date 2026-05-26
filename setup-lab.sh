#!/usr/bin/env bash
#
# Run WITHOUT sudo: ./setup-lab.sh
# The script uses sudo internally only for containerlab commands.
# Make sure your sudo credentials are cached (run "sudo true" first if needed).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="${SCRIPT_DIR}/ansible-net-lab.clab.yml"
LAB_NAME="ybettan-ansible-net-lab"
PREFIX="clab-${LAB_NAME}"
CONTAINERLAB="/home/ybettan/go/bin/containerlab"

SWITCHES=("${PREFIX}-spine" "${PREFIX}-leaf-1" "${PREFIX}-leaf-2")

# ---------- helpers ----------

info()  { echo "==> $*"; }
ok()    { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }

# ---------- destroy ----------

if [ "${1:-}" = "destroy" ]; then
    info "Destroying lab..."
    sudo ${CONTAINERLAB} destroy -t "$TOPO_FILE" --cleanup
    info "Done."
    exit 0
fi

# ---------- step 1: deploy containerlab ----------

if docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-spine$"; then
    info "Lab already running — skipping deploy"
else
    info "Deploying Containerlab topology..."
    sudo ${CONTAINERLAB} deploy -t "$TOPO_FILE"
fi

# ---------- step 2: wait for switches ----------

wait_for_switch() {
    local sw="$1"
    local elapsed=0
    # Wait for NVUE
    while ! docker exec "$sw" nv show system 2>/dev/null | grep -q "hostname" ; do
        sleep 3; elapsed=$((elapsed + 3))
        [ "$elapsed" -ge 90 ] && break
    done
    # Wait for SSH
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

# ---------- step 4: configure fabric (underlay + all tenants) ----------

info "Configuring network fabric (underlay + tenant-a + tenant-b)..."
ansible-playbook \
    -i "${SCRIPT_DIR}/ansible/inventory.yml" \
    "${SCRIPT_DIR}/ansible/playbooks/configure_network.yml" \
    -e "@${SCRIPT_DIR}/ansible/vars/all.yml"

# ---------- step 6: assign host IPs ----------

info "Assigning host IPs..."

for pair in "host-1:10.100.0.10/24" "host-2:10.100.0.20/24" "host-3:10.200.0.20/24"; do
    host="${pair%%:*}"
    ip="${pair##*:}"
    container="${PREFIX}-${host}"
    docker exec "$container" ip addr flush dev eth1 2>/dev/null || true
    docker exec "$container" ip addr add "$ip" dev eth1
    echo "  ${host} -> ${ip}"
done

# ---------- step 7: wait for EVPN convergence ----------

info "Waiting for BGP/EVPN convergence (15s)..."
sleep 15

# Warm up ARP/MAC learning across VXLAN before running tests
info "Warming up VXLAN paths..."
docker exec "${PREFIX}-host-1" ping -c 1 -W 2 10.100.0.20 &>/dev/null || true
docker exec "${PREFIX}-host-2" ping -c 1 -W 2 10.100.0.10 &>/dev/null || true
sleep 2

# ---------- step 8: verification ----------

info "Running verification tests..."
echo ""

errors=0

# tenant-a: host-1 <-> host-2 should work
if docker exec "${PREFIX}-host-1" ping -c 3 -W 3 10.100.0.20 &>/dev/null; then
    ok "host-1 (tenant-a) -> host-2 (tenant-a)"
else
    fail "host-1 (tenant-a) -> host-2 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 10.100.0.10 &>/dev/null; then
    ok "host-2 (tenant-a) -> host-1 (tenant-a)"
else
    fail "host-2 (tenant-a) -> host-1 (tenant-a) — expected PASS"
    errors=$((errors + 1))
fi

# cross-tenant: host-1 -> host-3 should FAIL
if docker exec "${PREFIX}-host-1" ping -c 2 -W 3 10.200.0.20 &>/dev/null; then
    fail "host-1 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

# cross-tenant: host-2 -> host-3 should FAIL (same leaf, different VRF)
if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 10.200.0.20 &>/dev/null; then
    fail "host-2 (tenant-a) -> host-3 (tenant-b) — expected FAIL but got PASS (isolation broken!)"
    errors=$((errors + 1))
else
    ok "host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)"
fi

echo ""
if [ "$errors" -eq 0 ]; then
    info "All tests passed!"
else
    info "${errors} test(s) FAILED"
    exit 1
fi
