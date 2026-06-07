# Ansible Networking Backend — Execution Log

Tracks progress against the plan in `ansible-network.md`.

---

## Phase 1: Set Up Containerlab Test Environment

### Step 1 — Install Containerlab

Downloaded containerlab binary v0.75.0 directly to `~/go/bin/` (no sudo needed):

```bash
CLAB_VERSION=$(curl -s https://api.github.com/repos/srl-labs/containerlab/releases/latest | grep tag_name | cut -d'"' -f4 | tr -d 'v')
curl -sL "https://github.com/srl-labs/containerlab/releases/download/v${CLAB_VERSION}/containerlab_${CLAB_VERSION}_Linux_amd64.tar.gz" -o /tmp/containerlab.tar.gz
tar -xzf /tmp/containerlab.tar.gz -C /tmp/ containerlab
mv /tmp/containerlab ~/go/bin/containerlab
chmod +x ~/go/bin/containerlab
```

**Result:** `containerlab version` → v0.75.0 ✓

### Step 2 — Pull Cumulus VX image

```bash
docker pull networkop/cx:5.3.0
```

**Result:** Downloaded `networkop/cx:5.3.0` (sha256:bd2d53ff...) ✓

### Step 3 — Create topology file

Created `ansible-net-lab.clab.yml`:

```
spine (Cumulus VX)
├── swp1 ── leaf-1 swp1
└── swp2 ── leaf-2 swp1

leaf-1 (Cumulus VX)
├── swp1 ── spine swp1  (uplink)
├── swp2 ── host-1 eth1 (tenant worker)
└── swp3 ── gw-node eth1 (gateway)

leaf-2 (Cumulus VX)
├── swp1 ── spine swp2  (uplink)
└── swp2 ── host-2 eth1 (tenant worker)
```

Nodes:
- `spine`, `leaf-1`, `leaf-2` — Cumulus VX 5.3.0
- `host-1`, `host-2` — Alpine Linux (simulate bare-metal workers)
- `gw-node` — Alpine Linux (simulate gateway / SoftGate replacement)

**Result:** File created at `ansible-net-lab.clab.yml` ✓

### Step 4 — Deploy the lab

```bash
sudo /home/ybettan/go/bin/containerlab deploy -t /home/ybettan/go/src/github.com/osac/osac-installer/ansible-net-lab.clab.yml
```

**Result:** All 6 containers started successfully ✓

```
╭──────────────────────────────────────┬────────────────────┬─────────┬───────────────────╮
│                 Name                 │     Kind/Image     │  State  │   IPv4/6 Address  │
├──────────────────────────────────────┼────────────────────┼─────────┼───────────────────┤
│ clab-ybettan-ansible-net-lab-gw-node │ linux/alpine:3.19  │ running │ 172.20.20.2       │
│ clab-ybettan-ansible-net-lab-host-1  │ linux/alpine:3.19  │ running │ 172.20.20.6       │
│ clab-ybettan-ansible-net-lab-host-2  │ linux/alpine:3.19  │ running │ 172.20.20.7       │
│ clab-ybettan-ansible-net-lab-leaf-1  │ cvx/cx:5.3.0       │ running │ 172.20.20.3       │
│ clab-ybettan-ansible-net-lab-leaf-2  │ cvx/cx:5.3.0       │ running │ 172.20.20.5       │
│ clab-ybettan-ansible-net-lab-spine   │ cvx/cx:5.3.0       │ running │ 172.20.20.4       │
╰──────────────────────────────────────┴────────────────────┴─────────┴───────────────────╯
```

Containerlab created:
- A dedicated Docker bridge network `clab` (`172.20.20.0/24`) for management access (SSH/Ansible)
- 5 data-plane veth links wiring the topology:
  - `spine:swp1 ↔ leaf-1:swp1` and `spine:swp2 ↔ leaf-2:swp1` (uplinks)
  - `leaf-1:swp2 ↔ host-1:eth1` (tenant worker)
  - `leaf-1:swp3 ↔ gw-node:eth1` (gateway)
  - `leaf-2:swp2 ↔ host-2:eth1` (tenant worker)
- SSH config at `/etc/ssh/ssh_config.d/clab-ybettan-ansible-net-lab.conf`
- Lab directory at `clab-ybettan-ansible-net-lab/`

**Management IPs (stable, for Ansible inventory):**

| Node     | IP           | Role                        |
|----------|--------------|-----------------------------|
| gw-node  | 172.20.20.2  | Gateway / SoftGate replacement |
| leaf-1   | 172.20.20.3  | Leaf switch (host-1, gw-node) |
| spine    | 172.20.20.4  | Spine switch                |
| leaf-2   | 172.20.20.5  | Leaf switch (host-2)        |
| host-1   | 172.20.20.6  | Simulated bare-metal worker |
| host-2   | 172.20.20.7  | Simulated bare-metal worker |

### Step 5 — Verify basic connectivity

```bash
docker exec clab-ybettan-ansible-net-lab-spine net show version
docker exec clab-ybettan-ansible-net-lab-host-1 ping -c 2 172.20.20.7
docker exec clab-ybettan-ansible-net-lab-leaf-1 net show interface
```

**Result:** All checks passed ✓

- Cumulus VX 5.3.0 running on all 3 switches (confirmed via `net show version`)
- host-1 → host-2 ping via management network: 0% packet loss
- leaf-1 interfaces: `eth0` (mgmt, 172.20.20.3), `swp1` (uplink to spine, LLDP confirmed), `swp2` (→ host-1, UP), `swp3` (→ gw-node, UP), `mgmt` VRF wrapping eth0

---

## Phase 2: Manual Switch Configuration with Ansible

### Step 6 — Create Ansible inventory

Created `ansible/inventory.yml` with:
- `cumulus`/`cumulus` credentials for switches
- Per-host port mappings (`server_port`, `gateway_port`, `uplink_port`)
- Separate groups: `switches` (spine + leaves), `hosts` (host-1, host-2, gw-node)
- `become` disabled globally — NCLU read commands don't need sudo; added per-task where needed

```bash
ansible -i ansible/inventory.yml leaves -m raw -a "net show version"
```

**Result:** Both leaf-1 and leaf-2 respond — Cumulus Linux 5.3.0 ✓

---

### Step 7 — Write and run tenant VRF playbook

Rewrote `ansible/playbooks/configure_tenant.yml` from NCLU (`net add`) to **NVUE** (`nv set`) — Cumulus VX 5.3.0 uses NVUE as the primary CLI, not NCLU.

Issues encountered and resolved:
1. **`nclu` Ansible module deprecated** — `community.network.nclu` fails with Python deserialization errors on ansible-core 2.20. Switched to `raw` module running `nv set` commands directly.
2. **`netaddr` Python library missing** — required by `ansible.utils.ipaddr` filter. Installed via `pip install netaddr`.
3. **Sudo permissions** — `cumulus` user had restricted sudo. Granted full NOPASSWD via `docker exec`. Later discovered `nv` commands don't require sudo on Cumulus VX — removed `sudo` prefixes from all `nv set`/`nv config apply` commands. `vtysh` still requires sudo.
4. **Per-neighbor EVPN activation** — NVUE requires explicit `neighbor <id> address-family l2vpn-evpn enable on` in addition to the VRF-level enable.
5. **`redistribute connected` missing** — leaves weren't advertising loopback IPs via IPv4 BGP, so spine couldn't resolve EVPN next-hops. Added via NVUE.
6. **`advertise-all-vni` not exposed via NVUE** — had to add via `vtysh` as a separate task. Without it, FRR doesn't pick up local VNIs for EVPN advertisement.

```bash
ansible-playbook -i ansible/inventory.yml \
  ansible/playbooks/configure_tenant.yml \
  -e @ansible/vars/tenant-a.yml
```

**Result:** All 3 plays succeeded ✓

### Steps 8-9 — Verify BGP underlay and EVPN overlay

```
Spine BGP summary:
  IPv4 unicast: leaf-1 (AS 65001) PfxRcd=1, leaf-2 (AS 65002) PfxRcd=1
  L2VPN EVPN:   leaf-1 PfxRcd=1 PfxSnt=2, leaf-2 PfxRcd=1 PfxSnt=2

Leaf-1 EVPN VNI:
  VNI 10100 (L2) — 2 MACs, 2 ARPs, 1 Remote VTEP (10.0.0.2)
  VNI 10001 (L3) — tenant-a VRF
```

**Result:** BGP underlay established, EVPN routes exchanged, VNIs discovered ✓

### Step 10 — Test tenant connectivity

Assigned IPs to simulated workers:
- host-1 (leaf-1): `10.100.0.10/24`
- host-2 (leaf-2): `10.100.0.20/24`

```bash
docker exec clab-ybettan-ansible-net-lab-host-1 ping -c 4 10.100.0.20
# 4 packets transmitted, 4 received, 0% loss
docker exec clab-ybettan-ansible-net-lab-host-2 ping -c 2 10.100.0.10
# 2 packets transmitted, 2 received, 0% loss
```

**Result:** Bidirectional L2 connectivity across VXLAN/EVPN fabric ✓

### Consolidation — Automated setup and tenant isolation

Consolidated all manual steps into an automated, reproducible deployment:

**Topology update:**
- Added `host-3` on `leaf-2:swp3` for tenant-b isolation testing
- Assigned static management IPs in topology file (no more DHCP randomization):
  - spine: `172.20.20.10`, leaf-1: `172.20.20.11`, leaf-2: `172.20.20.12`
  - host-1: `172.20.20.20`, host-2: `172.20.20.21`, host-3: `172.20.20.22`
  - gw-node: `172.20.20.30`

**Playbook consolidation:**
- Merged `configure_tenant.yml` + `configure_tenant_b.yml` → `configure_network.yml`
- Single playbook configures underlay (spine BGP) + tenant-a (both leaves) + tenant-b (leaf-2 only)
- `advertise-all-vni` runs last on each leaf, after all `nv config apply` calls (NVUE regenerates FRR config and drops vtysh-only settings)
- Merged vars into `ansible/vars/all.yml` (fabric + tenant-a + tenant-b)
- Added `UserKnownHostsFile=/dev/null` to SSH args (stale host keys after redeploy)

**Setup script (`setup-lab.sh`):**
- Full zero-to-working automation: deploy → wait → fix sudo → configure → assign IPs → verify
- Parallel SSH readiness checks on all switches
- ARP warm-up pings before verification tests
- `./setup-lab.sh destroy` for teardown

**Tenant isolation test (Step 10 — COMPLETE):**

```
==> Running verification tests...

  [PASS] host-1 (tenant-a) -> host-2 (tenant-a)
  [PASS] host-2 (tenant-a) -> host-1 (tenant-a)
  [PASS] host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)
  [PASS] host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)

==> All tests passed!
```

- host-1 (10.100.0.10, VLAN 100, VRF tenant-a) ↔ host-2 (10.100.0.20, VLAN 100, VRF tenant-a): **PASS**
- host-1 → host-3 (10.200.0.20, VLAN 200, VRF tenant-b): **unreachable** (isolation works)
- host-2 → host-3 (same leaf, different VRF): **unreachable** (isolation works)

---

## Phase 3: Configure Linux Gateway Node (NAT/LB)

### Step 11 — Connect gw-node to both tenant networks

**Topology change:**
- Added second data plane link: `leaf-1:swp4 ↔ gw-node:eth2`
- gw-node now has two data plane interfaces:
  - eth1 (via leaf-1:swp3, VLAN 100) → tenant-a network (10.100.0.254/24)
  - eth2 (via leaf-1:swp4, VLAN 200) → tenant-b network (10.200.0.254/24)
- host-1 is NOT affected — it stays on swp2 (VLAN 100, tenant-a only)
- leaf-1 now has tenant-b config (VRF, VLAN 200, VNI 10200) but only to serve the gateway port

**Playbook changes:**
- leaf-1 play: added `gateway_port_a` (swp3) as access port in VLAN 100
- leaf-1 play: added tenant-b VRF/VLAN/VNI block + `gateway_port_b` (swp4) as access port in VLAN 200
- Moved `advertise-all-vni` to run after both tenant configs (avoids NVUE overwriting vtysh settings)

**Setup script changes:**
- Assigns gw-node eth1=10.100.0.254/24, eth2=10.200.0.254/24
- Added gw-node connectivity tests (ping tenant-a and tenant-b VRR addresses)

**Result:** All gw-node connectivity tests pass ✓

### Steps 12-13 — SNAT and DNAT

1. Added static default routes in both tenant VRFs on both leaves → gw-node
2. Set default gateways on all hosts → tenant VRR address
3. Enabled IP forwarding on gw-node (`net.ipv4.ip_forward=1`)
4. Added MASQUERADE rules for both tenant subnets (`-o eth0 -j MASQUERADE`)
5. Added FORWARD DROP rules to block inter-tenant routing (`eth1 ↔ eth2`)
6. Added DNAT rule: `172.20.20.30:6443 → 10.100.0.10:6443`
7. Added SNAT for DNAT'd traffic (lab workaround for shared management network asymmetric routing)

**Issues encountered:**
- **Inter-tenant leak via gateway** — IP forwarding on gw-node allowed routing between eth1 (tenant-a) and eth2 (tenant-b). Fixed with iptables FORWARD DROP rules.
- **DNAT asymmetric routing** — host-1 replied directly to the client via management network (connected route on eth0), bypassing gw-node's conntrack. Fixed by also MASQUERADEing DNAT'd traffic so host-1 replies to gw-node.
- **Host default route conflict** — `ip route add` failed because Docker already sets a default route via eth0. Fixed with `ip route replace`.

**Result:**

```
==> Running verification tests...

  [PASS] host-1 (tenant-a) -> host-2 (tenant-a)
  [PASS] host-2 (tenant-a) -> host-1 (tenant-a)
  [PASS] host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)
  [PASS] host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)
  [PASS] gw-node -> tenant-a VRR (10.100.0.1)
  [PASS] gw-node -> tenant-b VRR (10.200.0.1)
  [PASS] host-1 (tenant-a) -> 172.20.20.1 (SNAT egress)
  [PASS] host-2 (tenant-a) -> 172.20.20.1 (SNAT egress, cross-leaf)
  [PASS] host-3 (tenant-b) -> 172.20.20.1 (SNAT egress)
  [PASS] DNAT: 172.20.20.30:6443 -> host-1:6443

==> All tests passed!
```

---

## Phase 4: Build Reusable Ansible Collections + Refactor Lab

### Step 14 — Create `ansible_networking.l2` collection

Created `ansible_collections/ansible_networking/l2/` with two roles:
- `vlan` — create/delete VLANs via `network-runner` role
- `port` — set_access_port/reset_port via `network-runner` role

These are thin wrappers around the `network-runner` pip package, which provides vendor-agnostic switch configuration (Cumulus NVUE, SONiC, etc.).

**Result:** Committed in `a26fb4b`, later moved to `ansible_collections/` in `40b8dd9` ✓

### Step 15 — Create `ansible_networking.l3` collection

Created `ansible_collections/ansible_networking/l3/` with four roles:
- `router` — create/delete per-tenant Linux namespace with VLAN sub-interface on trunk + veth pair for external connectivity
- `snat` — create/delete MASQUERADE rules (inside namespace + on host)
- `dnat` — create/delete port-forwarding rules inside namespace
- `ipam` — allocate/release IPs from a JSON-backed pool

All L3 roles use `ansible.builtin.raw` over SSH — same as production.

**Result:** Committed in `fb76658`, later moved to `ansible_collections/` in `40b8dd9` ✓

### Step 16 — Simplify topology

Replaced the VXLAN/EVPN spine-leaf fabric with a pure VLAN L2 setup:
- Removed spine switch entirely (no BGP/EVPN needed)
- Direct leaf-1 ↔ leaf-2 trunk link carrying tagged VLANs
- Renamed gw-node → net-node (per-tenant routing via Linux namespaces instead of flat interfaces with iptables FORWARD rules)
- Single trunk port from leaf-1:swp3 → net-node:eth1 (was two access ports for two tenants)
- Flattened inventory (no spine/leaves subgroups)
- Replaced BGP/EVPN/VRF vars with simple resource pool + net-node config

**Result:** Committed in `e27b0d8` ✓

### Step 17 — Refactor setup-lab.sh

Replaced all inline `docker exec` / raw NVUE commands with collection calls:
- Added `run_play()` helper for inline ansible-playbook invocations via heredoc
- Resolved network-runner role path via `network_runner.__file__` (handles pip user-installs)
- Installed openssh on net-node so `ansible.builtin.raw` works over SSH (matching production)
- L2 provisioning via `ansible_networking.l2.vlan` and `ansible_networking.l2.port`
- L3 provisioning via `ansible_networking.l3.router`, `.snat`, `.dnat`

**Issues encountered and resolved:**
1. **network-runner role not found** — `sysconfig.get_path('data')` returns `/usr/local` but pip user-install places roles under `~/.local/...`. Fixed by resolving path via `network_runner.__file__`.
2. **`port_description` required** — `network-runner`'s `conf_trunk_port` and `conf_access_port` require a `port_description` variable. Added to the playbook and collection role.
3. **`loop_var` collision** — `network-runner`'s `run.yaml` uses `with_first_found` which overwrites the outer `item` variable, corrupting `port_name`. Fixed with `loop_control: loop_var: trunk_port`.
4. **Recursive template vars** — `vlan_id: "{{ vlan_id }}"` in l2 roles caused "Recursive loop detected" errors. Removed redundant vars blocks — Ansible naturally passes vars to included roles.
5. **`ansible_collections/` prefix required** — Ansible requires collections under an `ansible_collections/` directory. Moved from `ansible_networking/` to `ansible_collections/ansible_networking/`.
6. **Linux 15-char interface name limit** — `veth-tenant-a-out` (17 chars) exceeded the limit. Shortened to `v-tenant-a-o` (12 chars).
7. **net-node SSH** — Alpine container has no SSH daemon. Installed `openssh`, generated host keys, started `sshd`.
8. **VLAN convergence timing** — cross-switch L2 pings failed intermittently at 5s wait. Increased to 10s.

**Result:** Committed in `cdd22b9` ✓

### Step 18 — End-to-end validation

```
==> Running verification tests...

  [PASS] host-1 (tenant-a) -> host-2 (tenant-a)
  [PASS] host-2 (tenant-a) -> host-1 (tenant-a)
  [PASS] host-1 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)
  [PASS] host-2 (tenant-a) -> host-3 (tenant-b) — unreachable (isolation works)
  [PASS] net-node (tenant-a ns) -> host-1
  [PASS] net-node (tenant-b ns) -> host-3
  [PASS] host-1 (tenant-a) -> 172.20.20.1 (SNAT egress)
  [PASS] host-3 (tenant-b) -> 172.20.20.1 (SNAT egress)

==> All tests passed!
```

All 8 tests pass on clean deploy (`./setup-lab.sh destroy && ./setup-lab.sh`).

**Result:** Phase 4 complete ✓

---

## Phase 5: Register and Test End-to-End Through OSAC

*(pending Phase 4 completion)*

---

## Phase 6: Multi-Tenant Isolation Test

*(pending Phase 5 completion)*
