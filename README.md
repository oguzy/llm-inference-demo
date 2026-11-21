# llm-inference-demo

A local, GPU-free demo of a Kubernetes LLM inference stack:
**Envoy Gateway → llm-d router → vLLM**, plus the same thing managed by **KServe**.

Everything runs in one kind cluster. The llm-d part uses simulated vLLM pods
(no GPU, no model download); the KServe part runs a real tiny model on the CPU.

## Architecture

```
                         ┌───────────── one kind cluster ──────────────────────────────┐
                         │                                                              │
 client ─port-forward─▶  │  Gateway llm-gateway/inference-gateway  (Envoy Gateway +     │
                         │        │                                Envoy AI Gateway)    │
                         │        ├─ HTTPRoute /            ─▶ InferencePool demo       │
                         │        │    (llm-d router chart)      EPP llm-d-sim/demo-epp │
                         │        │                              ▶ vllm-sim × 2         │
                         │        │                                                     │
                         │        └─ HTTPRoute /kserve-demo/opt-125m  (created by KServe)│
                         │                                       ▶ InferencePool + EPP  │
                         │                                       ▶ vLLM CPU opt-125m    │
                         └──────────────────────────────────────────────────────────────┘
```

The gateway is installed on its own (`make gateway`). Neither llm-d nor KServe
installs it; both only attach `HTTPRoute`s to it:

- the llm-d router chart through `httpRoute.inferenceGatewayName/Namespace`
- KServe through `router.gateway.refs` in the `LLMInferenceService`, and its
  default gateway setting (`kserve.controller.gateway.ingressGateway.kserveGateway`)

For every request, Envoy asks the llm-d Endpoint Picker (EPP) over ext_proc
which pod should serve it; the EPP picks by prompt-prefix cache affinity and load.

## Requirements

- Linux with Docker, about 8 CPU cores and 16 GB RAM
- `docker`, `kind`, `kubectl`, `helm`, `curl`, `jq`

On Arch Linux:

```bash
make install-tools-arch   # pacman installs, enables docker, adds you to the docker group
# log out and back in if it added you to the docker group
make check-tools

# optional: kubectx/kubens (aliases kx, kns) and kubectl-aliases (k, kgpo, kgpon ...)
make install-kube-extras-arch
```

## Usage

```bash
make help

make cluster         # kind cluster (KIND_CONFIG=kind/cluster-multinode.yaml for 1 control-plane + 2 workers)
make gateway         # Gateway API + InferencePool CRDs, Envoy Gateway, Envoy AI Gateway, shared Gateway

# llm-d router + simulated vLLM
make sim-router      # llm-d EPP + InferencePool + HTTPRoute on the shared Gateway
make sim-pods        # 2 simulated vLLM pods
make sim-test        # one completion through Gateway -> EPP -> sim
make sim-routing     # shared-prefix vs unrelated prompts; per-pod request counts

# KServe + vLLM on CPU, on the same Gateway
make kserve-deps     # cert-manager
make kserve-install  # KServe LLMInferenceService controller (helm charts), no gateway of its own
make kserve-model    # facebook/opt-125m as an LLMInferenceService
make kserve-status   # conditions, pods, route, recent events (watch -n5 make -s kserve-status)
make kserve-logs     # follow gateway + EPP + vLLM logs together (or kserve-logs-{gateway,epp,vllm})
make kserve-test

make down            # delete the cluster
```

`make sim-up` and `make kserve-up` run their whole chain. `sim-clean`,
`kserve-clean` and `gateway-clean` remove one layer and keep the rest.

`ROUTER_MODE=standalone make sim-router` installs the router the other way:
Envoy as a sidecar in the EPP pod, without the shared Gateway.

All versions are pinned in [`versions.env`](versions.env).

## Layout

```
versions.env            pinned upstream versions
kind/                   single-node and multi-node cluster configs
00-gateway/             GatewayClass (ClusterIP Envoy), shared Gateway, Envoy Gateway RBAC
01-llm-d-sim/           router Helm values (gateway / standalone) + simulator Deployment
02-kserve/              LLMInferenceService for opt-125m on CPU
scripts/                tool check and test requests
```

## Upstream references

- llm-d guides (`guides/optimized-baseline`, `guides/recipes/router`, `docs/infrastructure/gateway`): https://github.com/llm-d/llm-d/tree/release-1.0
- llm-d inference simulator: https://github.com/llm-d/llm-d-inference-sim
- Gateway API Inference Extension: https://github.com/kubernetes-sigs/gateway-api-inference-extension
- Envoy AI Gateway: https://aigateway.envoyproxy.io/
- KServe LLMInferenceService: https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview
