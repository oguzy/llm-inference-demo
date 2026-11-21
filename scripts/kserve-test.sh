#!/usr/bin/env bash
# Usage: kserve-test.sh <kube-context> <namespace> <llminferenceservice>
# Sends one completion to the URL KServe publishes in the LLMInferenceService status.
set -euo pipefail

ctx=$1 ns=$2 name=$3

url=$(kubectl --context "$ctx" -n "$ns" get llminferenceservice "$name" -o jsonpath='{.status.url}')
if [[ -z "$url" ]]; then
  echo "No status.url yet. Check: kubectl --context $ctx -n $ns describe llminferenceservice $name"
  exit 1
fi

echo "POST ${url}/v1/completions"
curl -sS "${url}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"facebook/opt-125m","prompt":"Kubernetes is","max_tokens":30}' | jq .
