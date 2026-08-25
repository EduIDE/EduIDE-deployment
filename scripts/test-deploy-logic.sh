#!/usr/bin/env bash
# Tests for the parts of the deploy workflows that are pure logic.
#
# The workflows themselves cannot run without a cluster, but the decisions they
# make - which image tags to override, which Gateway listeners a cluster needs,
# whether a tag is safe to pass to helm - are testable here.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAILED=1; }

# --- image overrides -------------------------------------------------------
# A pull request only builds the images of the repo it came from, so an
# override must be scoped to that component. A blanket tag would point every
# image at a tag that mostly does not exist.
overrides() {
  jq -cn --arg cp "${1:-}" --arg ide "${2:-}" --arg lp "${3:-}" \
    '{} + (if $cp  != "" then {controlPlane: $cp} else {} end)
        + (if $ide != "" then {ide: $ide}         else {} end)
        + (if $lp  != "" then {landingPage: $lp}  else {} end)'
}
echo "=== image override resolution ==="
[[ "$(overrides pr-451 '' '')" == '{"controlPlane":"pr-451"}' ]] \
  && ok "EduIDE-Cloud PR sets only controlPlane" \
  || bad "EduIDE-Cloud PR" "$(overrides pr-451 '' '')"
[[ "$(overrides '' pr-77 '')" == '{"ide":"pr-77"}' ]] \
  && ok "EduIDE PR sets only ide" || bad "EduIDE PR" "$(overrides '' pr-77 '')"
[[ "$(overrides '' '' '')" == '{}' ]] \
  && ok "no inputs means no overrides" || bad "empty" "$(overrides '' '' '')"

# --- tag validation --------------------------------------------------------
# Tags reach a helm --set, so they are constrained to Docker tag grammar.
valid_tag() { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$ ]]; }
echo
echo "=== tag validation (these reach helm --set) ==="
for t in pr-451 latest 1.1.0 latest-abc1234 2.3.0-rc.1; do
  valid_tag "$t" && ok "accepts $t" || bad "should accept $t" ""
done
for t in '.1.1.1' '-nope' 'a;rm -rf /' 'a b' '$(whoami)' ''; do
  valid_tag "$t" && bad "should reject '$t'" "" || ok "rejects '${t:-<empty>}'"
done

# --- gateway listener derivation ------------------------------------------
echo
echo "=== gateway listeners derived per cluster ==="
for cf in "$ROOT"/clusters/*.yaml; do
  cluster=$(yq -r '.metadata.name' "$cf")
  n=0; prefixes=""
  for f in "$ROOT"/environments/*/env.yaml; do
    [[ "$(yq -r '.spec.cluster' "$f")" == "$cluster" ]] || continue
    [[ "$(yq -r '.spec.gateway.mode' "$f")" == "shared" ]] || continue
    prefixes+="$(yq -r '.spec.gateway.listenerPrefix // .spec.hosts.landing' "$f") "
    n=$((n + 1))
  done
  dupes=$(tr ' ' '\n' <<<"$prefixes" | grep -v '^$' | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    bad "$cluster listener prefixes collide" "$dupes"
  else
    printf '  PASS  %-10s %s environment(s), %s listeners, prefixes: %s\n' \
      "$cluster" "$n" "$((n * 4))" "${prefixes:-none}"
  fi
done

# --- environments are internally consistent -------------------------------
echo
echo "=== every environment resolves ==="
for f in "$ROOT"/environments/*/env.yaml; do
  env=$(basename "$(dirname "$f")")
  c=$(yq -r '.spec.cluster' "$f")
  if [[ ! -f "$ROOT/clusters/$c.yaml" ]]; then
    bad "$env references unknown cluster" "$c"; continue
  fi
  if ! "$ROOT/scripts/render-values.sh" "$env" >/dev/null 2>&1; then
    bad "$env does not compile" ""; continue
  fi
  ok "$env -> cluster $c"
done

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAILED
