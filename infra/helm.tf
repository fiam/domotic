resource "helm_release" "_" {
    namespace = var.kubernetes_namespace
    name = "foo"
    chart = "../domotic"
    atomic = true
    create_namespace = true
}
