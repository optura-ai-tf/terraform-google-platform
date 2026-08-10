# Complete example: a full GKE platform with Teleport access, Cloud SQL, and
# the standard three-tier node pool layout. Mirrors a typical dev environment.
# Run `terraform init && terraform apply` after filling in your project ID.
#
# Fill in the `[REPLACE]` placeholders below with your own values before
# `terraform apply`; other values are sizing/architecture defaults.

module "platform" {
  source = "../../"

  # Core identity
  gcp_project_id = var.gcp_project_id
  region         = "us-central1"
  environment    = "dev"
  project_name   = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

  labels = {
    cost_center = "engineering"
    owner       = "platform-team"
    environment = "dev"
  }

  # Three-tier node pools
  node_pools = {
    system = {
      machine_type = "e2-standard-2"
      min_count    = 1
      max_count    = 2
      disk_size_gb = 50
      labels       = { "workload-type" = "system", "node-pool" = "system" }
      taints       = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    support = {
      machine_type  = "e2-standard-2"
      min_count     = 0
      max_count     = 4
      desired_count = 1
      disk_size_gb  = 50
      labels        = { "workload-type" = "support", "node-pool" = "support" }
    }
    application = {
      machine_type  = "e2-standard-2"
      min_count     = 0
      max_count     = 5
      desired_count = 1
      disk_size_gb  = 100
      labels        = { "workload-type" = "application", "node-pool" = "application" }
    }
  }

  # GKE
  release_channel           = "REGULAR"
  enable_cluster_encryption = false

  # Cloud SQL
  database_tier                  = "db-custom-2-7680"
  database_ha_enabled            = false
  database_deletion_protection   = false
  database_disk_autoresize_limit = 100

  # Access
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
  teleport_join_token             = var.teleport_join_token
  teleport_db_enabled             = true
}
