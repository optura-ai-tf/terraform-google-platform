# ===== Logging Storage Bucket =====

resource "google_storage_bucket" "logging" {
  count = var.storage_logging_enabled ? 1 : 0

  name          = "${local.name_prefix}-logging"
  location      = upper(var.region)
  force_destroy = var.environment != "prod"

  # Uniform bucket-level access (no ACLs)
  uniform_bucket_level_access = true

  # Public access prevention
  public_access_prevention = "enforced"

  # Versioning
  versioning {
    enabled = true
  }

  # KMS encryption
  encryption {
    default_kms_key_name = google_kms_crypto_key.storage[0].id
  }

  # Lifecycle rules
  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = var.storage_logging_lifecycle_rules.nearline_after_days
    }
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition {
      age = var.storage_logging_lifecycle_rules.coldline_after_days
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.storage_logging_lifecycle_rules.delete_after_days
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions         = 1
      days_since_noncurrent_time = var.storage_logging_lifecycle_rules.noncurrent_days
    }
  }

  labels = local.common_labels

  depends_on = [
    google_kms_crypto_key_iam_member.storage_encrypt,
  ]
}

# ===== General Storage Bucket =====

resource "google_storage_bucket" "storage" {
  count = var.storage_general_enabled ? 1 : 0

  name          = "${local.name_prefix}-storage"
  location      = upper(var.region)
  force_destroy = var.environment != "prod"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = var.storage_general_versioning
  }

  # A presigned PUT is issued by the app but sent by the browser, so GCS
  # answers the preflight itself.
  dynamic "cors" {
    for_each = length(var.storage_general_cors_origins) > 0 ? [1] : []
    content {
      origin          = var.storage_general_cors_origins
      method          = ["GET", "HEAD", "PUT"]
      response_header = ["Content-Type", "ETag"]
      max_age_seconds = 3000
    }
  }

  # Lifecycle rules
  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = var.storage_general_lifecycle_rules.nearline_after_days
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions         = 1
      days_since_noncurrent_time = var.storage_general_lifecycle_rules.noncurrent_days
    }
  }

  # Abort incomplete multipart uploads after 7 days
  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = 7
    }
  }

  labels = local.common_labels
}
