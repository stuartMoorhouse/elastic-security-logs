# Fleet policies, enrollment tokens and Fleet URL come from the Kibana Fleet API
# (not the elasticstack provider). Package policies are added by scripts/configure.sh.

data "external" "fleet_linux" {
  program = ["bash", "${path.module}/scripts/setup-fleet-policy.sh"]

  query = {
    kibana_url  = ec_security_project.main.endpoints.kibana
    username    = ec_security_project.main.credentials.username
    password    = ec_security_project.main.credentials.password
    policy_name = "linux-workstations"
  }
}

data "external" "fleet_windows" {
  program = ["bash", "${path.module}/scripts/setup-fleet-policy.sh"]

  query = {
    kibana_url  = ec_security_project.main.endpoints.kibana
    username    = ec_security_project.main.credentials.username
    password    = ec_security_project.main.credentials.password
    policy_name = "windows-workstations"
  }

  depends_on = [data.external.fleet_linux]
}

locals {
  fleet_url                = data.external.fleet_linux.result.fleet_url
  linux_enrollment_token   = sensitive(data.external.fleet_linux.result.enrollment_token)
  windows_enrollment_token = sensitive(data.external.fleet_windows.result.enrollment_token)
  linux_policy_id          = data.external.fleet_linux.result.policy_id
  windows_policy_id        = data.external.fleet_windows.result.policy_id
}
