# connect directly to the private AKS cluster through Bastion
$group = "rg-aks-terraform"
$cluster = "aksterraformsuggested"
$bastionId = terraform output -raw bastion_id

Write-Host "Opening a child PowerShell with the tunnel kubeconfig. Run kubectl there; exit closes the tunnel."
az aks bastion tunnel -g $group -n $cluster --bastion $bastionId --yes

if ($LASTEXITCODE -ne 0) {
	throw "AKS Bastion tunnel failed with exit code $LASTEXITCODE."
}