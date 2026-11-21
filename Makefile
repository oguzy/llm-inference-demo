SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

include versions.env
export

CLUSTER     ?= llmd-sim
KIND_CONFIG ?= kind/cluster.yaml
CTX         := kind-$(CLUSTER)

# Shared gateway that both the llm-d router and KServe attach to
GW_NS       ?= llm-gateway
GW_NAME     ?= inference-gateway

# llm-d router + simulator. ROUTER_MODE: gateway (EPP behind the shared Gateway)
# or standalone (EPP with its own Envoy sidecar, no Gateway needed).
SIM_NS      ?= llm-d-sim
RELEASE     ?= demo
ROUTER_MODE ?= gateway

# KServe controller and model namespaces
KSERVE_NS   ?= kserve
MODEL_NS    ?= kserve-demo

K := kubectl --context $(CTX)
H := helm --kube-context $(CTX)

.PHONY: help install-tools-arch install-kube-extras-arch check-tools cluster down \
	gateway-crds gateway gateway-clean \
	sim-up sim-router sim-pods sim-test sim-routing sim-clean \
	kserve-up kserve-deps kserve-install kserve-model kserve-test kserve-clean

help: ## Show targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

install-tools-arch: ## Install docker, kind, kubectl, helm, jq on Arch Linux (uses sudo)
	sudo pacman -S --needed --noconfirm docker kind kubectl helm jq curl
	sudo systemctl enable --now docker
	@if id -nG "$$USER" | grep -qw docker; then \
	  echo "$$USER is already in the docker group."; \
	else \
	  sudo usermod -aG docker "$$USER"; \
	  echo; echo "Added $$USER to the docker group. Log out and back in (or run 'newgrp docker'), then: make check-tools"; \
	fi

install-kube-extras-arch: ## Install kubectx/kubens + fzf and kubectl-aliases (adds a line to ~/.bashrc)
	sudo pacman -S --needed --noconfirm kubectx fzf
	curl -fsSL -o $$HOME/.kubectl_aliases \
	  https://raw.githubusercontent.com/ahmetb/kubectl-aliases/$(KUBECTL_ALIASES_COMMIT)/.kubectl_aliases
	@grep -q 'source ~/.kubectl_aliases' $$HOME/.bashrc 2>/dev/null || \
	  printf '\n# kubectl aliases: https://github.com/ahmetb/kubectl-aliases\n[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases\n' >> $$HOME/.bashrc
	@grep -q "alias kx=" $$HOME/.bashrc 2>/dev/null || \
	  printf "alias kx='kubectx'\nalias kns='kubens'\n" >> $$HOME/.bashrc
	@echo; echo "Done. Run 'source ~/.bashrc' or open a new terminal. Try: kx, kns llm-d-sim, kgpo"

check-tools: ## Verify docker, kind, kubectl, helm are installed and docker is reachable
	@scripts/check-tools.sh

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

cluster: check-tools ## Create the kind cluster (KIND_CONFIG=kind/cluster-multinode.yaml for 3 nodes)
	kind get clusters | grep -qx $(CLUSTER) || \
	  kind create cluster --name $(CLUSTER) --image $(KIND_NODE_IMAGE) --config $(KIND_CONFIG)
	$(K) wait --for=condition=Ready node --all --timeout=2m

down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

# ---------------------------------------------------------------------------
# Shared gateway: Envoy Gateway + Envoy AI Gateway, one Gateway for everything.
# Independent of llm-d and KServe; both only attach HTTPRoutes to it.
# ---------------------------------------------------------------------------

gateway-crds: ## Install Gateway API, InferencePool and llm-d CRDs
	$(K) apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	$(K) apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GAIE_VERSION)/v1-manifests.yaml
	$(K) apply --server-side -f https://github.com/llm-d/llm-d-router/releases/download/$(LLMD_ROUTER_CRDS_VERSION)/manifests.yaml

gateway: gateway-crds ## Install Envoy Gateway + Envoy AI Gateway and create the shared Gateway
	$(H) template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version $(ENVOY_GATEWAY_VERSION) \
	  --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true \
	  | grep -vE '^(Pulled|Digest):' | $(K) apply --server-side -f -
	# Before the controller starts: it can't sync its caches without InferencePool read access.
	$(K) apply -f 00-gateway/rbac.yaml
	$(H) upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version $(ENVOY_GATEWAY_VERSION) \
	  -n envoy-gateway-system --create-namespace --skip-crds --wait \
	  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/$(ENVOY_AI_GATEWAY_VERSION)/manifests/envoy-gateway-values.yaml \
	  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/$(ENVOY_AI_GATEWAY_VERSION)/examples/inference-pool/envoy-gateway-values-addon.yaml
	$(H) upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version $(ENVOY_AI_GATEWAY_VERSION) \
	  -n envoy-ai-gateway-system --create-namespace
	$(H) upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm --version $(ENVOY_AI_GATEWAY_VERSION) \
	  -n envoy-ai-gateway-system --create-namespace --wait
	$(K) apply -f 00-gateway/gatewayclass.yaml
	$(K) create namespace $(GW_NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) -n $(GW_NS) apply -f 00-gateway/gateway.yaml
	$(K) -n $(GW_NS) wait --for=condition=Programmed gateway/$(GW_NAME) --timeout=5m
	@echo; echo "Gateway $(GW_NS)/$(GW_NAME) is programmed."

gateway-clean: ## Remove the Gateway, Envoy AI Gateway and Envoy Gateway (keeps CRDs)
	-$(K) -n $(GW_NS) delete -f 00-gateway/gateway.yaml --ignore-not-found
	-$(K) delete -f 00-gateway/gatewayclass.yaml --ignore-not-found
	-$(H) uninstall aieg aieg-crd -n envoy-ai-gateway-system
	-$(H) uninstall eg -n envoy-gateway-system
	-$(K) delete -f 00-gateway/rbac.yaml --ignore-not-found

# ---------------------------------------------------------------------------
# llm-d router (EPP) -> simulated vLLM. No GPU, no model download.
# ---------------------------------------------------------------------------

sim-up: cluster gateway sim-router sim-pods ## Cluster + gateway + llm-d router + simulator pods
	@echo; echo "Ready. Try: make sim-test"

sim-router: ## Install the llm-d router (ROUTER_MODE=gateway|standalone)
	$(K) create namespace $(SIM_NS) --dry-run=client -o yaml | $(K) apply -f -
ifeq ($(ROUTER_MODE),standalone)
	$(K) apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GAIE_VERSION)/v1-manifests.yaml
	$(H) upgrade -i $(RELEASE) $(LLMD_ROUTER_STANDALONE_CHART) --version $(LLMD_ROUTER_CHART_VERSION) \
	  -n $(SIM_NS) -f 01-llm-d-sim/router-standalone.values.yaml
else
	$(H) upgrade -i $(RELEASE) $(LLMD_ROUTER_GATEWAY_CHART) --version $(LLMD_ROUTER_CHART_VERSION) \
	  -n $(SIM_NS) -f 01-llm-d-sim/router-gateway.values.yaml \
	  --set httpRoute.inferenceGatewayName=$(GW_NAME) --set httpRoute.inferenceGatewayNamespace=$(GW_NS)
endif
	$(K) -n $(SIM_NS) rollout status deploy/$(RELEASE)-epp --timeout=5m

sim-pods: ## Deploy the simulated vLLM pods the router sends traffic to
	$(K) create namespace $(SIM_NS) --dry-run=client -o yaml | $(K) apply -f -
	sed "s|LLMD_SIM_IMAGE|$(LLMD_SIM_IMAGE)|" 01-llm-d-sim/simulator.yaml | $(K) -n $(SIM_NS) apply -f -
	$(K) -n $(SIM_NS) rollout status deploy/vllm-sim --timeout=5m

sim-test: ## Send a completion through Envoy -> llm-d EPP -> simulator
	@scripts/sim-test.sh

sim-routing: ## Send repeated same-prefix requests and show which sim pod served each
	@scripts/sim-routing.sh

sim-clean: ## Remove the llm-d router and simulator pods (keeps cluster and gateway)
	-$(H) uninstall $(RELEASE) -n $(SIM_NS)
	-$(K) -n $(SIM_NS) delete deploy/vllm-sim --ignore-not-found

# ---------------------------------------------------------------------------
# KServe LLMInferenceService -> shared Gateway + llm-d scheduler -> vLLM on CPU.
# KServe does not install the gateway here; it uses $(GW_NS)/$(GW_NAME).
# ---------------------------------------------------------------------------

kserve-up: cluster gateway kserve-deps kserve-install kserve-model ## Cluster + gateway + KServe + opt-125m on CPU
	@echo; echo "Ready. Try: make kserve-test"

kserve-deps: ## Install cert-manager (KServe webhooks need it)
	$(H) upgrade -i cert-manager cert-manager --repo https://charts.jetstack.io --version $(CERT_MANAGER_VERSION) \
	  -n cert-manager --create-namespace --set crds.enabled=true --wait

kserve-install: ## Install the KServe LLMInferenceService controller, using the shared Gateway
	$(H) upgrade -i kserve-llmisvc-crd oci://ghcr.io/kserve/charts/kserve-llmisvc-crd --version $(KSERVE_VERSION) \
	  -n $(KSERVE_NS) --create-namespace --wait
	$(H) upgrade -i kserve-llmisvc-resources oci://ghcr.io/kserve/charts/kserve-llmisvc-resources --version $(KSERVE_VERSION) \
	  -n $(KSERVE_NS) --create-namespace --wait \
	  --set kserve.version=$(KSERVE_VERSION) \
	  --set kserve.llmisvc.createGIECRDs=false \
	  --set kserve.controller.gateway.ingressGateway.kserveGateway=$(GW_NS)/$(GW_NAME)
	$(H) upgrade -i kserve-runtime-configs oci://ghcr.io/kserve/charts/kserve-runtime-configs --version $(KSERVE_VERSION) \
	  -n $(KSERVE_NS) --wait \
	  --set kserve.version=$(KSERVE_VERSION) \
	  --set kserve.servingruntime.enabled=false \
	  --set kserve.llmisvcConfigs.enabled=true
	$(K) -n $(KSERVE_NS) rollout status deploy/llmisvc-controller-manager --timeout=5m

kserve-model: ## Deploy facebook/opt-125m as an LLMInferenceService (vLLM CPU)
	$(K) create namespace $(MODEL_NS) --dry-run=client -o yaml | $(K) apply -f -
	sed -e "s|VLLM_CPU_IMAGE|$(VLLM_CPU_IMAGE)|" -e "s|name: inference-gateway|name: $(GW_NAME)|" -e "s|namespace: llm-gateway|namespace: $(GW_NS)|" \
	  02-kserve/opt-125m-cpu.yaml | $(K) -n $(MODEL_NS) apply -f -
	$(K) -n $(MODEL_NS) wait --for=condition=Ready llminferenceservice/opt-125m --timeout=20m

kserve-test: ## Send a completion to opt-125m through the shared Gateway
	@scripts/kserve-test.sh

kserve-clean: ## Remove the model and KServe (keeps cluster, gateway, cert-manager)
	-$(K) -n $(MODEL_NS) delete llminferenceservice/opt-125m --ignore-not-found --wait
	-$(H) uninstall kserve-runtime-configs kserve-llmisvc-resources kserve-llmisvc-crd -n $(KSERVE_NS)
