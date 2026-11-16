output "elasticsearch_url" {
  value = ec_security_project.main.endpoints.elasticsearch
}

output "kibana_url" {
  value = ec_security_project.main.endpoints.kibana
}

output "elastic_username" {
  value = ec_security_project.main.credentials.username
}

output "elastic_password" {
  value     = ec_security_project.main.credentials.password
  sensitive = true
}

output "fleet_url" {
  value = local.fleet_url
}

output "linux_policy_id" {
  value = local.linux_policy_id
}

output "windows_policy_id" {
  value = local.windows_policy_id
}

output "linux_vm_public_ip" {
  value = azurerm_public_ip.linux.ip_address
}

output "windows_vm_public_ip" {
  value = azurerm_public_ip.windows.ip_address
}

output "vm_admin_username" {
  value = var.admin_username
}

output "windows_admin_password" {
  value     = random_password.windows.result
  sensitive = true
}

output "linux_ssh_private_key_path" {
  value = abspath(local_sensitive_file.linux_ssh_key.filename)
}

output "linux_ssh_command" {
  value = "ssh -i ${abspath(local_sensitive_file.linux_ssh_key.filename)} ${var.admin_username}@${azurerm_public_ip.linux.ip_address}"
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}
