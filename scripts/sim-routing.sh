#!/usr/bin/env bash
# Usage: sim-routing.sh <kube-context> <namespace> <helm-release>
# Sends requests that share a long prompt prefix, then counts requests per
# simulator pod. With prefix-cache-aware routing they should mostly land on
# one pod; unrelated prompts should spread out.
set -euo pipefail

ctx=$1 ns=$2 release=$3
port=${LOCAL_PORT:-8080}
n=${REQUESTS:-10}

kubectl --context "$ctx" -n "$ns" port-forward "svc/${release}-epp" "${port}:80" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
sleep 2

prefix=$(printf 'You are a helpful assistant for a Kubernetes inference demo. %.0s' {1..40})
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for i in $(seq 1 "$n"); do
  curl -sS -o /dev/null "http://localhost:${port}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"demo/tiny-model\",\"prompt\":\"${prefix} Question ${i}?\",\"max_tokens\":5}"
done

echo "Requests with a shared prefix, per simulator pod:"
for pod in $(kubectl --context "$ctx" -n "$ns" get pods -l app=vllm-sim -o name); do
  count=$(kubectl --context "$ctx" -n "$ns" logs "$pod" --since-time="$since" | grep -c 'completions' || true)
  echo "  ${pod#pod/}: ${count}"
done
