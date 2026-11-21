#!/usr/bin/env bash
# Sends one completion through Envoy -> llm-d EPP -> vllm-sim. Run via `make sim-test`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

start_port_forward "$ROUTER_MODE"

echo "POST /v1/completions"
curl -sS "${BASE_URL}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"demo/tiny-model","prompt":"Explain llm-d in one sentence.","max_tokens":30}' | jq .
