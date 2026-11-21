data "vsphere_datacenter" "dc" { name = var.datacenter }
data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_datastore" "store" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_host" "host" {
  name          = var.host
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_resource_pool" "pool" {
  name          = var.resource_pool == null ? "${var.cluster}/Resources" : var.resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_network" "portgroup" {
  for_each      = var.portgroups
  name          = each.value
  datacenter_id = data.vsphere_datacenter.dc.id
}

locals {
  nodes = {
    for n in range(var.desired_nodes) :
    format("%s-%02d", var.name_prefix, n + 1) => {
      ordinal = n + 1
      mgmt_ip = cidrhost(var.management_cidr, var.management_first_host + n)
      # Stable name and address for scale-out. Never renumber surviving nodes.
      nat_id = format("%s-%02d", var.registration_nat_id_prefix, n + 1)
    }
  }
  role_network_ids = { for role, net in data.vsphere_network.portgroup : role => net.id }
  ovf_network_ids = {
    for ovf_label, role in var.ovf_network_mapping :
    ovf_label => local.role_network_ids[role]
  }
}

# Onboarding based on the same SCCFM resources used in DEVNET-2150 CLUS26.
# This creates registrations, NOT the private-cloud FMC cluster itself.
resource "sccfm_ftd_device" "device" {
  for_each = var.enable_scc_onboarding ? local.nodes : {}

  name               = each.key
  access_policy_name = var.scc_access_policy_name
  virtual            = true
  performance_tier   = var.scc_performance_tier
  licenses           = ["BASE", "MALWARE", "URLFilter", "THREAT"]

  lifecycle {
    precondition {
      condition     = try(length(trimspace(var.scc_access_policy_name)) > 0, false)
      error_message = "Set scc_access_policy_name to an existing cdFMC access control policy before enabling SCC onboarding."
    }
  }
}

locals {
  day0_payload = {
    for name, node in local.nodes : name => {
      EULA               = "accept"
      Hostname           = name
      AdminPassword      = var.admin_password
      FirewallMode       = "routed"
      DNS1               = var.dns1
      DNS2               = var.dns2
      DNS3               = ""
      IPv4Mode           = "Manual"
      IPv4Addr           = node.mgmt_ip
      IPv4Mask           = cidrnetmask(var.management_cidr)
      IPv4Gw             = var.management_gateway
      IPv6Mode           = "disabled"
      IPv6Addr           = ""
      IPv6Mask           = ""
      IPv6Gw             = ""
      DeploymentType     = "Cluster"
      ManageLocally      = "No"
      FmcIp              = var.enable_scc_onboarding ? sccfm_ftd_device.device[name].hostname : var.fmc_address
      FmcRegKey          = var.enable_scc_onboarding ? sccfm_ftd_device.device[name].reg_key : var.registration_key
      FmcNatId           = var.enable_scc_onboarding ? sccfm_ftd_device.device[name].nat_id : node.nat_id
      Diagnostic         = "ON"
      IfNamingConvention = "New"
    }
  }
}

# Sensitive data is embedded in these files and in the resulting ISO.
resource "local_sensitive_file" "day0" {
  for_each = local.day0_payload
  filename = "${path.module}/.generated/${each.key}/day0-config"
  content = "#Secure Firewall Threat Defense\n{\n${join(",\n", [
    for key in [
      "EULA", "Hostname", "AdminPassword", "FirewallMode", "DNS1", "DNS2", "DNS3",
      "IPv4Mode", "IPv4Addr", "IPv4Mask", "IPv4Gw", "IPv6Mode", "IPv6Addr", "IPv6Mask", "IPv6Gw",
      "DeploymentType", "FmcIp", "FmcRegKey", "FmcNatId", "ManageLocally", "Diagnostic", "IfNamingConvention"
    ] : format("    %s: %s", jsonencode(key), jsonencode(each.value[key]))
  ])}\n}\n"
  file_permission = "0600"
}

# A local tool is required to produce an ISO; native Terraform doesn't encode ISOs.
resource "terraform_data" "iso" {
  for_each         = local.nodes
  triggers_replace = [local_sensitive_file.day0[each.key].content_sha256]
  provisioner "local-exec" {
    command     = "${path.module}/scripts/make-day0-iso.sh"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SOURCE = local_sensitive_file.day0[each.key].filename
      OUTPUT = "${path.module}/.generated/${each.key}/day0.iso"
    }
  }
}

resource "vsphere_file" "day0_iso" {
  for_each         = local.nodes
  datacenter       = var.datacenter
  datastore        = var.datastore
  source_file      = "${path.module}/.generated/${each.key}/day0.iso"
  destination_file = "${var.iso_datastore_folder}/${each.key}/day0.iso"
  depends_on       = [terraform_data.iso]
  lifecycle {
    replace_triggered_by = [terraform_data.iso[each.key]]
  }
}

resource "vsphere_virtual_machine" "ftdv" {
  for_each                   = local.nodes
  name                       = each.key
  datacenter_id              = data.vsphere_datacenter.dc.id
  resource_pool_id           = data.vsphere_resource_pool.pool.id
  datastore_id               = data.vsphere_datastore.store.id
  host_system_id             = data.vsphere_host.host.id
  folder                     = var.vm_folder
  num_cpus                   = var.cpu
  memory                     = var.memory_mb
  firmware                   = "efi"      # Match the Cisco FTDv 10.1 OVF.
  efi_secure_boot_enabled    = false      # Match the OVF's boot options.
  scsi_type                  = "lsilogic" # Match the controller specified by the Cisco OVF.
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  dynamic "network_interface" {
    for_each = var.network_roles_order
    content {
      network_id   = local.role_network_ids[network_interface.value]
      adapter_type = "vmxnet3"
    }
  }

  ovf_deploy {
    local_ovf_path    = var.ftdv_ovf_path
    disk_provisioning = "thin"
    ovf_network_map   = local.ovf_network_ids
  }

  # The Cisco VI OVF requires this vApp property before vSphere permits power-on.
  vapp {
    properties = {
      pw = var.admin_password
    }
  }

  cdrom {
    datastore_id = data.vsphere_datastore.store.id
    path         = vsphere_file.day0_iso[each.key].destination_file
  }

  lifecycle {
    precondition {
      condition     = alltrue([for role in var.network_roles_order : contains(keys(var.portgroups), role)])
      error_message = "Every network_roles_order item must have a corresponding portgroups entry."
    }
    precondition {
      condition     = alltrue([for role in values(var.ovf_network_mapping) : contains(keys(var.portgroups), role)])
      error_message = "Every OVF network mapping role must have a corresponding portgroups entry."
    }
    precondition {
      condition     = var.enable_scc_onboarding || var.registration_key != null
      error_message = "Provide registration_key or enable_scc_onboarding."
    }
  }
}

# Wait until SSH responds and the FTD has configured its SCC manager.
resource "terraform_data" "ftd_readiness" {
  for_each         = var.enable_scc_onboarding ? local.nodes : {}
  input            = sccfm_ftd_device.device[each.key].id
  triggers_replace = [vsphere_virtual_machine.ftdv[each.key].id, sccfm_ftd_device.device[each.key].id, var.ftd_readiness_timeout_seconds, filesha256("${path.module}/scripts/wait-for-ftd.py"), filesha256("${path.module}/scripts/check-ftd-ssh.exp")]
  provisioner "local-exec" {
    command = "python3 '${path.module}/scripts/wait-for-ftd.py'"
    environment = {
      FTD_ADDRESS       = each.value.mgmt_ip
      FTD_USERNAME      = "admin"
      FTD_PASSWORD      = var.admin_password
      FTD_MANAGER       = sccfm_ftd_device.device[each.key].hostname
      FTD_TIMEOUT       = tostring(var.ftd_readiness_timeout_seconds)
      FTD_KNOWN_HOSTS   = abspath("${path.module}/.generated/${each.key}/known_hosts-${vsphere_virtual_machine.ftdv[each.key].id}")
      FTD_EXPECT_SCRIPT = abspath("${path.module}/scripts/check-ftd-ssh.exp")
    }
  }
}

resource "sccfm_ftd_device_onboarding" "device" {
  for_each = var.enable_scc_onboarding ? local.nodes : {}
  ftd_uid  = terraform_data.ftd_readiness[each.key].output
}

# Verify the SCC inventory state after the provider's onboarding transaction.
resource "terraform_data" "ftd_onboarding_wait" {
  for_each         = var.enable_scc_onboarding ? local.nodes : {}
  triggers_replace = [sccfm_ftd_device_onboarding.device[each.key].id, var.scc_online_timeout_seconds, filesha256("${path.module}/scripts/wait-for-scc-online.py")]
  provisioner "local-exec" {
    command = "python3 '${path.module}/scripts/wait-for-scc-online.py'"
    environment = {
      SCC_BASE_URL   = var.scc_base_url
      SCC_API_TOKEN  = var.scc_api_token
      SCC_DEVICE_UID = sccfm_ftd_device.device[each.key].id
      SCC_TIMEOUT    = tostring(var.scc_online_timeout_seconds)
    }
  }
}

# cdFMC uses different identifiers from SCC; look up registered devices by name.
data "fmc_device" "cluster_node" {
  for_each   = var.enable_ftd_cluster ? local.nodes : {}
  name       = each.key
  depends_on = [terraform_data.ftd_onboarding_wait]
}

data "fmc_device_physical_interface" "cluster_control_link" {
  count     = var.enable_ftd_cluster ? 1 : 0
  device_id = data.fmc_device.cluster_node[format("%s-%02d", var.name_prefix, 1)].id
  name      = var.ftd_cluster_ccl_interface
}

resource "fmc_device_cluster" "ftdv" {
  count = var.enable_ftd_cluster ? 1 : 0

  name                          = var.ftd_cluster_name
  cluster_key                   = var.ftd_cluster_key
  control_node_device_id        = data.fmc_device.cluster_node[format("%s-%02d", var.name_prefix, 1)].id
  control_node_interface_id     = data.fmc_device_physical_interface.cluster_control_link[0].id
  control_node_interface_name   = var.ftd_cluster_ccl_interface
  control_node_interface_type   = data.fmc_device_physical_interface.cluster_control_link[0].type
  control_node_ccl_prefix       = var.ftd_cluster_vtep_cidr
  control_node_vni_prefix       = var.ftd_cluster_vni_cidr
  control_node_ccl_ipv4_address = cidrhost(var.ftd_cluster_vtep_cidr, 1)
  control_node_priority         = 1
  data_nodes = [for name in sort(keys(local.nodes)) : {
    device_id        = data.fmc_device.cluster_node[name].id
    ccl_ipv4_address = cidrhost(var.ftd_cluster_vtep_cidr, local.nodes[name].ordinal)
    priority         = local.nodes[name].ordinal
  } if local.nodes[name].ordinal > 1 && local.nodes[name].ordinal <= var.ftd_cluster_members]

  lifecycle {
    precondition {
      condition     = var.enable_scc_onboarding && var.ftd_cluster_members <= var.desired_nodes && var.ftd_cluster_key != null
      error_message = "Cluster formation requires SCC onboarding, ftd_cluster_key, and ftd_cluster_members no greater than desired_nodes."
    }
    precondition {
      condition     = var.ftd_cluster_vtep_cidr != "192.0.2.0/27" && var.ftd_cluster_vni_cidr != "198.51.100.0/27" && var.ftd_cluster_vtep_cidr != var.ftd_cluster_vni_cidr
      error_message = "Replace the example VTEP and VNI subnets with separate, usable networks before enabling the cluster."
    }
  }
}

output "node_management_ips" {
  value = { for name, node in local.nodes : name => node.mgmt_ip }
}
output "vm_ids" {
  value = { for name, vm in vsphere_virtual_machine.ftdv : name => vm.id }
}
output "ftd_cluster_id" {
  description = "cdFMC cluster identifier, when cluster management is enabled."
  value       = try(fmc_device_cluster.ftdv[0].id, null)
}
output "day0_iso_datastore_paths" {
  value = { for name, f in vsphere_file.day0_iso : name => f.destination_file }
}
