# Infra Terraform Project

1. Create the namespace that will hold the Terraform state if it does not already exist:

   ```sh
   kubectl create namespace terraform-state
   ```

2. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the Cloudflare API token.
3. Optionally, set your Kubernetes configuration:
   1. Use `$KUBE_CONFIG_PATH` to override the path to the Kubernetes configuration
   2. Use `$KUBE_CTX` to override the Kubernetes context.

4. Run Terraform as usual:

   ```sh
   terraform init
   terraform plan
   terraform apply
   ```
