locals {
    helm_release_name = "app"
}
resource "helm_release" "_" {
    depends_on = [ kubernetes_secret.cloudflared_tunnel_token_secret ]
    namespace = var.kubernetes_namespace
    name = local.helm_release_name
    chart = "../domotic"
#    atomic = true
    create_namespace = true
    cleanup_on_fail = true

    set = [
        {
            name = "homeassistant.config.external_url",
            value = "https://${local.home_assistant_external_hostname}"
        },
        {
            name = "zigbee2mqtt.config.serial.port",
            value = var.serial_port
        }
    ]
}
