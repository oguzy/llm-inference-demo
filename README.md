# llm-inference-demo

A local, GPU-free demo of a Kubernetes LLM inference stack:
**Envoy → llm-d router → vLLM**, then the same thing managed by **KServe**.

It runs on a single machine with kind. Stage 1 needs no GPU and no model
download. Stage 2 runs a real (tiny) model on the CPU.

## Stages

| Stage | What runs | Request path |
|---|---|---|
| 1. `sim` | llm-d router (Envoy sidecar + endpoint picker) and 2 simulated vLLM pods ([llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim)) | client → Envoy → llm-d EPP picks a pod (prefix-cache + load aware) → vllm-sim |
| 2. `kserve` | KServe `LLMInferenceService` with Envoy Gateway, the llm-d scheduler and vLLM CPU serving `facebook/opt-125m` | client → Envoy Gateway → llm-d scheduler → vLLM |

By default each cluster is a single node that runs both the control plane and
the workloads. For stage 1 you can use 1 control-plane + 2 workers instead, which
puts the two simulator pods on different nodes:

```bash
make sim-cluster KIND_CONFIG=kind/cluster-multinode.yaml
kubectl --context kind-llmd-sim get pods -n llm-d-sim -o wide   # after sim-pods
```

Each stage gets its own kind cluster (`llmd-sim`, `llmd-kserve`), because the
two upstreams pin different Gateway API / Inference Extension CRD versions.

## Requirements

- Linux with Docker, about 8 CPU cores and 16 GB RAM (stage 2 wants more headroom)
- `docker`, `kind`, `kubectl`, `helm`, `curl`, `jq`

On Arch Linux:

```bash
make install-tools-arch   # pacman installs, enables docker, adds you to the docker group
# log out and back in if it added you to the docker group
make check-tools
```

## Usage

```bash
make help

# Stage 1: simulated vLLM behind the llm-d router
make sim-up          # or step by step:
#   make sim-cluster   kind cluster
#   make sim-router    InferencePool CRDs + llm-d router (Envoy + EPP)
#   make sim-pods      2 simulated vLLM pods
make sim-test        # one completion through Envoy -> EPP -> sim
make sim-routing     # same-prefix requests; shows which pod served them
make sim-down

# Stage 2: KServe + llm-d + vLLM on CPU
make kserve-up       # runs KServe's pinned LLMISVC installer (cert-manager, Envoy Gateway,
                     # Envoy AI Gateway, Gateway API, LWS, KServe), then deploys opt-125m
make kserve-test
make kserve-down
```

All versions are pinned in [`versions.env`](versions.env).

## Layout

```
versions.env            pinned upstream versions
kind/cluster.yaml       kind cluster config
01-llm-d-sim/           router Helm values + simulator Deployment
02-kserve/              LLMInferenceService for opt-125m on CPU
scripts/                tool check and test requests
```

## Upstream references

- llm-d guides (`guides/optimized-baseline`, `guides/recipes/router`): https://github.com/llm-d/llm-d/tree/release-1.0
- llm-d inference simulator: https://github.com/llm-d/llm-d-inference-sim
- Gateway API Inference Extension: https://github.com/kubernetes-sigs/gateway-api-inference-extension
- KServe LLMInferenceService: https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview
