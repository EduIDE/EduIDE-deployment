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
    env=$(basename "$(dirname "$f")")
    v="$ROOT/environments/$env/values.yaml"
    [[ -f "$v" ]] || continue
    prefixes+="$(yq -r '[.["theia-cloud"].gateway.parentRefs[]?.sectionName | sub("-(landing|service|instances|webview)$"; "")] | unique | .[]' "$v" | tr '\n' ' ')" 
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
  if [[ ! -f "$ROOT/environments/$env/values.yaml" ]]; then
    bad "$env has no values.yaml" ""; continue
  fi
  if ! yq -e '.' "$ROOT/environments/$env/values.yaml" >/dev/null 2>&1; then
    bad "$env values.yaml is not valid YAML" ""; continue
  fi
  ok "$env -> cluster $c"
done

# --- storage class follows the cluster ------------------------------------
# Two subcharts claim storage independently, and theia-shared-cache's vendored
# reposilite chart hardcodes csi-rbd-sc. If a third one appears, a PVC on the
# eduide cluster will ask for a class that does not exist there and simply
# never bind - no error, just a Pending pod. This asserts the deploy sets every
# storage key the rendered output contains.
echo
echo "=== storage class follows the cluster ==="
CHARTS="$ROOT/charts/theia-cloud-combined"
if [[ -d "$CHARTS" ]] && helm dependency list "$CHARTS" >/dev/null 2>&1; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  cp -R "$ROOT/charts" "$W/charts"
  if helm dependency update "$W/charts/theia-cloud-combined" >/dev/null 2>&1; then
    # The same two keys the Cluster defaults step in deploy.yml writes.
    printf 'theia-cloud:\n  operator:\n    storageClassName: SENTINEL\ntheia-shared-cache:\n  reposilite:\n    persistence:\n      storageClass: SENTINEL\n' > "$W/cd.yaml"
    for f in "$ROOT"/environments/*/env.yaml; do
      env=$(basename "$(dirname "$f")")
      ns=$(yq -r '.spec.namespace' "$f")
      out=$(helm template eduide "$W/charts/theia-cloud-combined" -n "$ns" \
              -f "$W/cd.yaml" -f "$ROOT/environments/_base.yaml" \
              -f "$ROOT/environments/$env/values.yaml" 2>/dev/null) || {
        bad "$env does not render" ""; continue; }
      stray=$(grep -i 'storageclass' <<<"$out" | grep -v '\-\-storageClassName' | grep -vc 'SENTINEL' || true)
      if [[ "$stray" -gt 0 ]]; then
        bad "$env has $stray storage key(s) the cluster default does not reach" \
            "$(grep -i 'storageclass' <<<"$out" | grep -v '\-\-storageClassName' | grep -v 'SENTINEL' | head -2 | tr -s ' ' | tr '\n' ';')"
      else
        ok "$env all storage keys follow the cluster"
      fi
    done
  else
    echo "  SKIP  helm dependency update failed (no GHCR login?)"
  fi
else
  echo "  SKIP  charts not available"
fi

# --- the dependency cache stays off in production --------------------------
# Both keys matter. The umbrella declares theia-shared-cache without a
# condition, so `enabled: false` only silences that chart's own templates; its
# vendored reposilite subchart is gated separately by reposilite.enabled and
# would otherwise still bring a Deployment and a 20Gi PVC.
echo
echo "=== dependency cache off in production ==="
for f in "$ROOT"/environments/*/env.yaml; do
  env=$(basename "$(dirname "$f")")
  [[ "$(yq -r '.metadata.tier' "$f")" == "production" ]] || continue
  v="$ROOT/environments/$env/values.yaml"
  a=$(yq -r '.["theia-shared-cache"].enabled' "$v")
  b=$(yq -r '.["theia-shared-cache"].reposilite.enabled' "$v")
  if [[ "$a" == "false" && "$b" == "false" ]]; then
    ok "$env cache and reposilite both off"
  else
    bad "$env must set theia-shared-cache.enabled and .reposilite.enabled to false" \
        "enabled=$a reposilite.enabled=$b"
  fi
done

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAILED
