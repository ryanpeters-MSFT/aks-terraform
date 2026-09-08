# grant the current Azure user cluster-admin access
$group = "rg-aks-terraform"
$cluster = "aksterraform"

$env:TF_VAR_subscriptionId = az account show --query id -o tsv
$env:TF_VAR_tenantId = az account show --query tenantId -o tsv
$userId = az ad signed-in-user show --query id -o tsv
$clusterId = az aks show -g $group -n $cluster --query id -o tsv

az role assignment create --assignee-object-id $userId --assignee-principal-type User --role "Azure Kubernetes Service Cluster User Role" --scope $clusterId -o none
az role assignment create --assignee-object-id $userId --assignee-principal-type User --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $clusterId -o none

az aks get-credentials -g $group -n $cluster --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

Write-Host "Cluster-admin access configured. Run .\connect.ps1, then kubectl get nodes in the child PowerShell."
