# Networking Terminology

---

## Part 1: Simple Explanations

Think of a data center as a building full of servers that need to talk to each other and to the outside world.

**Switch** — A device that connects servers together, like a power strip connects appliances to electricity. It receives a network packet and forwards it to the right destination.

**Spine / Leaf** — A two-tier layout for switches. Leaf switches sit at the edges and connect directly to servers. The spine switch sits in the middle and connects all the leaves together. Every server is one hop from its leaf, two hops from any other server.

**Bridge** — A switch feature that groups multiple ports into one shared network segment. Think of it as a conference room — everyone in the room can hear each other.

**VLAN (Virtual LAN)** — A way to split one physical switch into multiple isolated networks. Like dividing a floor into separate conference rooms with soundproof walls — people in room 100 can't hear people in room 200, even though they're on the same floor.

**VRF (Virtual Routing and Forwarding)** — Takes isolation one step further. While VLANs isolate at the "room" level (Layer 2 / same network segment), VRFs isolate at the "building" level (Layer 3 / routing). Each VRF has its own routing table, so tenant-a's routes are completely invisible to tenant-b.

**VXLAN (Virtual Extensible LAN)** — A tunnel that extends a VLAN across multiple switches. Imagine two conference rooms in different buildings connected by a private tunnel — people in both rooms can talk as if they were in the same room, even though they're physically separated.

**VNI (VXLAN Network Identifier)** — The label on a VXLAN tunnel. Each VLAN gets its own VNI so traffic from different VLANs stays separated inside the tunnels. Room 100 gets tunnel 10100, room 200 gets tunnel 10200.

**VTEP (VXLAN Tunnel Endpoint)** — The entry/exit point of a VXLAN tunnel on each switch. Each leaf switch has a VTEP with a unique IP address (the loopback IP). Packets enter one VTEP, travel through the tunnel, and exit the other VTEP.

**BGP (Border Gateway Protocol)** — The protocol switches use to tell each other what networks they can reach. Like a postal system where each post office announces: "I can deliver mail to these addresses."

**eBGP (External BGP)** — BGP between switches with different AS numbers. In our lab, each leaf has its own AS number, so spine-to-leaf communication is eBGP. The "external" means they belong to different organizations (or in our case, different switching domains).

**ASN (Autonomous System Number)** — An ID number assigned to each switch for BGP. Like a zip code that identifies which "postal district" a switch belongs to.

**EVPN (Ethernet VPN)** — A BGP extension that lets switches automatically share VXLAN information. Without EVPN, you'd have to manually tell each switch about every other switch's VLANs and MAC addresses. EVPN automates this — switches discover each other's VNIs and MAC/IP bindings automatically.

**NVUE** — The management CLI for Cumulus Linux switches (`nv set`, `nv config apply`). Think of it as the switch's settings app.

**vtysh** — The FRR (routing daemon) CLI. A lower-level tool for configuring routing protocols directly. Used when NVUE doesn't expose a setting.

**SNAT (Source NAT)** — Rewrites the source IP of outgoing packets. When a server with a private IP (10.100.0.10) sends traffic to the internet, the gateway replaces it with its own public IP. Like sending a letter through a PO Box — the recipient sees the PO Box address, not your home address.

**DNAT (Destination NAT)** — Rewrites the destination IP of incoming packets. External traffic arrives at the gateway's public IP on a specific port, and the gateway forwards it to the right internal server. Like a receptionist routing incoming calls to the right extension.

**MASQUERADE** — An iptables rule that does SNAT automatically, using the outgoing interface's IP. Convenient when the public IP might change (like DHCP).

**IP Forwarding** — A kernel setting that allows a Linux machine to act as a router, forwarding packets between its network interfaces instead of dropping them.

**VRR (Virtual Router Redundancy)** — A shared virtual IP address on the leaf switches that serves as the default gateway for hosts. All leaves in the same VLAN share the same VRR IP (e.g., 10.100.0.1), so hosts always have a working gateway regardless of which leaf they're connected to.

---

## Part 2: Technical Details

**Switch** — Layer 2/3 network device that forwards Ethernet frames based on MAC address tables (L2) and IP routing tables (L3). In our lab, Cumulus Linux switches run on top of a standard Linux kernel with switchdev for hardware offload.

**Spine / Leaf (Clos topology)** — A non-blocking, horizontally scalable fabric. Every leaf connects to every spine. North-south traffic (server ↔ external) traverses one leaf + one spine. East-west traffic (server ↔ server across leaves) traverses leaf → spine → leaf. No leaf-to-leaf direct links.

**Bridge** — Linux kernel bridge (`br_default` in Cumulus). Operates at L2 — learns MAC addresses on ports and forwards frames accordingly. In VLAN-aware mode, a single bridge instance handles multiple VLANs using 802.1Q tags.

**VLAN (IEEE 802.1Q)** — L2 isolation via a 12-bit tag (1-4094) inserted into Ethernet frames. Access ports strip/add the tag (hosts send untagged). Trunk ports carry multiple VLAN tags. Each VLAN is a separate broadcast domain.

**VRF** — A Linux kernel construct (`ip vrf`) that creates isolated L3 routing table instances. Each VRF has its own FIB (Forwarding Information Base). In EVPN, each tenant maps to a VRF. Inter-VRF traffic is impossible unless explicitly leaked.

**VXLAN (RFC 7348)** — L2-over-L3 encapsulation. Original Ethernet frame is wrapped in a UDP packet (port 4789) with a 24-bit VNI header. The outer IP header uses VTEP loopback addresses as source/destination. MTU overhead: 50 bytes (outer Ethernet 14 + outer IP 20 + UDP 8 + VXLAN 8).

**VNI** — 24-bit identifier in the VXLAN header. L2 VNI maps 1:1 to a VLAN (bridged traffic within a subnet). L3 VNI maps 1:1 to a VRF (routed traffic between subnets of the same tenant). In our lab: L2 VNI 10100 → VLAN 100, L3 VNI 10001 → VRF tenant-a.

**VTEP** — The NVE (Network Virtualization Edge) interface on each leaf. Identified by a /32 loopback IP (e.g., 10.0.0.1). VXLAN packets are encapsulated/decapsulated here. The loopback must be reachable via the underlay (BGP IPv4 unicast).

**BGP (RFC 4271)** — Path-vector routing protocol. Exchanges NLRI (Network Layer Reachability Information) between peers. Uses TCP port 179. Selects best path based on attributes (AS path length, local preference, MED, etc.). Convergence is event-driven (not periodic like OSPF).

**eBGP** — BGP peering between different Autonomous Systems. In a Clos fabric, each leaf gets a unique ASN (e.g., 65001, 65002) and the spine gets its own (65000). Unnumbered eBGP uses link-local IPv6 addresses — no IP addressing needed on inter-switch links.

**ASN** — 16-bit (0-65535) or 32-bit identifier for a BGP domain. Private range: 64512-65534. In our lab, each switch has a unique private ASN for eBGP multi-path.

**EVPN (RFC 7432 + RFC 8365)** — BGP address family `l2vpn evpn`. Carries MAC/IP bindings (type-2 routes), subnet info (type-5 routes), and VNI membership (type-3 routes) across the fabric. Replaces flood-and-learn with control-plane MAC distribution. `advertise-all-vni` tells FRR to inject locally discovered VNIs into BGP EVPN.

**NVUE** — NVIDIA Unified Experience. Declarative configuration layer for Cumulus Linux. Stages changes with `nv set`, applies atomically with `nv config apply`. Generates underlying configs (FRR, ifupdown2, etc.). Some FRR settings (e.g., `advertise-all-vni`) are not exposed through NVUE.

**vtysh** — Integrated shell for FRR (Free Range Routing) daemons (bgpd, zebra, etc.). Provides Cisco-like CLI for direct FRR configuration. Changes made via vtysh can be overwritten by `nv config apply` since NVUE regenerates FRR config.

**SNAT** — Netfilter POSTROUTING chain. Rewrites source IP/port in the outgoing packet and creates a conntrack entry for return traffic. MASQUERADE is a dynamic variant that uses the outgoing interface's current IP.

**DNAT** — Netfilter PREROUTING chain. Rewrites destination IP/port before the routing decision. Conntrack ensures reply packets have their source rewritten back. Requires `ip_forward=1`.

**MASQUERADE** — iptables target in the nat table, POSTROUTING chain. Functionally equivalent to SNAT but dynamically uses the outgoing interface's IP. Slightly slower than SNAT (looks up IP per packet) but works with dynamic IPs.

**IP Forwarding** — Kernel parameter `net.ipv4.ip_forward`. When 0 (default), the kernel drops packets not destined for its own IPs. When 1, it routes them between interfaces according to the routing table. Essential for any Linux-based router or NAT gateway.

**VRR (Virtual Router Redundancy)** — Cumulus-specific active-active gateway mechanism. All leaves in the same VLAN respond to the same virtual MAC and IP. Unlike VRRP (one active, one standby), VRR is active on all leaves simultaneously — the nearest leaf always responds. Configured via `ip vrr address` on SVI (VLAN interface).
