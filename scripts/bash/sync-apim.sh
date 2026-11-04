#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$SCRIPT_DIR/apiops.sh"
dry_run=false
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash sync-apim.sh [--dry-run]\nPublishes shared Git artifacts to both private APIMs. Does not provision infrastructure or deploy workloads.\n'; exit 0 ;;
        --dry-run) dry_run=true; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
require_tools az azd jq node
load_environment
sync_apim "$dry_run"
