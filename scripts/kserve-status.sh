#!/usr/bin/env bash
# One-shot overview of the KServe deployment. Run via `make kserve-status`,
# or `watch -n5 make -s kserve-status` while `make kserve-model` is running.
# Missing resources are reported, not treated as errors.
set -uo pipefail

name=opt-125m
k() { kubectl --context "$CTX" "$@"; }
section() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
conds='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

section "KServe controller ($KSERVE_NS)"
k -n "$KSERVE_NS" get deploy llmisvc-controller-manager 2>&1

section "LLMInferenceService $MODEL_NS/$name"
if k -n "$MODEL_NS" get llminferenceservice "$name" >/dev/null 2>&1; then
  echo "url: $(k -n "$MODEL_NS" get llminferenceservice "$name" -o jsonpath='{.status.url}')"
  { printf 'TYPE\tSTATUS\tREASON\tMESSAGE\n'
    k -n "$MODEL_NS" get llminferenceservice "$name" -o jsonpath="$conds"; } | column -t -s $'\t'
else
  echo "not found (run: make kserve-model)"
fi

section "Workloads in $MODEL_NS"
k -n "$MODEL_NS" get deploy,svc 2>&1
k -n "$MODEL_NS" get pods -o wide 2>&1

section "InferencePool"
k -n "$MODEL_NS" get inferencepool 2>&1

section "HTTPRoute -> Gateway $GW_NS/$GW_NAME"
k -n "$MODEL_NS" get httproute 2>&1
for r in $(k -n "$MODEL_NS" get httproute -o name 2>/dev/null); do
  echo "-- ${r#*/} parent conditions:"
  k -n "$MODEL_NS" get "$r" -o jsonpath='{range .status.parents[*]}{.parentRef.namespace}/{.parentRef.name}{"\n"}{range .conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}{end}'
done
k -n "$GW_NS" get gateway "$GW_NAME" 2>&1

section "Recent events in $MODEL_NS"
k -n "$MODEL_NS" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15
