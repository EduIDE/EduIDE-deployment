#!/usr/bin/env bash
# How many landing page pods an environment runs when it is not in maintenance.
#
#   ./scripts/landing-replicas.sh <environment>
#
# The maintenance workflow scales the landing page to 0 and needs to know what
# to scale it back to. Same precedence Helm applies: the environment's
# values.yaml over _base.yaml over the chart default of 1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${1:?usage: landing-replicas.sh <environment>}"
V="$ROOT/environments/$ENV/values.yaml"
[[ -f "$V" ]] || { echo "no such environment: $ENV" >&2; exit 1; }
yq -r '.landingPage.replicas // ""' "$V" "$ROOT/environments/_base.yaml" | grep -vE '^(---)?$' | head -1 | grep . || echo 1
