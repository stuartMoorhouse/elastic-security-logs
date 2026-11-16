resource "tls_private_key" "linux" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "linux_ssh_key" {
  content         = tls_private_key.linux.private_key_openssh
  filename        = "${path.module}/.secrets/linux_vm_key.pem"
  file_permission = "0600"
}

resource "random_password" "windows" {
  length           = 24
  special          = true
  override_special = "!@#%^*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_linux_virtual_machine" "linux" {
  tags = var.tags
  #checkov:skip=CKV_AZURE_50:Agent is installed via custom_data, no VM extension is used; check is a false positive for this resource type
  name                            = "${var.prefix}-linux"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.linux_vm_size
  priority                        = "Regular"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  encryption_at_host_enabled      = var.encryption_at_host
  network_interface_ids           = [azurerm_network_interface.linux.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.linux.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/templates/linux-bootstrap.sh.tftpl", {
    agent_version    = var.agent_version
    fleet_url        = local.fleet_url
    enrollment_token = local.linux_enrollment_token
  }))

  # custom_data only runs at first boot. The Fleet data sources depend on ec_security_project.main, so any
  # in-place deployment update makes custom_data "known after apply" and would otherwise force a VM
  # replacement. To roll out a bootstrap change deliberately, use `terraform apply -replace=...`.
  lifecycle {
    ignore_changes = [custom_data]
  }
}

resource "azurerm_windows_virtual_machine" "windows" {
  tags = var.tags
  #checkov:skip=CKV_AZURE_50:Bootstrap uses Run Command, not a VM extension
  #checkov:skip=CKV_AZURE_151:Encryption at host is opt-in via var.encryption_at_host (needs subscription feature registration); managed disks are still encrypted at rest with platform-managed keys
  name                       = "win-${substr(replace(var.prefix, "-", ""), 0, 8)}"
  computer_name              = "winws01"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  size                       = var.windows_vm_size
  priority                   = "Regular"
  admin_username             = var.admin_username
  admin_password             = random_password.windows.result
  encryption_at_host_enabled = var.encryption_at_host
  network_interface_ids      = [azurerm_network_interface.windows.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }
}

# Run Command is used instead of CustomScriptExtension: no command-line length limit,
# and the token is passed as a protected parameter.
resource "azurerm_virtual_machine_run_command" "windows_bootstrap" {
  tags               = var.tags
  name               = "bootstrap-sysmon-agent"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.windows.id

  timeouts {
    create = "60m"
  }

  source {
    script = file("${path.module}/templates/windows-bootstrap.ps1.tftpl")
  }

  parameter {
    name  = "FleetUrl"
    value = local.fleet_url
  }
  parameter {
    name  = "AgentVersion"
    value = var.agent_version
  }
  parameter {
    name  = "SysmonConfigUrl"
    value = var.sysmon_config_url
  }

  protected_parameter {
    name  = "EnrollmentToken"
    value = local.windows_enrollment_token
  }
}
