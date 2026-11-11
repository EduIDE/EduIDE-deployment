#!/usr/bin/env bash
# Print the deploy kubeconfig for one environment, built from the deployer
# ServiceAccount that Bootstrap cluster creates when the cluster sets
# spec.deployers: true. Pipe it straight into the GitHub secret, so the token
# never lands in a file:
#
#   scripts/deployer-kubeconfig.sh eduide.artemis.cit.tum.de aet-cp \
#     | gh secret set KUBECONFIG --repo EduIDE/EduIDE-deployment --env eduide.artemis.cit.tum.de
#
# <admin-context> is any kubectl context with read access to the environment's
# namespace; the API server address is taken from it.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <environment> <admin-context>" >&2
  exit 2
fi
ENV_NAME=$1
CTX=$2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/environments/$ENV_NAME/env.yaml"
if [[ ! -f "$MANIFEST" ]]; then
  echo "no environment $ENV_NAME" >&2
  exit 1
fi
NS=$(yq -r '.spec.namespace' "$MANIFEST")
SECRET=eduide-deployer-token

SERVER=$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(kubectl --context "$CTX" -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl --context "$CTX" -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')
if [[ -z "$TOKEN" || -z "$CA" ]]; then
  echo "secret $NS/$SECRET has no token yet; has Bootstrap cluster run with spec.deployers: true?" >&2
  exit 1
fi

cat <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: $SERVER
      certificate-authority-data: $CA
users:
  - name: eduide
    user:
      token: $TOKEN
contexts:
  - name: eduide
    context:
      cluster: cluster
      user: eduide
      namespace: $NS
current-context: eduide
KUBECONFIG
