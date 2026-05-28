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

# gw-node: one interface per tenant
docker exec "${PREFIX}-gw-node" ip addr flush dev eth1 2>/dev/null || true
docker exec "${PREFIX}-gw-node" ip addr add 10.100.0.254/24 dev eth1
echo "  gw-node eth1 -> 10.100.0.254/24 (tenant-a)"
docker exec "${PREFIX}-gw-node" ip addr flush dev eth2 2>/dev/null || true
docker exec "${PREFIX}-gw-node" ip addr add 10.200.0.254/24 dev eth2
echo "  gw-node eth2 -> 10.200.0.254/24 (tenant-b)"

# Set default gateways on hosts (VRR address = their door out of the subnet)
info "Setting default gateways on hosts..."
docker exec "${PREFIX}-host-1" ip route replace default via 10.100.0.1
docker exec "${PREFIX}-host-2" ip route replace default via 10.100.0.1
docker exec "${PREFIX}-host-3" ip route replace default via 10.200.0.1
echo "  host-1, host-2 -> 10.100.0.1 (tenant-a VRR)"
echo "  host-3 -> 10.200.0.1 (tenant-b VRR)"

# ---------- step 6b: configure SNAT/DNAT on gw-node ----------

info "Configuring gateway node (IP forwarding + NAT)..."

# Install iptables (Alpine doesn't have it by default)
docker exec "${PREFIX}-gw-node" apk add --no-cache iptables >/dev/null 2>&1
echo "  Installed iptables"

# Enable IP forwarding (let gw-node route packets between interfaces)
docker exec "${PREFIX}-gw-node" sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "  Enabled IP forwarding"

# Block forwarding between tenant interfaces (preserve isolation!)
# gw-node must only route tenant ↔ eth0, never tenant-a ↔ tenant-b
docker exec "${PREFIX}-gw-node" iptables -A FORWARD -i eth1 -o eth2 -j DROP
docker exec "${PREFIX}-gw-node" iptables -A FORWARD -i eth2 -o eth1 -j DROP
echo "  Blocked inter-tenant forwarding (eth1 ↔ eth2)"

# SNAT: masquerade tenant traffic leaving via eth0 (management/external)
docker exec "${PREFIX}-gw-node" iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
docker exec "${PREFIX}-gw-node" iptables -t nat -A POSTROUTING -s 10.200.0.0/24 -o eth0 -j MASQUERADE
echo "  Added MASQUERADE rules for tenant-a and tenant-b"

# DNAT: forward gw-node:6443 to host-1:6443 (simulates API server access)
docker exec "${PREFIX}-gw-node" iptables -t nat -A PREROUTING -d 172.20.20.30 -p tcp --dport 6443 -j DNAT --to-destination 10.100.0.10:6443
# Also SNAT the DNAT'd traffic so host-1 replies via gw-node, not directly via mgmt network
docker exec "${PREFIX}-gw-node" iptables -t nat -A POSTROUTING -d 10.100.0.10 -p tcp --dport 6443 -j MASQUERADE
echo "  Added DNAT rule: 172.20.20.30:6443 -> 10.100.0.10:6443"

# ---------- step 7: wait for EVPN convergence ----------

info "Waiting for BGP/EVPN convergence (15s)..."
sleep 15

# Warm up ARP/MAC learning across VXLAN before running tests
info "Warming up VXLAN paths..."
docker exec "${PREFIX}-host-1" ping -c 1 -W 2 10.100.0.20 &>/dev/null || true
docker exec "${PREFIX}-host-2" ping -c 1 -W 2 10.100.0.10 &>/dev/null || true
docker exec "${PREFIX}-gw-node" ping -c 1 -W 2 10.100.0.1 &>/dev/null || true
docker exec "${PREFIX}-gw-node" ping -c 1 -W 2 10.200.0.1 &>/dev/null || true
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

# gw-node: verify it can reach both tenant VRR gateways
if docker exec "${PREFIX}-gw-node" ping -c 2 -W 3 10.100.0.1 &>/dev/null; then
    ok "gw-node -> tenant-a VRR (10.100.0.1)"
else
    fail "gw-node -> tenant-a VRR (10.100.0.1) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-gw-node" ping -c 2 -W 3 10.200.0.1 &>/dev/null; then
    ok "gw-node -> tenant-b VRR (10.200.0.1)"
else
    fail "gw-node -> tenant-b VRR (10.200.0.1) — expected PASS"
    errors=$((errors + 1))
fi

# SNAT: hosts should reach the management network via gw-node
if docker exec "${PREFIX}-host-1" ping -c 2 -W 3 172.20.20.1 &>/dev/null; then
    ok "host-1 (tenant-a) -> 172.20.20.1 (SNAT egress)"
else
    fail "host-1 (tenant-a) -> 172.20.20.1 (SNAT egress) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-2" ping -c 2 -W 3 172.20.20.1 &>/dev/null; then
    ok "host-2 (tenant-a) -> 172.20.20.1 (SNAT egress, cross-leaf)"
else
    fail "host-2 (tenant-a) -> 172.20.20.1 (SNAT egress, cross-leaf) — expected PASS"
    errors=$((errors + 1))
fi

if docker exec "${PREFIX}-host-3" ping -c 2 -W 3 172.20.20.1 &>/dev/null; then
    ok "host-3 (tenant-b) -> 172.20.20.1 (SNAT egress)"
else
    fail "host-3 (tenant-b) -> 172.20.20.1 (SNAT egress) — expected PASS"
    errors=$((errors + 1))
fi

# DNAT: connect to gw-node:6443 from management network, should reach host-1
# Use host-2 as client (Alpine has nc; spine's nc isn't in docker exec PATH)
docker exec "${PREFIX}-host-1" sh -c "echo DNAT-OK | nc -l -p 6443 &" 2>/dev/null
sleep 1
dnat_result=$(docker exec "${PREFIX}-host-2" sh -c "echo | nc -w 2 172.20.20.30 6443 2>/dev/null" || true)
if [ "$dnat_result" = "DNAT-OK" ]; then
    ok "DNAT: 172.20.20.30:6443 -> host-1:6443"
else
    fail "DNAT: 172.20.20.30:6443 -> host-1:6443 — expected 'DNAT-OK' but got '${dnat_result}'"
    errors=$((errors + 1))
fi

echo ""
if [ "$errors" -eq 0 ]; then
    info "All tests passed!"
else
    info "${errors} test(s) FAILED"
    exit 1
fi
