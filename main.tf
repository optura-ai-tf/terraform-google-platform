# ===== Terraform Configuration =====
# Provider floors use lower bounds rather than pessimistic pins so consuming
# root configurations can resolve the latest compatible major without an
# upstream module bump. The root config owns the backend and exact version
# locks via its lockfile.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}

# ===== Provider Configuration =====

provider "google" {
  project = var.gcp_project_id
  region  = var.region

  default_labels = local.common_labels
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.region

  default_labels = local.common_labels
}

# ===== In-Cluster Detection (for TFC Agent) =====

locals {
  is_in_cluster = fileexists("/var/run/secrets/kubernetes.io/serviceaccount/token")
}

# ===== Kubernetes & Helm Providers =====

# When running in-cluster (TFC agent pod), use service account token
# When running externally, use GKE cluster auth

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = local.is_in_cluster ? "https://kubernetes.default.svc" : "https://${google_container_cluster.main.endpoint}"
  token                  = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/token") : data.google_client_config.default.access_token
  cluster_ca_certificate = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") : base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
}

provider "kubectl" {
  host                   = local.is_in_cluster ? "https://kubernetes.default.svc" : "https://${google_container_cluster.main.endpoint}"
  token                  = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/token") : data.google_client_config.default.access_token
  cluster_ca_certificate = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") : base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  load_config_file       = false
}

provider "helm" {
  kubernetes = {
    host                   = local.is_in_cluster ? "https://kubernetes.default.svc" : "https://${google_container_cluster.main.endpoint}"
    token                  = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/token") : data.google_client_config.default.access_token
    cluster_ca_certificate = local.is_in_cluster ? file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") : base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  }
}

# ===== Required API Services =====

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudkms.googleapis.com",
    "servicenetworking.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "dns.googleapis.com",
  ])

  project                    = var.gcp_project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Wait for API enablement to propagate
resource "time_sleep" "api_propagation" {
  create_duration = "60s"

  depends_on = [google_project_service.apis]
}

# ===== Data Sources =====

data "google_project" "current" {}

# ===== Local Values =====

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  resource_names = {
    vpc      = "vpc-${local.name_prefix}"
    gke      = "gke-${local.name_prefix}"
    registry = "${var.project_name}-${var.environment}"
    cloudsql = "sql-${local.name_prefix}"
  }

  common_labels = merge(var.labels, {
    environment = var.environment
    managed-by  = "terraform"
    project     = var.project_name
  })
}
