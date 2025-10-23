.DEFAULT_GOAL := help

NAMESPACE ?= default

.PHONY: help

help:
	@echo "Usage: make <target>"
	@echo
	@awk 'BEGIN {print "Available targets:"} /^[a-zA-Z0-9][^$$#\/\t=]*:([^=]|$$)/ { line = $$0; target = line; sub(/:.*/, "", target); gsub(/[[:space:]]+$$/, "", target); if (target == "" || target ~ /\%/) next; if (!seen[target]++) { desc = line; if (sub(/.*##[[:space:]]*/, "", desc)) { gsub(/^[[:space:]]+/, "", desc); } else { desc = ""; } printf("  %-20s %s\n", target, desc); }}' $(MAKEFILE_LIST)

.PHONY: kind
kind:
	./kind-create.sh

.PHONY: helm-dev
helm-dev:
	helm upgrade --install dev ./domotic --create-namespace --wait --atomic


.PHONY: secrets
secrets:
	@echo "🔐 Creating/updating secrets in namespace: $(NAMESPACE)"
	@for f in secret.*; do \
		name=$${f#secret.}; \
		echo "→ Applying secret '$${name}' from file '$${f}'"; \
		kubectl create secret generic "$${name}" \
			--from-env-file="$${f}" \
			-n $(NAMESPACE) \
			--dry-run=client -o yaml | kubectl apply -f -; \
	done
	@echo "✅ All secrets applied successfully."
