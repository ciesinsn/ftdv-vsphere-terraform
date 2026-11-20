# LAB-ONLY AUTHENTICATION: enter values in terraform.tfvars (gitignored).
variable "vcenter_server" {
  type = string
}
variable "vcenter_username" {
  type = string
}
variable "vcenter_password" {
  type      = string
  sensitive = true
}
variable "vcenter_allow_unverified_ssl" {
  type    = bool
  default = false
}

variable "scc_base_url" {
  type = string
}
variable "scc_api_token" {
  type      = string
  sensitive = true
}

# cdFMC/FMC provider for future cluster membership management.
# For cdFMC, fmc_url should be the regional /firewall base URI.
variable "fmc_url" {
  type = string
}
variable "fmc_api_token" {
  type      = string
  sensitive = true
}
variable "fmc_insecure" {
  type    = bool
  default = false
}

variable "datacenter" {
  type = string
}
variable "cluster" {
  type = string
}
variable "datastore" {
  type = string
}
variable "host" {
  type = string
}
variable "resource_pool" {
  description = "Optional resource pool name. If null, use the cluster's Resources root pool."
  type        = string
  default     = null
}
variable "ftdv_ovf_path" {
  description = "Absolute path to Cisco's licensed vCenter-compatible FTDv OVF. Keep all associated VMDKs alongside it."
  type        = string
}
variable "ovf_network_mapping" {
  description = "Cisco OVF network label => role (management, diagnostic, inside, outside, ccl). Inspect OVF and set exact labels."
  type        = map(string)
}
variable "network_roles_order" {
  description = "VM NIC order matching Cisco's OVF for YOUR release; confirm via OVF descriptor."
  type        = list(string)
}
variable "portgroups" {
  description = "Network role => existing vSphere port group name."
  type        = map(string)
}
variable "desired_nodes" {
  type    = number
  default = 2
  validation {
    condition     = var.desired_nodes >= 1 && var.desired_nodes <= 16 && floor(var.desired_nodes) == var.desired_nodes
    error_message = "desired_nodes must be an integer from 1 to 16; confirm your FTDv version and tier's cluster limits."
  }
}
variable "name_prefix" {
  type    = string
  default = "ftdv-lab"
}
variable "management_cidr" {
  type    = string
  default = "192.168.10.0/24"
}
variable "management_first_host" {
  type    = number
  default = 11
}
variable "management_gateway" {
  type = string
}
variable "dns1" {
  type = string
}
variable "dns2" {
  type    = string
  default = ""
}
variable "fmc_address" {
  type = string
}
variable "registration_key" {
  description = "Used in static/manual FMC mode. In SCC mode registration keys are generated per device."
  type        = string
  sensitive   = true
  default     = null
}
variable "registration_nat_id_prefix" {
  type    = string
  default = "ftdv-lab"
}
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "enable_scc_onboarding" {
  description = "When true, reuse the previous CLUS26 SCC device registration pattern. Requires SCCFM credentials."
  type        = bool
  default     = false
}
variable "ftd_boot_wait_seconds" {
  description = "Deprecated and ignored; readiness is checked over SSH instead."
  type        = number
  default     = 120
  validation {
    condition     = var.ftd_boot_wait_seconds >= 0 && floor(var.ftd_boot_wait_seconds) == var.ftd_boot_wait_seconds
    error_message = "ftd_boot_wait_seconds must be a non-negative integer."
  }
}
variable "ftd_readiness_timeout_seconds" {
  description = "Maximum time to wait for FTD SSH and SCC manager configuration."
  type        = number
  default     = 1800
  validation {
    condition     = var.ftd_readiness_timeout_seconds >= 1 && floor(var.ftd_readiness_timeout_seconds) == var.ftd_readiness_timeout_seconds
    error_message = "ftd_readiness_timeout_seconds must be a positive integer."
  }
}
variable "scc_access_policy_name" {
  description = "Existing SCC/FMC access policy for the onboarded devices."
  type        = string
  default     = null
}
variable "scc_performance_tier" {
  type    = string
  default = "FTDv30"
}
variable "cpu" {
  type    = number
  default = 8
}
variable "memory_mb" {
  type    = number
  default = 16384
}
variable "vm_folder" {
  type    = string
  default = null
}
variable "iso_datastore_folder" {
  type    = string
  default = "ftdv-day0"
}
variable "power_on" {
  description = "Deprecated and ignored; SCC onboarding is controlled by enable_scc_onboarding. This does not control VM power."
  type        = bool
  default     = false
}
variable "acknowledge_vm_removal_risk" {
  type        = bool
  default     = false
  description = "Reserved for future scale-in controls; currently has no effect."
}
