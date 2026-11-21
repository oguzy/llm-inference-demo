#!/usr/bin/env bash
# Usage: sim-test.sh <kube-context> <namespace> <helm-release>
# Port-forwards the router's Envoy port and sends one completion.
set -euo pipefail

ctx=$1 ns=$2 release=$3
port=${LOCAL_PORT:-8080}

kubectl --context "$ctx" -n "$ns" port-forward "svc/${release}-epp" "${port}:80" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
sleep 2

echo "POST /v1/completions via Envoy -> llm-d EPP -> vllm-sim"
curl -sS "http://localhost:${port}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"demo/tiny-model","prompt":"Explain llm-d in one sentence.","max_tokens":30}' | jq .
