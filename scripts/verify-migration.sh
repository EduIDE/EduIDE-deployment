#!/usr/bin/env bash
# Prove the environment manifests are equivalent to the values files they replace.
#
# For every environment, render the umbrella chart twice - once with the legacy
# deployments/<fqdn>/values.yaml, once with the output of render-values.sh - and
# diff the resulting manifests. They must be identical, otherwise the migration
# changes what is deployed.
#
# This is the gate for cutting an environment over.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Legacy directory name per environment, since env names are short but the old
# directories are fully-qualified host names.
legacy_dir() {
  case "$1" in
    test1)    echo "test1.theia-test.artemis.cit.tum.de" ;;
    test2)    echo "test2.theia-test.artemis.cit.tum.de" ;;
    test3)    echo "test3.theia-test.artemis.cit.tum.de" ;;
    staging)  echo "theia-staging.artemis.cit.tum.de" ;;
    tum-production) echo "theia.artemis.cit.tum.de" ;;
  esac
}

cp -R "$ROOT/charts" "$WORK/charts"
helm dependency update "$WORK/charts/theia-cloud-combined" >/dev/null 2>&1 || {
  echo "helm dependency update failed" >&2; exit 1; }

# theia-shared-cache generates a Redis password when its lookup finds nothing,
# so mask it or every comparison differs for the wrong reason.
#
# The landing page image is also normalised. test1 and test2 wrote it without a
# tag while test3, staging and prod wrote it with one; an untagged reference
# pulls :latest, so those are the same image, and the compiled values make the
# tag explicit everywhere. This is the ONLY difference the migration introduces
# and it changes nothing about what runs.
mask() {
  sed -E \
    -e 's/^([[:space:]]*redis-password:).*/\1 <masked>/' \
    -e 's|(image: ghcr\.io/eduide/eduidec-landing-page):latest$|\1|'
}

fail=0
for env_dir in "$ROOT"/environments/*/; do
  env=$(basename "$env_dir")
  [[ -f "$env_dir/env.yaml" ]] || continue

  old="$ROOT/deployments/$(legacy_dir "$env")/values.yaml"
  if [[ ! -f "$old" ]]; then
    printf '  %-10s SKIP  no legacy values file\n' "$env"; continue
  fi

  ns=$(yq -r '.spec.namespace' "$env_dir/env.yaml")
  new="$WORK/$env-values.yaml"
  if ! "$ROOT/scripts/render-values.sh" "$env" > "$new" 2>"$WORK/$env.err"; then
    printf '  %-10s FAIL  render-values.sh errored\n' "$env"; sed 's/^/        /' "$WORK/$env.err"; fail=1; continue
  fi

  helm template tc "$WORK/charts/theia-cloud-combined" -f "$old" --namespace "$ns" 2>"$WORK/$env.old.err" | mask > "$WORK/$env.old" || {
    printf '  %-10s FAIL  legacy values do not render\n' "$env"; fail=1; continue; }
  helm template tc "$WORK/charts/theia-cloud-combined" -f "$new" --namespace "$ns" 2>"$WORK/$env.new.err" | mask > "$WORK/$env.new" || {
    printf '  %-10s FAIL  compiled values do not render\n' "$env"; sed 's/^/        /' "$WORK/$env.new.err" | head -3; fail=1; continue; }

  if diff -q "$WORK/$env.old" "$WORK/$env.new" >/dev/null; then
    printf '  %-10s IDENTICAL  (%s resources)\n' "$env" "$(grep -c '^kind:' "$WORK/$env.old")"
  else
    n=$(diff "$WORK/$env.old" "$WORK/$env.new" | grep -c '^[<>]')
    printf '  %-10s DIFFERS    (%s lines)\n' "$env" "$n"
    diff "$WORK/$env.old" "$WORK/$env.new" | grep '^[<>]' | cut -c1-150 | head -12 | sed 's/^/        /'
    fail=1
  fi
done

echo
[[ $fail -eq 0 ]] && echo "All environments equivalent - safe to cut over." \
                  || echo "Differences found - do NOT cut over until they are explained."
exit $fail
