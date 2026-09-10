# dap-doctor — troubleshooting reference

Load this only when a check reports a problem. Find the symptom, apply the action.
All `brew` fixes are macOS-only and require user consent first.

## Tier 1 — toolchain & access

| Symptom | Cause | Action |
|---------|-------|--------|
| `[MISS] kubelogin` | OIDC plugin absent | `brew install int128/kubelogin/kubelogin` |
| `[MISS] kubectl` / `gh` / `git` | binary not on PATH | `brew install kubectl` / `gh` / `git` |
| `[WARN] docker daemon — not running` | Docker Desktop/colima stopped | start Docker Desktop, or `colima start` |
| `[WARN] no GHCR login` | docker can't pull/push `ghcr.io` | `gh auth token \| docker login ghcr.io -u $(gh api user --jq .login) --password-stdin` |
| `[MISS] gh auth — not logged in` | no GitHub token | `gh auth login` (choose HTTPS + browser) |
| `[WARN] no current kube-context` | platform kubeconfig not added | save the kubeconfig from `PLATFORM.md` to `~/.kube/<project>.yaml`, then `export KUBECONFIG=~/.kube/config:~/.kube/<project>.yaml` |
| kube API request hangs, opens browser repeatedly | OIDC token not cached / wrong Google account | complete the Google login in the browser once; token caches 24h. Wrong account → `kubectl oidc-login clean` then retry |
| `[WARN] AI agent CLI not found` | neither `claude` nor `copilot` on PATH | install Claude Code or GitHub Copilot CLI (informational; not required for the platform itself) |

## OIDC / kubelogin specifics

- First `kubectl` call against the platform cluster opens a browser for Google SSO. Token is cached ~24h under `~/.kube/cache/oidc-login/`.
- `error: You must be logged in to the server (Unauthorized)` → token expired or wrong account → re-run any `kubectl get pods`, log in with the corporate Google account.
- `oidc-login` not found as a kubectl plugin → that's `kubelogin`; ensure it's installed and on PATH (the kubeconfig calls `kubectl oidc-login`).

## Tier 2 — deployed project visibility

| Symptom | Cause | Action |
|---------|-------|--------|
| `cannot get pods in <ns>` | not an owner / OIDC not done | confirm your email is in the project's `owners`; complete OIDC login |
| `403 on a private route after login` | your identity isn't permitted by that path's `auth` | for `auth: owners`: your `@dodobrands.io` identity must be in `spec.owners` (a `@dodopizza.com` alias won't match); for `auth: corp`: sign in with a corporate `@dodobrands.io` account |
| `database/bucket secret missing` | operator hasn't reconciled that module | check `kubectl get project <name> -o yaml`; the module may still be provisioning, or wasn't requested in the Project CR |
| `route — no response (000)` | DNS/TLS not ready, or service not routed | wait for cert-manager; verify the Service exists and matches the route's `backend.service` name/port |
| `Grafana — HTTP 4xx` | VPN/login required | open the dashboard URL in a browser on VPN |
| `drift — repo image != live` | someone edited cluster by hand, or PLATFORM.md changed | manifests are owned by `dap-shipmaster`; re-run it to regenerate `k8s/*.yaml` rather than `kubectl edit` |
| `agent guide missing PLATFORM.md reference` | link dropped from CLAUDE.md | the skill appends a one-line reference (loose coupling — a link, never a copy) |

## Pod-level failures (seen via `kubectl get pods -n <ns>` / `describe`)

| Pod state | Likely cause | Action |
|-----------|--------------|--------|
| `ImagePullBackOff` | image not pushed yet / wrong tag | check the GHCR push step in CI; confirm `image:` repo in `k8s/deployment.yaml` |
| `CrashLoopBackOff` | app exits on start | `kubectl logs deploy/<name> -n <ns>`; check env/secrets wiring |
| `CreateContainerConfigError` | referenced secret missing | the `envFrom` secret name must match PLATFORM.md (`<name>-db-credentials` etc.) |
| `Pending` (FailedScheduling) | over `ResourceQuota` | lower `requests/limits`, or raise the quota via `dap-shipmaster` |
| pod rejected by admission | restricted PSS violated | keep the full `securityContext` (`runAsNonRoot`, `drop: ALL`, `seccompProfile`), port ≥1024 — regenerate via `dap-shipmaster` |

## Escalation

If a subsystem is provisioned in the Project CR but never appears (secret, route, dashboard) after a few minutes, it's an operator-side reconcile issue — capture `kubectl get project <name> -o yaml` and raise with the platform team (CODEOWNERS: @RedkinM @malinborn @KirillAalex).
