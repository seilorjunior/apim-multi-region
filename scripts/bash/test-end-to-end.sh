#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
samples=10 expected='' interval=3
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash test-end-to-end.sh [--samples 10] [--expected-region eastus] [--interval-seconds 3]\nReads Azure configuration and sends HTTP requests; does not change resources.\n'; exit 0 ;;
        --samples|--expected-region|--interval-seconds)
            (( $# >= 2 )) || die "Missing value for $1."
            case "$1" in --samples) samples="$2" ;; --expected-region) expected="$2" ;; --interval-seconds) interval="$2" ;; esac
            shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
bounded_integer "$samples" 1 100 Samples
bounded_integer "$interval" 1 60 IntervalSeconds
require_tools az azd jq python3 curl
load_environment
SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
url="$(required API_URL)"
health_url="$(required API_HEALTH_URL)"
first="$(region_settings br)" second="$(region_settings us)"
allowed="$(jq -cn --argjson first "$first" --argjson second "$second" '[$first.Location,$second.Location]')"
if [[ -n "$expected" ]]; then jq -e --arg r "$expected" 'index($r) != null' <<<"$allowed" >/dev/null || die 'Expected region is not configured.'; fi
for region in "$first" "$second"; do
    name="$(jq -r .ApimName <<<"$region")"
    instance="$(az_json apim show --name "$name" --resource-group "$(jq -r .ResourceGroup <<<"$region")")"
    jq -e '.publicNetworkAccess == "Disabled"' <<<"$instance" >/dev/null || die "Public gateway access is enabled: $name"
    cluster="$(az_json aks show --name "$(jq -r .AksName <<<"$region")" --resource-group "$(jq -r .ResourceGroup <<<"$region")")"
    jq -e '.apiServerAccessProfile.enablePrivateCluster == true and .disableLocalAccounts == true' <<<"$cluster" >/dev/null ||
        die 'AKS private/admin configuration is invalid.'
    direct="$(http_get "https://$name.azure-api.net/demo/" "X-Azure-FDID: $(required FRONT_DOOR_ID)")"
    assert_apim_blocked "$direct" "$name"
    log "Verified private gateway and AKS configuration: $(jq -r .Location <<<"$region")."
done
for (( index=0; index<samples; index++ )); do
    sample="$(api_sample "$url" "$allowed")"
    jq -e '.Success' <<<"$sample" >/dev/null || die "API sample failed: $(jq -r .Error <<<"$sample")"
    assert_guid "$(jq -r .CorrelationId <<<"$sample")" X-Correlation-ID
    [[ -z "$expected" || "$(jq -r .Region <<<"$sample")" == "$expected" ]] || die 'Unexpected serving region; wait for health convergence.'
    printf '%s\n' "$sample"
    if (( index < samples - 1 )); then sleep "$interval"; fi
done
health="$(http_get "$health_url")"
jq -e --argjson allowed "$allowed" --arg expected "$expected" '
    . as $r | .Status == 200 and .Body.status == "ok" and
    ($allowed | index($r.Body.region)) != null and .Headers["x-served-region"] == .Body.region and
    ($expected == "" or .Body.region == $expected)' <<<"$health" >/dev/null || die 'Invalid Front Door health response.'
log 'Samples passed. Seeing one region in active-active mode is not proof of failure.'
