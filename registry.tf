# ===== Artifact Registry =====

resource "google_project_service" "artifact_registry_api" {
  count   = var.registry_enabled ? 1 : 0
  project = var.gcp_project_id
  service = "artifactregistry.googleapis.com"

  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "time_sleep" "artifact_registry_api_propagation" {
  count           = var.registry_enabled ? 1 : 0
  create_duration = "30s"
  depends_on      = [google_project_service.artifact_registry_api]
}

resource "google_artifact_registry_repository" "main" {
  count = var.registry_enabled ? 1 : 0

  location      = var.region
  repository_id = local.resource_names.registry
  format        = var.registry_format
  mode          = "STANDARD_REPOSITORY"

  # Immutable tags
  docker_config {
    immutable_tags = var.registry_immutable_tags
  }

  # Cleanup policies
  cleanup_policy_dry_run = false

  # Keep most recent N images
  cleanup_policies {
    id     = "keep-latest"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.registry_cleanup_policies.keep_latest_images
    }
  }

  # Delete untagged images older than N days
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.registry_cleanup_policies.expire_untagged * 24 * 60 * 60}s"
    }
  }

  labels = local.common_labels

  depends_on = [time_sleep.api_propagation, time_sleep.artifact_registry_api_propagation]
}

# Enable vulnerability scanning (project-level setting)
resource "google_project_service" "container_scanning" {
  count   = var.registry_enabled && var.registry_vulnerability_scanning ? 1 : 0
  service = "containerscanning.googleapis.com"

  disable_dependent_services = false
  disable_on_destroy         = false
}
