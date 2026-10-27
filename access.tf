# ===================================================================
# Teleport Access Configuration (GCP GKE)
# ===================================================================
#
# This module provides secure access to Kubernetes and Cloud SQL via Teleport
# using the official teleport-kube-agent Helm chart.
#
# Components:
# 1. User-facing RBAC - Two roles (admin, viewer)
# 2. Teleport agent - Kubernetes + Database services via Helm
#
# ===================================================================

locals {
  teleport_cluster_name = "${var.project_name}-${var.environment}-gke"

  # GKE cluster DNS service IP - dynamically derived from services_cidr
  # The kube-dns service is always assigned the 10th IP in the services CIDR range
  # Verify with: kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'
  gke_dns_service_ip = cidrhost(var.services_cidr, 10)

  # Validation logic - will fail at plan time if condition is not met
  validate_teleport = (
    var.access_mode == "teleport" &&
    (
      var.teleport_proxy_address == null || var.teleport_proxy_address == "" ||
      var.teleport_join_token == null || var.teleport_join_token == "" ||
      var.teleport_agent_chart_repository == null || var.teleport_agent_chart_repository == ""
    )
  ) ? file("ERROR: When access_mode is 'teleport', teleport_proxy_address, teleport_join_token, and teleport_agent_chart_repository must be provided.") : "valid"
}

# Force evaluation of teleport validation at plan time
# Without this resource, the validate_teleport local is never referenced
# and Terraform skips evaluating it entirely
resource "terraform_data" "teleport_validation" {
  count = var.access_mode == "teleport" ? 1 : 0

  input = local.validate_teleport
}

# ===== SECTION 1: User-Facing RBAC Roles =====

## Role 1: Cluster Admin (Full Access)
resource "kubectl_manifest" "teleport_admin_role" {
  count = var.access_mode == "teleport" ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "teleport-cluster-admin"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "teleport.dev/role"            = "admin"
      }
    }
    rules = [
      {
        apiGroups = ["*"]
        resources = ["*"]
        verbs     = ["*"]
      },
      {
        nonResourceURLs = ["*"]
        verbs           = ["*"]
      },
    ]
  })
}

resource "kubectl_manifest" "teleport_admin_binding" {
  count = var.access_mode == "teleport" ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "teleport-cluster-admin"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "teleport-cluster-admin"
    }
    subjects = [{
      kind     = "Group"
      name     = "teleport-admins"
      apiGroup = "rbac.authorization.k8s.io"
    }]
  })

  depends_on = [kubectl_manifest.teleport_admin_role]
}

## Role 2: Viewer (Read-Only)
resource "kubectl_manifest" "teleport_viewer_role" {
  count = var.access_mode == "teleport" ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "teleport-viewer"
    }
    rules = [
      {
        apiGroups = ["", "apps", "batch", "extensions"]
        resources = [
          "pods", "pods/log", "pods/status",
          "services", "endpoints",
          "deployments", "replicasets", "statefulsets", "daemonsets",
          "jobs", "cronjobs",
          "configmaps", "secrets",
          "persistentvolumes", "persistentvolumeclaims",
          "namespaces", "nodes"
        ]
        verbs = ["get", "list", "watch"]
      },
      {
        apiGroups = ["rbac.authorization.k8s.io"]
        resources = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  })
}

resource "kubectl_manifest" "teleport_viewer_binding" {
  count = var.access_mode == "teleport" ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "teleport-viewer"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "teleport-viewer"
    }
    subjects = [{
      kind     = "Group"
      name     = "teleport-viewers"
      apiGroup = "rbac.authorization.k8s.io"
    }]
  })

  depends_on = [kubectl_manifest.teleport_viewer_role]
}

# ===== SECTION 2: Teleport Agent via Helm =====

# Teleport Kube Agent Helm Release
resource "helm_release" "teleport_kube_agent" {
  count = var.access_mode == "teleport" ? 1 : 0

  name             = "teleport-kube-agent"
  repository       = var.teleport_agent_chart_repository
  chart            = "teleport-kube-agent"
  namespace        = "teleport-agent"
  version          = var.teleport_version
  create_namespace = true

  # Core configuration
  set = concat(
    # Custom agent image (e.g. a private-registry mirror) — omit to use the chart's default image
    var.teleport_agent_image != null && var.teleport_agent_image != "" ? [
      {
        name  = "image"
        value = var.teleport_agent_image
      }
    ] : [],
    [
      {
        name  = "roles"
        value = var.teleport_db_enabled && var.database_enabled ? "kube\\,app\\,discovery\\,db" : "kube\\,app\\,discovery"
      },
      # Enable app_service to allow header forwarding
      {
        name  = "teleportConfig.app_service.enabled"
        value = "true"
      },
      {
        name  = "proxyAddr"
        value = var.teleport_proxy_address
      },
      {
        name  = "authToken"
        value = var.teleport_join_token
      },
      {
        name  = "kubeClusterName"
        value = local.teleport_cluster_name
      },
      # App service resource matcher - only serve apps from THIS cluster
      {
        name  = "appResources[0].labels.teleport\\.dev/kubernetes-cluster"
        value = local.teleport_cluster_name
      },
      # Kubernetes discovery configuration (filter by label)
      {
        name  = "kubernetesDiscovery[0].types[0]"
        value = "app"
      },
      {
        name  = "kubernetesDiscovery[0].namespaces[0]"
        value = "*"
      },
      {
        name  = "kubernetesDiscovery[0].labels.teleport\\.dev/discover"
        value = "true"
      },
      # Labels for Teleport RBAC
      {
        name  = "labels.env"
        value = var.environment
      },
      {
        name  = "labels.region"
        value = var.region
      },
      {
        name  = "labels.cloud"
        value = "gcp"
      },
      {
        name  = "labels.customer"
        value = var.project_name
      },
      {
        name  = "labels.type"
        value = "kubernetes"
      },
      # Node scheduling (prefer support nodes)
      {
        name  = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight"
        value = "100"
      },
      {
        name  = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key"
        value = "workload-type"
      },
      {
        name  = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator"
        value = "In"
      },
      {
        name  = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].values[0]"
        value = "support"
      },
      # Tolerations for support nodes
      {
        name  = "tolerations[0].key"
        value = "workload-type"
      },
      {
        name  = "tolerations[0].operator"
        value = "Equal"
      },
      {
        name  = "tolerations[0].value"
        value = "support"
      },
      {
        name  = "tolerations[0].effect"
        value = "NoSchedule"
      },
      # Resource limits
      {
        name  = "resources.requests.cpu"
        value = "100m"
      },
      {
        name  = "resources.requests.memory"
        value = "256Mi"
      },
      {
        name  = "resources.limits.cpu"
        value = "500m"
      },
      {
        name  = "resources.limits.memory"
        value = "512Mi"
      },
      # DNS Configuration (fix for internal service resolution)
      # See: https://github.com/gravitational/teleport/discussions/34743
      # Force pods to use only the cluster DNS server to resolve *.svc.cluster.local names
      {
        name  = "dnsPolicy"
        value = "None"
      },
      {
        name  = "dnsConfig.nameservers[0]"
        value = local.gke_dns_service_ip
      },
      {
        name  = "dnsConfig.searches[0]"
        value = "teleport-agent.svc.cluster.local"
      },
      {
        name  = "dnsConfig.searches[1]"
        value = "svc.cluster.local"
      },
      {
        name  = "dnsConfig.searches[2]"
        value = "cluster.local"
      },
      {
        name  = "dnsConfig.options[0].name"
        value = "ndots"
      },
      {
        name  = "dnsConfig.options[0].value"
        value = "2"
        type  = "string"
      }
    ],
    # CA Pin (optional, recommended for production)
    var.teleport_ca_pin != "" ? [
      {
        name  = "caPin"
        value = var.teleport_ca_pin
      }
    ] : [],
    # Database configuration (if enabled) — one Teleport DB registration per
    # entry in google_sql_database_instance.main (var.databases). The
    # "core" key produces a name byte-identical to the legacy single-instance
    # registration so existing Teleport DB resources are not recreated.
    #
    # Stability note: `keys()` returns lexicographically-sorted keys, so the
    # databases[N] index is stable for any given key set. Inserting a new key
    # that sorts before an existing one (e.g. `analytics` before `core`) will
    # shift all subsequent indices and trigger a brief Teleport DB agent
    # reconnect for every database — no data loss, but operationally visible.
    # Prefer adding new keys with names that sort *after* every existing key.
    var.teleport_db_enabled && var.database_enabled ? flatten([
      for idx, k in keys(google_sql_database_instance.main) : [
        {
          name  = "databases[${idx}].name"
          value = k == "core" ? "${var.project_name}-${var.environment}-cloudsql" : "${var.project_name}-${var.environment}-cloudsql-${k}"
        },
        {
          name  = "databases[${idx}].protocol"
          value = "postgres"
        },
        {
          name  = "databases[${idx}].uri"
          value = "${google_sql_database_instance.main[k].private_ip_address}:5432"
        },
        {
          name  = "databases[${idx}].gcp.project_id"
          value = var.gcp_project_id
        },
        {
          name  = "databases[${idx}].gcp.instance_id"
          value = google_sql_database_instance.main[k].name
        },
        {
          name  = "databases[${idx}].tls.mode"
          value = "verify-ca"
        },
        {
          name  = "databases[${idx}].static_labels.env"
          value = var.environment
        },
        {
          name  = "databases[${idx}].static_labels.cloud"
          value = "gcp"
        },
        {
          name  = "databases[${idx}].static_labels.customer"
          value = var.project_name
        },
        {
          name  = "databases[${idx}].static_labels.type"
          value = "database"
        },
        {
          name  = "databases[${idx}].static_labels.db-user"
          value = trimsuffix(google_service_account.teleport_db[0].email, ".gserviceaccount.com")
        },
        {
          name  = "databases[${idx}].static_labels.db"
          value = k
        }
      ]
    ]) : [],
    # Service account annotation for Workload Identity (Teleport DB agent)
    var.access_mode == "teleport" && var.teleport_db_enabled && var.database_enabled ? [
      {
        name  = "annotations.serviceAccount.iam\\.gke\\.io/gcp-service-account"
        value = google_service_account.teleport_db[0].email
      }
    ] : [],
    # hostAliases — route Teleport proxy hostname through the gateway proxy
    # so all agent traffic (including reverse tunnel) exits via a single static IP
    var.teleport_gateway_ip != null ? [
      {
        name  = "hostAliases[0].ip"
        value = var.teleport_gateway_ip
      },
      {
        name  = "hostAliases[0].hostnames[0]"
        value = split(":", var.teleport_proxy_address)[0]
      }
    ] : []
  )

  depends_on = [
    google_container_node_pool.pools,
    google_service_account.teleport_db,
    kubernetes_job_v1.cloudsql_iam_bootstrap
  ]
}
