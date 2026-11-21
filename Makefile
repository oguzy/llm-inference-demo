SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

include versions.env
export

SIM_CLUSTER    ?= llmd-sim
KSERVE_CLUSTER ?= llmd-kserve
SIM_NS         ?= llm-d-sim
KSERVE_NS      ?= kserve-demo
RELEASE        ?= demo

SIM_CTX    := kind-$(SIM_CLUSTER)
KSERVE_CTX := kind-$(KSERVE_CLUSTER)
CACHE      := .cache

.PHONY: help check-tools sim-up sim-test sim-routing sim-down kserve-up kserve-test kserve-down down

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

check-tools: ## Verify docker, kind, kubectl, helm are installed and docker is reachable
	@scripts/check-tools.sh

# ---------------------------------------------------------------------------
# Stage 1: llm-d router (Envoy + EPP) -> simulated vLLM. No GPU, no model download.
# ---------------------------------------------------------------------------

sim-up: check-tools ## Create kind cluster and deploy llm-d router + vLLM simulator
	kind get clusters | grep -qx $(SIM_CLUSTER) || \
	  kind create cluster --name $(SIM_CLUSTER) --image $(KIND_NODE_IMAGE) --config kind/cluster.yaml
	kubectl --context $(SIM_CTX) apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GAIE_VERSION)/v1-manifests.yaml
	kubectl --context $(SIM_CTX) create namespace $(SIM_NS) --dry-run=client -o yaml | kubectl --context $(SIM_CTX) apply -f -
	sed "s|LLMD_SIM_IMAGE|$(LLMD_SIM_IMAGE)|" 01-llm-d-sim/simulator.yaml | kubectl --context $(SIM_CTX) -n $(SIM_NS) apply -f -
	helm upgrade --install $(RELEASE) $(LLMD_ROUTER_CHART) --version $(LLMD_ROUTER_CHART_VERSION) \
	  --kube-context $(SIM_CTX) -n $(SIM_NS) -f 01-llm-d-sim/router.values.yaml
	kubectl --context $(SIM_CTX) -n $(SIM_NS) rollout status deploy/vllm-sim --timeout=5m
	kubectl --context $(SIM_CTX) -n $(SIM_NS) wait --for=condition=Available deploy --all --timeout=5m
	@echo; echo "Ready. Try: make sim-test"

sim-test: ## Send a completion through Envoy -> llm-d EPP -> simulator
	@scripts/sim-test.sh $(SIM_CTX) $(SIM_NS) $(RELEASE)

sim-routing: ## Send repeated same-prefix requests and show which sim pod served each
	@scripts/sim-routing.sh $(SIM_CTX) $(SIM_NS) $(RELEASE)

sim-down: ## Delete the stage 1 cluster
	kind delete cluster --name $(SIM_CLUSTER)

# ---------------------------------------------------------------------------
# Stage 2: KServe LLMInferenceService -> Envoy Gateway + llm-d scheduler -> vLLM on CPU.
# ---------------------------------------------------------------------------

$(CACHE)/kserve-$(KSERVE_VERSION)-install.sh:
	mkdir -p $(CACHE)
	curl -fsSL -o $@ https://raw.githubusercontent.com/kserve/kserve/$(KSERVE_VERSION)/install/$(KSERVE_VERSION)/llmisvc-full-install-with-manifests.sh

kserve-up: check-tools $(CACHE)/kserve-$(KSERVE_VERSION)-install.sh ## Create kind cluster, install KServe LLMISVC stack, deploy opt-125m on CPU
	kind get clusters | grep -qx $(KSERVE_CLUSTER) || \
	  kind create cluster --name $(KSERVE_CLUSTER) --image $(KIND_NODE_IMAGE) --config kind/cluster.yaml
	kubectl config use-context $(KSERVE_CTX)
	PLATFORM=kind bash $(CACHE)/kserve-$(KSERVE_VERSION)-install.sh
	kubectl --context $(KSERVE_CTX) create namespace $(KSERVE_NS) --dry-run=client -o yaml | kubectl --context $(KSERVE_CTX) apply -f -
	sed "s|VLLM_CPU_IMAGE|$(VLLM_CPU_IMAGE)|" 02-kserve/opt-125m-cpu.yaml | kubectl --context $(KSERVE_CTX) -n $(KSERVE_NS) apply -f -
	kubectl --context $(KSERVE_CTX) -n $(KSERVE_NS) wait --for=condition=Ready llminferenceservice/opt-125m --timeout=20m
	@echo; echo "Ready. Try: make kserve-test"

kserve-test: ## Send a completion to opt-125m through KServe's gateway
	@scripts/kserve-test.sh $(KSERVE_CTX) $(KSERVE_NS) opt-125m

kserve-down: ## Delete the stage 2 cluster
	kind delete cluster --name $(KSERVE_CLUSTER)

down: sim-down kserve-down ## Delete both clusters
