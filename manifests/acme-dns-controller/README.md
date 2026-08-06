# acme-dns-controller

In-cluster operator (`garvey-sh-cert-controller`, repo `~/projects/garvey-sh-cert-controller`)
that turns an `AcmeDnsCert` CR into a per-service Let's Encrypt cert: it registers the
acme-dns account, upserts the Cloudflare `_acme-challenge` delegation CNAME, owns the
shared `cert-manager/acme-dns` account Secret, and creates the cert-manager `Certificate`.
cert-manager then does ACME issuance + renewal. This replaces the manual runbook in
`../acme-dns/ONBOARDING.md`.

## Files

| file | what |
|---|---|
| `namespace.yaml`  | `acme-dns-controller` namespace |
| `crd.yaml`        | the `AcmeDnsCert` CRD (copied verbatim from the controller repo's `config/crd`) |
| `rbac.yaml`       | ServiceAccount + ClusterRole + ClusterRoleBinding |
| `secret.yaml`     | Cloudflare API-token `SopsSecret` — **template, must be sealed before use** |
| `deployment.yaml` | the controller Deployment (pulls `oci.garvey.sh/garvey-sh-cert-controller:0.1.0`) |

## Prerequisites

- Controller image pushed to `oci.garvey.sh:0.1.0` (done).
- acme-dns `/register` must be **live-open**: confirm `disable_registration = false` is applied
  (`kubectl -n acme-dns get configmap acme-dns-config -o yaml`); if not,
  `kubectl apply -f ../acme-dns/configmap.yaml && kubectl -n acme-dns rollout restart deploy/acme-dns`.

## Apply order

```bash
# 1. Mint a Cloudflare token (Zone:DNS:Edit on garvey.sh), put it in secret.yaml, seal it:
nix run nixpkgs#sops -- --encrypt --in-place manifests/acme-dns-controller/secret.yaml

# 2. Apply (CRD before anything that references it; secret + rbac before the deployment):
kubectl apply -f manifests/acme-dns-controller/namespace.yaml
kubectl apply -f manifests/acme-dns-controller/crd.yaml
kubectl apply -f manifests/acme-dns-controller/secret.yaml
kubectl apply -f manifests/acme-dns-controller/rbac.yaml
kubectl apply -f manifests/acme-dns-controller/deployment.yaml

# 3. Verify:
kubectl -n acme-dns-controller rollout status deploy/garvey-sh-cert-controller
kubectl -n acme-dns-controller logs deploy/garvey-sh-cert-controller
```

## ⚠️ Still pending — do these deliberately

These are intentionally **not** automated here; they touch live state and cluster-wide policy.

### 1. Account-Secret ownership migration

`cert-manager/acme-dns` (key `acmedns.json`) is currently created by the SopsSecret operator
(`../acme-dns/secret.yaml`). The controller needs to **write** that Secret to add new accounts; if
the SopsSecret operator still owns it, it will revert those writes. Hand ownership to the
controller without losing the existing `oci.garvey.sh` account creds:

```bash
# Back up first (base64-encoded; keep it somewhere safe):
kubectl -n cert-manager get secret acme-dns -o yaml > /tmp/acme-dns-secret.backup.yaml

# Delete the SopsSecret CR but KEEP the underlying Secret (orphan strips its ownerRef):
kubectl -n cert-manager delete sopssecret acme-dns-sopssecret --cascade=orphan
```

Then **retire `../acme-dns/secret.yaml` from the apply path** (don't `kubectl apply` it again — a
re-apply recreates the SopsSecret and re-takes ownership). The controller merges into the existing
map, so the `oci.garvey.sh` entry is preserved. Since the account creds now live only in-cluster
(+ the acme-dns PVC), add a backup story for the `acme-dns` Secret — it is no longer in GitOps.

### 2. NetworkPolicy fence (security hardening)

acme-dns `/register` is open today (acknowledged debt). Add a CiliumNetworkPolicy restricting
ingress to `acme-dns-api:80` to just this controller's pod (`/register`) and cert-manager
(`/update`). This would be the cluster's first NetworkPolicy — verify cert-manager's DNS-01
self-check / `/update` path still works after applying it.

## Migrating an existing service (e.g. zot)

Replace the hand-written `../zot/certificate.yaml` with an `AcmeDnsCert` (see the controller repo's
`config/samples/acmednscert.yaml`). The controller adopts/owns the existing `zot-tls` Certificate.
Test first with a throwaway host on `letsencrypt-acmedns-staging` before touching prod certs.
