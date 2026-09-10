# AI-platform skills (canonical copies)

This directory is the **canonical home** of the Dodo AI-platform skill set. Agents
(Claude Code, GitHub Copilot CLI) load *local* copies from their own skills dir; these
copies here are the source `dap-doctor` installs/updates from.

| Skill | Repo it runs in | Does |
|-------|-----------------|------|
| `dap-doctor` | any / project repo | local toolchain + access diagnostic (tier 1); deployed-project feedback-loop (tier 2); bootstraps + version-checks `dap-shipmaster` |
| `dap-shipmaster` | `platform-projects` (Phase A) → project repo (Phase B) | **Phase A:** interview → Project CR PR → stops at CODEOWNERS merge gate (no self-serve routes). **Phase B:** Python Dockerfile + `k8s/*.yaml` → CI deploy → pod Running (precondition: real PLATFORM.md) |
| `_shared/platform-reader.sh` | — | defensive PLATFORM.md parser used by `dap-doctor` (tier 2) + `dap-shipmaster` (Phase B) |

Versions are tracked in `VERSION` (and mirrored in each `SKILL.md` frontmatter).

## Updating a skill (maintainer checklist)

Every content change ships only when both version markers move: bump `version:` in the
skill's `SKILL.md` frontmatter **and** the matching line in `VERSION` —
`install-skills.sh` judges freshness by the `VERSION` manifest alone.

When the change adds or renames a **platform module / contract field** (a `spec.*` block
like `mysql`, `redis`, a new secret, a new route kind), updating `references/` is **not
enough** — agents run the interview and fill manifests from the `SKILL.md` body, so a
module missing there is a module that "doesn't exist" (real incident: 2.11.0 added MySQL
to `references/` only; `SKILL.md` still offered PostgreSQL as the only relational DB and
agents told users MySQL wasn't supported). Sweep **every enumeration** of modules, using
an existing peer module as the probe:

```bash
grep -rin 'mongodb' dap-shipmaster/ _shared/ ../../CLAUDE.md
```

The new module must appear everywhere the peer does (unless a spot is genuinely
peer-specific). Known enumeration sites:

- `SKILL.md`: frontmatter `description`, self-serve list (Overview), interview (A1),
  webstatic auto-approve criteria (A3), omit-unused-blocks list (A4), secret-vars `echo`
  (B1), `envFrom` list (B3), Common Mistakes;
- `references/project-cr.md` (example CR, block section, webstatic criteria,
  deletion-protection table) and `references/manifest-rules.md` (secrets, egress);
- `_shared/platform-reader.sh` (`*_secret_name` emit) + its tests;
- repo `CLAUDE.md` (NetworkPolicy/egress list).

Webstatic auto-approve criteria live in **two places** (`SKILL.md` A3 and
`project-cr.md` → Routes) — they must stay literally in sync, or CRs get misclassified.

> Replaces the earlier three-skill set (`ai-platform-doctor` / `ai-platform-allocate` /
> `ai-platform-ship`): `dap-doctor` ← doctor; `dap-shipmaster` ← allocate + ship merged into
> one resumable two-phase skill. The installer removes the legacy directories on upgrade.

## End-to-end path

`dap-doctor` (machine ready) → `dap-shipmaster` Phase A (PR → merge → operator writes
PLATFORM.md) → `dap-shipmaster` Phase B (deploy) → `dap-doctor` tier 2 (feedback-loop healthy).

## Installation

The set is distributed **through this template repo** (distribution source =
`dodo-ai-platform/project-template`). `dap-doctor` installs/updates `dap-shipmaster`:

```bash
bash dap-doctor/scripts/install-skills.sh --check   # versions vs canonical
bash dap-doctor/scripts/install-skills.sh           # install/upgrade (+ removes legacy skills)
```

It installs into `~/.claude/skills/` (Claude Code) or `~/.agents/skills/` (Copilot/Codex);
override with `--dest`. **Canon is always fetched from `project-template@main` via `gh`** — the
checkout the script lives in is never used implicitly, because project repos are created from this
template and carry a frozen `.agents/skills` snapshot; installing from one silently downgrades the
set. To install from a checkout on purpose (fresh clone, or offline), pass `--from-local`.

### Seed (chicken-and-egg)

A developer with nothing yet needs `dap-doctor` before they can self-bootstrap. Seed
one-liner (only `git` + access to the DAP GitHub org required):

```bash
git clone --depth 1 https://github.com/dodo-ai-platform/project-template /tmp/pt \
  && bash /tmp/pt/.agents/skills/dap-doctor/scripts/install-skills.sh --from-local
```

`--from-local` is what makes this work without `gh`: the clone *is* canon (`main`, fresh), so
installing from it is legitimate. Once `gh` is authenticated, plain `install-skills.sh` fetches
canon itself and no clone is needed.

After that, `dap-doctor` keeps the set updated.

## Testing

```bash
bash _shared/tests/run.sh        # platform-reader.sh unit/contract tests
```
