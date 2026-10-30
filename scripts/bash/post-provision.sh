#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$SCRIPT_DIR/bootstrap.sh"
[[ "${1:-}" != --help ]] || { printf 'Usage: bash post-provision.sh\nApproves correlated Private Link requests, verifies both private gateways and publishes the demo. Changes Azure resources.\n'; exit 0; }
(( $# == 0 )) || die 'Unexpected arguments.'
require_tools az azd bicep jq python3
load_environment
private_bootstrap
