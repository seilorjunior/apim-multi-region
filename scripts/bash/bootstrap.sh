#!/usr/bin/env bash

private_bootstrap() {
    local attempts="${1:-120}" poll_seconds="${2:-15}" name profile fdid global_group origin_group
    local key region marker connections matches unexpected count connection status origin_id origin approved attempt instance image command
    bounded_integer "$attempts" 1 120 ApprovalAttempts
    bounded_integer "$poll_seconds" 0 60 PollSeconds
    SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
    name="$(required AZURE_ENV_NAME)"
    profile="$(required FRONT_DOOR_PROFILE_NAME)"
    fdid="$(required FRONT_DOOR_ID)"
    global_group="$(required AZURE_RESOURCE_GROUP)"
    origin_group="$(required FRONT_DOOR_ORIGIN_GROUP_NAME)"
    for key in br us; do
        region="$(region_settings "$key")"
        marker="azd:$name:$key:$profile"
        approved=false
        for (( attempt=0; attempt<attempts; attempt++ )); do
            connections="$(az_json network private-endpoint-connection list --id "$(jq -r .ApimId <<<"$region")")"
            matches="$(jq -c --arg marker "$marker" '[.[] | select(.properties.privateLinkServiceConnectionState.description == $marker)]' <<<"$connections")"
            unexpected="$(jq -r --arg marker "$marker" '[.[] | select(.properties.privateLinkServiceConnectionState.status == "Approved" and .properties.privateLinkServiceConnectionState.description != $marker)] | length' <<<"$connections")"
            count="$(jq -r length <<<"$matches")"
            (( unexpected == 0 && count <= 1 )) || die 'Unexpected or ambiguous private connections.'
            if (( count == 1 )); then
                connection="$(jq -c '.[0]' <<<"$matches")"
                status="$(jq -r .properties.privateLinkServiceConnectionState.status <<<"$connection")"
                case "$status" in
                    Pending)
                        log "Approving correlated request: $(jq -r .id <<<"$connection"); endpoint $(jq -r .properties.privateEndpoint.id <<<"$connection")"
                        az_json network private-endpoint-connection approve --id "$(jq -r .id <<<"$connection")" --description "$marker" >/dev/null ;;
                    Approved) ;;
                    Rejected|Disconnected) die "Private Link connection is $status." ;;
                    *) die "Unsupported Private Link state: $status" ;;
                esac
                origin_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$global_group/providers/Microsoft.Cdn/profiles/$profile/originGroups/$origin_group/origins/$key"
                origin="$(az_json resource show --ids "$origin_id" --api-version 2025-04-15)"
                jq -e --arg id "$(jq -r .ApimId <<<"$region")" --arg marker "$marker" '
                    .properties.sharedPrivateLinkResource |
                    (.privateLink.id | ascii_downcase) == ($id | ascii_downcase) and
                    .groupId == "Gateway" and .requestMessage == $marker' <<<"$origin" >/dev/null ||
                    die 'Front Door origin does not match the expected private APIM connection.'
                if [[ "$status" == Approved ]]; then approved=true; break; fi
            fi
            log "Waiting for Private Link in $key..."
            if (( attempt < attempts - 1 )); then sleep "$poll_seconds"; fi
        done
        [[ "$approved" == true ]] || die 'Private Link approval timed out. No demo API will be published.'
        instance="$(az_json apim show --name "$(jq -r .ApimName <<<"$region")" --resource-group "$(jq -r .ResourceGroup <<<"$region")")"
        if [[ "$(jq -r .publicNetworkAccess <<<"$instance")" != Disabled ]]; then
            az_json resource update --ids "$(jq -r .ApimId <<<"$region")" --api-version 2024-05-01 --set properties.publicNetworkAccess=Disabled >/dev/null
        fi
        instance="$(az_json apim show --name "$(jq -r .ApimName <<<"$region")" --resource-group "$(jq -r .ResourceGroup <<<"$region")")"
        [[ "$(jq -r .publicNetworkAccess <<<"$instance")" == Disabled ]] || die 'Gateway public access is not disabled.'
        set_value "APIM_PUBLIC_ACCESS_${key^^}" Disabled
    done
    BOOTSTRAP_TEMP_DIR="$(mktemp -d)"
    trap cleanup_bootstrap EXIT
    bicep build "$PROJECT_ROOT/infra/gateway.bicep" --outfile "$BOOTSTRAP_TEMP_DIR/gateway.json"
    image="$(jq -r '.DEMO_IMAGE // ""' <<<"$ENV_JSON")"
    for key in br us; do
        region="$(region_settings "$key")"
        render_manifest "$(jq -r .Location <<<"$region")" "$(jq -r .BackendIp <<<"$region")" \
            "$(jq -r .ApimSubnet <<<"$region")" "$image" > "$BOOTSTRAP_TEMP_DIR/demo.yaml"
        command="kubectl apply -f demo.yaml && kubectl -n private-poc rollout restart deployment/regional-demo && kubectl -n private-poc rollout status deployment/regional-demo --timeout=180s && kubectl -n private-poc wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'=$(jq -r .BackendIp <<<"$region") service/regional-demo --timeout=300s"
        aks_checked "$region" "$command" "$BOOTSTRAP_TEMP_DIR/demo.yaml"
        jq -n --arg name "$(jq -r .ApimName <<<"$region")" --arg ip "$(jq -r .BackendIp <<<"$region")" \
            --arg region "$(jq -r .Location <<<"$region")" --arg fdid "$fdid" '{
            "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
            contentVersion:"1.0.0.0", parameters:{
                apimName:{value:$name}, backendIp:{value:$ip}, region:{value:$region}, frontDoorId:{value:$fdid}
            }}' > "$BOOTSTRAP_TEMP_DIR/gateway.parameters.json"
        az_json deployment group create --resource-group "$(jq -r .ResourceGroup <<<"$region")" --name private-demo-gateway \
            --template-file "$BOOTSTRAP_TEMP_DIR/gateway.json" --parameters "@$BOOTSTRAP_TEMP_DIR/gateway.parameters.json" >/dev/null
    done
    log "Demo published at $(required API_URL). Allow Front Door propagation, then run scripts/bash/test-end-to-end.sh."
}

cleanup_bootstrap() {
    local code=$?
    rm -f -- "$BOOTSTRAP_TEMP_DIR/demo.yaml" "$BOOTSTRAP_TEMP_DIR/gateway.json" "$BOOTSTRAP_TEMP_DIR/gateway.parameters.json" || code=1
    rmdir -- "$BOOTSTRAP_TEMP_DIR" || code=1
    return "$code"
}
