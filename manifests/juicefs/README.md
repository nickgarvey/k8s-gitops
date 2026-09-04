# JuiceFS metadata engine (PD + TiKV)

JuiceFS splits a filesystem in two. File *content* becomes content-addressed blocks in a
garage S3 bucket; all *metadata* — the tree, inodes, chunk maps — lives here, in TiKV. The
client talks to both directly, so this cluster is not a server the workstations go through,
it is half of the filesystem.

**The blocks in garage carry no filesystem structure of their own.** Lose all three TiKV
stores and the bytes survive but nothing can address them. That asymmetry drives most of
the decisions below.

The client side is `nix-configs`' `modules/services/juicefs.nix`.

## Shape

| Component | Replicas | Storage | Why |
|---|---|---|---|
| PD | 1 | `longhorn-wffc` (2 replicas + backups) | Topology and the timestamp oracle. No peer to rebuild from, so it gets the durable class. |
| TiKV | 3 | `longhorn-r1` (1 replica, no backups) | Three Raft copies already, one per node. The default class would store six. |

PD is a single replica: restarting it stalls the filesystem until it returns.

### Addressing

PD advertises the **LoadBalancer address** `2001:470:482f:2::5005`, not its pod IP. The PD
client fetches the member list on connect and then re-dials members at whatever they
advertise, so a pod IP would work only for as long as the pod kept it.

TiKV stores advertise their **pod IPs**, because there is one address per store and they
cannot share an LB. This works from the LAN only because pod CIDRs are routable: the router
installs per-node routes (`nix-configs/modules/router/lan-ipv6.nix`), LAN hosts learn the
/48 via RFC 4191 route-info RA, and the forward chain permits it
(`nix-configs/modules/router/nftables.nix`). Pod IPs are ephemeral, but a restarted store
re-registers under its existing store ID and clients re-resolve through PD.

If a LAN client can reach PD but hangs on any actual operation, suspect that routing rather
than PD: confirm `lan-hosts.nix`'s podCIDRs still match `kubectl get nodes -o
custom-columns=:.spec.podCIDR`.

## ⚠️ No authentication

**PD and TiKV are unauthenticated and unencrypted.** Any host that can route to them can
read or rewrite the entire filesystem metadata. There is no default-deny pod-ingress policy
in this cluster — `manifests/cilium/host-firewall.yaml` is nodeSelector-scoped and no
`CiliumNetworkPolicy` exists — so that is every LAN host.

This was chosen deliberately over mTLS, which would mean reviving the private CA retired in
August 2026 (`nix-configs/docs/tls.md`) and would land badly anyway: JuiceFS dials each
store at an ephemeral pod IP, and you cannot put a `/56` in an IP SAN, so it degrades to
`cert-allowed-cn` with hostname verification effectively off. An address allowlist was also
rejected — `dovahkiin` has no `lan-hosts.nix` entry and SLAACs, so only `talos` is pinnable.

Note the data path is *not* plaintext: the client reaches garage over
`https://garage.home.garvey.sh`. TiKV is the exception, and it is known debt.

## Apply order

Bring PD up alone first and verify it before adding stores — TiKV registers with PD
permanently on first start, and a store that registers against a misconfigured PD is
awkward to unpick.

```bash
kubectl apply -f manifests/longhorn/storage-class.yaml   # adds longhorn-r1
kubectl apply -f manifests/juicefs/namespace.yaml
kubectl apply -f manifests/juicefs/pd.yaml

# Members must show the LB address, not a pod IP:
curl -s 'http://[2001:470:482f:2::5005]:2379/pd/api/v1/members' | jq '.members[].client_urls'

kubectl apply -f manifests/juicefs/tikv.yaml

# Three stores, all Up, each at a pod IP:
curl -s 'http://[2001:470:482f:2::5005]:2379/pd/api/v1/stores' \
  | jq '.stores[].store | {id, address, state_name}'
```

PingCAP's IPv6-only support is the least-proven part of this deployment. If PD logs bracket
parsing errors or advertises something unexpected, stop and reconsider the metadata engine
rather than working around it — every later step bakes this choice in deeper.

## One-time format

Create the bucket and key first (the `garage-bucket` skill in `nix-configs`): bucket
`juicefs`, key `juicefs-key` with read/write/owner. **Both garage nodes must be up** — RF=2
means write quorum 2, so one node down blocks all writes.

```bash
juicefs format --storage minio \
  --bucket https://garage.home.garvey.sh/juicefs \
  --access-key "$ACCESS_KEY" --secret-key "$SECRET_KEY" \
  'tikv://[2001:470:482f:2::5005]:2379/jfs' jfs
```

The endpoint is **written into the volume settings**, so a typo here is a metadata edit to
fix later, not a remount. Use the hostname, never one of the round-robin literals: it is
what the certificate attests and what SigV4 signs. `--storage minio` selects path-style
addressing, which is what garage serves.

Format is a one-time step. Re-running it against an existing volume updates settings rather
than erasing data, but do not treat that as a routine operation.

## Metadata backup and restore

The mount runs `--backup-meta 1h`, which writes a full metadata dump into the bucket under
`meta/`. **This is the disaster-recovery path**, not Longhorn snapshots — a volume snapshot
of one live Raft peer is not a consistent backup, and restoring one would rejoin a store
carrying stale state.

```bash
juicefs load 'tikv://[2001:470:482f:2::5005]:2379/jfs' dump.json   # into an empty volume
```

An untested restore is not a backup. Verify a dump can actually be loaded before relying on
it.
