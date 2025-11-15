# k3s

1. Install [k3s](https://docs.k3s.io/quick-start) with `curl -sfL https://get.k3s.io | sh -`
2. Create `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` with:

    ```yaml
    apiVersion: helm.cattle.io/v1
    kind: HelmChartConfig
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      valuesContent: |
        providers:
          kubernetesGateway:
            enabled: true
        gateway:
          enabled: true
          name: traefik-gateway
          listeners:
            web:
              namespacePolicy: All
   ```

3. If you want to manage the cluster from your local network, create `/etc/rancher/k3s/config.yaml` with:

   ```sh
   tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
    tls-san:
        - $(hostname).local
    EOF
    ```

    Then run `k3s certificate rotate` followed by `systemctl restart k3s`.
