# Agent Guidelines

## Destructive Actions

**CRITICAL: ALWAYS ask the user before performing any destructive action.**

### What Counts as Destructive

**ANY file deletion**, including but not limited to:
- Files in the workspace (even if they appear temporary or test-related)
- Files in `/tmp` or other temporary directories
- Files created by the agent during the current session
- Backup files, log files, or any other files
- **When in doubt, ASK - never assume cleanup is safe**

**Kubernetes resource deletion:**
- Deleting PVCs, PVs, or any persistent data
- Deleting deployments, pods, services, or any Kubernetes resources
- Cluster resets or etcd operations
- Rebooting nodes

### Rules

1. **Never delete files without explicit user permission** - even if you created them, even if they're in `/tmp`, even if they appear to be temporary
2. **Never delete Kubernetes resources without explicit user permission**
3. **When in doubt, ask first** - it's better to ask than to delete something important
4. **The user decides what is safe to delete** - not the agent

### Examples

❌ **DON'T:** `rm -f /tmp/secret-temp.yaml` (even if you created it)  
✅ **DO:** Ask: "Should I clean up the temporary files I created in /tmp?"

❌ **DON'T:** Delete a pod because it appears to be in an error state  
✅ **DO:** Ask: "I see pod X is in an error state. Would you like me to delete and recreate it?"

This applies regardless of whether data appears to be "test data", "fresh", "temporary", or "unimportant". The user decides what is safe to delete.

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

---

# Container Registry (zot)

Registry: `zot.home.arpa:5000`

## Quick Commands

List all repositories:
```bash
curl -s http://zot.home.arpa:5000/v2/_catalog | jq
```

List tags (requires skopeo from nix environment):
```bash
nix develop --command skopeo list-tags docker://zot.home.arpa:5000/<repo> --tls-verify=false
```

Pull with podman:
```bash
podman pull zot.home.arpa:5000/<repo>:<tag> --tls-verify=false
```

Push with podman:
```bash
podman tag <image>:<tag> zot.home.arpa:5000/<repo>:<tag>
podman push zot.home.arpa:5000/<repo>:<tag> --tls-verify=false
```

