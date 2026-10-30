#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$SCRIPT_DIR/failover.sh"
region='' output='' timeout=300 interval=3 consecutive=5 allow=false what_if=false yes=false
while (( $# )); do
    case "$1" in
        --help) printf 'Usage: bash test-failover.sh --region region1|region2|br|us --allow-disruption [--what-if] [--yes] [--output-path FILE] [--timeout-seconds 300] [--interval-seconds 3] [--consecutive-successes 5]\nInterrupts one regional backend, measures failover and attempts restoration. Not a full regional DR test.\n'; exit 0 ;;
        --allow-disruption) allow=true; shift ;;
        --what-if) what_if=true; shift ;;
        --yes) yes=true; shift ;;
        --region|--output-path|--timeout-seconds|--interval-seconds|--consecutive-successes)
            (( $# >= 2 )) || die "Missing value for $1."
            case "$1" in --region) region="$2" ;; --output-path) output="$2" ;; --timeout-seconds) timeout="$2" ;;
                --interval-seconds) interval="$2" ;; --consecutive-successes) consecutive="$2" ;; esac
            shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
key="$(resolve_region "$region")"
bounded_integer "$timeout" 1 1800 TimeoutSeconds
bounded_integer "$interval" 1 30 IntervalSeconds
bounded_integer "$consecutive" 1 100 ConsecutiveSuccesses
[[ "$allow" == true ]] || die 'Explicit --allow-disruption is required.'
if [[ "$what_if" == true ]]; then
    log "What if: scale $region to zero, measure failover and restore its original replica count."
    exit 0
fi
if [[ "$yes" != true ]]; then
    [[ -t 0 ]] || die 'Interactive confirmation required. Use --yes only after approving this exercise.'
    read -r -p "Interrupt $region and then attempt restoration? Type YES: " answer
    [[ "$answer" == YES ]] || die 'Exercise cancelled; no environment was read or changed.'
fi
require_tools az azd jq python3 curl
if [[ -z "$output" ]]; then output="$PROJECT_ROOT/TestResults/failover-$(python3 -c 'import uuid; print(uuid.uuid4().hex)').json"; fi
load_environment
measured_failover "$key" "$output" "$timeout" "$interval" "$consecutive"
