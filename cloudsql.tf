# ===== Cloud SQL PostgreSQL =====
#
# Multi-database fanout: each entry in var.databases produces a
# separate Cloud SQL Flexible instance. Per-entry fields fall back to the
# top-level database_* defaults so a `{}` entry is byte-identical to the
# legacy single-instance configuration. The "core" key preserves the
# legacy unsuffixed instance name; every other key is unconditionally
# suffixed so future names cannot collide.

# Per-key name suffix used by every supporting resource (K8s ConfigMap/
# Secret/Job, …). "core" resolves to "" so the legacy unsuffixed names are
# preserved on upgrade — avoiding ForceNew replacement of resources whose
# `name` is immutable. Future keys are suffixed unconditionally so they
# cannot collide with "core".
locals {
  db_name_suffix = {
    for k in keys(var.databases) : k => k == "core" ? "" : "-${k}"
  }
}

# Random password for Cloud SQL admin (per instance).
# IMPORTANT: no `keepers` argument — adding a new entry to var.databases
# must NOT rotate the existing core admin password.
resource "random_password" "cloudsql" {
  for_each = var.database_enabled ? var.databases : {}
  length   = 32
  special  = true

  # Exclude characters that cause issues with connection strings
  override_special = "!#$%&*()-_=+[]{}|:;<>?"
}

resource "google_sql_database_instance" "main" {
  for_each = var.database_enabled ? var.databases : {}

  # Identifier preservation: "core" keeps the legacy unsuffixed name to avoid
  # destroy+recreate of the existing primary Cloud SQL instance. Every other
  # key is suffixed unconditionally so future names cannot collide.
  name                = "${local.resource_names.cloudsql}${local.db_name_suffix[each.key]}"
  database_version    = var.database_version
  region              = var.region
  deletion_protection = coalesce(each.value.deletion_protection, var.database_deletion_protection)

  # CMEK encryption (shared key across all named instances)
  encryption_key_name = google_kms_crypto_key.cloudsql[0].id

  settings {
    # `coalesce()` (not `try()`) is required: optional() attributes resolve to
    # null when unset and `try()` only catches errors, so `try(null, var.X)`
    # returns null and leaves required Cloud SQL fields unset.
    tier                  = coalesce(each.value.tier, var.database_tier)
    edition               = coalesce(each.value.edition, var.database_edition)
    availability_type     = coalesce(each.value.ha_enabled, var.database_ha_enabled) ? "REGIONAL" : "ZONAL"
    disk_size             = coalesce(each.value.disk_size, var.database_disk_size)
    disk_autoresize       = var.database_disk_autoresize
    disk_autoresize_limit = coalesce(each.value.disk_autoresize_limit, var.database_disk_autoresize_limit)
    disk_type             = "PD_SSD"

    # Private networking (no public IP)
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = local.vpc_id
      enable_private_path_for_google_cloud_services = true
    }

    # Backups
    backup_configuration {
      enabled                        = coalesce(each.value.backup_enabled, var.database_backup_enabled)
      point_in_time_recovery_enabled = coalesce(each.value.backup_enabled, var.database_backup_enabled)
      transaction_log_retention_days = min(coalesce(each.value.backup_retention_days, var.database_backup_retention_days), 7)

      backup_retention_settings {
        retained_backups = coalesce(each.value.backup_retention_days, var.database_backup_retention_days)
      }
    }

    # Query Insights
    insights_config {
      query_insights_enabled  = coalesce(each.value.insights_enabled, var.database_insights_enabled)
      query_plans_per_minute  = 5
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    # Maintenance window (Sunday 2am)
    maintenance_window {
      day          = 7 # Sunday
      hour         = 2
      update_track = "stable"
    }

    # Database flags (cloudsql.iam_authentication is managed below and must not be duplicated)
    dynamic "database_flags" {
      for_each = { for k, v in coalesce(each.value.database_flags, var.database_flags) : k => v if k != "cloudsql.iam_authentication" }
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }

    # IAM authentication is always enabled; filtering it from var.database_flags above
    # prevents the Cloud SQL API from rejecting the config due to duplicate flags.
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    user_labels = local.common_labels
  }

  depends_on = [
    google_service_networking_connection.private_vpc,
    google_kms_crypto_key_iam_member.cloudsql_encrypt,
  ]

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# Default database (one per instance)
resource "google_sql_database" "main" {
  for_each = var.database_enabled ? var.databases : {}
  name     = coalesce(each.value.db_name, var.database_name)
  instance = google_sql_database_instance.main[each.key].name
}

# Admin user with password (one per instance)
resource "google_sql_user" "admin" {
  for_each = var.database_enabled ? var.databases : {}
  name     = coalesce(each.value.admin_username, var.database_admin_username)
  instance = google_sql_database_instance.main[each.key].name
  password = random_password.cloudsql[each.key].result
  type     = "BUILT_IN"
}

# IAM user for Teleport (Cloud SQL IAM authentication, one per instance)
resource "google_sql_user" "teleport_iam" {
  for_each = var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}
  name     = trimsuffix(google_service_account.teleport_db[0].email, ".gserviceaccount.com")
  instance = google_sql_database_instance.main[each.key].name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

# ===== IAM Auth Bootstrap Job =====
# Kubernetes Job grants database-level permissions
# because Terraform cannot reach private Cloud SQL directly.
# Runs once per named instance.

locals {
  # Autopilot rejects workloads in kube-system, so the Job gets its own namespace there.
  cloudsql_bootstrap_namespace   = var.autopilot_enabled ? "cloudsql-bootstrap" : "kube-system"
  cloudsql_iam_setup_names       = { for k in keys(var.databases) : k => "cloudsql-iam-setup${local.db_name_suffix[k]}" }
  cloudsql_bootstrap_creds_names = { for k in keys(var.databases) : k => "cloudsql-bootstrap-creds${local.db_name_suffix[k]}" }
  cloudsql_iam_setup_sql = { for k, v in(var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}) : k => <<-EOT
      -- Grant permissions to Teleport IAM user
      -- Cloud SQL IAM username = SA email without .gserviceaccount.com
      DO $$
      DECLARE
        iam_user TEXT := '${trimsuffix(google_service_account.teleport_db[0].email, ".gserviceaccount.com")}';
        schema_rec RECORD;
      BEGIN
        -- Grant connect and create on database (CREATE needed for extensions)
        EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO "%s"',
          '${coalesce(v.db_name, var.database_name)}', iam_user);

        -- Grant privileges on all current schemas (not just public)
        FOR schema_rec IN
          SELECT schema_name FROM information_schema.schemata
          WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        LOOP
          EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA %I TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON FUNCTIONS TO "%s"', schema_rec.schema_name, iam_user);
          EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TYPES TO "%s"', schema_rec.schema_name, iam_user);
        END LOOP;

        -- Grant cloudsqlsuperuser (Cloud SQL equivalent of AWS rds_superuser)
        -- Required for creating extensions in any database
        EXECUTE format('GRANT cloudsqlsuperuser TO "%s"', iam_user);

        -- Grant CREATEROLE and CREATEDB for Teleport auto-user provisioning
        -- Grant BYPASSRLS for row-level security parity with AWS rds_superuser
        EXECUTE format('ALTER ROLE "%s" CREATEROLE CREATEDB BYPASSRLS', iam_user);

        RAISE NOTICE 'Cloud SQL IAM auth setup complete for %', iam_user;
      END $$;
    EOT
  }
}

resource "kubectl_manifest" "cloudsql_bootstrap_namespace" {
  count = var.autopilot_enabled && var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.cloudsql_bootstrap_namespace
    }
  })
}

resource "kubectl_manifest" "cloudsql_iam_setup" {
  for_each = var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = local.cloudsql_iam_setup_names[each.key]
      namespace = local.cloudsql_bootstrap_namespace
    }
    data = {
      "setup.sql" = local.cloudsql_iam_setup_sql[each.key]
    }
  })

  depends_on = [
    google_container_node_pool.pools,
    kubectl_manifest.cloudsql_bootstrap_namespace,
  ]
}

resource "kubectl_manifest" "cloudsql_bootstrap_creds" {
  for_each = var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata = {
      name      = local.cloudsql_bootstrap_creds_names[each.key]
      namespace = local.cloudsql_bootstrap_namespace
    }
    data = {
      PGHOST     = base64encode(google_sql_database_instance.main[each.key].private_ip_address)
      PGPORT     = base64encode("5432")
      PGDATABASE = base64encode(coalesce(each.value.db_name, var.database_name))
      PGUSER     = base64encode(coalesce(each.value.admin_username, var.database_admin_username))
      PGPASSWORD = base64encode(random_password.cloudsql[each.key].result)
    }
  })

  depends_on = [
    google_container_node_pool.pools,
    kubectl_manifest.cloudsql_bootstrap_namespace,
  ]
}

# Re-running the bootstrap Job when its ConfigMap SQL changes is non-trivial:
# spec.template is immutable on a K8s Job, so a pod-template annotation
# (e.g. sha256 of the SQL) is silently dropped by the API server and never
# triggers a re-run. Instead we hash the SQL into a `terraform_data` resource
# and use `lifecycle.replace_triggered_by` on the Job — when the hash changes,
# Terraform performs a full delete + create on the Job. Mirrors the Azure
# pattern in azure/postgresql.tf.
resource "terraform_data" "cloudsql_iam_setup_hash" {
  for_each = var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}

  # `triggers_replace` (not `input`) so a SQL change renders as `-/+` in plan
  # output — clearer than the `~` update an `input` change would produce.
  triggers_replace = [sha256(local.cloudsql_iam_setup_sql[each.key])]
}

resource "kubernetes_job_v1" "cloudsql_iam_bootstrap" {
  for_each = var.database_enabled && var.access_mode == "teleport" && var.teleport_db_enabled ? var.databases : {}

  metadata {
    name      = "cloudsql-iam-bootstrap${local.db_name_suffix[each.key]}"
    namespace = local.cloudsql_bootstrap_namespace
    labels = {
      app = "cloudsql-iam-bootstrap"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          app = "cloudsql-iam-bootstrap"
        }
      }

      spec {
        restart_policy = "OnFailure"

        # Autopilot has no support pool; the one-shot Job runs on general-purpose nodes.
        node_selector = var.autopilot_enabled ? {} : {
          "workload-type" = "support"
        }

        container {
          name    = "psql"
          image   = "postgres:17-alpine"
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
              echo "Waiting for Cloud SQL to be ready..."
              until pg_isready -h $PGHOST -p $PGPORT -U $PGUSER; do
                echo "Waiting..."
                sleep 5
              done
              echo "Cloud SQL is ready. Running IAM setup..."
              psql -f /scripts/setup.sql
              echo "IAM bootstrap complete."
            EOT
          ]

          env_from {
            secret_ref {
              name = local.cloudsql_bootstrap_creds_names[each.key]
            }
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = local.cloudsql_iam_setup_names[each.key]
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [
    google_sql_user.admin,
    google_sql_user.teleport_iam,
    google_container_node_pool.pools,
    kubectl_manifest.cloudsql_iam_setup,
    kubectl_manifest.cloudsql_bootstrap_creds,
  ]

  # Re-run the Job whenever the SQL hash changes. See `terraform_data.cloudsql_iam_setup_hash`
  # above for the rationale (spec.template is immutable on K8s Jobs).
  lifecycle {
    replace_triggered_by = [
      terraform_data.cloudsql_iam_setup_hash[each.key]
    ]
  }
}
