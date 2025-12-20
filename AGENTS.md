# Agent Guidelines

## Destructive Actions

**ALWAYS ask the user before performing any destructive action**, including but not limited to:
- Deleting PVCs, PVs, or any persistent data
- Deleting deployments, pods, or services
- Cluster resets or etcd operations
- Rebooting nodes
- Deleting files

This applies regardless of whether data appears to be "test data" or "fresh". The user decides what is safe to delete.

---

# Network Configuration

## Network: 10.28.0.0/20

Full range: 10.28.0.0 - 10.28.15.255

| Range | Purpose | Count |
|-------|---------|-------|
| 10.28.0.1 | Gateway | 1 |
| 10.28.3.42 - 10.28.12.198 | DHCP | ~2200 |
| 10.28.12.199 - 10.28.14.255 | Available | ~500 |
| 10.28.15.1 - 10.28.15.199 | Static IPs (nodes, servers) | 199 |
| 10.28.15.200 - 10.28.15.250 | MetalLB VIPs (LoadBalancers) | 51 |
| 10.28.15.251 - 10.28.15.255 | Reserved | 5 |

## K3s Nodes

| Node | Static IP | DNS Name |
|------|-----------|----------|
| k3s-node-1 | 10.28.15.1 | k3s-node-1.home.arpa |
| k3s-node-2 | 10.28.15.2 | k3s-node-2.home.arpa |
| k3s-node-3 | 10.28.15.3 | k3s-node-3.home.arpa |

## MetalLB

MetalLB is configured to allocate LoadBalancer IPs from `10.28.15.200 - 10.28.15.250`.

Configuration: `manifests/metallb/config.yaml`

