#!/usr/bin/env bash
# Compile an environment manifest into Helm values.
#
#   ./scripts/render-values.sh <environment-name>       # prints values to stdout
#
# env.yaml is not a Helm values file. This is the one place that maps it onto
# the chart's value structure, so the mapping is testable in isolation rather
# than being spread through a workflow.
#
# Order of precedence, lowest first:
#   1. environments/_base.yaml        values identical in every environment
#   2. cluster facts                  storage class, gateway reference
#   3. derived values                 hostnames, parentRefs, preload list
#   4. spec.values                    the environment's own escape hatch
#
# Requires: yq v4

set -euo pipefail

ENV_NAME="${1:?usage: render-values.sh <environment-name>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/environments/$ENV_NAME/env.yaml"
BASE_FILE="$ROOT/environments/_base.yaml"

[[ -f "$ENV_FILE" ]] || { echo "No such environment: $ENV_NAME" >&2; exit 2; }

CLUSTER=$(yq -r '.spec.cluster' "$ENV_FILE")
CLUSTER_FILE="$ROOT/clusters/$CLUSTER.yaml"
[[ -f "$CLUSTER_FILE" ]] || { echo "$ENV_NAME references unknown cluster: $CLUSTER" >&2; exit 2; }

BASE_HOST=$(yq -r '.spec.hosts.baseHost' "$ENV_FILE")
LANDING=$(yq -r '.spec.hosts.landing' "$ENV_FILE")
SERVICE=$(yq -r '.spec.hosts.service // ("service." + .spec.hosts.landing)' "$ENV_FILE")
INSTANCE=$(yq -r '.spec.hosts.instance // ("instance." + .spec.hosts.landing)' "$ENV_FILE")
PREFIX=$(yq -r '.spec.gateway.listenerPrefix // .spec.hosts.landing' "$ENV_FILE")
GW_NAME=$(yq -r '.spec.sharedGateway.name // "theia-shared-gateway"' "$CLUSTER_FILE")
GW_NS=$(yq -r '.spec.sharedGateway.namespace // "gateway-system"' "$CLUSTER_FILE")
STORAGE=$(yq -r '.spec.storageClassName' "$CLUSTER_FILE")
IMAGE_TAG=$(yq -r '.spec.imageTag // "latest"' "$ENV_FILE")

# The IDE images preloaded onto every node. Kept in step with the app set the
# landing page offers; the old files listed these by hand per environment and
# drifted apart as a result.
PRELOAD_APPS=$(yq -r '.spec.preloadApps[]?' "$ENV_FILE" 2>/dev/null || true)
if [[ -z "$PRELOAD_APPS" ]]; then
  PRELOAD_APPS=$'java-17\njava-17-templates\nc\nc-templates\njavascript\nocaml\nrust\npython'
fi

derived=$(mktemp); trap 'rm -f "$derived"' EXIT
{
  echo "hosts: &hostsConfig"
  echo "  configuration:"
  echo "    baseHost: $BASE_HOST"
  echo "    service: $SERVICE"
  echo "    landing: $LANDING"
  echo "    instance: $INSTANCE"
  echo "theia-certificates:"
  echo "  hosts:"
  echo "    configuration:"
  echo "      baseHost: $BASE_HOST"
  echo "      service: $SERVICE"
  echo "      landing: $LANDING"
  echo "      instance: $INSTANCE"
  echo "theia-cloud:"
  echo "  hosts:"
  echo "    configuration:"
  echo "      baseHost: $BASE_HOST"
  echo "      service: $SERVICE"
  echo "      landing: $LANDING"
  echo "      instance: $INSTANCE"
  echo "    allWildcardInstances:"
  yq -r '.spec.hosts.wildcardPrefixes[]? // "*.webview."' "$ENV_FILE" | sed 's/^/      - "/;s/$/"/'
  echo "  app:"
  echo "    name: $(yq -r '.spec.branding.appName' "$ENV_FILE")"
  echo "  keycloak:"
  echo "    realm: \"$(yq -r '.spec.keycloak.realm' "$ENV_FILE")\""
  echo "    clientId: \"$(yq -r '.spec.keycloak.clientId' "$ENV_FILE")\""
  echo "  operator:"
  echo "    storageClassName: $STORAGE"
  echo "    image: ghcr.io/eduide/eduide-cloud/operator:$IMAGE_TAG"
  echo "  service:"
  echo "    image: ghcr.io/eduide/eduide-cloud/service:$IMAGE_TAG"
  echo "  landingPage:"
  echo "    infoTitle: \"$(yq -r '.spec.branding.infoTitle' "$ENV_FILE")\""
  echo "    image: ghcr.io/eduide/eduidec-landing-page:$IMAGE_TAG"
  echo "    footerLinks:"
  echo "      attribution:"
  echo "        version: \"$(yq -r '.spec.branding.footerVersion' "$ENV_FILE")\""
  echo "  gateway:"
  echo "    parentRefs:"
  for section in landing service instances webview; do
    echo "      - name: $GW_NAME"
    echo "        namespace: $GW_NS"
    echo "        sectionName: $PREFIX-$section"
  done
  echo "  preloading:"
  echo "    images:"
  echo "      - ghcr.io/eduide/eduidec-landing-page:$IMAGE_TAG"
  while IFS= read -r app; do
    [[ -n "$app" ]] && echo "      - ghcr.io/eduide/eduide/$app:$IMAGE_TAG"
  done <<< "$PRELOAD_APPS"
  echo "      - image: quay.io/oauth2-proxy/oauth2-proxy:v7.12.0"
  echo "        args: [\"--version\"]"
} > "$derived"

# The environment's own escape hatch wins over everything derived.
overrides=$(mktemp); trap 'rm -f "$derived" "$overrides"' EXIT
yq -r '.spec.values // {}' "$ENV_FILE" > "$overrides"

yq eval-all '. as $item ireduce ({}; . * $item)' \
  "$BASE_FILE" "$derived" "$overrides"
