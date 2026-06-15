# cert-manager

cert-manager is **vendored pristine** at `vendor/cert-manager/cert-manager.yaml` (upstream
v1.20.1) and applied with one small **patch on top** — `vendor/` is never edited.

## Install / upgrade order

```sh
# 1. Base (pristine upstream)
kubectl apply -f vendor/cert-manager/cert-manager.yaml

# 2. Controller patch: DNS-01 self-check via cluster CoreDNS (see patch file header)
kubectl patch deploy cert-manager -n cert-manager --type=strategic \
  --patch-file manifests/cert-manager/cert-manager-controller-recursive-ns.patch.yaml
```

The patch's `args` list mirrors upstream's 5 controller args plus 2 added flags; because `args`
has no strategic-merge key it is replaced wholesale, so re-check the first 5 entries when bumping
the vendored version.

## Issuers & secrets (this dir)

- `cluster-issuer.yaml` — legacy Cloudflare DNS-01 issuer `letsencrypt-prod` (dormant).
- `cluster-issuer-acmedns-staging.yaml` / `-prod.yaml` — acme-dns DNS-01 issuers.
- `secret.yaml` — Cloudflare API token (SopsSecret). The acme-dns account secret lives at
  `manifests/acme-dns/secret.yaml` (also namespaced to `cert-manager`).
