# ===== GKE Cluster =====

resource "google_container_cluster" "main" {
  name     = local.resource_names.gke
  location = var.region

  # Use release channel for version management
  release_channel {
    channel = var.release_channel
  }
  min_master_version = var.kubernetes_version

  # VPC-native networking
  network    = local.vpc_id
  subnetwork = local.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # We manage node pools separately, remove default pool
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity for pod-level IAM
  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true # Nodes have internal IPs only
    enable_private_endpoint = var.private_cluster_enabled
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # Master authorized networks
  dynamic "master_authorized_networks_config" {
    for_each = length(var.api_server_authorized_cidrs) > 0 || var.private_cluster_enabled ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.api_server_authorized_cidrs
        content {
          cidr_block   = cidr_blocks.value
          display_name = "authorized-${cidr_blocks.key}"
        }
      }
      # Allow access from within the VPC (for TFC agent, pods)
      cidr_blocks {
        cidr_block   = local.subnet_cidr
        display_name = "vpc-nodes"
      }
    }
  }

  # Application-layer secrets encryption with Cloud KMS
  dynamic "database_encryption" {
    for_each = var.enable_cluster_encryption ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = google_kms_crypto_key.gke[0].id
    }
  }

  # Cluster add-ons
  addons_config {
    # Built-in HTTP(S) load balancing (GKE Ingress)
    http_load_balancing {
      disabled = false
    }

    # Horizontal Pod Autoscaler
    horizontal_pod_autoscaling {
      disabled = false
    }

    # Network Policy (Calico)
    network_policy_config {
      disabled = false
    }

    # GCE Persistent Disk CSI Driver
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    # DNS Cache for improved DNS performance
    dns_cache_config {
      enabled = true
    }
  }

  # Logging and monitoring
  logging_config {
    enable_components = var.monitoring_enabled ? [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER"
    ] : ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = var.monitoring_enabled ? [
      "SYSTEM_COMPONENTS",
      "STORAGE",
      "POD",
      "DEPLOYMENT",
      "STATEFULSET",
      "DAEMONSET",
      "HPA"
    ] : ["SYSTEM_COMPONENTS"]

    managed_prometheus {
      enabled = var.monitoring_enabled
    }
  }

  # Network policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Maintenance window (2am-6am UTC daily)
  # GKE requires >= 48h of maintenance availability in any 32-day rolling window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "02:00"
    }
  }

  # Binary authorization (optional, for prod)
  binary_authorization {
    evaluation_mode = var.environment == "prod" ? "PROJECT_SINGLETON_POLICY_ENFORCE" : "DISABLED"
  }

  resource_labels = local.common_labels

  depends_on = [
    google_service_networking_connection.private_vpc
  ]

  lifecycle {
    ignore_changes = [
      # Node pool changes managed separately
      node_config,
      initial_node_count,
    ]
  }
}
