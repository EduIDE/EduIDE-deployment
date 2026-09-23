#!/usr/bin/env bash
# Report what is actually running in a namespace, read from the cluster.
#
#   ./scripts/live-summary.sh <namespace> [environment] [cluster]
#
# Deliberately reads the cluster rather than echoing back the values that were
# just applied. "What we told Helm to do" and "what is running" are different
# questions, and only the second one is worth putting in a deploy summary.

set -uo pipefail

NS="${1:?usage: live-summary.sh <namespace> [environment] [cluster]}"
ENV_NAME="${2:-}"
CLUSTER="${3:-}"

k() { kubectl -n "$NS" "$@" 2>/dev/null; }

rel_json=$(helm status eduide -n "$NS" -o json 2>/dev/null || echo '{}')
chart=$(jq -r '.chart // "unknown"' <<<"$rel_json" 2>/dev/null || echo unknown)
revision=$(jq -r '.version // "?"' <<<"$rel_json" 2>/dev/null || echo "?")
status=$(jq -r '.info.status // "unknown"' <<<"$rel_json" 2>/dev/null || echo unknown)

echo "### ${ENV_NAME:-$NS}"
echo ""
echo "| | |"
echo "|---|---|"
[[ -n "$CLUSTER" ]] && echo "| Cluster | \`$CLUSTER\` |"
echo "| Namespace | \`$NS\` |"
echo "| Chart | \`$chart\` |"
echo "| Helm revision | $revision (\`$status\`) |"
[[ -n "${GITHUB_ACTOR:-}" ]] && echo "| Triggered by | @${GITHUB_ACTOR} |"
echo ""

echo "**Images running now**"
echo ""
echo "| Workload | Image |"
echo "|---|---|"
k get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
  | while IFS=$'\t' read -r name image; do
      [[ -n "$name" ]] && echo "| \`$name\` | \`$image\` |"
    done
echo ""

if k get appdefinitions.theia.cloud >/dev/null 2>&1; then
  echo "**AppDefinitions**"
  echo ""
  echo "| Name | Image | min/max |"
  echo "|---|---|---|"
  k get appdefinitions.theia.cloud -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\t"}{.spec.minInstances}{"/"}{.spec.maxInstances}{"\n"}{end}' \
    | while IFS=$'\t' read -r name image scale; do
        [[ -n "$name" ]] && echo "| \`$name\` | \`$image\` | $scale |"
      done
  echo ""
fi

echo "**Gateway routes**"
echo ""
if k get httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  k get httproutes.gateway.networking.k8s.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\t"}{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' \
    | while IFS=$'\t' read -r name accepted resolved; do
        [[ -z "$name" ]] && continue
        if [[ "$accepted" == "True" && "$resolved" == "True" ]]; then
          echo "- \`$name\` attached"
        else
          echo "- \`$name\` **Accepted=${accepted:-?} ResolvedRefs=${resolved:-?}** - the route is not serving traffic"
        fi
      done
else
  echo "- (no HTTPRoutes found)"
fi
echo ""

notready=$(k get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -o name | wc -l | tr -d ' ')
total=$(k get pods -o name | wc -l | tr -d ' ')
if [[ "${notready:-0}" -gt 0 ]]; then
  echo "**${notready} of ${total} pods not Running:**"
  echo ""
  echo '```'
  k get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide | head -15
  echo '```'
else
  echo "All ${total} pods Running."
fi
