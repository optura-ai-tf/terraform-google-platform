# ===== Cloud KMS =====

# Key ring (regional, contains all keys)
resource "google_kms_key_ring" "main" {
  count    = var.enable_cluster_encryption || var.database_enabled || var.storage_logging_enabled ? 1 : 0
  name     = "${local.name_prefix}-keyring"
  location = var.region

  depends_on = [time_sleep.api_propagation]
}

# GKE application-layer encryption key
resource "google_kms_crypto_key" "gke" {
  count    = var.enable_cluster_encryption ? 1 : 0
  name     = "${local.name_prefix}-gke-secrets"
  key_ring = google_kms_key_ring.main[0].id

  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# Grant GKE service agent access to use the key
resource "google_kms_crypto_key_iam_member" "gke_encrypt" {
  count         = var.enable_cluster_encryption ? 1 : 0
  crypto_key_id = google_kms_crypto_key.gke[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@container-engine-robot.iam.gserviceaccount.com"
}

# Cloud SQL encryption key
resource "google_kms_crypto_key" "cloudsql" {
  count    = var.database_enabled ? 1 : 0
  name     = "${local.name_prefix}-cloudsql"
  key_ring = google_kms_key_ring.main[0].id

  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

# Ensure Cloud SQL service agent exists before granting KMS access
resource "google_project_service_identity" "cloudsql_sa" {
  count    = var.database_enabled ? 1 : 0
  provider = google-beta
  project  = var.gcp_project_id
  service  = "sqladmin.googleapis.com"

  depends_on = [time_sleep.api_propagation]
}

# Grant Cloud SQL service agent access
resource "google_kms_crypto_key_iam_member" "cloudsql_encrypt" {
  count         = var.database_enabled ? 1 : 0
  crypto_key_id = google_kms_crypto_key.cloudsql[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.cloudsql_sa[0].email}"
}

# Storage encryption key (for logging bucket)
resource "google_kms_crypto_key" "storage" {
  count    = var.storage_logging_enabled ? 1 : 0
  name     = "${local.name_prefix}-storage"
  key_ring = google_kms_key_ring.main[0].id

  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

# Grant Cloud Storage service agent access
data "google_storage_project_service_account" "gcs_sa" {}

resource "google_kms_crypto_key_iam_member" "storage_encrypt" {
  count         = var.storage_logging_enabled ? 1 : 0
  crypto_key_id = google_kms_crypto_key.storage[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}
