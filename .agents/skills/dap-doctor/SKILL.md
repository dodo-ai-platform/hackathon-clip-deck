---
name: dap-doctor
description: Use when setting up or verifying a machine for the Dodo AI platform, when docker/git/gh/kubectl/kubelogin is missing or its version/auth is in doubt, when "kubectl Unauthorized"/OIDC login loops/GHCR 403 appear, when a deployed project's logs, pods, routes, Grafana, or DB/bucket secrets are not visible, or before running dap-shipmaster. Diagnostic and idempotent — safe to re-run.
version: 2.1.0
---

# dap-doctor

## Overview

Idempotent diagnostic for the Dodo AI platform. Each run: **detect state → report what's OK / broken / will-fix → fix what it safely can (macOS, with consent)**. Two tiers:

- **Tier 1 — local environment** (always): toolchain presence + versions, and whether access actually *works* (gh auth, kube API, GHCR). Plus bootstrap/version-check of the sibling skill (`dap-shipmaster`).
- **Tier 2 — deployed project** (only when a non-placeholder `PLATFORM.md` exists in the repo): visibility of the live service and its subsystems, the `CLAUDE.md → PLATFORM.md` link, and config drift.

Never mutates the cluster. Never installs without asking. Never prints secrets.

## Plain-language narration (default)

You act on real infrastructure. **Before each step that inspects or changes infra** — running a script, a login, building or pushing an image, `kubectl apply`, or any `gh` / `docker` / `kubectl` call — first tell the user in **1–2 short, jargon-free sentences** what you're about to do and why, so a non-DevOps user isn't startled by raw commands. Keep it brief, then run the command. If the user says "skip the explanations", stop narrating.

## When to Use

- New laptop / "is my machine ready for the platform?"
- `kubectl` says `Unauthorized`, OIDC keeps opening the browser, `docker push` to ghcr.io 403s, `gh` not logged in
- A shipped project's pods/logs/routes/Grafana/secrets aren't showing up
- Before `dap-shipmaster` (need working access) or after it (verify the feedback-loop)

Not for: creating projects or building/deploying code (use `dap-shipmaster`).

## Workflow

Scripts live in this skill's `scripts/` directory. Run them with `bash`, read stdout, act on `[MISS]`/`[WARN]` lines.

### 1. Tier 1 — local environment

```bash
bash scripts/check-env.sh
```

Each line is `[ ok ] / [WARN] / [MISS] <detail> — fix: <command>`.

- **macOS, user consents:** run the `fix:` `brew` commands one at a time, then re-run `check-env.sh` (idempotent — already-installed tools just report `ok`). **Ask before each install/login.** Never auto-install on non-macOS — show the user the command instead.
- The kube-API check may open a browser for Google SSO on first run; tell the user to expect it.
- `[WARN] no kube-context yet` is **normal before your project is allocated** — the kubeconfig arrives via `PLATFORM.md` after provisioning. Don't treat it as broken on a first run.
- Re-run until green or until remaining gaps need the user (e.g. VPN, account access).

For any symptom you don't recognize, read `references/troubleshooting.md` (load on demand).

### 2. Bootstrap + version-check the sibling skill

```bash
bash scripts/install-skills.sh --check     # report versions vs canonical
bash scripts/install-skills.sh             # install/upgrade dap-shipmaster locally
```

Canonical source is `dodo-ai-platform/project-template@main` (`.agents/skills/`), always fetched via `gh`. The checkout the script lives in is **not** used unless you pass `--from-local` — a project repo carries a frozen `.agents/skills` snapshot from provisioning time, and installing from it downgrades the set (that is how a tenant kept seeing pre-2.6.0 route rules). Use `--from-local` only for a fresh `project-template` clone or offline installs. Offer the upgrade when `--check` shows one available. The installer also removes legacy `ai-platform-doctor`/`ai-platform-allocate`/`ai-platform-ship` directories so old and new skills don't both load.

### 3. Tier 2 — deployed project (only if PLATFORM.md is real)

```bash
bash scripts/check-deploy.sh        # run from the project repo root
```

It reads the contract via `../../_shared/platform-reader.sh`, then checks namespace access, pods/readiness, DB/bucket secrets, routes, Grafana, the OTLP target, and drift between `k8s/*.yaml` and the live deployment. If it reports the `CLAUDE.md → PLATFORM.md` reference is missing, **append a one-line link** (loose coupling — a link, never a copy of PLATFORM.md). If `PLATFORM.md` is still a placeholder, Tier 2 self-skips — that's expected on an un-provisioned project.

## Quick Reference

| Goal | Command |
|------|---------|
| Check local toolchain + access | `bash scripts/check-env.sh` |
| Compare skill versions | `bash scripts/install-skills.sh --check` |
| Install/upgrade dap-shipmaster | `bash scripts/install-skills.sh` |
| Check a deployed project | `bash scripts/check-deploy.sh` |
| Parse PLATFORM.md directly | `bash ../_shared/platform-reader.sh` (path relative to skill dir; no arg — walks up from cwd) |
| Error → action lookup | `references/troubleshooting.md` |

## Common Mistakes

- **Auto-installing without consent**, or running `brew` on non-macOS — always ask; on Linux/Windows print the command.
- **Running Tier 2 on an un-provisioned project** — gated by a real `PLATFORM.md`; the script self-skips, don't force it.
- **Copying PLATFORM.md into CLAUDE.md** — add a *reference*, never duplicate the contract.
- **Editing the cluster to fix drift** — manifests are owned by `dap-shipmaster`; regenerate, don't `kubectl edit`.
- **Echoing tokens/kubeconfig** to logs — never print secret material.

## Cross-agent note

All work is plain `bash` + `gh`/`kubectl`, portable across Claude Code and GitHub Copilot CLI. For tool-name differences (file edits when appending the CLAUDE.md link, etc.) see `../_shared/copilot-tools.md`.
