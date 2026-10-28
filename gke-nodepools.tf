# ===== GKE Node Pools =====

resource "google_container_node_pool" "pools" {
  for_each = var.autopilot_enabled ? {} : var.node_pools

  name     = "${local.name_prefix}-${each.key}"
  location = var.region
  cluster  = google_container_cluster.main.name

  # Autoscaling (built-in, no separate Helm chart needed)
  autoscaling {
    min_node_count = each.value.min_count
    max_node_count = each.value.max_count
  }

  initial_node_count = coalesce(each.value.desired_count, each.value.min_count)

  # Node configuration
  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = each.value.image_type

    # Use custom service account (not default compute SA)
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Workload Identity on nodes
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded instance (secure boot)
    shielded_instance_config {
      enable_secure_boot = true
    }

    # Labels (including standardized workload-type and node-pool)
    labels = each.value.labels

    # Resource labels (GCP resource labels, not K8s labels)
    resource_labels = merge(local.common_labels, {
      node-pool = each.key
    })

    # Tags for firewall rules
    tags = ["gke-${local.resource_names.gke}", "gke-${local.resource_names.gke}-${each.key}"]

    # Taints
    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # Spot VMs (preemptible, cost-optimized)
    spot = each.value.spot

    # Metadata
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # Management settings
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Upgrade settings
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  lifecycle {
    ignore_changes = [
      initial_node_count, # Managed by autoscaler
    ]
  }
}
