#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$SCRIPT_DIR/apiops.sh"
action=publish config='' plan="$PROJECT_ROOT/TestResults/apiops-plan.json" has_plan=false
arguments=()
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash sync-apim.sh [--dry-run | --action export|drift] [--config FILE] [--revision SHA] [--plan FILE] [--report FILE] [--output FILE] [--deletions FILE --allow-delete]\nShared lifecycle: export, preview, publish, rollback, drift, evidence and explicit operation deletion.\n'; exit 0 ;;
        --dry-run) action=plan; shift ;;
        --allow-delete) arguments+=(--allow-delete); shift ;;
        --config|--action|--plan|--revision|--report|--output|--deletions)
            (( $# >= 2 )) || die "Missing value for $1."
            case "$1" in
                --config) config="$2" ;;
                --action) [[ "$2" == export || "$2" == drift ]] || die 'Action must be export or drift.'; action="$2" ;;
                --plan) plan="$2"; arguments+=(--plan "$2"); has_plan=true ;;
                *) arguments+=("$1" "$2") ;;
            esac
            shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
require_apiops
if [[ "$action" == plan && "$has_plan" == false ]]; then arguments+=(--plan "$plan"); fi
if [[ -n "$config" ]]; then
    node "$PROJECT_ROOT/scripts/apiops.mjs" --config "$config" --action "$action" "${arguments[@]}"
else
    require_tools azd jq
    load_environment
    printf '%s\n' "$ENV_JSON" | node "$PROJECT_ROOT/scripts/apiops.mjs" --config - --action "$action" "${arguments[@]}"
fi
