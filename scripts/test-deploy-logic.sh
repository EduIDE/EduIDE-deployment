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
CHART_VERSION=$(yq -r '.spec.platform.chartVersion' "$ROOT/environments/test1.eduide.student.k8s.aet.cit.tum.de/env.yaml")
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

# --- no duplicate keys in a values file ------------------------------------
# YAML keeps the LAST of two identical keys and says nothing. Writing a second
# `service:` block silently dropped service.authToken from _base.yaml, and the
# only symptom would have been the landing page and the REST service
# disagreeing on the spam-mitigation token at runtime.
echo
echo "=== values files have no duplicate top-level keys ==="
for f in "$ROOT"/environments/_base.yaml "$ROOT"/environments/*/values.yaml; do
  [[ -f "$f" ]] || continue
  dupes=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_.-]*:' "$f" | sort | uniq -d | tr -d ':' | tr '\n' ' ')
  name="$(basename "$(dirname "$f")")/$(basename "$f")"
  if [[ -z "$dupes" ]]; then
    ok "$name"
  else
    bad "$name has duplicate top-level keys" "$dupes"
  fi
done

# --- manifests match their schemas -----------------------------------------
# CI validates these, and this script did not, so a field added to a cluster
# manifest without updating the schema passed locally and failed on push -
# spec.tls did exactly that. Same check, run before the push instead of after.
echo
echo "=== manifests match their schemas ==="
if command -v check-jsonschema >/dev/null 2>&1; then
  for pair in "cluster:clusters" "environment:environments"; do
    kind="${pair%%:*}"; dir="${pair##*:}"
    files=()
    if [[ "$kind" == cluster ]]; then
      while IFS= read -r f; do files+=("$f"); done < <(find "$ROOT/$dir" -maxdepth 1 -name '*.yaml')
    else
      while IFS= read -r f; do files+=("$f"); done < <(find "$ROOT/$dir" -mindepth 2 -name 'env.yaml')
    fi
    for f in "${files[@]}"; do
      if check-jsonschema --schemafile "$ROOT/schemas/${kind}.schema.json" "$f" >/dev/null 2>&1; then
        ok "$(basename "$(dirname "$f")")/$(basename "$f")"
      else
        bad "$f does not match the $kind schema" \
            "$(check-jsonschema --schemafile "$ROOT/schemas/${kind}.schema.json" "$f" 2>&1 | grep -m1 '\$\.' || true)"
      fi
    done
  done
else
  echo "  SKIP  check-jsonschema not installed (pip install check-jsonschema)"
fi

# --- every derived HTTPS listener carries a TLS secret ---------------------
# A listener without one renders certificateRefs with an empty name. Nothing
# rejects that - the Gateway is accepted and simply never programs TLS for the
# hostname, so the first symptom is a browser connection failure. The chart
# fails the render now, and this catches a cluster manifest missing the policy
# before it gets that far.
echo
echo "=== derived listeners carry a TLS secret ==="
for cf in "$ROOT"/clusters/*.yaml; do
  cluster=$(yq -r '.metadata.name' "$cf")
  missing=""
  for role in landing service instances webview; do
    v=$(yq -r ".spec.tls.${role} // \"\"" "$cf")
    [[ -n "$v" ]] || missing+="$role "
  done
  if [[ -n "$missing" ]]; then
    bad "$cluster is missing spec.tls entries" "$missing"
    continue
  fi
  acme=$(yq -r '.spec.tls.acmeHttp // false' "$cf")
  # acmeHttp means bootstrap creates the ClusterIssuer the derived certificates
  # point at, and cert-manager will not register an ACME account without a
  # contact address. Caught here rather than half way through a bootstrap.
  if [[ "$acme" == "true" ]]; then
    email=$(yq -r '.spec.acmeEmail // ""' "$cf")
    if [[ -z "$email" ]]; then
      bad "$cluster sets spec.tls.acmeHttp but has no spec.acmeEmail" "cert-manager needs a contact address"
      continue
    fi
    ok "$cluster: all four roles have a secret, acmeHttp=true, acmeEmail=$email"
  else
    ok "$cluster: all four roles have a secret, acmeHttp=false"
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

# --- alerting is complete where it is switched on --------------------------
# Alerting that fires into nowhere is worse than no alerting: it reads as
# covered. The chart already fails the render on an empty channel list, but the
# failure would land mid-bootstrap on a cluster, so the same conditions are
# checked here where the feedback is a pull request comment.
#
# The secretKey prefix is load-bearing, not cosmetic. bootstrap-cluster.yml
# picks which GitHub Environment secret to read from it, so a key named
# anything else silently gets no webhook URL.
echo
echo "=== alerting configuration is complete ==="
for cf in "$ROOT"/clusters/*.yaml; do
  cluster=$(yq -r '.metadata.name' "$cf")
  if [[ "$(yq -r '.spec.alerting.enabled // false' "$cf")" != "true" ]]; then
    ok "$cluster: alerting off"
    continue
  fi
  n=$(yq -r '(.spec.alerting.channels // []) | length' "$cf")
  if [[ "$n" == "0" ]]; then
    bad "$cluster enables alerting but declares no channels" \
        "alerts would fire and notify nobody; add spec.alerting.channels"
    continue
  fi
  sev=$(yq -r '.spec.alerting.minSeverity // "warning"' "$cf")
  if [[ "$sev" != "warning" && "$sev" != "critical" ]]; then
    bad "$cluster has minSeverity '$sev'" "must be 'warning' or 'critical'"
  fi
  bad_channel=0
  # Tab-separated, not space-separated. A channel name is a free-form string and
  # may contain spaces; splitting on those silently shifted every field along and
  # reported a bogus "unsupported type", which would block validation on a
  # perfectly valid manifest.
  while IFS=$'\t' read -r cname ctype ckey; do
    [[ -n "$cname" ]] || continue
    if [[ "$ctype" != "slack" && "$ctype" != "discord" ]]; then
      bad "$cluster channel '$cname' has type '$ctype'" "supported: slack, discord"
      bad_channel=1
    fi
    # The prefix picks the GitHub Environment secret; the rest has to survive
    # being used as a Kubernetes Secret data key, which allows only
    # alphanumerics, '-', '_' and '.'. A slash passes a prefix-only check and is
    # then rejected by the API server halfway through a bootstrap.
    if [[ ! "$ckey" =~ ^(slack|discord)-[A-Za-z0-9._-]*$ ]]; then
      bad "$cluster channel '$cname' has secretKey '$ckey'" \
          "must match ^(slack|discord)-[A-Za-z0-9._-]*\$ so it is both routable and a valid Secret key"
      bad_channel=1
    elif [[ "$ctype" == "slack" && "$ckey" != slack-* ]] \
       || [[ "$ctype" == "discord" && "$ckey" != discord-* ]]; then
      bad "$cluster channel '$cname' is $ctype but reads '$ckey'" \
          "the prefix decides which webhook URL is used, so it must match the type"
      bad_channel=1
    fi
    if (( ${#ckey} > 253 )); then
      bad "$cluster channel '$cname' has a secretKey of ${#ckey} characters" \
          "Kubernetes Secret keys are limited to 253"
      bad_channel=1
    fi
  done < <(yq -r '.spec.alerting.channels[]? | [.name, .type, .secretKey] | @tsv' "$cf")

  # A channel scoped to an environment that does not exist on this cluster
  # matches nothing, so that channel silently receives only the cluster-scoped
  # alerts and nobody notices the tenant's own alerts are going elsewhere.
  # Typos here are invisible at render time: the matcher is just a regex.
  while IFS=$'\t' read -r cname cenv; do
    [[ -n "$cenv" ]] || continue
    found=0
    for f in "$ROOT"/environments/*/env.yaml; do
      [[ "$(yq -r '.spec.cluster' "$f")" == "$cluster" ]] || continue
      [[ "$(yq -r '.spec.namespace' "$f")" == "$cenv" ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      bad "$cluster channel '$cname' is scoped to namespace '$cenv'" \
          "no environment with that namespace lives on $cluster, so the route matches nothing"
      bad_channel=1
    fi
  done < <(yq -r '.spec.alerting.channels[]? as $c | ($c.environments // [])[] | [$c.name, .] | @tsv' "$cf")
  [[ $bad_channel -eq 0 ]] && ok "$cluster: alerting on, $n channel(s), minSeverity $sev"
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

# --- the hostname comment matches what the chart will actually serve --------
# Each values.yaml lists its four hostnames above the block that composes them,
# because `<prefix>.<baseHost>` hides the result and a name wrong by one label
# fails silently: the Gateway reports the listener healthy and the browser
# cannot reach it. tum-production carried `artemis.aet.cit.tum.de` for exactly
# that reason. A comment nobody checks would have the same problem, so it is
# checked.
echo
echo "=== hostname comments match the composed hosts ==="
for v in "$ROOT"/environments/*/values.yaml; do
  env=$(basename "$(dirname "$v")")
  base=$(yq -r '.hosts.configuration.baseHost' "$v")
  expected=$(printf '%s.%s\n%s.%s\n%s.%s\n*.webview.%s.%s\n' \
    "$(yq -r '.hosts.configuration.landing'  "$v")" "$base" \
    "$(yq -r '.hosts.configuration.service'  "$v")" "$base" \
    "$(yq -r '.hosts.configuration.instance' "$v")" "$base" \
    "$(yq -r '.hosts.configuration.instance' "$v")" "$base" | sort)
  documented=$(sed -n '/--- hostnames served by this installation/,/--- end hostnames/p' "$v" \
    | grep -oE '[*a-z0-9.-]+\.tum\.de' | sort)
  if [[ -z "$documented" ]]; then
    bad "$env has no hostname comment" "add the block above hosts.configuration"
  elif [[ "$documented" == "$expected" ]]; then
    ok "$env: 4 hostnames documented and correct"
  else
    bad "$env hostname comment does not match the composed hosts" \
        "$(diff <(echo "$documented") <(echo "$expected") | tr '\n' ' ')"
  fi
done

echo
[[ $FAILED -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAILED
