# AKS Terraform

Provisions private cluster `aksterraformsuggested` in `centralus` with Azure CNI Overlay, API server VNet integration, VMSS and Virtual Machines user pools, and Azure Bastion. Terraform state is stored locally.

```powershell
.\setup.ps1
```

The script uses the active Azure CLI subscription, initializes the latest AzureRM 5.x provider, validates the configuration, and applies the generated plan.

Run `./connect.ps1` to connect directly to the private cluster through Azure Bastion. The command opens a child PowerShell with a temporary kubeconfig; run `kubectl` in that child shell and use `exit` to close the tunnel.

This workflow requires the Azure CLI `aks-preview` and `bastion` extensions. The working command is `az aks bastion tunnel`; the bare `az aks bastion` command shown in some Microsoft Learn examples is a command group in current Azure CLI versions.
