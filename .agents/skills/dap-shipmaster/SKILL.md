---
name: dap-shipmaster
description: Use to take a Dodo AI-platform service end-to-end — allocate resources (namespace + optional PostgreSQL + MySQL + MongoDB + Redis + object storage) and ship code to the cluster. Covers "выдели проект/ресорсы", a new environment, resize/delete a project, AND "deploy/ship this project", first deploy, redeploy, or fixing a failed build/rollout. Two phases: Phase A runs in dodo-ai-platform/platform-projects (Project CR PR → CODEOWNERS merge gate); Phase B runs in the project repo once the operator has written a real PLATFORM.md. Public routes are not self-serve, except SSO-gated webstatic (auto-approved by CI).
version: 2.12.0
---

# dap-shipmaster

## Overview

The full delivery path for a platform service, in **two phases** separated by a hard human/operator gate:

- **Phase A — Allocate** (in the **`platform-projects`** repo): a short interview → `projects/<name>.yaml` Project CR → PR → CI validation → **stop at the CODEOWNERS merge gate**. After a human approves, the **operator** provisions namespace/DB/buckets/repo/dashboard and writes `PLATFORM.md` into the project's repo — a **brand-new repo the operator creates at `github.com/dodo-ai-platform/<name>`** (from `project-template`), *not* any pre-existing app repo you may already have.
- **Phase B — Ship** (in the **project repo**): read the `PLATFORM.md` contract → Python `Dockerfile` → fill `k8s/*.yaml` → deploy via the existing CI → confirm the pod is Running.

Between the phases there is an **async boundary you cannot cross automatically**: CODEOWNERS approval + operator reconcile. The manifests in Phase B are a **regenerable artifact owned by this skill** — edit through the skill, not by hand. Self-serve covers compute + databases (PostgreSQL / MySQL / MongoDB) + Redis + buckets + external LLM egress (`llmEgress`); **public routes are not self-serve** — they need separate approval, with one automated carve-out: a pure **webstatic** CR (SSO-gated static site from a bucket, no compute/DB/llmEgress) is auto-approved by CI (see A3).

This skill is **resumable**: it detects which phase you're in and continues from there.

## Plain-language narration (default)

You act on real infrastructure. **Before each step that inspects or changes infra** — opening a PR, a `git` push, building or pushing an image, `kubectl apply`, deploying via CI, or any `gh` / `docker` / `kubectl` call — first tell the user in **1–2 short, jargon-free sentences** what you're about to do and why, so a non-DevOps user isn't startled by raw commands. Keep it brief, then run the command. If the user says "skip the explanations", stop narrating.

## When to Use

- "I need a project / namespace / environment on the AI platform", "add a database / bucket", "bump my quota", "delete my project" → **Phase A**
- "Deploy / ship this project", "first deploy", "my build/rollout failed", "redeploy after a change" → **Phase B**

Not for checking machine readiness or diagnosing a live project's health — that's `dap-doctor`.

## Workflow

### 0. Detect the phase

- cwd is a **`platform-projects`** checkout → **Phase A**.
- cwd is a **project repo**, `PLATFORM.md` is still a placeholder → not provisioned yet: tell the user to wait for CODEOWNERS merge + operator, then return. Stop.
- cwd is a **project repo**, `PLATFORM.md` is real (operator-written) → **Phase B**.

Confirm Phase B provisioning with the bundled parser (see B1). Idempotency throughout: detect what already exists and resume from the first incomplete step rather than redoing work.

---

### Phase A — Allocate (in `platform-projects`)

#### A0. Context first

**Sync the checkout before reading anything.** The schema and docs in `platform-projects` evolve; a stale clone — or an allocate branch cut from an older `main` — makes the local CRD lie about what the platform supports (real incident: an agent read a pre-`mysql` CRD from a days-old branch and declared the module unsupported). The CRD is authoritative **as of `origin/main`**, not as of whenever the repo was cloned:

```bash
git fetch origin
git switch main && git pull --ff-only
# resuming an open allocate branch instead? bring its base up to date:
#   git switch "allocate/$name" && git merge origin/main
```

Read `projects/example.yaml` and a couple of active `projects/*.yaml` so proposed values match house style. **House style only** — never infer which fields are required/optional (or copy blocks wholesale) from existing CRs: they may predate schema changes.

**The schema's source of truth is the live cluster**, not any file: CI judges the PR with a server-side dry-run against it. Prefer reading the served schema directly — it cannot be stale and needs no extra rights (any Dex-authenticated kubeconfig works, e.g. the one `dap-doctor` sets up):

```bash
kubectl explain aiproject.spec              # field list; drill down: kubectl explain aiproject.spec.<field>
```

No working kubeconfig yet → fall back to the repo CRD `crds/ai.paas.dodois.io_aiprojects.yaml`, valid only as of a synced `origin/main`. **Conflict rule:** a field this skill or a reference documents but your CRD copy lacks is a *staleness signal* — re-sync and check `kubectl explain` before concluding the docs are wrong. Full schema notes, sizing tables, and the database/buckets/routes rules are in `references/project-cr.md` — load it before sizing.

#### A1. Interview

Ask, in plain language: project **name**; **owners** (corporate emails); expected **load** (rough: bot/cron vs API vs heavier); needs a **database** (PostgreSQL — the default relational choice)? a **mysql** (MySQL 8.0 on shared RDS — self-serve, for stacks that can't run on Postgres, e.g. WordPress)? a **mongodb** (document DB)? a **redis** (cache/queues, e.g. BullMQ)? a **bucket**? wants to **host static files / a static web app** (served straight from a bucket — public or behind SSO, no pod needed)? calls **foreign LLMs** (OpenAI/Anthropic → `llmEgress`)? Note if they think they need public access (→ routes caveat in A3).

#### A2. Size with justification

Propose `resources.cpu/memory/storageRequests` from the load, using the sizing table in `references/project-cr.md`. **Explain each number and warn that quotas are enforced** (a pod over the namespace quota won't schedule; LimitRange defaults are per-container). Let the user revise before writing anything.

#### A3. Routes — approval rules (webstatic auto-approves; the rest is manual)

Default to **no `routes:` block**. If the user wants web access, check which approval bucket the CR falls into (full criteria in `references/project-cr.md` → "Routes"):

- **Webstatic → auto-approve.** A CR with no `resources`/`database`/`mongodb`/`mysql`/`llmEgress`, no `access: public` bucket, and only bucket-backed routes with `auth: corp|owners|allowlist` is approved by CI automatically — just open the PR, don't flag it.
- **Everything else → manual.** Any `service`-backed route, `auth: none` route, or `public` bucket requires CODEOWNERS approval: explain the gate and either leave `routes:` out or add it **and flag the PR** with `routes: requires manual approval` in the title/body so CODEOWNERS decide deliberately.

**Static sites are a first-class option** — raise them proactively when the user has static assets / a built front-end / a static web app. Files are served straight from a bucket via a route, no pod or Dockerfile: `access: restricted` + `auth: corp|owners|allowlist` for a site behind SSO (webstatic, self-serve), or `access: public` + `auth: none` for a truly public one (manual approval). The recipe and an upload snippet are in `references/project-cr.md` → "Hosting static files from a bucket". **Omit `resources` on a pure static project** — it's optional, nothing runs there, and adding it disqualifies the PR from webstatic auto-approve.

#### A4. Validate the name, then generate

DNS-1123 + uniqueness, before writing:

```bash
name="my-project"
echo "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' || echo "INVALID: DNS-1123 (lowercase alnum + '-', ≤63, no leading/trailing '-')"
[ -e "projects/$name.yaml" ] && echo "TAKEN: projects/$name.yaml already exists — this may be a re-run; do not duplicate"
```

If the file or an open PR for this name already exists, **don't create a duplicate** — resume/report instead. Then write `projects/<name>.yaml` matching `example.yaml`'s shape (omit unused module blocks — `database`/`mysql`/`mongodb`/`redis`/`buckets`/`routes`).

#### A5. PR + wait for CI

```bash
git checkout -b "allocate/$name"
git add "projects/$name.yaml"
git commit -m "feat: allocate project $name"
git push -u origin "allocate/$name"
gh pr create --title "Allocate project: $name" --body "<why this project, who owns it, what the resources are for, which modules (db/buckets/routes) and why>"
gh pr checks --watch        # wait for validate.yml (kubectl apply --dry-run=server)
```

Report the `validate.yml` result. If it fails, read the dry-run error (usually a shape/field issue), fix the YAML, push again.

#### A6. Stop at the merge gate

Tell the user: **"PR is open and CI is green; it now needs CODEOWNERS approval (webstatic PRs are approved by CI automatically — then it just needs a merge). After merge, the operator provisions the namespace/DB/buckets/dashboard and creates a brand-new repo at `github.com/dodo-ai-platform/<name>` with `PLATFORM.md` inside — clone THAT repo (not your existing app repo, if you have one) and run me there to ship. If your code already lives in another repo, move/copy it into `dodo-ai-platform/<name>`."** Do not attempt to merge or provision.

> The project repo is **always** `github.com/dodo-ai-platform/<name>` (= the Project CR name) — a fresh repo the operator generates from `project-template`. It is **not** any existing codebase repo. This is the #1 point of confusion: an agent running in a pre-existing app repo wrongly waits for `PLATFORM.md` to appear there — it never will, `PLATFORM.md` only lands in `dodo-ai-platform/<name>`.

> Delete/resize a project: edit or remove `projects/<name>.yaml` → PR → merge (the operator destroys/adjusts resources). Same gate.

---

### Phase B — Ship (in the project repo)

#### B1. Precondition + contract

The bundled parser is at **`../_shared/platform-reader.sh` relative to THIS skill's own directory** (not your cwd) — resolve it to an absolute path first. It takes **no argument**: it finds `PLATFORM.md` by walking up from your current directory, so keep the project repo as cwd. Run the `eval` and the variable read in the **same shell call** (a fresh shell loses the vars):

```bash
READER="<this-skill-dir>/../_shared/platform-reader.sh"   # absolute path to the bundled parser
eval "$(bash "$READER")"
echo "$provisioned $namespace $registry $db_secret_name $mysql_secret_name $mongodb_secret_name $redis_secret_name $bucket_secret_name $otlp_endpoint"
```
If `provisioned` isn't `true` → stop: "PLATFORM.md is still a placeholder — finish Phase A, wait for the operator, then come back."

Note on names: by construction **app name = repo name = namespace = project name** (CI derives the namespace from the repo name). Use that single value everywhere a placeholder asks for an app/repo/service name.

> **Pure static project? Skip B2–B6.** If the project just serves static files from a bucket (its routes are all `bucket`-backed, no running app pod), there is **nothing to containerize or deploy** — don't write a Dockerfile or `k8s/*.yaml` (the operator leaves template ones in the repo; ignore/remove them). Just **upload your files to the bucket** following `PLATFORM.md` → "Object Storage" (entry page named `index.html`), then reach them through the route. The rest of Phase B applies only to projects with a running service.

#### B2. Build the container FIRST

Analyze the code, then **rewrite the `Dockerfile` for Python** following `references/dockerfile-python.md` (multi-stage, non-root UID ≥ 1024, pinned base, deps-before-source, real `/healthz`). Build locally to prove it works before touching manifests:

```bash
docker build -t "ghcr.io/dodo-ai-platform/$namespace:dev" .
```

#### B3. THEN fill the manifests

Only now load `references/manifest-rules.md` (kept separate so its rules don't sit in context during the container step). Following it, fill `k8s/deployment.yaml` + `k8s/service.yaml`: replace `myapp`/`REPO_NAME`, set `OTEL_SERVICE_NAME`, leave `IMAGE_TAG`, set the app port (≥1024) and real probe paths, **uncomment DB/mysql/mongodb/redis/bucket `envFrom` only if `$db_secret_name`/`$mysql_secret_name`/`$mongodb_secret_name`/`$redis_secret_name`/`$bucket_secret_name` are set**, and **keep the full securityContext + resources** (the cluster does not inject them). **Do not create route/ingress manifests.** Then validate against the server:

```bash
kubectl apply --dry-run=server -f k8s/ -n "$namespace"
```
Fix until clean (catches restricted/quota/shape errors before CI).

#### B4. Keep the CLAUDE.md → PLATFORM.md link

Ensure `CLAUDE.md` references `PLATFORM.md` (the template already does). If missing, append a one-line reference — `dap-doctor` later guards it.

#### B5. Deploy via CI and watch

The repo's `.github/workflows/deploy.yaml` already does build → push `ghcr.io` → `sed IMAGE_TAG` → `kubectl apply -f k8s/`. Don't recreate it; just verify file names match. Commit and push to a branch, open a PR or push to `main` per repo policy, then:

```bash
gh run watch        # follow the Actions run; report each step / failure
```

#### B6. Confirm the rollout

```bash
kubectl rollout status deploy/<name> -n "$namespace" --timeout=120s
kubectl get pods -n "$namespace"
```
Confirm the pod is **Running and readiness passed** — that proves *your* deploy landed. For ongoing health/visibility of the live project (logs, routes, Grafana, drift) hand off to `dap-doctor` Tier 2. If the rollout fails, read logs/events (`kubectl logs`, `kubectl get events`) — common causes and fixes are in `dap-doctor/references/troubleshooting.md` (pod-level table).

## Edge cases

- **Build fails in CI** → read the failing step via `gh run view --log-failed`; fix Dockerfile/deps; push again (idempotent).
- **Deploy step fails** → re-run `kubectl apply --dry-run=server` locally to reproduce; usually a manifest/quota/secret-name mismatch.
- **ImagePullBackOff** → image not pushed or wrong `image:` repo; check the GHCR push step.
- **Re-run after partial success** → phase detection + B1 detection skip already-done work.

## Quick Reference

| Step | Command / file |
|------|----------------|
| Live schema — preferred source of truth (Phase A) | `kubectl explain aiproject.spec` |
| Schema, sizing, db/buckets/routes rules (Phase A) | `references/project-cr.md` |
| Open allocate PR | `gh pr create …` → `gh pr checks --watch` |
| Read contract (Phase B) | `bash ../_shared/platform-reader.sh` |
| Dockerfile rules | `references/dockerfile-python.md` |
| Manifest rules (load after build) | `references/manifest-rules.md` |
| Validate manifests | `kubectl apply --dry-run=server -f k8s/ -n "$namespace"` |
| Watch deploy | `gh run watch` |
| Confirm rollout | `kubectl rollout status deploy/<name> -n "$namespace"` |

## Common Mistakes

- **Crossing the gate yourself** — Phase A stops at CODEOWNERS approval; humans approve, the operator provisions. Never merge or provision.
- **Writing PLATFORM.md** — skills never author it; the operator does, after merge.
- **Granting public routes self-serve** — only SSO-gated webstatic auto-approves (A3); everything else: omit or flag for approval.
- **Judging the schema from a stale checkout** — `git fetch` + sync with `origin/main` first (A0); a pre-update local CRD makes you deny features the platform already has. Docs mention a field your CRD copy lacks? Check `kubectl explain aiproject.spec` before declaring the docs wrong — repeating the same grep on the same stale file is not re-verification.
- **Treating existing `projects/*.yaml` as schema authority** — they show house style; required/optional comes from the CRD (`crds/…aiprojects.yaml`). Don't copy a sibling's block (e.g. `resources`) just because a similar project has it.
- **Sizing without justification or quota warning** — always explain and caution about enforced quotas.
- **Wrong repo for the phase** — Phase A is `platform-projects`; Phase B is `dodo-ai-platform/<name>` (the operator-created repo, = the project name), **not** any pre-existing app repo. If your code lives elsewhere, move it into `dodo-ai-platform/<name>` — `PLATFORM.md` and the deploy pipeline only exist there.
- **Loading manifest-rules.md before building** — build the container first, then read manifest rules (lazy).
- **Dropping securityContext or resources** — both mandatory; the cluster does not inject them.
- **Creating route/ingress manifests** — never; public routes are operator-granted via Phase A.
- **Uncommenting db/mysql/mongodb/redis/bucket envFrom that isn't in PLATFORM.md** → CreateContainerConfigError.
- **Editing manifests by hand later** — regenerate via this skill; `dap-doctor` flags drift.
- **Running Phase B on an un-provisioned repo** — placeholder PLATFORM.md means finish Phase A first.

## Cross-agent note

Pure `git` + `gh` + `docker` + `kubectl` + file edits — identical across Claude Code and GitHub Copilot CLI. For file/edit tool-name differences see `../_shared/copilot-tools.md`.
