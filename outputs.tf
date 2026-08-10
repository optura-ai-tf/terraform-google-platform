# ===== Network Outputs =====

output "network_id" {
  description = "ID of the VPC network"
  value       = local.vpc_id
}

output "network_name" {
  description = "Name of the VPC network"
  value       = local.vpc_name
}

output "network_cidr" {
  description = "Primary CIDR block of the node subnet"
  value       = var.create_network ? google_compute_subnetwork.nodes[0].ip_cidr_range : data.google_compute_subnetwork.existing[0].ip_cidr_range
}

output "cluster_subnet_ids" {
  description = "IDs of cluster subnets (node subnet)"
  value       = [local.subnet_id]
}

output "ingress_subnet_ids" {
  description = "IDs of ingress subnets (proxy-only subnet for load balancers)"
  value       = var.create_network ? [google_compute_subnetwork.proxy_only[0].id] : []
}

output "database_subnet_ids" {
  description = "IDs of database subnets"
  value       = var.create_private_service_connection && var.database_enabled ? [google_compute_global_address.private_ip_range[0].id] : []
}

# ===== Cluster Outputs =====

output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.main.name
}

output "cluster_id" {
  description = "ID of the GKE cluster"
  value       = google_container_cluster.main.id
}

output "cluster_endpoint" {
  description = "Endpoint for GKE cluster API server"
  value       = google_container_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Not applicable for GCP (uses VPC firewall rules)"
  value       = null
}

output "kubectl_config_command" {
  description = "Command to configure kubectl access"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.region} --project ${var.gcp_project_id}"
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate"
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# ===== Container Registry Outputs =====

output "registry_url" {
  description = "URL of the Artifact Registry repository"
  value       = var.registry_enabled ? "${var.region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.main[0].repository_id}" : var.registry_repository_id
}

output "registry_id" {
  description = "ID of the Artifact Registry repository"
  value       = var.registry_enabled ? google_artifact_registry_repository.main[0].id : null
}

output "registry_name" {
  description = "Name of the Artifact Registry repository"
  value       = var.registry_enabled ? google_artifact_registry_repository.main[0].repository_id : var.registry_repository_id
}

output "registry_created" {
  description = "Whether the Artifact Registry was created by this module"
  value       = var.registry_enabled
}

# ===== SSL Certificate Outputs =====

output "ssl_certificate_id" {
  description = "ID of the Google-managed SSL certificate"
  value       = var.ssl_certificate_create ? google_compute_managed_ssl_certificate.main[0].id : null
}

output "ssl_certificate_domains" {
  description = "Domains associated with the SSL certificate"
  value       = var.ssl_certificate_create ? google_compute_managed_ssl_certificate.main[0].managed[0].domains : null
}

output "ssl_certificate_created" {
  description = "Whether the SSL certificate was created by this module"
  value       = var.ssl_certificate_create
}

# ===== Database Outputs =====
#
# Multi-database fanout: each named instance in var.databases is exposed
# via the map outputs below (database_endpoints, database_names, etc.). The
# legacy singular outputs (database_endpoint, database_admin_username,
# database_admin_password, ...) are preserved as aliases for the "core" entry
# so existing customers see no change.

output "database_server_name" {
  description = "Name of the \"core\" Cloud SQL instance (legacy alias)"
  value       = try(google_sql_database_instance.main["core"].name, null)
}

output "database_endpoint" {
  description = "Connection name of the \"core\" Cloud SQL instance — project:region:instance (legacy alias)"
  value       = try(google_sql_database_instance.main["core"].connection_name, null)
}

output "database_address" {
  description = "Private IP address of the \"core\" Cloud SQL instance (legacy alias)"
  value       = try(google_sql_database_instance.main["core"].private_ip_address, null)
}

output "database_port" {
  description = "Port of the \"core\" Cloud SQL instance (legacy alias)"
  value       = try(google_sql_database_instance.main["core"] != null, false) ? 5432 : null
}

output "database_name" {
  description = "Name of the default database on the \"core\" instance (legacy alias)"
  value       = try(google_sql_database.main["core"].name, null)
}

output "database_admin_username" {
  description = "Administrator username for the \"core\" Cloud SQL instance (legacy alias)"
  value       = try(google_sql_user.admin["core"].name, null)
  sensitive   = true
}

output "database_admin_password" {
  description = "Administrator password for the \"core\" Cloud SQL instance (legacy alias)"
  value       = try(random_password.cloudsql["core"].result, null)
  sensitive   = true
}

# ===== Multi-database map outputs =====

output "database_endpoints" {
  description = "Map of named DB key → connection name (project:region:instance)"
  value       = { for k, v in google_sql_database_instance.main : k => v.connection_name }
}

output "database_names" {
  description = "Map of named DB key → initial database name"
  value       = { for k, v in google_sql_database.main : k => v.name }
}

output "database_admin_usernames" {
  description = "Map of named DB key → administrator username"
  value       = { for k, v in google_sql_user.admin : k => v.name }
  sensitive   = true
}

output "database_admin_passwords" {
  description = "Map of named DB key → administrator password"
  value       = { for k, v in random_password.cloudsql : k => v.result }
  sensitive   = true
}

# ===== Storage Outputs =====

output "logging_storage_name" {
  description = "Name of the logging storage bucket"
  value       = var.storage_logging_enabled ? google_storage_bucket.logging[0].name : null
}

output "logging_storage_id" {
  description = "ID of the logging storage bucket"
  value       = var.storage_logging_enabled ? google_storage_bucket.logging[0].id : null
}

output "logging_storage_region" {
  description = "Region of the logging storage bucket"
  value       = var.storage_logging_enabled ? google_storage_bucket.logging[0].location : null
}

output "logging_storage_role_id" {
  description = "Service account email for logging workload access"
  value       = var.storage_logging_enabled ? google_service_account.logging[0].email : null
}

output "general_storage_name" {
  description = "Name of the general storage bucket"
  value       = var.storage_general_enabled ? google_storage_bucket.storage[0].name : null
}

output "general_storage_id" {
  description = "ID of the general storage bucket"
  value       = var.storage_general_enabled ? google_storage_bucket.storage[0].id : null
}

output "general_storage_region" {
  description = "Region of the general storage bucket"
  value       = var.storage_general_enabled ? google_storage_bucket.storage[0].location : null
}

output "general_storage_role_id" {
  description = "Service account email for general storage workload access"
  value       = var.storage_general_enabled ? google_service_account.storage[0].email : null
}

# ===== IAM Outputs =====

output "workload_identity_pool" {
  description = "Workload Identity pool for the GKE cluster"
  value       = "${var.gcp_project_id}.svc.id.goog"
}

output "node_pool_service_account" {
  description = "Service account email used by node pools"
  value       = google_service_account.gke_nodes.email
}

# ===== Vertex AI Outputs =====

output "vertex_ai_service_account_email" {
  description = "GCP service account email for Vertex AI workload identity (use as iam.gke.io/gcp-service-account annotation)"
  value       = var.vertex_ai_enabled ? google_service_account.vertex_ai[0].email : null
}

output "vertex_ai_workload_identities" {
  description = "Map of Kubernetes service accounts bound to the Vertex AI GCP service account"
  value = var.vertex_ai_enabled ? {
    for k, v in var.vertex_ai_workload_identities : k => {
      namespace           = v.namespace
      gcp_service_account = google_service_account.vertex_ai[0].email
    }
  } : {}
}

# ===== Cost Estimation Output =====

output "estimated_monthly_cost" {
  description = "Rough monthly cost estimate based on configuration"
  value       = <<-EOT
    Estimated Monthly Cost (${var.environment}):
    - GKE Cluster Management: $73/mo (standard tier)
    - Node Pools: Varies by machine type and count
    - Cloud NAT: ${var.enable_cloud_nat ? "~$32/mo + data processing" : "Disabled"}
    - Cloud SQL: ${var.database_enabled ? "Varies by tier (${var.database_tier})" : "Disabled"}
    - Cloud Storage: ${var.storage_logging_enabled || var.storage_general_enabled ? "~$2-10/mo" : "Disabled"}
    - Artifact Registry: ${var.registry_enabled ? "~$0.10/GB storage" : "Using existing"}
    Note: Actual costs vary. Check https://cloud.google.com/products/calculator
  EOT
}

# ===== Access Configuration Outputs =====

output "access_mode" {
  description = "Configured access mode (teleport or vpn)"
  value       = var.access_mode
}

output "api_endpoint_access_type" {
  description = "Whether the API server endpoint is public or private"
  value       = var.private_cluster_enabled ? "private" : "public"
}

# ===== Teleport =====

output "teleport_db_agent_service_account" {
  description = "Service account email for Teleport database agent"
  value       = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? google_service_account.teleport_db[0].email : null
}

# ===== TFC Agent =====

output "tfc_agent_status" {
  description = "Terraform Cloud agent deployment status"
  value = {
    enabled   = var.tfc_agent_enabled
    namespace = var.tfc_agent_enabled ? "terraform-cloud" : null
  }
}
