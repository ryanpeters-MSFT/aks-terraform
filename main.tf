provider "azurerm" {
  features {}

  subscription_id = var.subscriptionId
}

provider "azapi" {
  subscription_id = var.subscriptionId
}

# create network and identity prerequisites
resource "azurerm_resource_group" "rg_aks" {
  name     = var.group
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.clusterName}"
  location            = azurerm_resource_group.rg_aks.location
  resource_group_name = azurerm_resource_group.rg_aks.name
  address_space       = [var.vnetCidr]
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.rg_aks.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.nodeSubnetCidr]
}

resource "azurerm_subnet" "apiServer" {
  name                 = "snet-aks-apiserver"
  resource_group_name  = azurerm_resource_group.rg_aks.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.apiServerSubnetCidr]

  delegation {
    name = "aks-apiserver"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.rg_aks.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.bastionSubnetCidr]
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = "aksidentity"
  location            = azurerm_resource_group.rg_aks.location
  resource_group_name = azurerm_resource_group.rg_aks.name
}

resource "azurerm_role_assignment" "nodeNetwork" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "apiServerNetwork" {
  scope                = azurerm_subnet.apiServer.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# create private AKS with API server VNet integration and CNI Overlay
resource "azurerm_kubernetes_cluster" "main" {
  name                                = var.clusterName
  location                            = azurerm_resource_group.rg_aks.location
  resource_group_name                 = azurerm_resource_group.rg_aks.name
  dns_prefix                          = var.clusterName
  kubernetes_version                  = var.kubernetesVersion
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = "System"
  oidc_issuer_enabled                 = true
  workload_identity_enabled           = true
  role_based_access_control_enabled   = true
  local_account_disabled              = true

  default_node_pool {
    name                         = "system"
    node_count                   = var.nodeCount
    vm_size                      = var.vmSize
    os_sku                       = "AzureLinux3"
    orchestrator_version         = var.kubernetesVersion
    vnet_subnet_id               = azurerm_subnet.nodes.id
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtemp"
    zones                        = ["1", "2", "3"]

    upgrade_settings {
      max_surge = "10%"
    }
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenantId
  }

  api_server_access_profile {
    subnet_id                           = azurerm_subnet.apiServer.id
    virtual_network_integration_enabled = true
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.podCidr
    service_cidr        = var.serviceCidr
    dns_service_ip      = var.dnsServiceIp
    load_balancer_sku   = "standard"
  }

  depends_on = [
    azurerm_role_assignment.nodeNetwork,
    azurerm_role_assignment.apiServerNetwork
  ]
}

# enable managed Gateway API with only the App Routing Istio implementation
resource "azapi_update_resource" "gatewayApi" {
  type        = "Microsoft.ContainerService/managedClusters@2026-04-01"
  resource_id = azurerm_kubernetes_cluster.main.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          enabled = true
          nginx = {
            defaultIngressControllerType = "None"
          }
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }
}

# create the generic workload identity and trust its Kubernetes service account
resource "azurerm_user_assigned_identity" "workloaduser" {
  name                = "workloaduser"
  location            = azurerm_resource_group.rg_aks.location
  resource_group_name = azurerm_resource_group.rg_aks.name
}

resource "azurerm_federated_identity_credential" "workloaduser" {
  name                      = "workloaduser"
  user_assigned_identity_id = azurerm_user_assigned_identity.workloaduser.id
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.workloadNamespace}:workloaduser"
  audience                  = ["api://AzureADTokenExchange"]
}

# create VMSS and Virtual Machines user pools
resource "azurerm_kubernetes_cluster_node_pool" "appspool" {
  name                  = "appspool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.vmSize
  auto_scaling_enabled  = true
  min_count             = 2
  max_count             = 6
  mode                  = "User"
  os_sku                = "AzureLinux3"
  orchestrator_version  = var.kubernetesVersion
  vnet_subnet_id        = azurerm_subnet.nodes.id
  node_taints           = ["workload=apps:NoSchedule"]
  zones                 = ["1", "2", "3"]

  upgrade_settings {
    max_surge = "10%"
  }
}

resource "azapi_resource" "uservms" {
  type      = "Microsoft.ContainerService/managedClusters/agentPools@2025-10-01"
  name      = "uservms"
  parent_id = azurerm_kubernetes_cluster.main.id

  body = {
    properties = {
      mode                = "User"
      orchestratorVersion = var.kubernetesVersion
      osSKU               = "AzureLinux3"
      osType              = "Linux"
      type                = "VirtualMachines"
      vnetSubnetID        = azurerm_subnet.nodes.id
      virtualMachinesProfile = {
        scale = {
          manual = [
            for profile in var.userVmProfiles : {
              count = profile.count
              size  = profile.size
            }
          ]
        }
      }
    }
  }
}

# create Bastion for direct private AKS access
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.rg_aks.location
  resource_group_name = azurerm_resource_group.rg_aks.name
  allocation_method   = "Static"
  sku                 = "Standard"

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_bastion_host" "main" {
  name                = "bas-aks"
  location            = azurerm_resource_group.rg_aks.location
  resource_group_name = azurerm_resource_group.rg_aks.name
  sku                 = "Standard"
  tunneling_enabled   = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

output "cluster_version" {
  value = azurerm_kubernetes_cluster.main.current_kubernetes_version
}

output "bastion_id" {
  value = azurerm_bastion_host.main.id
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.workloaduser.client_id
}
