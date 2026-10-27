# ===================================================================
# State migration: single-DB → multi-DB (var.databases fanout)
# ===================================================================
#
# These `moved` blocks rename every previously count-gated [0] address
# to its for_each-keyed ["core"] equivalent so existing customers
# upgrade with zero destroy/create on the legacy primary Cloud SQL
# instance.
#
# See docs/plans/2026-04-26-multi-database-provisioning-state-migration.md
# for the full inventory and recreation enumeration.
#
# Adding new keys to var.databases (e.g. "temporal") is a pure
# add — no `moved` block is required for those.
#
# If a customer never had var.database_enabled = true (or the resource
# was otherwise absent), the moved block is a no-op (Terraform handles
# absent-source addresses silently).
# ===================================================================

moved {
  from = random_password.cloudsql[0]
  to   = random_password.cloudsql["core"]
}

moved {
  from = google_sql_database_instance.main[0]
  to   = google_sql_database_instance.main["core"]
}

moved {
  from = google_sql_database.main[0]
  to   = google_sql_database.main["core"]
}

moved {
  from = google_sql_user.admin[0]
  to   = google_sql_user.admin["core"]
}

moved {
  from = google_sql_user.teleport_iam[0]
  to   = google_sql_user.teleport_iam["core"]
}

moved {
  from = kubernetes_job_v1.cloudsql_iam_bootstrap[0]
  to   = kubernetes_job_v1.cloudsql_iam_bootstrap["core"]
}

# The provider can't move these to the _v1 types, so they're dropped from state
# and the kubectl_manifest replacements take over the same objects in place.

removed {
  from = kubernetes_namespace.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.tfc_agent_token

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_deployment.tfc_agent

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role.teleport_admin

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.teleport_admin

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role.teleport_viewer

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding.teleport_viewer

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_config_map.cloudsql_iam_setup

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.cloudsql_bootstrap_creds

  lifecycle {
    destroy = false
  }
}
