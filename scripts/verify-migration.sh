#!/usr/bin/env bash
# Prove the environment values files are equivalent to what they replace.
#
# Renders the umbrella chart twice per environment - once from the legacy
# deployments/<fqdn>/values.yaml, once from
# `-f environments/_base.yaml -f environments/<env>/values.yaml`, which is
# exactly what the deploy does - and diffs the manifests. They must be
# identical, otherwise the migration changes what is deployed.
#
# Delete this once deployments/ is gone.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Environment names are short; the old directories are fully-qualified hosts.
legacy_dir() {
  case "$1" in
    test1)          echo "test1.theia-test.artemis.cit.tum.de" ;;
    test2)          echo "test2.theia-test.artemis.cit.tum.de" ;;
    test3)          echo "test3.theia-test.artemis.cit.tum.de" ;;
    staging)        echo "theia-staging.artemis.cit.tum.de" ;;
    tum-production) echo "theia.artemis.cit.tum.de" ;;
  esac
}

cp -R "$ROOT/charts" "$WORK/charts"
helm dependency update "$WORK/charts/theia-cloud-combined" >/dev/null 2>&1 || {
  echo "helm dependency update failed" >&2; exit 1; }

# theia-shared-cache generates a Redis password when its lookup finds nothing,
# and the landing page image was written without a tag in test1/test2 while the
# others wrote :latest - the same image either way.
mask() {
  sed -E \
    -e 's/^([[:space:]]*redis-password:).*/\1 <masked>/' \
    -e 's|(image: ghcr\.io/eduide/eduidec-landing-page):latest$|\1|'
}

fail=0
for env_dir in "$ROOT"/environments/*/; do
  env=$(basename "$env_dir")
  [[ -f "$env_dir/values.yaml" ]] || continue

  old="$ROOT/deployments/$(legacy_dir "$env")/values.yaml"
  if [[ ! -f "$old" ]]; then
    printf '  %-15s SKIP  no legacy values file\n' "$env"; continue
  fi

  ns=$(yq -r '.spec.namespace' "$env_dir/env.yaml")

  helm template tc "$WORK/charts/theia-cloud-combined" \
    -f "$old" --namespace "$ns" 2>/dev/null | mask > "$WORK/$env.old" || {
      printf '  %-15s FAIL  legacy values do not render\n' "$env"; fail=1; continue; }

  # Exactly what the deploy does: base, then the environment.
  helm template tc "$WORK/charts/theia-cloud-combined" \
    -f "$ROOT/environments/_base.yaml" -f "$env_dir/values.yaml" \
    --namespace "$ns" 2>"$WORK/$env.err" | mask > "$WORK/$env.new" || {
      printf '  %-15s FAIL  new values do not render\n' "$env"
      sed 's/^/        /' "$WORK/$env.err" | head -3; fail=1; continue; }

  if diff -q "$WORK/$env.old" "$WORK/$env.new" >/dev/null; then
    printf '  %-15s IDENTICAL  (%s resources)\n' "$env" "$(grep -c '^kind:' "$WORK/$env.old")"
  else
    n=$(diff "$WORK/$env.old" "$WORK/$env.new" | grep -c '^[<>]')
    printf '  %-15s DIFFERS    (%s lines)\n' "$env" "$n"
    diff "$WORK/$env.old" "$WORK/$env.new" | grep '^[<>]' | cut -c1-150 | head -12 | sed 's/^/        /'
    fail=1
  fi
done

echo
if [[ $fail -eq 0 ]]; then
  echo "All environments equivalent - safe to cut over."
else
  echo "Differences found - do NOT cut over until they are explained."
fi
exit $fail
