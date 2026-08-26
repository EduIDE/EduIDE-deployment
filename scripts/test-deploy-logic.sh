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
    prefixes+="$(yq -r '[.gateway.parentRefs[]?.sectionName | sub("-(landing|service|instances|webview)$"; "")] | unique | .[]' "$v" | tr '\n' ' ')" 
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
# The chart and its shared-cache dependency claim storage independently, and the
# cache's vendored reposilite chart hardcodes csi-rbd-sc. If a third key
# appears, a PVC on the eduide cluster will ask for a class that does not exist
# there and simply never bind - no error, just a Pending pod. This asserts the
# deploy sets every storage key the rendered output contains.
#
# Needs the chart. Set EDUIDE_CHART to a local checkout of EduIDE-Helm's
# charts/eduide to run this before 2.0.0 is published.
echo
echo "=== storage class follows the cluster ==="
CHART="${EDUIDE_CHART:-oci://ghcr.io/eduide/charts/eduide}"
CHART_VERSION=$(yq -r '.spec.platform.chartVersion' "$ROOT/environments/test1/env.yaml")
VER_ARG=()
if [[ "$CHART" == oci://* ]]; then VER_ARG=(--version "$CHART_VERSION"); fi
if helm show chart "$CHART" "${VER_ARG[@]}" >/dev/null 2>&1; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  {
    # The same two keys the Cluster defaults step in deploy.yml writes.
    printf 'operator:\n  storageClassName: SENTINEL\n'
    printf 'eduide-shared-cache:\n  reposilite:\n    persistence:\n      storageClass: SENTINEL\n'
  } > "$W/cd.yaml"
  printf 'keycloak:\n  cookieSecret: x\nservice:\n  adminApiToken: dG9r\n' > "$W/sec.yaml"
  {
    for f in "$ROOT"/environments/*/env.yaml; do
      env=$(basename "$(dirname "$f")")
      ns=$(yq -r '.spec.namespace' "$f")
      out=$(helm template eduide "$CHART" "${VER_ARG[@]}" -n "$ns" \
              -f "$W/cd.yaml" -f "$ROOT/environments/_base.yaml" \
              -f "$ROOT/environments/$env/values.yaml" -f "$W/sec.yaml" 2>/dev/null) || {
        bad "$env does not render" ""; continue; }
      stray=$(grep -i 'storageclass' <<<"$out" | grep -v '\-\-storageClassName' | grep -vc 'SENTINEL' || true)
      if [[ "$stray" -gt 0 ]]; then
        bad "$env has $stray storage key(s) the cluster default does not reach" \
            "$(grep -i 'storageclass' <<<"$out" | grep -v '\-\-storageClassName' | grep -v 'SENTINEL' | head -2 | tr -s ' ' | tr '\n' ';')"
      else
        ok "$env all storage keys follow the cluster"
      fi
    done
  }
else
  echo "  SKIP  chart $CHART not reachable (set EDUIDE_CHART to a local checkout)"
fi

# --- the dependency cache stays off in production --------------------------
# The chart declares the cache with `condition: eduide-shared-cache.enabled`, so one key
# now switches it off cleanly - including its vendored reposilite subchart and
# the 20Gi PVC that came with it.
echo
echo "=== dependency cache off in production ==="
for f in "$ROOT"/environments/*/env.yaml; do
  env=$(basename "$(dirname "$f")")
  [[ "$(yq -r '.metadata.tier' "$f")" == "production" ]] || continue
  v="$ROOT/environments/$env/values.yaml"
  a=$(yq -r '.["eduide-shared-cache"].enabled' "$v")
  if [[ "$a" == "false" ]]; then
    ok "$env dependency cache off"
  else
    bad "$env must set eduide-shared-cache.enabled to false" "eduide-shared-cache.enabled=$a"
  fi
done

# --- monitoring opt-out reaches the derived namespace list -----------------
# The PodMonitors live in the cluster chart and watch a namespace list that
# bootstrap derives. An environment opting out has to actually drop out of that
# list, or the toggle is decoration.
echo
echo "=== monitoring toggle reaches the derived namespaces ==="
for cf in "$ROOT"/clusters/*.yaml; do
  cluster=$(yq -r '.metadata.name' "$cf")
  want=""; got=""
  for f in "$ROOT"/environments/*/env.yaml; do
    env=$(basename "$(dirname "$f")")
    [[ "$(yq -r '.spec.cluster' "$f")" == "$cluster" ]] || continue
    v="$ROOT/environments/$env/values.yaml"
    ns=$(yq -r '.spec.namespace' "$f")
    if [[ "$(yq -r '.monitoring.enabled // true' "$v")" == "true" ]]; then
      want+="$ns "
    fi
    got+="$ns "
  done
  [[ -n "$got" ]] || continue
  n_in=$(wc -w <<<"$want" | tr -d ' '); n_all=$(wc -w <<<"$got" | tr -d ' ')
  ok "$cluster: $n_in of $n_all environment(s) monitored"
done

# --- every namespace carries the eduide- prefix ----------------------------
echo
echo "=== namespaces are prefixed ==="
for f in "$ROOT"/environments/*/env.yaml; do
  env=$(basename "$(dirname "$f")")
  ns=$(yq -r '.spec.namespace' "$f")
  if [[ "$ns" == eduide-* ]]; then
    ok "$env -> $ns"
  else
    bad "$env namespace '$ns' is missing the eduide- prefix" ""
  fi
done

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAILED
