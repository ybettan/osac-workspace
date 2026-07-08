# Agentless Networking E2E Lab Topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Bare-metal host                               │
│                                                                          │
│  ┌──────────── Containerlab fabric ───────────────────────────────────┐  │
│  │                                                                    │  │
│  │  ┌────────┐             trunk             ┌────────┐              │  │
│  │  │ leaf-1 │ swp1 ◄──────────────────► swp1│ leaf-2 │              │  │
│  │  │ (.11)  │                               │ (.12)  │              │  │
│  │  └┬──┬────┘                               └───┬──┬─┘              │  │
│  │   │  │                                        │  │                │  │
│  │ swp2 swp3                                  swp2  swp3             │  │
│  │   │  │                                        │  │                │  │
│  │   │  ▼                                        │  │                │  │
│  │   │ net-node ◄── eth2 ──► upstream-router     │  │                │  │
│  │   │ (.30)     eBGP /30    (.40)               │  │                │  │
│  │   │  │                                        │  │                │  │
│  │   │ eth1 (trunk)                              │  │                │  │
│  └───┼──┼────────────────────────────────────────┼──┼────────────────┘  │
│      │  │                                        │  │                    │
│   br-host1                                  br-host2  br-host3          │
│      │                                        │        │                 │
│  ┌───┴────────┐                          ┌────┴─────┐ ┌┴───────────┐    │
│  │  host-1    │                          │  host-2  │ │  host-3    │    │
│  │  KVM VM    │                          │  KVM VM  │ │  KVM VM    │    │
│  │  tenant 1  │                          │  tenant 1│ │  tenant 2  │    │
│  └────────────┘                          └──────────┘ └────────────┘    │
│                                                                          │
│  ┌──────────── KVM (cluster-tool) ────────────────────────────────────┐  │
│  │                                                                    │  │
│  │  mgmt-server (OCP SNO + OSAC)                                      │  │
│  │  - fulfillment-service, osac-operator, AAP                         │  │
│  │  NIC attached to containerlab management bridge (172.20.20.0/24)   │  │
│  │  so AAP can SSH to net-node and switches                           │  │
│  │                                                                    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  Management network: 172.20.20.0/24                                      │
│  eBGP: net-node (AS 65001) ◄──► upstream-router (AS 65000)              │
└──────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Type | Mgmt IP | Purpose |
|-----------|------|---------|---------|
| leaf-1 | Containerlab (Cumulus VX) | 172.20.20.11 | VLAN switch |
| leaf-2 | Containerlab (Cumulus VX) | 172.20.20.12 | VLAN switch |
| net-node | Containerlab (Alpine) | 172.20.20.30 | L3 routing, IPAM, SNAT/DNAT, FRR/BGP |
| upstream-router | Containerlab (Alpine) | 172.20.20.40 | DC edge router, eBGP peer |
| sushy-emulator | Containerlab (Alpine) | 172.20.20.50 | Redfish BMC emulator for host KVM VMs |
| host-1 | KVM VM | — | Bare-metal host, tenant 1 (on leaf-1) |
| host-2 | KVM VM | — | Bare-metal host, tenant 1 (on leaf-2, cross-switch L2) |
| host-3 | KVM VM | — | Bare-metal host, tenant 2 (on leaf-2) |
| mgmt-server | KVM VM (cluster-tool) | — | OCP SNO + OSAC stack |

## Containerlab Links

| Link | Purpose |
|------|---------|
| leaf-1:swp1 ↔ leaf-2:swp1 | Inter-switch trunk (carries all VLANs) |
| leaf-1:swp2 ↔ host:leaf1-swp2 | Switch port exposed to host for host-1 VM bridge |
| leaf-1:swp3 ↔ net-node:eth1 | Trunk to L3 gateway |
| leaf-2:swp2 ↔ host:leaf2-swp2 | Switch port exposed to host for host-2 VM bridge |
| leaf-2:swp3 ↔ host:leaf2-swp3 | Switch port exposed to host for host-3 VM bridge |
| net-node:eth2 ↔ upstream-router:eth1 | eBGP peering (/30 point-to-point) |

## VM-to-Switch Connectivity

KVM VMs connect to the containerlab switch fabric through Linux bridges:

1. Containerlab creates host-side veth endpoints using the `host:` link syntax
   (e.g., `leaf-1:swp2 ↔ host:leaf1-swp2` creates a `leaf1-swp2` interface on the bare-metal host)
2. A Linux bridge is created per host VM (e.g., `br-host1`)
3. The host-side veth endpoint is added to the bridge (`ip link set leaf1-swp2 master br-host1`)
4. The KVM VM's data-plane NIC is attached to the same bridge via libvirt

```
  leaf-1 container                 bare-metal host                  KVM VM
  ┌──────────────┐    veth pair    ┌─────────────┐    libvirt     ┌──────────┐
  │    swp2      ├────────────────►│ leaf1-swp2  │               │          │
  └──────────────┘                 │      │       │               │  host-1  │
                                   │  br-host1   │◄──────────────┤  eth0    │
                                   └─────────────┘               └──────────┘
```

This gives each VM a direct L2 path into the switch, as if physically cabled.

| VM | Bridge | Veth endpoint | Switch port |
|----|--------|---------------|-------------|
| host-1 | br-host1 | leaf1-swp2 | leaf-1:swp2 |
| host-2 | br-host2 | leaf2-swp2 | leaf-2:swp2 |
| host-3 | br-host3 | leaf2-swp3 | leaf-2:swp3 |

## BMC Emulation (sushy-tools)

The sushy-emulator container provides a Redfish API that emulates a BMC for each
host KVM VM. The Bare Metal Operator (BMO) on the mgmt-server uses this API to
power on/off VMs and attach boot media (discovery ISO/qcow2), just as it would
with real IPMI/Redfish hardware.

The container runs on the management network (172.20.20.50) and has the host's
libvirt socket mounted (`/var/run/libvirt/libvirt-sock`) so it can control KVM VMs.
BMH CRs on the mgmt-server point to `http://172.20.20.50:8000` as the BMC address.

## mgmt-server Connectivity

The mgmt-server has no data-plane connection to the switch fabric. It only needs
management network access so AAP can SSH to the lab nodes (net-node, switches).

Containerlab creates a Docker bridge for the management network (172.20.20.0/24).
All containerlab nodes are attached to it. The mgmt-server VM gets a NIC attached
to the same bridge during VM creation, giving AAP direct L2 access to all lab nodes.
