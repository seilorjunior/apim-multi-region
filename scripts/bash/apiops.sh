#!/usr/bin/env bash

sync_apim() (
    local dry_run="${1:-false}" key region instance marker connections origin origin_id override_dir
    local name profile fdid global_group origin_group
    local -a arguments
    SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
    name="$(required AZURE_ENV_NAME)"
    profile="$(required FRONT_DOOR_PROFILE_NAME)"
    fdid="$(required FRONT_DOOR_ID)"
    global_group="$(required AZURE_RESOURCE_GROUP)"
    origin_group="$(required FRONT_DOOR_ORIGIN_GROUP_NAME)"
    for key in br us; do
        region="$(region_settings "$key")"
        instance="$(az_json apim show --name "$(jq -r .ApimName <<<"$region")" --resource-group "$(jq -r .ResourceGroup <<<"$region")")"
        [[ "$(jq -r .publicNetworkAccess <<<"$instance")" == Disabled ]] || die 'Gateway public access is not disabled. Run postprovision first.'
        marker="azd:$name:$key:$profile"
        connections="$(az_json network private-endpoint-connection list --id "$(jq -r .ApimId <<<"$region")")"
        jq -e --arg marker "$marker" '[.[] | select(.properties.privateLinkServiceConnectionState.status == "Approved")] |
            length == 1 and .[0].properties.privateLinkServiceConnectionState.description == $marker' <<<"$connections" >/dev/null ||
            die 'Expected one correlated approved Private Link connection.'
        origin_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$global_group/providers/Microsoft.Cdn/profiles/$profile/originGroups/$origin_group/origins/$key"
        origin="$(az_json resource show --ids "$origin_id" --api-version 2025-04-15)"
        jq -e --arg id "$(jq -r .ApimId <<<"$region")" --arg marker "$marker" '.properties.sharedPrivateLinkResource |
            (.privateLink.id | ascii_downcase) == ($id | ascii_downcase) and .groupId == "Gateway" and .requestMessage == $marker' <<<"$origin" >/dev/null ||
            die 'Front Door origin does not match the expected private APIM connection.'
    done
    local cli="$PROJECT_ROOT/node_modules/@azure-tools/apiops-cli/dist/cli/index.js"
    [[ -f "$cli" ]] || die 'APIOps CLI is missing. Install Node.js 22+ and run npm ci from the repository root.'
    override_dir="$(mktemp -d)"
    trap 'rm -f -- "$override_dir/configuration.json"; rmdir -- "$override_dir"' EXIT
    for key in br us; do
        region="$(region_settings "$key")"
        jq -n --arg fdid "$fdid" --arg location "$(jq -r .Location <<<"$region")" --arg ip "$(jq -r .BackendIp <<<"$region")" '{
            namedValues:[
                {name:"poc-front-door-id",properties:{value:$fdid}},
                {name:"poc-region",properties:{value:$location}}
            ],
            apis:[{name:"regional-demo",properties:{serviceUrl:("http://"+$ip)}}]
        }' > "$override_dir/configuration.json"
        arguments=("$cli" publish --subscription-id "$SUBSCRIPTION_ID"
            --resource-group "$(jq -r .ResourceGroup <<<"$region")" --service-name "$(jq -r .ApimName <<<"$region")"
            --source "$PROJECT_ROOT/apim-artifacts" --overrides "$override_dir/configuration.json")
        if [[ "$dry_run" == true ]]; then arguments+=(--dry-run); fi
        log "APIOps sync: $(jq -r .ApimName <<<"$region") ($(jq -r .Location <<<"$region")); dry-run=$dry_run"
        COMMIT_ID='' AZURE_API_VERSION=2024-05-01 node "${arguments[@]}" || die "APIOps sync failed for $key. Correct the failure and rerun sync for both APIMs."
    done
)
