# Manual service onboarding: per-service Let's Encrypt cert via acme-dns

This is the **break-glass / by-hand** procedure for giving a new service its own
publicly-trusted Let's Encrypt cert (scoped to its own name) without putting any
Cloudflare credentials on the service and without manual DNS-zone edits.

It is also the **behavioral spec** for the future `AcmeDnsCert` controller — every
step here is something the controller will automate (see the mapping at the end).
If the controller is ever down or being rebuilt, this is how you do it manually.

---

## How it works (the moving parts)

- **acme-dns** (`acme.garvey.sh`) holds one *account* per hostname. Each account can
  only write the TXT record under its own random subdomain (`<fulldomain>`), so a
  leaked account can't touch any other name. The API is **ClusterIP-only**
  (`http://acme-dns-api.acme-dns.svc.cluster.local`), so from a workstation you reach
  it via `kubectl port-forward`.
- **Delegation CNAME** in Cloudflare: `_acme-challenge.<host>` → `<fulldomain>.`
  This is what lets Let's Encrypt's DNS-01 lookup for `<host>` land on the account's
  acme-dns subdomain, where cert-manager will have written the challenge TXT.
- **cert-manager** does the actual ACME issuance + **renewal**. Its `acmeDNS` solver
  reads the account from the `acme-dns` Secret (key `acmedns.json`, a JSON map keyed by
  hostname) and calls acme-dns `/update` at challenge time. You never touch renewal.
- **The cert is fully decoupled from the service's IP** — DNS-01 proves control via
  `acme.garvey.sh`, not via where `<host>` points. So you can issue the cert before the
  service exists. The service IP only matters for split-horizon DNS (last step).

### Key facts / values
| Thing | Value |
|---|---|
| acme-dns namespace / deploy / API svc | `acme-dns` / `acme-dns` / `acme-dns-api` (:80, ClusterIP) |
| acme-dns config | configmap `acme-dns-config`, key `config.cfg` |
| Registration | **open** (`disable_registration = false`) — no toggle dance |
| Account secret | `manifests/acme-dns/secret.yaml` → SopsSecret `acme-dns-sopssecret` → Secret `acme-dns` in ns `cert-manager`, key `acmedns.json` |
| `allowfrom` (who may call `/update`) | `2001:470:482f:100::/56` (k3s cluster pod-CIDR — covers the cert-manager solver pod) |
| ClusterIssuers | `letsencrypt-acmedns-staging`, `letsencrypt-acmedns-prod` |
| LB IP pool | `2001:470:482f:2::/…` (statically pinned via `io.cilium/lb-ipam-ips`) |
| Public zone / API | `garvey.sh` (Cloudflare) |

### `acmedns.json` structure
```json
{
  "oci.garvey.sh": {
    "username":  "…",
    "password":  "…",
    "fulldomain":"<random>.acme.garvey.sh",
    "subdomain": "<random>",
    "allowfrom": ["2001:470:482f:100::/56"]
  },
  "<new-host>": { … }
}
```
One account **per hostname**. Never register a host twice (acme-dns has no lookup; a
second `/register` orphans the first account and leaves a dangling CNAME). acme-dns keeps
only the last 2 TXT values per account, and cert-manager breaks past 2 domains per
account — so do not share an account across hostnames.

---

## Prerequisites (once)

- Registration is open. Verify the live config:
  ```bash
  kubectl -n acme-dns get cm acme-dns-config -o jsonpath='{.data.config\.cfg}' | grep disable_registration
  # want: disable_registration = false
  # if it says true: kubectl apply -f manifests/acme-dns/configmap.yaml && kubectl -n acme-dns rollout restart deploy/acme-dns
  ```
- A Cloudflare API token scoped `Zone:DNS:Edit` on `garvey.sh` (for the CNAME step).
- Your sops age key available locally (to re-seal `acmedns.json`).
- A clean git working tree (so the only resulting diff is `secret.yaml`).

---

## Onboarding a new host (`foo.garvey.sh`)

### 1. Register the acme-dns account
The API is ClusterIP-only, so port-forward, then `POST /register`. `allowfrom` restricts
who can later call `/update` for this account to in-cluster solver pods.
```bash
kubectl -n acme-dns port-forward svc/acme-dns-api 8080:80 &
PF=$!
REG=$(curl -sX POST http://localhost:8080/register \
        -H 'Content-Type: application/json' \
        -d '{"allowfrom":["2001:470:482f:100::/56"]}')
kill $PF
echo "$REG" | jq      # -> {username, password, fulldomain, subdomain, allowfrom}
```
Keep `$REG`. Note its `.fulldomain` — that's the CNAME target.

### 2. Create the delegation CNAME in Cloudflare
`_acme-challenge.foo.garvey.sh` → `<fulldomain>.` (trailing dot; DNS-only / grey cloud).

Dashboard: add a CNAME record. Or via API:
```bash
ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=garvey.sh" \
  -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id')
FULLDOMAIN=$(echo "$REG" | jq -r .fulldomain)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "_acme-challenge.foo.garvey.sh" --arg c "$FULLDOMAIN" \
        '{type:"CNAME",name:$n,content:$c,proxied:false,ttl:120}')" | jq .success
# verify:
dig +short _acme-challenge.foo.garvey.sh CNAME      # -> <fulldomain>.acme.garvey.sh.
```

### 3. Merge the account into the sealed secret
Easiest (interactive) — opens the file decrypted in `$EDITOR`; add the new key to the
`acmedns.json` object, save, sops re-seals to both age recipients automatically:
```bash
sops manifests/acme-dns/secret.yaml
```
Scriptable equivalent (what the controller logic mirrors):
```bash
cur=$(sops -d --extract '["spec"]["secretTemplates"][0]["stringData"]["acmedns.json"]' \
        manifests/acme-dns/secret.yaml)
new=$(echo "$cur" | jq --argjson a "$REG" '. + {"foo.garvey.sh": $a}')
sops --set "[\"spec\"][\"secretTemplates\"][0][\"stringData\"][\"acmedns.json\"] $(echo "$new" | jq -Rs .)" \
  manifests/acme-dns/secret.yaml
git diff --stat manifests/acme-dns/secret.yaml      # sanity: only this file changed
```
Then publish it so cert-manager sees the account:
```bash
git add manifests/acme-dns/secret.yaml && git commit -m "acme-dns: register foo.garvey.sh"
kubectl apply -f manifests/acme-dns/secret.yaml
```

### 4. Issue the cert (IP-independent — can run before the service exists)
Create `manifests/foo/certificate.yaml` (mirror `manifests/zot/certificate.yaml`), start
on the **staging** issuer:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: foo-tls, namespace: foo, labels: { app.kubernetes.io/managed-by: ngarvey-homelab } }
spec:
  secretName: foo-tls
  dnsNames: [foo.garvey.sh]
  issuerRef: { name: letsencrypt-acmedns-staging, kind: ClusterIssuer }
```
```bash
kubectl apply -f manifests/foo/certificate.yaml
kubectl get certificate,order -n foo            # wait Ready=True (challenge clears + is GC'd)
# then flip issuerRef -> letsencrypt-acmedns-prod, re-apply, confirm a real LE issuer:
kubectl get secret foo-tls -n foo -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -issuer        # should NOT say "(STAGING)"
```

### 5. Deploy the service (the zot pattern)
Pick an unused LB IP from the pool (`grep -rh lb-ipam-ips manifests/*/service.yaml`), then
write `manifests/foo/` mirroring zot:
- `configmap` — app serves TLS on **443**, cert/key from a mounted secret
- `deployment` — mount `foo-tls` at the TLS path, HTTPS probes on 443
- `service` — `io.cilium/lb-ipam-ips: <picked IP>`, port `443 → 443`

Apply **after** `foo-tls` exists (else the pod hangs on the missing secret volume):
```bash
kubectl apply -f manifests/foo/{namespace,configmap,service,deployment}.yaml
kubectl rollout status deploy/foo -n foo
```

### 6. Split-horizon DNS (nix-configs)
So LAN clients reach it internally and TLS name-matches:
```nix
# modules/networking/dns.nix
garveyShOverrides = {
  "oci.garvey.sh" = "2001:470:482f:2::5000";
  "foo.garvey.sh" = "<picked LB IP>";
};
```
Deploy the router: `cd ~/nix-configs && nix run .#deploy -- --hosts <router> --mode safe`.

### Verify
```bash
dig +short foo.garvey.sh AAAA @<router>          # -> picked LB IP
curl -sI https://foo.garvey.sh/…                  # 200, valid public cert, no --insecure
```

---

## What the `AcmeDnsCert` controller will automate

You apply one CR; the controller does steps 1–4 in-cluster:

```yaml
apiVersion: homelab.garvey.sh/v1alpha1
kind: AcmeDnsCert
metadata: { name: foo, namespace: foo }
spec:
  dnsName: foo.garvey.sh
  secretName: foo-tls
  issuerRef: { name: letsencrypt-acmedns-prod, kind: ClusterIssuer }
```

| Manual step | Controller behavior |
|---|---|
| 1. port-forward + `/register` | Calls the ClusterIP API **directly** (no port-forward); only the controller pod is allowed to register (NetworkPolicy). |
| 2. Cloudflare CNAME | Upserts via the CF token Secret in its own namespace. Idempotent / self-healing. |
| 3. sops re-seal + commit + apply | **Owns the `acme-dns` Secret in-cluster** — writes the account natively, no sops, no git. |
| 4. create Certificate (staging→prod) | Creates/owns a cert-manager `Certificate` (ownerRef → CR); mirrors its Ready status into the CR. |
| 5–6. deploy service + split-horizon DNS | Still manual (per-service manifests + router) — out of the controller's scope. |

Renewal is cert-manager's job in both the manual and controller paths — nothing to do.
