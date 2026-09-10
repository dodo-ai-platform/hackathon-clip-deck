#!/usr/bin/env bash
# check-env.sh — Tier 1 diagnostic: local toolchain + access liveness for the
# Dodo AI platform. READ-ONLY: detects and reports, never installs or mutates.
# The skill (SKILL.md) offers consent-gated `brew` fixes from the reported gaps.
#
# Checks presence + minimum version of: docker, git, gh, kubectl, kubelogin,
# and at least one AI agent CLI (claude / copilot). Then verifies that access
# actually WORKS (not just that binaries exist): gh auth, kube API reachability,
# docker daemon + GHCR login.
#
# Output: one "[ ok ]/[WARN]/[MISS]" line per check on stdout, then a summary.
# Lines with a "fix:" suffix carry the suggested remediation command.
# Exit: 0 = all green, 1 = at least one MISS/WARN.

set -u

# minimum versions (major.minor is enough for our purposes)
MIN_docker=20.10
MIN_git=2.30
MIN_gh=2.20
MIN_kubectl=1.27
MIN_kubelogin=1.28

problems=0
report() { printf '%s\n' "$1"; }
ok()   { report "[ ok ] $1"; }
warn() { report "[WARN] $1"; problems=$((problems+1)); }
miss() { report "[MISS] $1"; problems=$((problems+1)); }

# verlte A B -> true if A <= B (compares dotted numbers, portable)
verlte() {
  [ "$1" = "$2" ] && return 0
  local lo
  lo="$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
  [ "$lo" = "$1" ]
}

# extract first dotted-number token from a version string
vernum() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

check_version() {
  # name binary raw_version_cmd min  fix
  local name="$1" bin="$2" got min="$4" fix="$5"
  if ! command -v "$bin" >/dev/null 2>&1; then
    miss "$name — not installed — fix: $fix"
    return
  fi
  got="$(vernum "$($3 2>&1 | head -3)")"
  if [ -z "$got" ]; then
    ok "$name — installed (version unknown)"
  elif verlte "$min" "$got"; then
    ok "$name $got (>= $min)"
  else
    warn "$name $got is below minimum $min — fix: $fix"
  fi
}

report "=== Tier 1: toolchain ==="
check_version docker    docker    "docker --version"               "$MIN_docker"    "install Docker Desktop / colima"
check_version git       git       "git --version"                  "$MIN_git"       "brew install git"
check_version gh        gh        "gh --version"                   "$MIN_gh"        "brew install gh"
check_version kubectl   kubectl   "kubectl version --client" "$MIN_kubectl" "brew install kubectl"
check_version kubelogin kubelogin "kubelogin --version"            "$MIN_kubelogin" "brew install int128/kubelogin/kubelogin"

# AI agent CLI — at least one
if command -v claude >/dev/null 2>&1; then ok "AI agent: claude CLI present"
elif command -v copilot >/dev/null 2>&1; then ok "AI agent: GitHub Copilot CLI present"
else warn "no AI agent CLI (claude / copilot) found on PATH"; fi

report ""
report "=== Tier 1: access liveness (does it actually work?) ==="

# gh auth
if ! command -v gh >/dev/null 2>&1; then
  miss "gh auth — gh not installed"
elif gh auth status >/dev/null 2>&1; then
  ok "gh auth — logged in ($(gh api user --jq .login 2>/dev/null || echo '?'))"
else
  miss "gh auth — not logged in — fix: gh auth login"
fi

# kube API reachability (first run may open a browser for Google OIDC login)
if ! command -v kubectl >/dev/null 2>&1; then
  miss "kube API — kubectl not installed"
elif ! kubectl config current-context >/dev/null 2>&1; then
  warn "kube API — no kube-context yet — normal before your project is allocated; the kubeconfig arrives via PLATFORM.md after provisioning — fix (once allocated): add the platform kubeconfig (see PLATFORM.md)"
elif kubectl auth can-i get pods --request-timeout=10s >/dev/null 2>&1; then
  ok "kube API — reachable, can get pods in $(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')"
else
  warn "kube API — context set but request failed (OIDC login may be required) — fix: run any 'kubectl get pods' once to complete Google login"
fi

# docker daemon + GHCR auth
if ! command -v docker >/dev/null 2>&1; then
  miss "docker — not installed"
elif ! docker info >/dev/null 2>&1; then
  warn "docker daemon — not running — fix: start Docker Desktop / colima start"
else
  if grep -q 'ghcr.io' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null; then
    ok "docker daemon running, GHCR credentials present"
  else
    warn "docker daemon running, but no GHCR login — fix: gh auth token | docker login ghcr.io -u \$(gh api user --jq .login) --password-stdin"
  fi
fi

report ""
if [ "$problems" -eq 0 ]; then
  report "=== SUMMARY: all green — local environment ready ==="
  exit 0
else
  report "=== SUMMARY: $problems issue(s) above need attention ==="
  exit 1
fi
