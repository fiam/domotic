locals {
  helm_release_name = "app"
  mqtt_server       = "${local.helm_release_name}-mosquitto.${var.kubernetes_namespace}.svc.cluster.local"
}
resource "helm_release" "_" {
  depends_on = [kubernetes_secret.cloudflared_tunnel_token_secret]
  namespace  = var.kubernetes_namespace
  name       = local.helm_release_name
  chart      = "../domotic"
  #    atomic = true
  create_namespace = true
  cleanup_on_fail  = true

  set = [
    {
      name  = "homeassistant.config.external_url",
      value = "https://${local.home_assistant_external_hostname}"
    },
    {
      name  = "homeassistant.config.mqtt.server",
      value = local.mqtt_server
    },
    {
      name  = "zigbee2mqtt.config.serial.port",
      value = var.serial_port
    },
    {
      name  = "zigbee2mqtt.config.serial.adapter",
      value = var.serial_adapter
    },
    {
      name  = "zigbee2mqtt.config.mqtt.server",
      value = local.mqtt_server
    },
    {
      name  = "zigbee2mqtt.config.pan_id",
      value = var.zigbee_pan_id
    },
    {
      name  = "zigbee2mqtt.config.channel",
      value = var.zigbee_channel
    }
  ]

  set_sensitive = [{
    name  = "zigbee2mqtt.config.ext_pan_id"
    value = var.zigbee_ext_pan_id
    }, {
    name  = "zigbee2mqtt.config.network_key"
    value = var.zigbee_network_key
  }]
}
