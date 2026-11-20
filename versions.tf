terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vsphere = { source = "vmware/vsphere", version = "~> 2.14" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
    sccfm   = { source = "CiscoDevNet/sccfm", version = "~> 0.5" }
    fmc     = { source = "CiscoDevNet/fmc", version = "~> 2.2" }
  }
}

# LAB ONLY: credentials are read directly from terraform.tfvars.
# Production should use a secrets manager / protected runtime injection.
provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_username
  password             = var.vcenter_password
  allow_unverified_ssl = var.vcenter_allow_unverified_ssl
}

# SCC registration/onboarding. Keep the base URL appropriate for your region.
provider "sccfm" {
  base_url  = var.scc_base_url
  api_token = var.scc_api_token
}

# cdFMC cluster management provider is configured for the next development phase.
# No fmc_device_cluster resource exists in this scaffold yet.
provider "fmc" {
  url      = var.fmc_url
  token    = var.fmc_api_token
  insecure = var.fmc_insecure
}
