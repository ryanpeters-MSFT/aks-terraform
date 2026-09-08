# Baseline-Informed Private AKS with Terraform

This repository provides an opinionated, baseline-informed Terraform foundation for private Azure Kubernetes Service (AKS). It adopts Microsoft-recommended cluster identity, networking, availability-zone, workload-isolation, and managed Gateway API patterns, but it is not a complete implementation of the Microsoft AKS baseline architecture or a production-ready landing zone.

The repository provisions the AKS foundation and a sample workload. The default values create `aksterraformsuggested` in `centralus`. Terraform state and saved plans are stored locally.

## Architecture

The Terraform configuration creates:

- A private AKS cluster with API Server VNet Integration.
- Azure CNI Overlay powered by Cilium, including Cilium network-policy enforcement.
- Microsoft Entra authentication, Azure RBAC for Kubernetes authorization, and disabled local accounts.
- An OIDC issuer and Microsoft Entra Workload ID.
- The managed Kubernetes Gateway API with the App Routing Istio implementation.
- No managed NGINX ingress controller; Istio and Envoy provide ingress for Gateways that use the `approuting-istio` GatewayClass.
- A zone-spanning system node pool and an autoscaling, zone-spanning `appspool` VMSS user pool.
- An optional, disabled-by-default heterogeneous `VirtualMachines` user pool example based on `userVmProfiles`.
- Azure Bastion Standard with native-client tunneling for access to the private API server.
- A user-assigned managed identity and federated credential for the sample Kubernetes service account.

The App Routing Gateway API implementation is ingress-only. It deploys `istiod` as its managed control plane, but it is not the AKS Istio service-mesh add-on and does not provide sidecar injection or general east-west service-mesh features. Each `Gateway` using `approuting-istio` causes AKS to create an Envoy proxy deployment, LoadBalancer service, autoscaler, and disruption budget in the Gateway's namespace.

## Prerequisites

- Terraform 1.10 or later.
- Azure CLI authenticated with `az login`.
- An Azure subscription selected with `az account set`.
- The Azure CLI `aks-preview` extension, which provides `az aks bastion tunnel`.
- `kubectl` and `kubelogin` for cluster access.
- Permission to create the Azure resources and subnet-scoped role assignments in the configuration.
- For cluster access, the signed-in principal needs permission to retrieve AKS user credentials and an Azure Kubernetes Service RBAC role at the cluster or narrower scope.

Install or update the required extension:

```powershell
az extension add -n aks-preview --upgrade
```

Azure Bastion must use the Standard or Premium SKU with native-client tunneling enabled. This repository configures a Standard Bastion host with tunneling enabled. Microsoft documents Reader access to the AKS cluster and Bastion resource as the minimum management-plane access for the tunnel, plus Reader on the AKS virtual network when Bastion is in a peered virtual network.

## Deploy

Review the defaults in `variables.tf`, then run:

```powershell
.\setup.ps1
```

The script:

1. Reads the subscription and tenant IDs from the active Azure CLI session.
2. Initializes and upgrades providers within the configured version constraints.
3. Checks formatting and validates the Terraform configuration.
4. Creates `main.tfplan`.
5. Prompts before applying the saved plan.

To select a different subscription before deployment:

```powershell
az account set --subscription <SUBSCRIPTION_ID>
```

If you override `group` or `clusterName`, update the matching values in `connect.ps1`, which currently uses the repository defaults.

The configuration uses local Terraform state. Protect `terraform.tfstate`, backup state, and saved plan files because they can contain sensitive infrastructure data. Do not edit state files manually.

### Optional Virtual Machines agent pool

The `azapi_resource.uservms` block in `main.tf` is commented out by default. To create an AKS agent pool that uses the `VirtualMachines` type instead of VMSS, uncomment the complete block and customize `userVmProfiles` in `variables.tf`. Each profile specifies a VM size and node count for the heterogeneous pool.

Always review the Terraform plan after enabling or disabling this block. If the pool is already tracked in Terraform state, commenting out the block schedules that existing agent pool for destruction on the next apply.

## Connect to the private cluster

Run:

```powershell
.\connect.ps1
```

The script calls `az aks bastion tunnel` with the provisioned Bastion resource. The command retrieves a temporary user kubeconfig and opens a child PowerShell configured to use the tunnel. Run `kubectl` commands in that child shell and enter `exit` when finished.

Do not use AKS admin credentials or `--admin`; local accounts are disabled. The signed-in Microsoft Entra principal must have appropriate Azure RBAC permissions for the requested Kubernetes operations.

Verify access from the child shell:

```powershell
kubectl get nodes
```

## Deploy the sample workload

The `app` directory contains:

- A `workloaduser` ServiceAccount configured for Microsoft Entra Workload ID.
- A three-replica Deployment pinned to the dedicated `appspool` node pool.
- Required toleration for the pool's `workload=apps:NoSchedule` taint.
- Topology spread constraints across nodes and availability zones with `maxSkew: 1`.
- A ClusterIP Service.
- A Gateway using the managed `approuting-istio` GatewayClass.
- An HTTPRoute for `workload.example.com`.

The sample manifests use the `default` namespace. Keep `workloadNamespace` set to its default value or add the same namespace to every sample manifest so the federated credential subject and Kubernetes service account remain aligned.

From the child PowerShell opened by `connect.ps1`, inject the managed identity client ID and apply the manifests:

```powershell
$clientId = terraform output -raw workload_identity_client_id

(Get-Content .\app\service-account.yaml) `
	-replace '<WORKLOAD_IDENTITY_CLIENT_ID>', $clientId |
	kubectl apply -f -

kubectl apply `
	-f .\app\deployment.yaml `
	-f .\app\service.yaml `
	-f .\app\gateway.yaml `
	-f .\app\http-route.yaml
```

The ServiceAccount annotation selects the user-assigned managed identity, and the required `azure.workload.identity/use: "true"` pod label enables token injection. The Terraform configuration creates the trust relationship but does not grant the identity access to any Azure data-plane resource; add workload-specific Azure role assignments when the application needs them.

Wait for the workload and gateway to become ready:

```powershell
kubectl rollout status deployment/workload
kubectl wait --for=condition=Programmed gateway/workload --timeout=5m
kubectl get gateway workload
kubectl get deployment workload-approuting-istio
```

The example hostname is intentionally not published in DNS. Get the Gateway address and test it with the expected Host header:

```powershell
$gatewayAddress = kubectl get gateway workload -o jsonpath='{.status.addresses[0].value}'
curl.exe -H 'Host: workload.example.com' "http://$gatewayAddress/"
```

## Verify managed networking and ingress

Check the Azure-side configuration:

```powershell
az aks show `
	-g rg-aks-terraform `
	-n aksterraformsuggested `
	--query '{state:provisioningState,dataPlane:networkProfile.networkDataplane,policy:networkProfile.networkPolicy,ingress:ingressProfile}'
```

Expected networking values are `cilium` for both `dataPlane` and `policy`. Under the ingress profile, Gateway API is installed, App Routing Istio is enabled, and the default NGINX controller type is `None`.

From the Bastion child shell, verify the managed Istio components:

```powershell
kubectl get gatewayclass approuting-istio
kubectl get deployment istiod -n aks-istio-system
kubectl get gateway,httproute
kubectl get deployment workload-approuting-istio
```

`istiod` configures Gateway API resources; `workload-approuting-istio` is the generated Envoy ingress data plane for the sample `workload` Gateway.

## References

- [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [Application Routing with Gateway API and Istio](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)
- [Microsoft Entra Workload ID for AKS](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Azure CLI: `az aks bastion tunnel`](https://learn.microsoft.com/cli/azure/aks/bastion#az-aks-bastion-tunnel)
- [Connect to a private AKS cluster with Azure Bastion](https://learn.microsoft.com/azure/bastion/bastion-connect-to-aks-private-cluster)
