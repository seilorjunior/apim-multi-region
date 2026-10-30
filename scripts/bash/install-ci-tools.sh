#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "${1:-}" != --help ]] || { printf 'Usage: bash install-ci-tools.sh\nInstalls pinned Bicep/actionlint into a disposable Linux x64 GitHub runner. Does not install PowerShell.\n'; exit 0; }
(( $# == 0 )) || die 'Unexpected arguments.'
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_PATH:-}" ]] ||
    die 'This installer requires a disposable Linux x64 GitHub runner.'
require_tools curl jq tar
versions="$PROJECT_ROOT/scripts/toolchain.json"
bicep_version="$(jq -r .bicep "$versions")"
linter_version="$(jq -r .actionlint "$versions")"
tools="$RUNNER_TEMP/poc-tools"
mkdir -p -- "$tools"
curl --fail --silent --show-error --location --retry 3 "https://github.com/Azure/bicep/releases/download/v$bicep_version/bicep-linux-x64" -o "$tools/bicep"
curl --fail --silent --show-error --location --retry 3 "https://github.com/rhysd/actionlint/releases/download/v$linter_version/actionlint_${linter_version}_linux_amd64.tar.gz" -o "$tools/actionlint.tar.gz"
tar -xzf "$tools/actionlint.tar.gz" -C "$tools" actionlint
rm -f -- "$tools/actionlint.tar.gz"
chmod +x -- "$tools/bicep" "$tools/actionlint"
printf '%s\n' "$tools" >> "$GITHUB_PATH"
