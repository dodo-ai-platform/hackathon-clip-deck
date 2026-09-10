# Project CR reference — `ai.paas.dodois.io/v1alpha1`

The registry repo `dodo-ai-platform/platform-projects` holds one YAML per project in
`projects/<name>.yaml`. The **file name must equal `metadata.name`**. Merging to `main`
makes CI apply the CR and the operator provisions namespace, DB, buckets, GitHub repo,
Grafana dashboard, and (separately approved) public routes — then writes `PLATFORM.md`.

**Source of truth for the schema is the live cluster's served schema** — that is what CI's
server-side `kubectl apply --dry-run=server` (`validate.yml`) judges the PR against. Read it
with `kubectl explain aiproject.spec` (any Dex-authenticated kubeconfig suffices). The repo CRD
`crds/ai.paas.dodois.io_aiprojects.yaml` is its mirror, with machine-readable `required:` lists
and enums — trustworthy only at a synced `origin/main`; this doc is a convenience snapshot one
step further removed. When sources disagree: **live schema > synced repo CRD > this doc** — and
a disagreement usually means your checkout is stale, not that the docs are wrong.

**Never infer schema requirements from other `projects/*.yaml`.** Existing CRs show house
style, not the rules: they may predate schema/policy changes (e.g. old projects carry a
`resources` block from when it was mandatory). Copying a sibling's block "because a similar
project has it" is how stale fields spread — justify every block from the CRD and this doc.

## Full shape (from example.yaml)

```yaml
apiVersion: ai.paas.dodois.io/v1alpha1
kind: AIProject
metadata:
  name: my-project            # DNS-1123: [a-z0-9-], starts/ends alnum, ≤ 63 chars
spec:
  owners:                     # REQUIRED — list of objects (NOT bare strings); namespace + GitHub admin
    - email: i.petrov@dodobrands.io   # use @dodobrands.io (see auth note); email is required
    # - email: a.sidorov@dodobrands.io
    #   githubLogin: asidorov   # optional — set explicitly if the email isn't public on GitHub,
    #                           #   else repo admin won't be granted (Kaiten 65644546)
  expiresAt: "2026-12-31"     # optional — lifetime; project may be removed after
  resources:                  # OPTIONAL — namespace ResourceQuota (enforced). Omit for a purely
                              #   static (webstatic) project: the namespace then gets an explicit
                              #   ZERO compute quota (pods=0) — nothing can run. Include it for
                              #   any project with compute (pods/workers).
    cpu: "4"
    memory: "8Gi"
    storageRequests: "20Gi"
  database:                   # optional — PostgreSQL on shared RDS; omit if not needed
    extensions: []            #   e.g. [pgvector, uuid-ossp]
  # mongodb: {}               # optional — MongoDB document DB on shared Cloud.ru DDS; omit if not needed
  # mysql: {}                 # optional — MySQL 8.0 on shared Cloud.ru RDS; only for stacks that cannot run on Postgres
  # redis:                    # optional — dedicated in-pod Redis in the project namespace; omit if not needed
  #   sizeGb: 1               #   the only knob: data budget (maxmemory) in GiB, 1..16, default 1
  buckets:                    # optional — object stores; list, one entry per bucket
    - name: data              #   private by default (only the project's code)
      versioning: false
    #                         #   set access: public | restricted to host static files
    #                         #   from a bucket — see "Buckets block" below
  # llmEgress:                # optional — reach foreign LLMs (OpenAI/Anthropic) via platform proxy
  #   enabled: true
  # domains:                  # custom company-owned hosts — always manual approval
  # routes:                   # public HTTP exposure — approval rules in "Routes" below
  #                           #   (SSO-gated webstatic auto-approves; the rest is manual)
```

**Only `owners` is required.** Everything else (`resources`, `database`, `mongodb`, `mysql`, `redis`, `buckets`, `llmEgress`, `domains`, `routes`) is optional — delete the whole block if not needed. **Omit `resources` for a purely static (webstatic) project** — the namespace gets an explicit zero compute quota (`pods=0`), so it can only serve static files from a bucket (`access: restricted`) behind a `corp`/`owners` route; nothing runs. The namespace still works as the project's secret store: owners (and the deployer SA) can create and manage Kubernetes Secrets there even without compute — the project namespace is the platform's single home for secrets. A bare compute project is just `owners` + `resources`.

## Sizing guidance (justify every number; warn about ceilings)

`ResourceQuota` and `LimitRange` are **enforced**: a pod whose requests exceed the namespace
quota will not schedule. `resources` here is the *namespace ceiling* (sum across all pods),
not a single pod. Propose from expected load, explain the trade-off, let the user revise.

| Workload profile | cpu | memory | storageRequests | Rationale |
|------------------|-----|--------|-----------------|-----------|
| Nano — CronJob / webhook (no long-running server) | `"250m"` | `"512Mi"` | — | one short-lived pod, no rollout surge |
| Small — bot / worker (1 replica) | `"500m"` | `"1Gi"` | — | 1 replica + rollout (2 pods) + a migration Job still fit; matches the live `dodobot-ai-stub` shape |
| Standard — API / worker (2 replicas) | `"2"` | `"4Gi"` | opt-in | room for 2 replicas + DB-bound work (demo/showcase use this) |
| Heavier service / batch | `"4"` | `"8Gi"` | opt-in | parallel workers / larger memory footprint |

- The number is a **ceiling, not a reservation** — `requests==limits` in the quota caps the namespace, but the cluster only holds each pod's actual `requests` (~`100m/128Mi` for a 1-replica app), whatever the tier. So pick the number that *reads true* (a bot at `cpu: "4"` is a red flag), with one rollout's worth of headroom — not 10× "just in case".
- Warn: total pod `requests` **and** `limits` must each fit under `cpu`/`memory` (the quota sets both equal, so every container also needs a limit — LimitRange defaults `100m/128Mi` request, `200m/256Mi` limit). Account for rolling updates (~2× pods transiently) plus any migration/seed Job — that's why Small keeps `1Gi`, not `512Mi`.
- `storageRequests` is **opt-in** — omit it unless the workload mounts a PVC. Projects on OBS + RDS need none (every live project runs with `requests.storage` at 0).

## Database block

```yaml
  database:
    extensions: []     # add PG extensions here, e.g. [pgvector]
```
Operator creates the DB and a `<name>-db-credentials` Secret (keys: `DATABASE_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`). `dap-shipmaster` (Phase B) wires it via `envFrom`.

## MongoDB block

```yaml
  mongodb: {}     # enable-only; omit if not needed
```
Optional MongoDB-compatible document database on the shared Cloud.ru **DDS** instance —
orthogonal to `database` (a project can have both, neither, or either). Operator creates a
per-project database + a user scoped `readWrite` **only** to that database, and a
`<name>-mongodb-credentials` Secret. Keys: `MONGODB_URI` (full connection string, multi-host
replica-set + `authSource` + `replicaSet`), `MONGO_HOSTS` (comma-separated `host:port`; DDS
listens on **8635**, not 27017), `MONGO_REPLICA_SET`, `MONGO_DB`, `MONGO_USER`,
`MONGO_PASSWORD`. `dap-shipmaster` (Phase B) wires it via `envFrom`. Prefer `MONGODB_URI` —
it already lists all replica-set nodes.

## MySQL block

```yaml
  mysql: {}       # enable-only; omit if not needed
```
Optional MySQL **8.0** database on the shared Cloud.ru **RDS** instance — orthogonal to
`database` and `mongodb`. Take it only when your stack cannot run on PostgreSQL (CMS engines
such as WordPress); `database` stays the platform default. Operator creates a per-project
database + account whose privileges cover **its own** database in full (DDL included, so
migrations and CMS installers work) and nothing else — other databases on the instance are not
even visible. Secret `<name>-mysql-credentials`, keys: `MYSQL_URL`
(`mysql://user:pass@host:3306/db`), `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`, `MYSQL_USER`,
`MYSQL_PASSWORD`. `dap-shipmaster` (Phase B) wires it via `envFrom`; WordPress images want the
keys mapped to `WORDPRESS_DB_HOST` / `_NAME` / `_USER` / `_PASSWORD` (see the generated
`PLATFORM.md`).

⚠️ A MySQL database does not make the pod's filesystem persistent: things like
`wp-content/uploads` still live in the container and vanish on restart — put them in a project
bucket (S3-offload plugin) or a PVC.

## Redis block

```yaml
  redis:
    sizeGb: 1     # optional knob (1..16, default 1); `redis: {}` is enough to enable
```
Dedicated **in-pod Redis** for the project — a single-replica StatefulSet the operator runs
in the project's namespace (not a shared instance; full isolation). `sizeGb` is the only
knob: the data budget in GiB (= `maxmemory`), 1..16, default 1. Operator creates a
`<name>-redis-credentials` Secret. Keys: `REDIS_URL` (full connection string,
`redis://default:<pwd>@<name>-redis:6379/0` — prefer it), `REDIS_HOST`, `REDIS_PORT` (6379),
`REDIS_PASSWORD`. `dap-shipmaster` (Phase B) wires it via `envFrom`.

Important boundaries (tell the user when they ask for Redis):

- **`maxmemory-policy` is `noeviction`** — writes fail loudly when the budget is full instead
  of silently dropping keys; safe for queues (BullMQ and similar).
- **Persistence:** AOF on a PVC — data survives pod restarts and node loss (≤1s of writes may
  be lost). **No backups** — treat it as cache/queues, not a system of record.
- **No failover:** single replica; a node loss means a few minutes of downtime while the pod
  reschedules.
- **Growing `sizeGb` raises memory/`maxmemory` but does NOT expand the existing PVC** (disk
  expansion is a manual operator action).
- Reachable only inside the project namespace (`<name>-redis:6379`) — no extra NetworkPolicy
  or CR wiring needed for the app to connect.

## Buckets block

```yaml
  buckets:
    - name: data            # private (default): only the project's code, via creds
      versioning: false
    # - name: assets        # public website: world-readable (direct URLs / CDN origin /
    #   access: public      #   served by an auth:none route)
    #   spa: false          #     404 -> index.html (SPA) vs error.html
    #   # cors: ["https://app.example.com"]   # opt-in CORS (GET,HEAD)
    # - name: site          # static behind SSO: reachable ONLY through a corp/owners route;
    #   access: restricted  #   the raw OBS URL returns 403 (origin-lock — see access modes)
```
Each bucket → an OBS bucket `{prefix}-aipltf-<name-of-project>-<name>` + a
`<project>-<name>-credentials` Secret (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`). OBS is virtual-hosted style (`UsePathStyle: false`).
`name` is **immutable in practice** — renaming maps to a different OBS bucket + state
(i.e. a new, empty bucket).

### Access modes

| `access` | Who can read | Web-exposed? | Use for |
|----------|-------------|--------------|---------|
| `private` (default) | only the project's code, via the credentials Secret | no | data, uploads, anything private |
| `public` | **anyone** — anonymous GetObject on the whole bucket (direct OBS/CDN URLs work too) | via an `auth: none` route | a fully public static site / assets |
| `restricted` | anonymous GetObject **only through a platform route** — the raw OBS URL returns **403** | via a `corp`/`owners` route (and `auth: none` works too) | a static site behind SSO |

- **`public` ⇒ the bucket is world-readable** — never put secrets/private data there (that's what a private bucket is for).
- **`restricted` is the origin-lock**: the platform edge injects a secret `Referer` the bucket requires, so the content is reachable only *through* a route, not by hitting the OBS URL directly. This is what lets static content sit behind `auth: corp`/`owners` (a `public` bucket behind `auth: corp` would still be downloadable straight from OBS, bypassing SSO — so SSO-gated static **must** be `restricted`).

### Hosting static files from a bucket

A static site/SPA or a pile of assets can be served straight from a bucket — no pod, no Dockerfile.

1. **Declare the bucket + a route** in `projects/<name>.yaml` (approval: the SSO-gated
   `restricted` variant auto-approves as webstatic; the `public` variant needs manual
   approval → flag the PR — see Routes):

   ```yaml
   buckets:
     - name: site            # PUBLIC static site
       access: public
       spa: true             # serve index.html for unknown paths (SPA routing)
   routes:
     - path: /               # whole site at https://<name>.<base-domain>/
       auth: none
       backend:
         bucket: { name: site }
   ```

   …or, to put it **behind corporate SSO** (the showcase `/static` pattern):

   ```yaml
   buckets:
     - name: assets
       access: restricted    # MUST be restricted for an SSO-gated static route
   routes:
     - path: /static
       auth: corp            # any @dodobrands.io after Google SSO (use owners to limit)
       backend:
         bucket: { name: assets }
   ```

2. **Upload your files** to the bucket using the credentials Secret the operator created
   (`<project>-<name>-credentials`). Set `ContentType` so the browser renders instead of
   downloading; for a website, name the entry page `index.html` (and `error.html` for errors):

   ```python
   import boto3, mimetypes, os
   from botocore.config import Config
   s3 = boto3.client(
       "s3",
       endpoint_url=os.environ["S3_ENDPOINT"],
       aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
       aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
       region_name=os.environ["S3_REGION"],
       # The two checksum kwargs are REQUIRED for SberCloud OBS — without them the first
       # put_object fails with XAmzContentSHA256Mismatch (botocore >= 1.36 default checksums).
       config=Config(
           s3={"addressing_style": "virtual", "payload_signing_enabled": False},
           request_checksum_calculation="when_required",
           response_checksum_validation="when_required",
       ),
   )
   bucket = os.environ["S3_BUCKET"]
   for root, _, files in os.walk("dist"):
       for f in files:
           p = os.path.join(root, f)
           key = os.path.relpath(p, "dist")          # entry page must be named index.html
           ctype = mimetypes.guess_type(p)[0] or "application/octet-stream"
           s3.upload_file(p, bucket, key, ExtraArgs={"ContentType": ctype})
   ```

3. **Always reach the content through the route** — a relative path (`/static/app.js`) or
   `https://<name>.<base-domain>/...`. A hard-coded `*.obs-website…` URL is fetched by the
   browser directly and a `restricted` bucket returns **403** (the browser doesn't hold the
   secret `Referer`).

## Routes — public exposure; approval rules

Public HTTPS exposure is **operator-granted** (governance: self-serve allocates compute, DB,
buckets — but not exposure to the world). One carve-out is automated — the CI classifier
(`webstatic-classify`, run by `validate.yml`) **auto-approves a pure-webstatic PR**:

- the PR touches **only** `projects/*.yaml` (added/modified — no deletes, nothing outside `projects/`), **and**
- the CR has **no** `resources` / `database` / `mongodb` / `mysql` / `llmEgress`, **and**
- **no bucket has `access: public`**, **and**
- every route is **bucket-backed** with `auth: corp | owners | allowlist` (not `none`).

I.e. an SSO-gated static site is fully self-serve — no human in the loop. **Everything else
needs manual CODEOWNERS approval**: any `service`-backed route, any `auth: none` route or
`public` bucket (truly public content), or a route on a CR that also has compute/DB/llmEgress.

So:

- **Default: do not add a `routes:` block** unless the user needs web access. The service is reachable in-cluster and via `kubectl port-forward`.
- If the CR qualifies as webstatic (see above), just open the PR — it auto-approves; **don't** mark it as requiring manual approval.
- Otherwise, explain the approval gate and **either** leave `routes:` out, **or** add it and mark the PR title/body explicitly: `routes: requires manual approval`, so CODEOWNERS review it deliberately. (A `public` bucket likewise → manual approval — flag it too.)

Schema (`spec.routes[]` — paths share the project's hosts: `<name>.<base-domain>` plus any
`spec.domains[]`; each route is a path prefix + auth + exactly one backend: a pod `service`
or a static `bucket`):

```yaml
  # routes:                    # webstatic auto-approves; anything else — flag the PR
  #   - path: /                #   pathType: Prefix, longest-match-wins
  #     auth: none             #   none | corp | owners | allowlist
  #     backend:
  #       service: { name: app, port: 8080 }   # a pod Service in the project namespace
  #   - path: /admin
  #     auth: owners           #   SSO-gated app path
  #     backend:
  #       service: { name: app, port: 8080 }
  #   - path: /objects         #   upload endpoint: raise the request-body cap
  #     auth: none
  #     maxBodySize: 100m      #   whole megabytes 1m..256m; service routes only
  #     backend:
  #       service: { name: app, port: 8080 }
  #   - path: /legal           #   SSO-gated to a fixed list of internal people
  #     auth: allowlist
  #     allowedEmails:         #   corporate emails only; owners denied by default too
  #       - a.ivanov@dodobrands.io
  #       - legal.head@dodobrands.io
  #     backend:
  #       service: { name: app, port: 8080 }
  #   - path: /site            #   public static files from a bucket
  #     auth: none
  #     backend:
  #       bucket: { name: assets }             # a buckets[] entry with access: public
  #   - path: /static          #   SSO-gated static files (showcase /static pattern)
  #     auth: corp
  #     backend:
  #       bucket: { name: docs }               # a buckets[] entry with access: restricted
```

A `bucket` backend works under **any** auth level: `auth: none` needs the bucket
`access: public`; `auth: corp`/`owners`/`allowlist` needs it `access: restricted` (so the
files can't be pulled straight from OBS, bypassing SSO). See "Hosting static files from a
bucket" above.

**Uploads:** the edge accepts request bodies up to **20m** by default — bigger uploads get
HTTP 413. If the app receives larger payloads (file/model/geometry uploads), set
`maxBodySize` on that route: whole megabytes, `1m`..`256m`, **service routes only** (bucket
routes are static). Anything beyond the cap should be uploaded to a bucket directly
(presigned URL), not through the ingress.

### Custom domains (`spec.domains[]`)

A project can also be served on a **company-owned domain** (e.g. `jobs.dodobrands.io`) on top
of the automatic `<name>.<base-domain>`. Each entry is a whole-project alias: every `routes[]`
entry answers on every host with the same paths, backends and auth. There is deliberately no
per-domain path or auth.

```yaml
  # domains:                   # up to 5; ALWAYS manual CODEOWNERS approval
  #   - host: jobs.dodobrands.io
```

Rules an agent must not get wrong:

- **Never self-serve.** `domains` always needs manual approval — flag the PR body explicitly,
  the same way as a `service`-backed route. Do not add it speculatively.
- **DNS comes first, before the PR is merged.** The zone owner creates
  `CNAME <host> → <name>.<base-domain>.` (subdomain) or `A <host> → <ingress EIP>` (apex).
  Merging first makes cert-manager burn ACME validation attempts. Registry CI checks this and
  fails the PR if the host does not resolve to the platform.
- **Not a host inside the platform zone** (`*.dodo-ai-platform.io`, `*.d.dodoteam.ru`) — the
  automatic hostname is assigned by the platform; the operator rejects such a domain with
  `DomainInvalid`.
- **One host, one project.** If another project (or any cluster Ingress) already serves the
  host, the operator refuses it with `DomainConflict` and the incumbent keeps it.
- TLS is issued per host automatically. If a host later stops resolving to the platform, only
  that host's certificate stops renewing — the others are unaffected.

**Four auth levels per path** (`pathType: Prefix`, longest-match-wins):

| `auth` | Who | How |
|--------|-----|-----|
| `none` | anyone (public) | nginx → Service directly (Pomerium not in the path) |
| `corp` | any authenticated user with a corporate email (`@dodobrands.io`/`@dodopizza.com`) | через Pomerium SSO (Google) |
| `owners` | only emails in `spec.owners` | через Pomerium SSO (Google) |
| `allowlist` | only the corporate emails in the route's `allowedEmails` | через Pomerium SSO (Google) |

- `none` paths never depend on Pomerium (its outage can't take them down). `corp`/`owners`/`allowlist` paths are proxied through the shared platform Pomerium.
- Anonymous request to a `corp`/`owners`/`allowlist` path → **302** to Google sign-in; after login a non-permitted user gets **403**.
- **`allowlist`** is the middle ground between `corp` (whole domain) and `owners` (only owners): grant a **fixed set of named internal people** access to a path. Set `allowedEmails: [...]` on the route (required iff `auth: allowlist`). **Owners are denied by default too** — an owner gets access only if their email is in `allowedEmails`; if an owner needs web access, add their email (they can always reach the app via `kubectl port-forward` without it). Only corporate-domain emails are accepted — external accounts can't sign in via SSO and are rejected fail-loud. To gate a whole site, put `auth: allowlist` on both the app-route and the bucket-route.
- **Identity domain matters.** Pomerium matches the **Google Workspace identity = `@dodobrands.io`**. A user with a `@dodopizza.com` alias still signs in as `@dodobrands.io`, so list owners with their `@dodobrands.io` address — a `@dodopizza.com` entry in `spec.owners` will **not** match (`auth: owners` → 403 even for the owner). `auth: corp` admits the `@dodobrands.io` domain.
- All hosts share one host = `<name>.<base-domain>`; per-path, not per-host (MVP). TLS is automatic (cert-manager, one cert per host).

## External LLM egress (foreign LLM APIs)

Direct calls to foreign LLMs (OpenAI/Anthropic/…) from the cluster's RU IP are geo-blocked
(HTTP 403 region-not-supported). Opt in to route them through the platform's non-RU egress
proxy — **self-serve, no approval needed**:

```yaml
  llmEgress:
    enabled: true
```

When enabled, the operator puts a ConfigMap `llm-proxy-env` (key `LLM_PROXY_URL`) in your
namespace and opens egress to the proxy. App contract:

- **Route ONLY your LLM client through `LLM_PROXY_URL`** (an HTTP `CONNECT` proxy); keep
  regular traffic direct. Do **NOT** set a global `HTTPS_PROXY` — it would capture all HTTPS
  and hit the proxy's domain allowlist.
- The tunnel is end-to-end TLS, so **your native API token is never visible to the proxy**
  (bring your own key — it stays in your Secret).
- HTTP(S) only — **gRPC LLM clients are not supported** (use the REST variants).
- Wire the ConfigMap into your Deployment: `envFrom: [{configMapRef: {name: llm-proxy-env}}]`.
- Go (proxy only on the LLM client):
  ```go
  tr := &http.Transport{}
  if raw := os.Getenv("LLM_PROXY_URL"); raw != "" {
      if u, err := url.Parse(raw); err == nil { tr.Proxy = http.ProxyURL(u) }
  }
  llm := openai.NewClient(option.WithAPIKey(key), option.WithHTTPClient(&http.Client{Transport: tr}))
  ```

## Lifecycle (tell the user)

| Action | How | Result |
|--------|-----|--------|
| Create | add `projects/<name>.yaml` → PR → merge | operator provisions namespace, DB, buckets, dashboard, and a **new repo `github.com/dodo-ai-platform/<name>`** (from `project-template`, with `PLATFORM.md`) — ship from that repo, not a pre-existing one |
| Change | edit the YAML → PR → merge | operator adds/removes modules to match |
| Drop a data section (`database`/`mongodb`/`mysql`/`redis`) or a `buckets[]` entry | remove it **and add a confirmation annotation** (below) → PR → merge | operator destroys that resource with its data; without the annotation admission rejects the apply |
| Delete | remove the file → PR → merge | CI `kubectl delete`; operator destroys all resources, archives the repo |

### Deletion protection for data

Removing `database`, `mongodb`, `mysql`, `redis` or a `buckets[]` entry makes the operator finalize that
module — `terraform destroy` of the database, destroy of the bucket, deletion of the Redis
StatefulSet with its PVC. A cluster admission policy (`ai-platform-aiproject-data-guard`) rejects
such an edit unless the manifest carries one confirmation token per removed resource
(`buckets/<name>` for a bucket):

```yaml
metadata:
  name: my-project
  annotations:
    ai.paas.dodois.io/confirm-destroy: "database,buckets/data"
```

Tokens are matched exactly: `redis` does not authorize dropping `database`, and `buckets/data2` does
not authorize dropping `data`. Remove the annotation from the manifest once the deletion has landed
(the operator strips spent tokens from the live object, but the registry manifest is yours).
Deleting the whole project file needs no annotation. Such PRs never auto-approve — they go to
CODEOWNERS review.

All changes go through PR — `CODEOWNERS` (@RedkinM @malinborn @KirillAalex) approval is required.
