#!/usr/bin/env bash
# Print the API server URL from a kubeconfig, for pasting into a cluster manifest.
#
#   ./scripts/cluster-url.sh ~/.kube/tum-student.yaml
#   ./scripts/cluster-url.sh                          # uses the current context
#
# This is the value of spec.apiServerUrl. It is NOT a separate credential and
# NOT extra information: it is one field out of the kubeconfig
# (clusters[0].cluster.server), copied into git.
#
# Why copy it at all, when the kubeconfig already has it? Because the point is
# that the two must AGREE. The kubeconfig lives in a GitHub Environment secret
# where nobody reviews it; the manifest lives in git where a pull request shows
# it. If the wrong kubeconfig is ever pasted into an environment's secret, the
# deploy checks it against the reviewed file and stops instead of quietly
# deploying to the wrong cluster. Reading the cluster's identity out of the same
# secret you are trying to check would prove nothing.
#
# Leaving it empty is allowed. The check then degrades to a warning that prints
# what the kubeconfig points at, which is also how you find the value if you do
# not have the file locally: run a deploy with dry_run and read the log.

set -euo pipefail

KUBECONFIG_FILE="${1:-${KUBECONFIG:-$HOME/.kube/config}}"

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "No such kubeconfig: $KUBECONFIG_FILE" >&2
  exit 2
fi

server=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl config view --minify \
           -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)

if [[ -z "$server" ]]; then
  echo "Could not read a server URL from $KUBECONFIG_FILE" >&2
  exit 1
fi

context=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl config current-context 2>/dev/null || echo unknown)

echo "context:  $context"
echo "server:   $server"
echo
echo "Put this in the cluster manifest:"
echo "  apiServerUrl: \"$server\""
