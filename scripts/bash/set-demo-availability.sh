#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
region='' state=''
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash set-demo-availability.sh --region region1|region2|br|us --state Available|Unavailable\nChanges live replicas to 2 or 0; does not automatically restore them.\n'; exit 0 ;;
        --region|--state)
            (( $# >= 2 )) || die "Missing value for $1."
            if [[ "$1" == --region ]]; then region="$2"; else state="$2"; fi
            shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
key="$(resolve_region "$region")"
case "$state" in Available) replicas=2 ;; Unavailable) replicas=0 ;; *) die 'State must be Available or Unavailable.' ;; esac
require_tools az azd jq
load_environment
SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
settings="$(region_settings "$key")"
set_replicas "$settings" "$replicas"
log "Demo in $(jq -r .Location <<<"$settings"): $state. Front Door probes take time to detect the transition."
