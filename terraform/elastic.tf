# Elastic Cloud Serverless Security project (no tiers, no ILM: retention uses data stream lifecycle).
resource "ec_security_project" "main" {
  name      = var.prefix
  region_id = var.ec_region

  product_types = [
    {
      product_line = "security"
      product_tier = var.security_tier
    }
  ]
}
