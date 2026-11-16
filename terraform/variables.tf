variable "region" {
  description = "Azure region for the VMs"
  type        = string
  default     = "westeurope"
}

variable "ec_region" {
  description = "Elastic Cloud Serverless region ID (azure-westeurope is not offered; see GET /api/v1/serverless/regions)"
  type        = string
  default     = "azure-northeurope"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "elastic-security-logs"
}

variable "agent_version" {
  description = "Elastic Agent version installed on the VMs. Must not exceed the version the Serverless project runs"
  type        = string
  default     = "9.5.6"
}

variable "security_tier" {
  description = "Security project feature tier: essentials or complete (Automatic Import needs complete)"
  type        = string
  default     = "complete"
}

variable "linux_vm_size" {
  description = "Linux VM size"
  type        = string
  default     = "Standard_B2s"
}

variable "windows_vm_size" {
  description = "Windows VM size"
  type        = string
  default     = "Standard_B2ms"
}

variable "admin_username" {
  description = "Admin username for both VMs"
  type        = string
  default     = "azureuser"
}

variable "encryption_at_host" {
  description = "Enable encryption at host. Requires `az feature show --namespace Microsoft.Compute --name EncryptionAtHost` = Registered"
  type        = bool
  default     = false
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach SSH/RDP/WinRM. Empty = auto-detect your public IP /32"
  type        = string
  default     = ""
}

variable "sysmon_config_url" {
  description = "Sysmon configuration XML"
  type        = string
  default     = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
}

variable "tags" {
  description = "Tags applied to all Azure resources. Required by subscription policy (e.g. team, division). No default on purpose: set values in the gitignored terraform.tfvars."
  type        = map(string)
}
