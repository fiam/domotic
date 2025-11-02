KUBE_CONFIG_PATH ?= ~/.kube/config
KUBE_CTX ?=

.PHONY: init
init:
	KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) KUBE_CTX=$(KUBE_CTX) terraform init

.PHONY: plan
plan:
	KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) KUBE_CTX=$(KUBE_CTX) terraform plan

.PHONY: apply
apply:
	KUBE_CONFIG_PATH=$(KUBE_CONFIG_PATH) KUBE_CTX=$(KUBE_CTX) terraform apply
