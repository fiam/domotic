terraform {
  backend "kubernetes" {
    secret_suffix    = "domotic-infra"
    config_path      = "~/.kube/config"
  }
}
