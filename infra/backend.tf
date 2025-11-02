terraform {
  backend "kubernetes" {
    secret_suffix = "domotic-infra"
  }
}
