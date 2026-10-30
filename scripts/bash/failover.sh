#!/usr/bin/env bash

now_millis() { python3 -c 'import time; print(time.monotonic_ns() // 1000000)'; }

record_failover_failure() {
    local code="$1" line="$2"
    FO_ERRORS="$(jq -c --arg message "Command failed at line $line (exit $code); see stderr." '. + [$message]' <<<"$FO_ERRORS")"
    log "ERROR: command failed at line $line (exit $code)."
    return "$code"
}

finish_failover() {
    local code=$? restored recovery completed
    trap - EXIT INT TERM ERR
    set +e
    if (( code != 0 )); then
        FO_PASSED=false
        if [[ "$FO_ERRORS" == '[]' ]]; then
            FO_ERRORS="$(jq -c --arg message "${LAST_ERROR:-Exercise failed (exit $code); see stderr.}" '. + [$message]' <<<"$FO_ERRORS")"
        fi
    fi
    if [[ "$FO_FAULT_ATTEMPTED" == true ]]; then
        if (set_replicas "$FO_TARGET" "$FO_ORIGINAL"); then
            if restored="$(get_deployment "$FO_TARGET")" &&
                jq -e --argjson count "$FO_ORIGINAL" '.spec.replicas == $count and .status.readyReplicas == $count' <<<"$restored" >/dev/null; then
                if recovery="$(api_sample "$FO_URL" "$FO_ALLOWED")" && jq -e .Success <<<"$recovery" >/dev/null; then
                    FO_RESTORED=true
                fi
            fi
        fi
        if [[ "$FO_RESTORED" != true ]]; then
            FO_PASSED=false
            code=1
            FO_ERRORS="$(jq -c '. + ["RESTORATION FAILED: restore the original replica count manually; see stderr."]' <<<"$FO_ERRORS")"
            log "RESTORATION FAILED: $(jq -r .AksName <<<"$FO_TARGET"); restore $FO_ORIGINAL replicas manually."
        fi
    fi
    completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! (set -o noclobber; jq -s --arg started "$FO_STARTED" --arg completed "$completed" \
        --arg target "$(jq -r .Location <<<"$FO_TARGET")" --arg survivor "$(jq -r .Location <<<"$FO_SURVIVOR")" \
        --argjson replicas "$FO_ORIGINAL" --argjson timeout "$FO_TIMEOUT" --argjson consecutive "$FO_CONSECUTIVE" \
        --argjson baseline "$FO_BASELINE" --argjson fault_duration "$FO_FAULT_DURATION" --argjson observed "$FO_OBSERVED" \
        --argjson restored "$FO_RESTORED" --argjson passed "$FO_PASSED" --argjson errors "$FO_ERRORS" '
        . as $samples | {
          SchemaVersion:1, Exercise:"backend-failover-not-regional-DR",
          TargetRegion:$target, SurvivingRegion:$survivor, OriginalReplicas:$replicas,
          StartedUtc:$started, CompletedUtc:$completed, TimeoutSeconds:$timeout,
          RequiredConsecutiveSuccesses:$consecutive, Baseline:$baseline,
          FaultCommandDurationSeconds:$fault_duration, ObservedConvergenceSeconds:$observed,
          Restored:$restored, Passed:$passed, Samples:$samples, Errors:$errors,
          FailedRequests:([$samples[] | select(.Success == false)] | length),
          SampleCount:($samples | length),
          P95LatencyMs:(if ($samples | length) > 0 then
            ([$samples[].LatencyMs] | sort | .[((length * 0.95 | ceil) - 1)])
            else null end)
        }' "$FO_TEMP/samples.ndjson" > "$FO_OUTPUT"); then
        log "ERROR: could not persist failover evidence to $FO_OUTPUT."
        code=1
    else
        log "Failover evidence: $FO_OUTPUT"
        cat -- "$FO_OUTPUT"
    fi
    rm -f -- "$FO_TEMP/samples.ndjson" || code=1
    rmdir -- "$FO_TEMP" || code=1
    exit "$code"
}

measured_failover() {
    local key="$1" first second deployment sample streak=0 start elapsed
    FO_OUTPUT="$2" FO_TIMEOUT="$3" interval="$4" FO_CONSECUTIVE="$5"
    SUBSCRIPTION_ID="$(required AZURE_SUBSCRIPTION_ID)"
    FO_URL="$(required API_URL)"
    [[ "$FO_URL" == https://* ]] || die 'API_URL must use HTTPS.'
    first="$(region_settings br)" second="$(region_settings us)"
    if [[ "$key" == br ]]; then FO_TARGET="$first" FO_SURVIVOR="$second"; else FO_TARGET="$second" FO_SURVIVOR="$first"; fi
    FO_ALLOWED="$(jq -cn --argjson first "$first" --argjson second "$second" '[$first.Location,$second.Location]')"
    for region in "$first" "$second"; do
        deployment="$(get_deployment "$region")"
        jq -e '.spec.replicas >= 1 and .spec.replicas <= 100 and .status.readyReplicas == .spec.replicas' <<<"$deployment" >/dev/null ||
            die 'Both deployments must be fully available before a fault.'
        if [[ "$(jq -r .Key <<<"$region")" == "$key" ]]; then FO_ORIGINAL="$(jq -r .spec.replicas <<<"$deployment")"; fi
    done
    FO_BASELINE="$(api_sample "$FO_URL" "$FO_ALLOWED")"
    jq -e .Success <<<"$FO_BASELINE" >/dev/null || die 'Baseline failed; no fault injected.'
    mkdir -p -- "$(dirname -- "$FO_OUTPUT")"
    [[ ! -e "$FO_OUTPUT" && -w "$(dirname -- "$FO_OUTPUT")" ]] || die 'Evidence path must be new and its directory writable.'
    FO_TEMP="$(mktemp -d)"
    : > "$FO_TEMP/samples.ndjson"
    FO_ERRORS='[]' FO_PASSED=false FO_RESTORED=false FO_FAULT_ATTEMPTED=false
    FO_FAULT_DURATION=null FO_OBSERVED=null
    FO_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    trap finish_failover EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'record_failover_failure "$?" "$LINENO"' ERR
    start="$(now_millis)"
    FO_FAULT_ATTEMPTED=true
    set_replicas "$FO_TARGET" 0
    elapsed=$(( $(now_millis) - start ))
    FO_FAULT_DURATION="$(jq -n --argjson ms "$elapsed" '$ms / 1000')"
    while (( $(now_millis) - start < FO_TIMEOUT * 1000 )); do
        sample="$(api_sample "$FO_URL" "$FO_ALLOWED")"
        printf '%s\n' "$sample" >> "$FO_TEMP/samples.ndjson"
        if jq -e --arg survivor "$(jq -r .Location <<<"$FO_SURVIVOR")" '.Success and .Region == $survivor' <<<"$sample" >/dev/null; then
            streak=$((streak + 1))
        else
            streak=0
            log "WARNING: failover sample: $sample"
        fi
        elapsed=$(( $(now_millis) - start ))
        if (( streak >= FO_CONSECUTIVE && elapsed <= FO_TIMEOUT * 1000 )); then
            FO_OBSERVED="$(jq -n --argjson ms "$elapsed" '$ms / 1000')"
            FO_PASSED=true
            break
        fi
        sleep "$interval"
    done
    [[ "$FO_PASSED" == true ]] || die "Failover did not converge within $FO_TIMEOUT seconds."
}
