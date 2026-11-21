#!/usr/bin/env bash
# Follow the logs of each hop of a KServe request. Run via `make kserve-logs`
# (all hops, interleaved) or `make kserve-logs-{gateway,epp,vllm}`.
# TAIL=N shows the last N lines first (default 0: only new lines).
set -uo pipefail

name=opt-125m
TAIL=${TAIL:-0}
k() { kubectl --context "$CTX" "$@"; }

# Envoy access log: keep the fields that matter, skip non-JSON lines.
gateway() {
  k -n envoy-gateway-system logs -f -c envoy --tail="$TAIL" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}" |
    jq --unbuffered -R -c 'fromjson? | {start_time, route_name, upstream_host, response_code, duration, "x-request-id"}'
}

# EPP: Envoy streams each request to it in many ext_proc messages and it logs
# every one. Keep the first line of each kind per x-request-id.
epp() {
  k -n "$MODEL_NS" logs -f --tail="$TAIL" "deploy/${name}-kserve-router-scheduler" |
    awk '{
      id = ""; msg = ""
      if (match($0, /"x-request-id":"[^"]*"/)) id = substr($0, RSTART, RLENGTH)
      if (match($0, /"msg":"[^"]*"/)) msg = substr($0, RSTART, RLENGTH)
      if (id != "") { if ((msg id) in seen) next; seen[msg id] = 1 }
      print; fflush()
    }'
}

vllm() {
  k -n "$MODEL_NS" logs -f --tail="$TAIL" "deploy/${name}-kserve" -c main
}

# Run one hop with a colored prefix on every line.
prefixed() {
  local hop=$1 color=$2
  "$hop" 2>&1 | sed -u "s/^/\x1b[${color}m[${hop}]\x1b[0m /"
}

case ${1:-all} in
  gateway|epp|vllm) "$1" ;;
  all)
    # Clear the trap first: kill 0 signals this shell too and would re-enter it.
    trap 'trap - EXIT INT TERM; kill 0 2>/dev/null' EXIT INT TERM
    prefixed gateway 36 &
    prefixed epp 33 &
    prefixed vllm 35 &
    wait
    ;;
  *) echo "usage: $0 [all|gateway|epp|vllm]" >&2; exit 1 ;;
esac
