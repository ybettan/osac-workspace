# Agentless Networking E2E Lab Topology

Two logical networks:

- **Management** (`192.168.X.0/24`): flat L2 on the libvirt bridge created by cluster-tool.
  All nodes (mgmt VM, containers, host VMs) share this subnet. Used for SSH, API,
  DNS, DHCP, kubelet→API, and AAP automation.
- **Data** (switch fabric): containerlab Cumulus VX switches + net-node L3 router.
  Carries tenant traffic. VLANs are configured by AAP after initial deployment.

## 1) Data network before VLANs

```
                                ┌───────────────┐
                                │ u/s router    │
                                └───────┬───────┘
                                        │ eth1 (BGP peering, 10.253.0.0/30)
                                        │
                                        │ eth2
                                  ┌─────┴───────┐
                                  │  net-node   │
                                  └─────┬───────┘
                                        │ eth1 (trunk)
                                        │
                                   leaf-1:swp3
                                        │
                     ┌──────────────────┴──────────────────┐
                     │            leaf-1                   │──────────────│            leaf-2                   │
                     └───┬──────────────────┬──────────────┘ swp1──swp1   └─────┬──────────────────┬────────────┘
                         │ swp2             │ swp4              (trunk)          │ swp2             │ swp3
                         │ (untagged)       │ (untagged)                        │ (untagged)       │ (untagged)
                         │                  │                                   │                  │
                    ┌────┴────┐        ┌────┴────┐                         ┌────┴────┐        ┌────┴────┐
                    │ host-1  │        │ mgmt VM │                         │ host-2  │        │ host-3  │
                    └─────────┘        └─────────┘                         └─────────┘        └─────────┘

All ports in default VLAN — full L2 connectivity between all nodes
```

## 2) Management network before VLANs

```
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
│ mgmt VM │  │ host-1  │  │ host-2  │  │ host-3  │  │ leaf-1  │  │ leaf-2  │  │ net-node│
└────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘
     │            │            │            │            │            │            │
     └────────────┴────────────┴────────────┴────────────┴────────────┴────────────┘
                                  192.168.X.0/24
                          (DHCP, DNS, NAT, kubelet→API,
                           AAP SSH to switches/net-node)
```

## 3) Data network after VLANs (one cluster using host-2)

```
                                ┌───────────────┐
                                │ u/s router    │
                                └───────┬───────┘
                                        │ eth1 (BGP peering, 10.253.0.0/30)
                                        │
                                        │ eth2
                                  ┌─────┴───────┐
                                  │  net-node   │
                                  └─────┬───────┘
                                        │ eth1 (trunk, carries VLAN 100)
                                        │
                                   leaf-1:swp3
                                        │
                     ┌──────────────────┴──────────────────┐
                     │            leaf-1                   │──────────────│            leaf-2                   │
                     └───┬──────────────────┬──────────────┘ swp1──swp1   └─────┬──────────────────┬────────────┘
                         │ swp2             │ swp4              (trunk)          │ swp2             │ swp3
                         │ (untagged)       │ (untagged)                        │ VLAN 100         │ (untagged)
                         │                  │                                   │ (access)         │
                    ┌────┴────┐        ┌────┴────┐                         ┌────┴────┐        ┌────┴────┐
                    │ host-1  │        │ mgmt VM │                         │ host-2  │        │ host-3  │
                    └─────────┘        └─────────┘                         └─────────┘        └─────────┘

host-2 isolated on VLAN 100 — can only reach net-node (L3 router → DNAT)
Public IPs (192.168.100.x) announced via BGP through u/s router
```

## 4) Management network after VLANs (unchanged)

```
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
│ mgmt VM │  │ host-1  │  │ host-2  │  │ host-3  │  │ leaf-1  │  │ leaf-2  │  │ net-node│
└────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘
     │            │            │            │            │            │            │
     └────────────┴────────────┴────────────┴────────────┴────────────┴────────────┘
                                  192.168.X.0/24
                                      Unchanged
```

## Components

| Component | Type | Mgmt IP | Purpose |
|-----------|------|---------|---------|
| mgmt-server | KVM VM (cluster-tool) | .10 | OCP SNO + OSAC stack |
| leaf-1 | Containerlab (Cumulus VX) | .11 | VLAN switch |
| leaf-2 | Containerlab (Cumulus VX) | .12 | VLAN switch |
| net-node | Containerlab (Alpine) | .30 | L3 routing, IPAM, SNAT/DNAT, FRR/BGP |
| upstream-router | Containerlab (Alpine) | .40 | DC edge router, eBGP peer |
| host-1 | KVM VM | — | Bare-metal host, tenant 1 (on leaf-1) |
| host-2 | KVM VM | — | Bare-metal host, tenant 1 (on leaf-2, cross-switch L2) |
| host-3 | KVM VM | — | Bare-metal host, tenant 2 (on leaf-2) |

## Containerlab Links

| Link | Purpose |
|------|---------|
| leaf-1:swp1 ↔ leaf-2:swp1 | Inter-switch trunk (carries all VLANs) |
| leaf-1:swp2 ↔ host:leaf1-swp2 | Switch port exposed to host for host-1 VM bridge |
| leaf-1:swp3 ↔ net-node:eth1 | Trunk to L3 gateway |
| leaf-1:swp4 ↔ host:leaf1-swp4 | Switch port exposed to host for mgmt VM bridge |
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
| mgmt-server | br-mgmt | leaf1-swp4 | leaf-1:swp4 |

## Implementation: Unified Management Network

Cluster-tool and containerlab share a single management subnet:

1. `cluster-tool boot` runs first — creates the libvirt bridge and mgmt VM (.10)
2. `setup-lab.sh` reads the bridge name and subnet from cluster-tool state
3. Containerlab is deployed with `mgmt.bridge` pointing to the existing libvirt bridge

This eliminates the need for a separate containerlab management network and ensures
all nodes (VM and containers) are on the same L2 segment.

## Worker Joining Process

### Standard OpenShift

In a standard (non-HyperShift) OpenShift cluster, the kube-apiserver runs on master
nodes with `hostNetwork: true` and binds to `0.0.0.0:6443`. This makes it accessible
on **all NICs** simultaneously — no LoadBalancer is needed. Workers connect to
`api-int.<cluster>` or `api.<cluster>`, both of which resolve to the master node's IP
and reach the same process.

### HyperShift (what OSAC uses)

OSAC uses HyperShift (hosted control planes). The control plane does not run on the
worker nodes — it runs as **pods** on the management cluster:

- Each hosted cluster gets its own kube-apiserver Deployment in a dedicated namespace
  (e.g., `osac-e2e-ci-order-5fptc-order-5fptc`)
- The kube-apiserver is a regular pod inside the management cluster's OVN network
  (NOT `hostNetwork`) — it cannot bind to host IPs directly
- OVN and MetalLB are the **data plane** — on the management cluster they handle
  service routing and external IP assignment; on worker nodes they carry tenant
  workload traffic through the switch fabric. To make the kube-apiserver reachable
  from workers, HyperShift creates a LoadBalancer Service; MetalLB assigns a VIP
  from `192.168.X.240-250`
- Workers connect to `api.<cluster-name>.<domain>:6443` — HyperShift does not use
  `api-int` because the control plane is always external to workers
- Konnectivity proxy handles the reverse direction (API server → workers) via a
  tunnel that workers initiate outbound to the kube-apiserver
