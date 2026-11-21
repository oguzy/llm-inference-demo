#!/usr/bin/env bash
# Sends one completion to opt-125m through the shared Gateway. Run via `make kserve-test`.
# KServe publishes the model URL in status.url; its host is the Gateway's
# in-cluster address, so we keep only the path and go through a port-forward.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

name=opt-125m
url=$(kubectl --context "$CTX" -n "$MODEL_NS" get llminferenceservice "$name" -o jsonpath='{.status.url}')
if [[ -z $url ]]; then
  echo "No status.url yet. Check: kubectl --context $CTX -n $MODEL_NS describe llminferenceservice $name" >&2
  exit 1
fi
path=/${url#*://*/}
[[ $url == *://*/* ]] || path=

start_port_forward gateway

echo "status.url = ${url}"
echo "POST ${path}/v1/completions"
curl -sS "${BASE_URL}${path}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"facebook/opt-125m","prompt":"Kubernetes is","max_tokens":30}' | jq .
