# initialize and provision the Terraform configuration
$env:TF_VAR_subscriptionId = az account show --query id -o tsv
terraform init -upgrade
terraform fmt -check
terraform validate
terraform plan -out main.tfplan
terraform apply main.tfplan
