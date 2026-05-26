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
3. **Sudo permissions** — `cumulus` user had restricted sudo. Granted full NOPASSWD via `docker exec`.
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

Tenant isolation test (Step 10 second part — creating tenant-b for isolation) deferred to Phase 6.

---

## Phase 3: Configure Linux Gateway Node (NAT/LB)

*(ready to start)*

---

## Phase 4: Build the `ansible.steps` Collection

*(pending Phase 3 completion)*

---

## Phase 5: Register and Test End-to-End Through OSAC

*(pending Phase 4 completion)*

---

## Phase 6: Multi-Tenant Isolation Test

*(pending Phase 5 completion)*
