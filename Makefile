.DEFAULT_GOAL := help

NAMESPACE ?= domotic
KUBE_CONFIG_PATH ?= ~/.kube/config
CUSTOM_VALUES ?= examples/values-kind.yaml

.PHONY: help

help: ## Show this help message
	@echo "Usage: make <target>"
	@echo
	@awk 'BEGIN {print "Available targets:"} /^[a-zA-Z0-9][^$$#\/\t=]*:([^=]|$$)/ { line = $$0; target = line; sub(/:.*/, "", target); gsub(/[[:space:]]+$$/, "", target); if (target == "" || target ~ /\%/) next; if (!seen[target]++) { desc = line; if (sub(/.*##[[:space:]]*/, "", desc)) { gsub(/^[[:space:]]+/, "", desc); } else { desc = ""; } printf("  %-20s %s\n", target, desc); }}' $(MAKEFILE_LIST)

# ==============================================================================
# Development Environment
# ==============================================================================

.PHONY: kind
kind: ## Create kind cluster with Gateway API
	./scripts/kind-create.sh

.PHONY: kind-destroy
kind-destroy: ## Destroy kind cluster
	kind delete cluster --name domotic

# ==============================================================================
# Infrastructure (Terraform)
# ==============================================================================

.PHONY: infra-init
infra-init: ## Initialize Terraform
	cd infra && KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) terraform init

.PHONY: infra-plan
infra-plan: ## Plan Terraform changes
	cd infra && KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) terraform plan

.PHONY: infra-apply
infra-apply: ## Apply Terraform infrastructure
	cd infra && KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) terraform apply -auto-approve
	cd infra && terraform output -raw helm_values_yaml > helm-values.yaml

.PHONY: infra-destroy
infra-destroy: ## Destroy Terraform infrastructure
	cd infra && KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) terraform destroy

# ==============================================================================
# Helm Deployment
# ==============================================================================

.PHONY: helm-install
helm-install: ## Install Helm chart
	helm install $(NAMESPACE) ./charts/domotic \
		--namespace $(NAMESPACE) \
		--create-namespace \
		-f infra/helm-values.yaml \
		-f $(CUSTOM_VALUES)

.PHONY: helm-upgrade
helm-upgrade: ## Upgrade Helm release
	helm upgrade $(NAMESPACE) ./charts/domotic \
		--namespace $(NAMESPACE) \
		-f infra/helm-values.yaml \
		-f $(CUSTOM_VALUES)

.PHONY: helm-uninstall
helm-uninstall: ## Uninstall Helm release
	helm uninstall $(NAMESPACE) --namespace $(NAMESPACE)

# ==============================================================================
# Complete Deployment Workflows
# ==============================================================================

.PHONY: deploy
deploy: infra-apply helm-upgrade ## Deploy complete stack (infra + helm)

.PHONY: deploy-kind
deploy-kind: kind infra-apply helm-install ## Full deployment to kind cluster

.PHONY: destroy
destroy: helm-uninstall infra-destroy ## Destroy everything (helm + infra)

.PHONY: destroy-all
destroy-all: destroy kind-destroy ## Destroy everything including kind cluster
