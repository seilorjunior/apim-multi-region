#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
subscription='' tenant='' email='' name=poc-apim-private publisher='PoC multi-regiao'
group='' region1=brazilsouth region2=eastus
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash initialize-environment.sh --subscription-id GUID --tenant-id GUID --publisher-email EMAIL [--environment-name NAME] [--publisher-name TEXT] [--aks-admin-group-object-id GUID] [--region1-location REGION] [--region2-location REGION]\n'; exit 0 ;;
        --subscription-id|--tenant-id|--publisher-email|--environment-name|--publisher-name|--aks-admin-group-object-id|--region1-location|--region2-location)
            (( $# >= 2 )) || die "Missing value for $1."
            case "$1" in
                --subscription-id) subscription="$2" ;; --tenant-id) tenant="$2" ;;
                --publisher-email) email="$2" ;; --environment-name) name="$2" ;;
                --publisher-name) publisher="$2" ;; --aks-admin-group-object-id) group="$2" ;;
                --region1-location) region1="$2" ;; --region2-location) region2="$2" ;;
            esac
            shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
require_tools az azd jq
assert_guid "$subscription" SubscriptionId
assert_guid "$tenant" TenantId
assert_environment_name "$name"
assert_email "$email"
[[ -z "$group" ]] || assert_guid "$group" AksAdminGroupObjectId
SUBSCRIPTION_ID="$subscription"
account="$(az_json account show)"
[[ "$(jq -r .tenantId <<<"$account")" == "$tenant" ]] || die 'Authenticated subscription tenant does not match.'
cd -- "$PROJECT_ROOT"
if [[ -f ".azure/$name/.env" ]]; then
    azd env select "$name"
else
    azd env new "$name" --subscription "$subscription" --location "$region1" --no-prompt
fi
set_value AZURE_SUBSCRIPTION_ID "$subscription"
set_value AZURE_TENANT_ID "$tenant"
set_value AZURE_LOCATION "$region1"
set_value BRAZIL_LOCATION "$region1"
set_value US_LOCATION "$region2"
set_value APIM_PUBLISHER_NAME "$publisher"
set_value APIM_PUBLISHER_EMAIL "$email"
if [[ -n "$group" ]]; then set_value AKS_ADMIN_GROUP_OBJECT_ID "$group"; else log 'WARNING: AKS_ADMIN_GROUP_OBJECT_ID is still required.'; fi
log "Local azd environment '$name' configured. No Azure resource was provisioned."
