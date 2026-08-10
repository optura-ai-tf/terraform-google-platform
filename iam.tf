# ===== GKE Node Service Account =====
# Custom service account for nodes (instead of default Compute Engine SA)

resource "google_service_account" "gke_nodes" {
  account_id   = "${local.name_prefix}-gke-nodes"
  display_name = "GKE Node Pool Service Account for ${local.name_prefix}"

  depends_on = [time_sleep.api_propagation]
}

# Minimal permissions for nodes
resource "google_project_iam_member" "gke_nodes_log_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metric_writer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring_viewer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_resource_metadata_writer" {
  project = var.gcp_project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_artifact_registry_reader" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ===== Workload Identity: Logging Storage =====

resource "google_service_account" "logging" {
  count        = var.storage_logging_enabled ? 1 : 0
  account_id   = "${local.name_prefix}-logging"
  display_name = "Logging Workload Identity SA for ${local.name_prefix}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account_iam_member" "logging_workload_identity" {
  count              = var.storage_logging_enabled ? 1 : 0
  service_account_id = google_service_account.logging[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project_id}.svc.id.goog[${var.storage_logging_namespace}/${var.storage_logging_service_account}]"

  depends_on = [google_container_cluster.main]
}

resource "google_storage_bucket_iam_member" "logging_object_admin" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = google_storage_bucket.logging[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.logging[0].email}"
}

# ===== Workload Identity: General Storage =====

resource "google_service_account" "storage" {
  count        = var.storage_general_enabled ? 1 : 0
  account_id   = "${local.name_prefix}-storage"
  display_name = "General Storage Workload Identity SA for ${local.name_prefix}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account_iam_member" "storage_workload_identity" {
  count              = var.storage_general_enabled ? 1 : 0
  service_account_id = google_service_account.storage[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project_id}.svc.id.goog[${var.storage_general_namespace}/${var.storage_general_service_account}]"

  depends_on = [google_container_cluster.main]
}

resource "google_storage_bucket_iam_member" "storage_object_admin" {
  count  = var.storage_general_enabled ? 1 : 0
  bucket = google_storage_bucket.storage[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.storage[0].email}"
}

# ===== Workload Identity: Teleport DB Agent =====

resource "google_service_account" "teleport_db" {
  count        = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  account_id   = "${local.name_prefix}-teleport-db"
  display_name = "Teleport DB Agent SA for ${local.name_prefix}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account_iam_member" "teleport_db_workload_identity" {
  count              = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  service_account_id = google_service_account.teleport_db[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project_id}.svc.id.goog[teleport-agent/teleport-kube-agent]"

  depends_on = [google_container_cluster.main]
}

resource "google_project_iam_member" "teleport_db_cloudsql_client" {
  count   = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.teleport_db[0].email}"
}

resource "google_project_iam_member" "teleport_db_cloudsql_instance_user" {
  count   = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.teleport_db[0].email}"
}

# Viewer role needed by Teleport to download Cloud SQL CA certificates
resource "google_project_iam_member" "teleport_db_cloudsql_viewer" {
  count   = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/cloudsql.viewer"
  member  = "serviceAccount:${google_service_account.teleport_db[0].email}"
}

# Allow the Teleport DB agent SA to generate IAM auth tokens for itself
resource "google_service_account_iam_member" "teleport_db_token_creator" {
  count              = var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? 1 : 0
  service_account_id = google_service_account.teleport_db[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.teleport_db[0].email}"
}

# ===== Workload Identity: Vertex AI =====

resource "google_project_service" "vertex_ai_api" {
  count   = var.vertex_ai_enabled ? 1 : 0
  project = var.gcp_project_id
  service = "aiplatform.googleapis.com"

  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "time_sleep" "vertex_ai_api_propagation" {
  count           = var.vertex_ai_enabled ? 1 : 0
  create_duration = "30s"
  depends_on      = [google_project_service.vertex_ai_api]
}

resource "google_service_account" "vertex_ai" {
  count        = var.vertex_ai_enabled ? 1 : 0
  account_id   = "${local.name_prefix}-vertex-ai"
  display_name = "Vertex AI Workload Identity SA for ${local.name_prefix}"

  depends_on = [time_sleep.api_propagation, time_sleep.vertex_ai_api_propagation]

  lifecycle {
    precondition {
      condition     = length(var.vertex_ai_roles) > 0
      error_message = "vertex_ai_roles must contain at least one IAM role when vertex_ai_enabled is true."
    }
  }
}

resource "google_project_iam_member" "vertex_ai" {
  for_each = var.vertex_ai_enabled ? toset(var.vertex_ai_roles) : toset([])
  project  = var.gcp_project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.vertex_ai[0].email}"

}

resource "google_service_account_iam_member" "vertex_ai_workload_identity" {
  for_each           = var.vertex_ai_enabled ? var.vertex_ai_workload_identities : {}
  service_account_id = google_service_account.vertex_ai[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project_id}.svc.id.goog[${each.value.namespace}/${each.key}]"

  depends_on = [google_container_cluster.main]
}

# ===== Cluster Admin Access =====
# Cluster admin access via IAM bindings

resource "google_project_iam_member" "cluster_admins" {
  for_each = toset(var.cluster_admin_emails)
  project  = var.gcp_project_id
  role     = "roles/container.admin"
  member   = each.value
}
