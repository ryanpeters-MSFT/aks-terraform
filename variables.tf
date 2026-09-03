variable "subscriptionId" {
  type = string
}

variable "group" {
  type    = string
  default = "rg-aks-terraform"
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "clusterName" {
  type    = string
  default = "aksterraformsuggested"
}

variable "kubernetesVersion" {
  type    = string
  default = "1.36"
}

variable "nodeCount" {
  type    = number
  default = 3
}

variable "vmSize" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "userVmProfiles" {
  type = list(object({
    count = number
    size  = string
  }))
  default = [
    {
      count = 2
      size  = "Standard_D2s_v5"
    },
    {
      count = 1
      size  = "Standard_D4s_v5"
    }
  ]
}

variable "vnetCidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "nodeSubnetCidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "apiServerSubnetCidr" {
  type    = string
  default = "10.0.1.0/28"
}

variable "bastionSubnetCidr" {
  type    = string
  default = "10.0.2.0/26"
}

variable "podCidr" {
  type    = string
  default = "10.244.0.0/16"
}

variable "serviceCidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "dnsServiceIp" {
  type    = string
  default = "10.2.0.10"
}