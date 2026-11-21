# Sourced by the test scripts. Expects CTX, GW_NS, GW_NAME, SIM_NS, RELEASE,
# ROUTER_MODE from the Makefile (it exports all its variables).

LOCAL_PORT=${LOCAL_PORT:-8080}

# Port-forward to whatever fronts the requests and set BASE_URL.
#   gateway: the Envoy Service that Envoy Gateway created for $GW_NS/$GW_NAME
#   standalone: the router's own <release>-epp Service (Envoy sidecar)
start_port_forward() {
  local target ns
  if [[ ${1:-gateway} == standalone ]]; then
    ns=$SIM_NS
    target=svc/${RELEASE}-epp
  else
    ns=envoy-gateway-system
    target=$(kubectl --context "$CTX" -n "$ns" get svc -o name \
      -l "gateway.envoyproxy.io/owning-gateway-name=${GW_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${GW_NS}")
    if [[ -z $target ]]; then
      echo "No Envoy service found for Gateway ${GW_NS}/${GW_NAME}. Did 'make gateway' finish?" >&2
      exit 1
    fi
  fi

  kubectl --context "$CTX" -n "$ns" port-forward "$target" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null' EXIT
  for _ in $(seq 1 20); do
    (exec 3<>/dev/tcp/127.0.0.1/"$LOCAL_PORT") 2>/dev/null && break
    sleep 0.25
  done
  BASE_URL=http://localhost:${LOCAL_PORT}
  echo "port-forward ${ns}/${target#*/} -> ${BASE_URL}"
}
