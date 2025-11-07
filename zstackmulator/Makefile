.PHONY: help install uninstall status logs

help:
	@echo "Z-Stack Emulator Kubernetes Deployment"
	@echo ""
	@echo "Usage:"
	@echo "  make install    - Deploy zstackmulator to Kubernetes"
	@echo "  make uninstall  - Remove zstackmulator from Kubernetes"
	@echo "  make status     - Check deployment status"
	@echo "  make logs       - View adapter logs"
	@echo ""
	@echo "Development:"
	@echo "  docker compose up   - Run full stack locally"

install:
	@echo "🚀 Deploying zstackmulator to Kubernetes..."
	@kubectl apply -k .
	@echo "✅ Deployment complete!"
	@echo ""
	@echo "Service endpoint: tcp://zstackmulator.zstackmulator.svc.cluster.local:6638"
	@echo ""
	@echo "Check status with: make status"

uninstall:
	@echo "🗑️  Removing zstackmulator from Kubernetes..."
	@kubectl delete -k .
	@echo "✅ Removed successfully"

status:
	@echo "📊 Z-Stack Emulator Status:"
	@echo ""
	@kubectl -n zstackmulator get all
	@echo ""
	@kubectl -n zstackmulator get configmap

logs:
	@kubectl -n zstackmulator logs -l app=zstackmulator --tail=100 -f
