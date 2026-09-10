#!/usr/bin/env bash
# check-deploy.sh — Tier 2 diagnostic: feedback-loop for a PROVISIONED project.
# READ-ONLY. Reads the PLATFORM.md contract via platform-reader.sh, then checks
# that the deployed service and its subsystems are VISIBLE from this machine:
# namespace access, workloads, DB/bucket secrets, ingress, Grafana, OTLP target,
# the CLAUDE.md -> PLATFORM.md link, and config drift between repo k8s/*.yaml and
# the live cluster objects.
#
# Run from the project repo root. Tier 2 only applies when PLATFORM.md exists and
# is non-placeholder; otherwise it exits 0 with "not provisioned, tier2 skipped".
#
# Exit: 0 = everything visible (or not provisioned), 1 = visibility gaps found.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
READER="$SELF/../../_shared/platform-reader.sh"
REPO="${1:-$PWD}"
KTMO=(--request-timeout=10s)   # array: expands cleanly as kubectl args

problems=0
ok()   { printf '[ ok ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; problems=$((problems+1)); }
info() { printf '[info] %s\n' "$1"; }

# --- read the contract -------------------------------------------------------
provisioned=''; namespace=''; registry=''; deploy_secret_name=''
db_secret_name=''; bucket_secret_name=''; otlp_endpoint=''
ingress_url=''; grafana_url=''; resource_quota=''
eval "$(bash "$READER" "$REPO" 2>/dev/null)"

if [ "$provisioned" != "true" ]; then
  echo "[info] PLATFORM.md is a placeholder or absent — project not provisioned yet."
  echo "[info] Tier 2 skipped. Run 'dap-shipmaster' — Phase A to allocate, then Phase B to ship."
  exit 0
fi

echo "=== Tier 2: deployed feedback-loop for namespace '$namespace' ==="

if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not installed — cannot inspect the cluster"
  echo "=== SUMMARY: $problems issue(s) ==="; exit 1
fi

# --- namespace access --------------------------------------------------------
if kubectl auth can-i get pods -n "$namespace" "${KTMO[@]}" >/dev/null 2>&1; then
  ok "namespace access — can get pods in '$namespace'"
else
  warn "namespace access — cannot get pods in '$namespace' (OIDC login or RoleBinding missing)"
  echo "=== SUMMARY: $problems issue(s) ==="; exit 1
fi

# --- workloads visibility ----------------------------------------------------
pods="$(kubectl get pods -n "$namespace" "${KTMO[@]}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${pods:-0}" -gt 0 ]; then
  ok "workloads — $pods pod(s) present; readiness:"
  kubectl get pods -n "$namespace" "${KTMO[@]}" -o wide 2>/dev/null | sed 's/^/        /'
else
  info "workloads — no pods yet (nothing shipped, or rollout pending). Run 'dap-shipmaster' (Phase B)."
fi

# --- resource secrets --------------------------------------------------------
if [ -n "$db_secret_name" ]; then
  if kubectl get secret "$db_secret_name" -n "$namespace" "${KTMO[@]}" >/dev/null 2>&1; then
    ok "database secret '$db_secret_name' present"
  else
    warn "database secret '$db_secret_name' missing — operator may not have reconciled DB yet"
  fi
fi
if [ -n "$bucket_secret_name" ]; then
  if kubectl get secret "$bucket_secret_name" -n "$namespace" "${KTMO[@]}" >/dev/null 2>&1; then
    ok "bucket secret '$bucket_secret_name' present"
  else
    warn "bucket secret '$bucket_secret_name' missing — operator may not have reconciled bucket yet"
  fi
fi

# --- ingress -----------------------------------------------------------------
if [ -n "$ingress_url" ]; then
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$ingress_url" 2>/dev/null || echo 000)"
  case "$code" in
    2*|3*|401|403) ok "ingress $ingress_url responds (HTTP $code)" ;;
    000)           warn "ingress $ingress_url — no response (DNS/TLS/not-routed yet)" ;;
    *)             warn "ingress $ingress_url — HTTP $code" ;;
  esac
else
  info "ingress — none in PLATFORM.md (ingress is operator-granted, not self-serve)"
fi

# --- grafana dashboard -------------------------------------------------------
if [ -n "$grafana_url" ]; then
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$grafana_url" 2>/dev/null || echo 000)"
  case "$code" in
    2*|3*|401|403) ok "Grafana dashboard $grafana_url reachable (HTTP $code)" ;;
    *)             warn "Grafana dashboard $grafana_url — HTTP $code (VPN/login may be required)" ;;
  esac
fi

# --- OTLP target (cluster-internal: informational) ---------------------------
if [ -n "$otlp_endpoint" ]; then
  info "OTLP target: $otlp_endpoint (cluster-internal DNS; resolvable only from a pod)"
fi

# --- CLAUDE.md -> PLATFORM.md link -------------------------------------------
linkfile=""
for f in "$REPO/CLAUDE.md" "$REPO/AGENTS.md"; do
  [ -f "$f" ] && { linkfile="$f"; break; }
done
if [ -n "$linkfile" ]; then
  if grep -q 'PLATFORM.md' "$linkfile" 2>/dev/null; then
    ok "agent guide ($(basename "$linkfile")) references PLATFORM.md"
  else
    warn "agent guide ($(basename "$linkfile")) is missing a PLATFORM.md reference — the skill can add it"
  fi
else
  warn "no CLAUDE.md / AGENTS.md found — the skill can create one referencing PLATFORM.md"
fi

# --- drift: repo k8s/*.yaml vs live cluster ----------------------------------
dep_file="$REPO/k8s/deployment.yaml"
if [ -f "$dep_file" ]; then
  dep_name="$(grep -m1 -E '^[[:space:]]*name:' "$dep_file" | awk '{print $2}')"
  if [ -n "$dep_name" ] && kubectl get deploy "$dep_name" -n "$namespace" "${KTMO[@]}" >/dev/null 2>&1; then
    # compare image WITHOUT tag/digest (CI rewrites the tag): strip @sha256:... and :tag,
    # but not a registry host:port or a path segment ([^:/] before $)
    strip_tag='s/@sha256:.*$//; s/:[^:/]*$//'
    file_img="$(grep -m1 -E 'image:' "$dep_file" | sed -e 's/.*image:[[:space:]]*//' -e "$strip_tag")"
    live_img="$(kubectl get deploy "$dep_name" -n "$namespace" "${KTMO[@]}" \
                 -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed -e "$strip_tag")"
    if [ -n "$file_img" ] && [ "$file_img" = "$live_img" ]; then
      ok "drift — repo image matches live deployment ($file_img)"
    else
      warn "drift — repo image '$file_img' != live '$live_img'. Manifests are owned by 'dap-shipmaster'; re-run it instead of editing by hand."
    fi
  else
    info "drift — deployment '$dep_name' not on cluster yet (nothing shipped)"
  fi
fi

echo ""
if [ "$problems" -eq 0 ]; then
  echo "=== SUMMARY: all subsystems visible — feedback-loop healthy ==="; exit 0
else
  echo "=== SUMMARY: $problems visibility gap(s) above ==="; exit 1
fi
