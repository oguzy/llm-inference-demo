#!/usr/bin/env bash
# Shows prefix-cache-aware routing. Round 1 sends requests that share a long
# prompt prefix (expect most on one pod); round 2 sends unrelated short prompts
# (expect them spread by load). Counts come from each simulator pod's
# vllm:e2e_request_latency_seconds_count metric. Run via `make sim-routing`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

n=${REQUESTS:-10}
pods=$(kubectl --context "$CTX" -n "$SIM_NS" get pods -l app=vllm-sim -o jsonpath='{.items[*].metadata.name}')

count() {
  kubectl --context "$CTX" get --raw "/api/v1/namespaces/${SIM_NS}/pods/$1:8000/proxy/metrics" |
    awk '/^vllm:e2e_request_latency_seconds_count/ {s += $2} END {print s + 0}'
}

snapshot() { for p in $pods; do echo "$p $(count "$p")"; done; }

report() {
  local before=$1 after
  after=$(snapshot)
  join <(sort <<<"$before") <(sort <<<"$after") | while read -r pod b a; do
    printf '  %-32s %d\n' "$pod" $((a - b))
  done
}

send() {
  curl -sS -o /dev/null "${BASE_URL}/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"demo/tiny-model\",\"prompt\":\"$1\",\"max_tokens\":5}"
}

start_port_forward "$ROUTER_MODE"

prefix=$(printf 'You are a helpful assistant for a Kubernetes inference demo. %.0s' {1..40})
before=$(snapshot)
for i in $(seq 1 "$n"); do send "${prefix} Question ${i}?"; done
echo "Round 1: ${n} requests sharing a long prefix"
report "$before"

before=$(snapshot)
for i in $(seq 1 "$n"); do send "Unrelated question number ${i} ${RANDOM}${RANDOM}"; done
echo "Round 2: ${n} unrelated short prompts"
report "$before"
