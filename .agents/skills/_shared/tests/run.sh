#!/usr/bin/env bash
# Test suite for platform-reader.sh — portable (bash 3.2+, no external deps).
# Usage: .agents/skills/_shared/tests/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
READER="$HERE/../platform-reader.sh"
FIX="$HERE/fixtures"

pass=0
fail=0

# run_reader FILE -> sets globals: rc + all emitted vars (registry, namespace, ...)
run_reader() {
  # reset known output vars so a previous run never leaks into the next
  provisioned=''; namespace=''; registry=''; deploy_secret_name=''
  db_secret_name=''; mongodb_secret_name=''; redis_secret_name=''
  bucket_secret_name=''; otlp_endpoint=''
  ingress_url=''; grafana_url=''; resource_quota=''
  local out
  out="$(bash "$READER" "$1" 2>/dev/null)"
  rc=$?
  eval "$out"
}

# assert "label" "expected" "actual"
assert() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

echo "== full-demo: all sections present =="
run_reader "$FIX/full-demo.md"
assert "exit 0 (provisioned)"      "0"                                             "$rc"
assert "provisioned flag"          "true"                                          "$provisioned"
assert "namespace"                 "demo"                                          "$namespace"
assert "registry"                  "ghcr.io/dodo-ai-platform/demo"                 "$registry"
assert "deploy_secret_name"        "KUBE_CONFIG_B64"                               "$deploy_secret_name"
assert "db_secret_name"            "demo-db-credentials"                           "$db_secret_name"
assert "redis_secret_name"         "demo-redis-credentials"                        "$redis_secret_name"
assert "bucket_secret_name"        "demo-bucket-credentials"                       "$bucket_secret_name"
assert "otlp_endpoint"             "alloy.infra-alloy.svc.cluster.local:4318"      "$otlp_endpoint"
assert "ingress_url"               "https://demo.p.dodoteam.ru"                    "$ingress_url"
assert "grafana_url"               "https://grafana.p.dodoteam.ru/d/demo"          "$grafana_url"
assert "resource_quota"            "CPU 2, Memory 4Gi"                             "$resource_quota"

echo "== placeholder: not provisioned =="
run_reader "$FIX/placeholder.md"
assert "exit 3 (not provisioned)"  "3"          "$rc"
assert "provisioned flag"          "false"      "$provisioned"

echo "== missing-database: degrades, does not crash =="
run_reader "$FIX/missing-database.md"
assert "exit 0"                    "0"                                 "$rc"
assert "namespace"                 "nodb"                              "$namespace"
assert "db_secret_name empty"      ""                                  "$db_secret_name"
assert "redis_secret_name empty"   ""                                  "$redis_secret_name"
assert "bucket_secret_name"        "nodb-bucket-credentials"           "$bucket_secret_name"
assert "registry present"          "ghcr.io/dodo-ai-platform/nodb"     "$registry"
assert "ingress_url empty"         ""                                  "$ingress_url"
assert "grafana_url empty"         ""                                  "$grafana_url"

echo "== drifted: reordered + reworded + unknown section =="
run_reader "$FIX/drifted.md"
assert "exit 0"                    "0"                                       "$rc"
assert "namespace"                 "widget"                                  "$namespace"
assert "registry"                  "ghcr.io/dodo-ai-platform/widget"         "$registry"
assert "db_secret_name"            "widget-db-credentials"                   "$db_secret_name"
assert "grafana_url"               "https://grafana.p.dodoteam.ru/d/widget"  "$grafana_url"
assert "bucket_secret_name empty"  ""                                        "$bucket_secret_name"

echo "== missing file: not provisioned =="
run_reader "$FIX/does-not-exist.md"
assert "exit 3"                    "3"        "$rc"
assert "provisioned flag"          "false"    "$provisioned"

echo "== directory search: finds PLATFORM.md by walking from a path =="
tmp="$(mktemp -d)"
cp "$FIX/full-demo.md" "$tmp/PLATFORM.md"
mkdir -p "$tmp/sub/deep"
run_reader "$tmp/sub/deep"   # pass a subdir; reader must walk up to find PLATFORM.md
assert "exit 0 from subdir"        "0"        "$rc"
assert "namespace from subdir"     "demo"     "$namespace"
rm -rf "$tmp"

echo "== regression: relative path arg must terminate (no infinite dirname loop) =="
tmpr="$(mktemp -d)"   # no PLATFORM.md anywhere up the tree
( cd "$tmpr" && bash "$READER" . >/dev/null 2>&1 ) &
rpid=$!
( sleep 8; kill -9 "$rpid" 2>/dev/null ) &
wpid=$!
wait "$rpid" 2>/dev/null; rrc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
assert "relative '.' terminates, exit 3" "3" "$rrc"
rm -rf "$tmpr"

echo "== regression: 'name:' anchor must not match 'username:' (substring collision) =="
tmpu="$(mktemp -d)"
cat > "$tmpu/PLATFORM.md" <<'EOF'
# x Platform

## Namespace

- Service username: `svc-account`
- Name: `realns`
- ResourceQuota: CPU 1, Memory 2Gi
EOF
run_reader "$tmpu/PLATFORM.md"
assert "namespace ignores 'username:'" "realns" "$namespace"
rm -rf "$tmpu"

echo "== VERSION manifest matches each SKILL.md frontmatter =="
# install-skills.sh decides "up to date" from the VERSION manifest alone, so a
# manifest lagging behind a bumped SKILL.md silently suppresses the upgrade.
SKILLS_ROOT="$(cd "$HERE/../.." && pwd)"
for skill_dir in "$SKILLS_ROOT"/*/SKILL.md; do
  [ -f "$skill_dir" ] || continue
  skill_name="$(basename "$(dirname "$skill_dir")")"
  frontmatter_ver="$(grep -m1 -E '^version:' "$skill_dir" | awk '{print $2}')"
  manifest_ver="$(grep -E "^$skill_name=" "$SKILLS_ROOT/VERSION" | head -1 | cut -d= -f2)"
  assert "$skill_name: VERSION manifest == SKILL.md" "$frontmatter_ver" "$manifest_ver"
done

echo ""
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
