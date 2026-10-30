#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "${1:-}" != --help ]] || { printf 'Usage: bash pre-provision.sh\nValidates the selected azd environment and preserves private APIM access. Called by azd.\n'; exit 0; }
(( $# == 0 )) || die 'Unexpected arguments.'
require_tools az azd bicep jq python3
load_environment
for pair in DEPLOYMENT_PROFILE=poc MONITORING_MODE=Disabled ALERTS_MODE=Disabled REGION1_ZONES=none REGION2_ZONES=none ALERT_ACTION_GROUP_ID=none; do
    key="${pair%%=*}" value="${pair#*=}"
    if ! jq -e --arg key "$key" '.[$key] | type == "string" and test("\\S")' <<<"$ENV_JSON" >/dev/null; then
        set_value "$key" "$value"
        ENV_JSON="$(jq -c --arg key "$key" --arg value "$value" '.[$key]=$value' <<<"$ENV_JSON")"
    fi
done
assert_operations
SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
tenant="$(required AZURE_TENANT_ID)"
group="$(required AKS_ADMIN_GROUP_OBJECT_ID)"
name="$(required AZURE_ENV_NAME)"
assert_guid "$SUBSCRIPTION_ID" AZURE_SUBSCRIPTION_ID
assert_guid "$tenant" AZURE_TENANT_ID
assert_guid "$group" AKS_ADMIN_GROUP_OBJECT_ID
assert_environment_name "$name"
for key in APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL BRAZIL_LOCATION US_LOCATION AZURE_LOCATION; do required "$key" >/dev/null; done
assert_email "$(required APIM_PUBLISHER_EMAIL)"
[[ "$(required BRAZIL_LOCATION)" != "$(required US_LOCATION)" ]] || die 'The two regions must be different.'
account="$(az_json account show)"
jq -e --arg tenant "$tenant" '.tenantId == $tenant and .state == "Enabled"' <<<"$account" >/dev/null || die 'Subscription tenant/state mismatch.'
group_json="$(az_json ad group show --group "$group")"
jq -e '.securityEnabled == true' <<<"$group_json" >/dev/null || die 'AKS admin group must be an Entra security group.'
for provider in Microsoft.ApiManagement Microsoft.Cdn Microsoft.Network Microsoft.ContainerService Microsoft.Compute Microsoft.ManagedIdentity Microsoft.OperationalInsights Microsoft.Insights; do
    registration="$(az_json provider show --namespace "$provider" --query registrationState)"
    [[ "$(jq -r . <<<"$registration")" == Registered ]] || die "Register $provider before provisioning."
done
for key in br us; do
    resource_group="rg-$name-$key"
    exists="$(az_json group exists --name "$resource_group")"
    access=Enabled
    if [[ "$exists" == true ]]; then
        if [[ "$(required DEPLOYMENT_PROFILE)" == production ]]; then
            if [[ "$key" == br ]]; then zones="$(required REGION1_ZONES)"; else zones="$(required REGION2_ZONES)"; fi
            clusters="$(az_json aks list --resource-group "$resource_group")"
            jq -e --arg zones "$zones" 'all(.[]; .sku.tier == "Standard" and
                (.agentPoolProfiles[0].availabilityZones | sort) == ($zones | split(",") | sort))' <<<"$clusters" >/dev/null ||
                die 'Existing clusters require a separately planned zonal migration; use a new environment.'
        fi
        instances="$(az_json apim list --resource-group "$resource_group")"
        count="$(jq -r length <<<"$instances")"
        (( count <= 1 )) || die "Expected at most one APIM in $resource_group."
        if (( count == 1 )); then
            access="$(jq -er '.[0].publicNetworkAccess' <<<"$instances")"
            [[ "$access" == Enabled || "$access" == Disabled ]] || die 'Cannot determine current APIM public access.'
        fi
    fi
    set_value "APIM_PUBLIC_ACCESS_${key^^}" "$access"
done
log 'Preflight complete. Existing Disabled gateway access will be preserved.'
