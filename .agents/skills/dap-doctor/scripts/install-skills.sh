#!/usr/bin/env bash
# install-skills.sh — bootstrap + version-check for the AI-platform skill set
# (dap-doctor + dap-shipmaster).
#
# Canonical copies of the skills live in dodo-ai-platform/project-template under
# .agents/skills/. This installs/updates the local copies an agent loads, and
# compares installed versions against the canonical VERSION manifest. It also
# removes the legacy ai-platform-{doctor,allocate,ship} skills so old and new
# don't both load.
#
# Usage:
#   install-skills.sh [--check] [--from-local] [--dest DIR] [--ref REF]
#     --check       compare versions only; do not copy anything
#     --from-local  install from the checkout this script lives in instead of
#                   fetching canon (only correct for a fresh project-template
#                   clone — a project repo's .agents/skills is a frozen snapshot)
#     --dest DIR    target skills dir (default: ~/.claude/skills if ~/.claude exists,
#                   else ~/.agents/skills)
#     --ref  REF    project-template git ref to fetch (default: main)
#
# Canonical source resolution:
#   1) $CANONICAL_SKILLS_DIR (if it contains VERSION)
#   2) --from-local: the checkout this script lives in (offline, no network)
#   3) default: gh tarball of dodo-ai-platform/project-template@main (network)
#
# The checkout is never used implicitly — see the note above resolve_src().
#
# Idempotent: re-running on an up-to-date machine reports "up to date" and copies
# identical files. READ-ONLY against the cluster; only writes under --dest.

set -u

SKILLS=(dap-doctor dap-shipmaster)
LEGACY_SKILLS=(ai-platform-doctor ai-platform-allocate ai-platform-ship)
REPO="dodo-ai-platform/project-template"
REF="main"
DEST=""
CHECK_ONLY=0
FROM_LOCAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --from-local) FROM_LOCAL=1 ;;
    --dest)  [ $# -ge 2 ] || { echo "--dest needs a directory" >&2; exit 2; }; DEST="$2"; shift ;;
    --ref)   [ $# -ge 2 ] || { echo "--ref needs a git ref" >&2; exit 2; }; REF="$2"; shift ;;
    -h|--help) awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/,""); print } else if ($0=="") next; else exit }' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# default destination
if [ -z "$DEST" ]; then
  if [ -d "$HOME/.claude" ]; then DEST="$HOME/.claude/skills"; else DEST="$HOME/.agents/skills"; fi
fi

# --- resolve canonical source ------------------------------------------------
# Canon is $REPO@$REF over the network. The copy sitting next to this script is
# NEVER used implicitly: project repos are created from this template and carry a
# frozen .agents/skills snapshot that never updates, so treating "the checkout I
# live in" as canon silently downgrades the installed set. Opt in with --from-local
# (correct for a fresh project-template clone, e.g. the seed one-liner).
SRC=""
CLEANUP=""
resolve_src() {
  if [ -n "${CANONICAL_SKILLS_DIR:-}" ] && [ -f "$CANONICAL_SKILLS_DIR/VERSION" ]; then
    SRC="$CANONICAL_SKILLS_DIR"; echo "[info] source: \$CANONICAL_SKILLS_DIR ($SRC)"; return
  fi
  # this script lives at <skills>/dap-doctor/scripts/install-skills.sh
  local local_root
  local_root="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ "$FROM_LOCAL" -eq 1 ]; then
    [ -f "$local_root/VERSION" ] || { echo "[err] --from-local: no VERSION manifest at $local_root" >&2; exit 1; }
    local origin
    origin="$(git -C "$local_root" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
      *project-template*) ;;
      *)
        echo "[warn] $local_root is not a project-template checkout (origin: ${origin:-none})." >&2
        echo "[warn] If this is a project repo, its .agents/skills is a frozen snapshot from" >&2
        echo "[warn] provisioning time — installing from it can DOWNGRADE your skills." >&2
        ;;
    esac
    SRC="$local_root"; echo "[info] source: local checkout via --from-local ($SRC)"; return
  fi
  # canon: gh tarball
  command -v gh >/dev/null 2>&1 || {
    echo "[err] canon is $REPO@$REF and fetching it needs gh (authenticated)." >&2
    echo "[err] Install/auth gh, or pass --from-local to install from the checkout this" >&2
    echo "[err] script lives in — only correct for a fresh project-template clone." >&2
    exit 1; }
  local tmp; tmp="$(mktemp -d)"; CLEANUP="$tmp"
  echo "[info] source: fetching $REPO@$REF via gh ..."
  gh api "repos/$REPO/tarball/$REF" > "$tmp/t.tgz" 2>/dev/null || { echo "[err] tarball fetch failed" >&2; exit 1; }
  tar -xzf "$tmp/t.tgz" -C "$tmp" || { echo "[err] tarball extract failed" >&2; exit 1; }
  SRC="$(find "$tmp" -type d -path '*/.agents/skills' | head -1)"
  [ -n "$SRC" ] || { echo "[err] .agents/skills not found in tarball" >&2; exit 1; }
  echo "[info] source: $SRC"
}

# read "name=ver" manifest -> ver
ver_of() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2; }

resolve_src

echo "=== version check (dest: $DEST) ==="
need_update=0
for s in "${SKILLS[@]}"; do
  canon="$(ver_of "$s" "$SRC/VERSION")"
  localv=""
  [ -f "$DEST/VERSION" ] && localv="$(ver_of "$s" "$DEST/VERSION")"
  [ -z "$localv" ] && [ -f "$DEST/$s/SKILL.md" ] && \
    localv="$(grep -m1 -E '^version:' "$DEST/$s/SKILL.md" | awk '{print $2}')"
  if [ -z "$localv" ]; then
    printf '  %-22s not installed -> %s\n' "$s" "${canon:-?}"; need_update=1
  elif [ "$localv" = "$canon" ]; then
    printf '  %-22s %s (up to date)\n' "$s" "$localv"
  else
    printf '  %-22s %s -> %s (upgrade available)\n' "$s" "$localv" "$canon"; need_update=1
  fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -n "$CLEANUP" ] && rm -rf "$CLEANUP"
  [ "$need_update" -eq 0 ] && echo "all up to date" || echo "run without --check to install/upgrade"
  exit 0
fi

echo "=== installing into $DEST ==="
mkdir -p "$DEST"
# remove legacy skills so old + new don't both load
for s in "${LEGACY_SKILLS[@]}"; do
  if [ -e "$DEST/$s" ]; then rm -rf "$DEST/$s"; echo "  removed legacy $s"; fi
done
# copy the skill set + shared lib + version manifest
for s in "${SKILLS[@]}"; do
  rm -rf "$DEST/$s"
  cp -R "$SRC/$s" "$DEST/$s"
  echo "  installed $s"
done
mkdir -p "$DEST/_shared"
cp "$SRC/_shared/platform-reader.sh" "$DEST/_shared/platform-reader.sh"
cp "$SRC/VERSION" "$DEST/VERSION"
chmod +x "$DEST"/_shared/platform-reader.sh "$DEST"/*/scripts/*.sh 2>/dev/null || true
echo "=== done — restart the agent or reload skills to pick up changes ==="

[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"
exit 0
