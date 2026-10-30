#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
pinned=false
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash invoke-validation.sh [--require-pinned-tools]\nRuns native Bash/Python tests and Bicep compilation. No Azure resource access and no PowerShell dependency.\n'; exit 0 ;;
        --require-pinned-tools) pinned=true; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
require_tools bash jq python3 bicep
cd -- "$PROJECT_ROOT"
if [[ "$pinned" == true ]]; then
    versions="$PROJECT_ROOT/scripts/toolchain.json"
    [[ "$(python3 --version)" == "Python $(jq -r .python "$versions")" ]] || die 'Python does not match scripts/toolchain.json.'
    [[ "$(bicep --version)" == "Bicep CLI version $(jq -r .bicep "$versions") "* ]] || die 'Bicep does not match scripts/toolchain.json.'
    require_tools actionlint
    actionlint -shellcheck= -pyflakes= .github/workflows/validate.yml .github/workflows/release-image.yml .github/workflows/deploy.yml
fi
for file in "$SCRIPT_DIR"/*.sh; do bash -n "$file"; done
SCRIPT_TEST_SHELL=bash python3 -B -m unittest discover -s tests -p 'test_*.py' -v
bicep build infra/main.bicep --stdout >/dev/null
bicep build infra/gateway.bicep --stdout >/dev/null
log 'All native local validation checks passed. No Azure resource was changed.'
