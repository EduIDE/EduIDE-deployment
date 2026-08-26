#!/usr/bin/env bash
# Flag paths referenced by AGENTS.md that no longer exist.
#
# Both pre-existing AGENTS.md files in this org had rotted into fiction. One
# named a CI job that had been deleted and a package.json path that does not
# exist; the other described a landing page removed months earlier. Nothing
# checked them, so nothing noticed.
#
# Only repo-relative, extension-bearing paths in backticks are checked. Prose is
# not validated, and this is a lint rather than a proof.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/AGENTS.md"
[[ -f "$DOC" ]] || { echo "no AGENTS.md here"; exit 0; }

missing=0
while read -r p; do
  [[ "$p" == */* ]] || continue          # must look like a path
  [[ "$p" == *.* ]] || continue          # and carry an extension
  case "$p" in
    http*|*ghcr.io*|*github.com*|oci://*|*.tum.de*) continue ;;
  esac
  if [[ ! -e "$ROOT/$p" ]]; then
    echo "  missing: $p"
    missing=1
  fi
done < <(grep -oE '`[A-Za-z0-9_./-]+`' "$DOC" | tr -d '`' | sort -u)

if [[ $missing -ne 0 ]]; then
  echo "AGENTS.md references paths that do not exist. Fix the doc or the path."
  exit 1
fi
echo "AGENTS.md: every referenced path exists"
