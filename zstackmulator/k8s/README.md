# Kubernetes Deployment for Z-Stack Emulator

This directory contains Kustomize manifests for deploying the Z-Stack emulator to Kubernetes.

## Prerequisites

- kubectl with Kustomize support (kubectl 1.14+)
- Access to a Kubernetes cluster

## Quick Start

### Deploy

From the repository root:

```bash
kubectl apply -k .
```

### Verify

```bash
kubectl -n zstackmulator get pods
kubectl -n zstackmulator get svc
```

### Service Endpoint

The adapter will be available at:

```
tcp://zstackmulator.zstackmulator.svc.cluster.local:6638
```

### Undeploy

```bash
kubectl delete -k .
```

## What Gets Deployed

- **Namespace**: `zstackmulator`
- **ConfigMap**: Contains the `zstackmulator.py` script (auto-generated from file)
- **Deployment**: Single replica running the adapter
- **Service**: ClusterIP service on port 6638

## Files

- `kustomization.yaml` - Main Kustomize configuration
- `namespace.yaml` - Creates the namespace
- `deployment.yaml` - Defines the pod and container
- `service.yaml` - Exposes the TCP service

## Using with zigbee2mqtt

Point your zigbee2mqtt configuration to:

```yaml
serial:
  port: tcp://zstackmulator.zstackmulator.svc.cluster.local:6638
```
