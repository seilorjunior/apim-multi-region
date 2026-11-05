#!/usr/bin/env bash

require_apiops() {
    require_tools node
    [[ -f "$PROJECT_ROOT/node_modules/@azure-tools/apiops-cli/dist/clients/apim-client.js" ]] ||
        die 'APIOps dependency is missing. Install Node.js 22+ and run npm ci --ignore-scripts from the repository root.'
}

sync_apim() {
    local dry_run="${1:-false}" action
    if (( $# )); then shift; fi
    require_apiops
    action=publish
    if [[ "$dry_run" == true ]]; then action=plan; fi
    printf '%s\n' "$ENV_JSON" | node "$PROJECT_ROOT/scripts/apiops.mjs" --config - --action "$action" "$@" ||
        die 'APIOps lifecycle failed. Inspect the sanitized report; correct the issue and rerun for both APIMs.'
}
