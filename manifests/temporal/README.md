# temporal

Temporal workflow engine at `https://temporal.garvey.sh`, backed by its own
single-replica Postgres. `temporalio/auto-setup` runs frontend, history,
matching and worker in one process and creates + migrates the schema on start,
so there is no separate schema Job.

**The UI has no authentication.** `temporal.garvey.sh` resolves from the open
internet and the LB address is a globally routable GUA; inbound IPv6 is
default-deny at the router, so it is not reachable from outside today. Revisit
with authentik forward-auth or `TEMPORAL_DISABLE_WRITE_ACTIONS` before opening
anything up.

## Certificate (do this first — it is IP-independent)

Follow `../acme-dns/ONBOARDING.md` by hand for `temporal.garvey.sh`. The manual
runbook is the only path — the `AcmeDnsCert` controller was never deployed and
its manifests were removed (see "Status: not deployed" in that doc).

1. `POST /register` against a port-forwarded `acme-dns-api` with
   `{"allowfrom":["2001:470:482f:100::/56"]}`. Save the response with
   `curl -o` — an orphaned account is unrecoverable.
2. Cloudflare CNAME `_acme-challenge.temporal.garvey.sh` → `<fulldomain>.`,
   DNS-only.
3. Merge the account under key `temporal.garvey.sh` into
   `../acme-dns/secret.yaml`, commit, and apply it.
4. `certificate.yaml` ships pointing at `letsencrypt-acmedns-staging`. Once it
   reports Ready, flip to `letsencrypt-acmedns-prod`, delete the `temporal-tls`
   Secret so cert-manager re-issues, and record the date in the comment.

## Apply order

```bash
kubectl apply -f manifests/temporal/namespace.yaml
kubectl apply -f manifests/temporal/secret.yaml
kubectl apply -f manifests/temporal/certificate.yaml
kubectl apply -f manifests/temporal/postgres.yaml
kubectl -n temporal rollout status statefulset/temporal-postgres
kubectl apply -f manifests/temporal/deployment.yaml
kubectl apply -f manifests/temporal/service.yaml
kubectl apply -f manifests/temporal/caddy-configmap.yaml
kubectl apply -f manifests/temporal/ui-deployment.yaml
kubectl apply -f manifests/temporal/ui-service.yaml
kubectl apply -f manifests/temporal/service-monitor.yaml
```

Postgres must be up before the server (auto-setup retries, but logs noisily),
and `temporal-tls` must exist before the UI pod starts or Caddy crashloops on
the missing `/certs`.

Split-horizon DNS lives outside this repo: add
`"temporal.garvey.sh" = "2001:470:482f:2::5002";` to `garveyShOverrides` in
`~/nix-configs/modules/networking/dns.nix`, then `nixos-rebuild switch` on the
router.

## The POSTGRES_DB gotcha

`POSTGRES_DB` in `secret.yaml` must equal `DBNAME` in `deployment.yaml` (both
`temporal`). `auto-setup.sh` guards its own `CREATE DATABASE` with
`DBNAME != POSTGRES_USER` and, when they match, assumes the Postgres container
already created the database via `POSTGRES_DB`. Point `POSTGRES_DB` anywhere
else and the server crashloops on `database "temporal" does not exist`.

`temporal_visibility` differs from the user name, so auto-setup creates that one
itself on every fresh deploy.

## The IPv6 gotcha

Temporal's config template defaults every service's `bindOnIP` to `127.0.0.1`,
so `BIND_ON_IP: "::"` in `deployment.yaml` is load-bearing — without it the pod
is unreachable on this IPv6-only cluster. `TEMPORAL_BROADCAST_ADDRESS` is fed
from `status.podIP`; without it ringpop membership never forms.

`TEMPORAL_AUTH_AUTHORIZER` and `TEMPORAL_AUTH_CLAIM_MAPPER` are deliberately
unset. With both unset the template omits the `publicClient` block entirely —
otherwise it renders `hostPort` by concatenating `BIND_ON_IP + ":" + port`,
giving the unparseable `":::7233"`.

If membership still fails, the fallback is to mount our own
`config_template.yaml` via ConfigMap at
`/etc/temporal/config/config_template.yaml` with bracketed addresses hardcoded.

## Metrics are unprefixed

Temporal's docker config template exposes `timerType` but no metrics `prefix`,
so the ~489 series land in Prometheus under bare names — `service_requests`,
`errors`, `action`, `ack_level_update` — not `temporal_*`. Filter by
`{namespace="temporal"}` when querying. If the collisions ever become a problem,
add a `metricRelabelings` prefix rule to `service-monitor.yaml`.

## Adding a worker later

Workers are ordinary application Deployments in this namespace. Point them at
`temporal-frontend.temporal.svc:7233` and give each its own task queue. Nothing
in these manifests needs to change.
