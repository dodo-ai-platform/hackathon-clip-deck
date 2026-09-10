# Manifest rules — filling `k8s/*.yaml` (load AFTER the container builds)

The template already carries the correct *form* (securityContext, OTLP env, probes,
resources, commented db/bucket `envFrom`). Your job is to **fill placeholders and
uncomment what the contract says is present** — not to redesign the manifest. The cluster
does **not** inject securityContext (per SRE): the full block must stay in every manifest.

Read the contract first (parser path is relative to the *skill* dir, not your cwd; one shell call):
`eval "$(bash <skill-dir>/../_shared/platform-reader.sh)"` gives `$namespace`, `$registry`,
`$db_secret_name`, `$mongodb_secret_name`, `$redis_secret_name`, `$bucket_secret_name`,
`$otlp_endpoint`. App name = repo name = namespace.

## `k8s/deployment.yaml`

1. Replace `myapp` → your app name (also `app:` labels and `OTEL_SERVICE_NAME`).
2. Image: `ghcr.io/dodo-ai-platform/<repo-name>:IMAGE_TAG`. Set `<repo-name>` (= the project name).
   **Leave the literal `IMAGE_TAG`** — CI replaces it via `sed` with the commit SHA.
3. `containerPort` = the app's port (**≥ 1024**, e.g. 8080); must match the Dockerfile `EXPOSE` and the Service.
4. Probes: point `livenessProbe`/`readinessProbe` `httpGet.path`+`port` at a real endpoint the app serves (template default `/healthz:8080`).
5. **Secrets — uncomment only what's in PLATFORM.md.** If `db_secret_name` is set, uncomment the DB `envFrom` and use that exact name. Same for `mongodb_secret_name`, `mysql_secret_name`, `redis_secret_name` and `bucket_secret_name`. If a secret isn't in the contract, leave it commented.
   ```yaml
   envFrom:
     - secretRef:
         name: <name>-db-credentials        # only if database in PLATFORM.md
     - secretRef:
         name: <name>-mongodb-credentials   # only if mongodb in PLATFORM.md
     - secretRef:
         name: <name>-mysql-credentials     # only if mysql in PLATFORM.md
     - secretRef:
         name: <name>-redis-credentials     # only if redis in PLATFORM.md
     - secretRef:
         name: <name>-bucket-credentials    # only if bucket in PLATFORM.md
   ```
   **One `envFrom:` key, both refs under it.** The template splits the db and bucket `secretRef`
   under two separate comment headers — when uncommenting, merge them under a **single** `envFrom:`
   list (as above). Two `envFrom:` keys, or a list item with no `envFrom:`, is invalid YAML.
   `envFrom` injects *all* keys of the secret as env vars (simplest, what the template uses); if you
   need only specific keys, use `env: … valueFrom.secretKeyRef` instead (PLATFORM.md shows both).
6. **Keep `resources` (requests AND limits)** — LimitRange requires them; without them the pod is rejected.
7. **Keep `strategy: { type: Recreate }`** — the template default. The namespace `ResourceQuota` is
   sized to `spec.resources` with **no slack for a rollout surge**. A `RollingUpdate` (the k8s default
   if you drop `strategy`, +25% surge) creates an extra pod during deploy → `exceeded quota` → rollout
   stalls → the CI `kubectl rollout status --timeout` fails. `Recreate` scales old pods to 0 before
   creating new ones, so peak usage never exceeds the quota. Cost: a few seconds of downtime per deploy
   (fine for internal tools). **Need zero-downtime?** Raise `spec.resources` in the Project CR to leave
   surge headroom, then switch to `strategy: { type: RollingUpdate, rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }`.
8. **Keep the full `securityContext`** exactly as templated:
   ```yaml
   securityContext:
     allowPrivilegeEscalation: false
     runAsNonRoot: true
     runAsUser: 65534
     capabilities: { drop: [ALL] }
     seccompProfile: { type: RuntimeDefault }
   ```
   This is mandatory and not injected by the cluster — dropping it = pod rejected.
9. OTLP env stays as templated (`OTEL_EXPORTER_OTLP_ENDPOINT` = `alloy.infra-alloy.svc.cluster.local:4318`, `OTEL_EXPORTER_OTLP_PROTOCOL` = `http/protobuf`). Set `OTEL_SERVICE_NAME` to the app name.

## `k8s/service.yaml`

Replace `myapp` → app name; `port`/`targetPort` = the container port.

## What NOT to create

- **No `ingress.yaml`.** Public routes are operator-granted via the Project CR with separate approval (see `dap-shipmaster` Phase A). Never self-serve it here.
- Don't touch `.github/workflows/deploy.yaml` — it already does build → push ghcr.io → `sed IMAGE_TAG` → `kubectl apply -f k8s/`. Only verify it still matches your file names.

## NetworkPolicy reality (default-deny + egress exceptions)

The pod can reach: DNS (53), HTTP/HTTPS (80/443), intra-namespace, OTLP to Alloy (4317/4318 —
**at the collector address from PLATFORM.md only**, not those ports on an arbitrary host),
PostgreSQL RDS (5432), MongoDB DDS (8635, if `mongodb` enabled), MySQL RDS (3306, if `mysql` enabled). **Everything else egress is
blocked.** If the app needs another egress target, that's an operator/NetworkPolicy change —
flag it, don't expect it to work by default.

## Locking a worker down (`ai.paas.dodois.io/egress: restricted`)

If a pod runs untrusted or model-generated code, label it and it loses every path out of the
cluster — internet 80/443, **object storage (your buckets go over that same 80/443 rule)**, the LLM
proxy, the platform databases. It keeps DNS, traffic inside this namespace and the OTLP collector.
Pods without the label are unaffected.

Losing bucket access is deliberate: a bucket with `access: public` is a ready-made exfiltration
channel. If the worker needs bucket data, have an unlabelled pod in the same namespace fetch it and
hand it over — see the pattern below.

Shape the deployment accordingly: the labelled pod is pure compute, and anything that must reach
outside (your own proxy, pgbouncer) goes in **another pod of the same namespace**, unlabelled — the
worker reaches it over intra-namespace traffic.

```yaml
metadata:
  labels:
    ai.paas.dodois.io/egress: restricted   # без выхода из кластера
spec:
  automountServiceAccountToken: false      # иначе код внутри снимет метку сам
  initContainers:
    - name: wait-netpol                    # правила применяются через 1-3 с после старта пода
      image: busybox
      command: ["sh","-c","sleep 30"]
```

Both extra lines matter and are not decoration: without `automountServiceAccountToken: false` code
holding a token that can patch pods removes its own label; without the init delay the pod has
unrestricted egress for the first seconds. Full caveat list — in PLATFORM.md; DNS in particular
stays open and we cannot close it.

Platform endpoints (OTLP collector, LLM proxy) are pinned by address, not just by port: pointing
`OTEL_EXPORTER_OTLP_ENDPOINT` at any other collector, or an `HTTP_PROXY` at some proxy that happens
to listen on 3128, silently times out. Use the addresses PLATFORM.md gives you.

**Redis needs no NetworkPolicy work in tenant manifests:** the redis Service lives in the
same namespace (intra-namespace egress is already allowed) and the operator ships its own
allow-policy for the redis pod. Just `envFrom` the secret and connect via `REDIS_URL`.

## Anti-patterns → pod won't start

- Missing/edited `securityContext`, `privileged: true`, `hostPath`, host network/PID, port < 1024.
- Missing `resources.requests`/`limits`.
- `envFrom` a secret that isn't in PLATFORM.md (CreateContainerConfigError).
- Total pod requests over the namespace `ResourceQuota` (Pending / FailedScheduling).

## Validate before pushing

```bash
kubectl apply --dry-run=server -f k8s/ -n "$namespace"
```
Catches restricted/quota/shape violations before CI. Note: `--dry-run=server` (and even
`--dry-run=client` on modern kubectl) needs a **reachable API server** (VPN + kubeconfig) — it is
not an offline check. If you can't reach the cluster, the only local gate is a YAML lint (e.g.
`python -c 'import sys,yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' k8s/*.yaml`);
CI runs the server-side dry-run regardless on push. Fix until clean, then push.
