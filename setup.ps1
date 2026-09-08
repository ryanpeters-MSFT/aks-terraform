# initialize and provision the Terraform configuration
$env:TF_VAR_subscriptionId = az account show --query id -o tsv
$env:TF_VAR_tenantId = az account show --query tenantId -o tsv
terraform init -upgrade
terraform fmt -check
terraform validate
terraform plan -out main.tfplan
terraform apply main.tfplan
