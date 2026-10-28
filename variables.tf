# ===== Global Configuration =====

variable "gcp_project_id" {
  description = "GCP project ID for all resources"
  type        = string
}

variable "region" {
  description = "GCP region for all resources (e.g., us-central1, us-east1, europe-west1)"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, stg, uat, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "uat", "prod"], var.environment)
    error_message = "Environment must be dev, stg, uat, or prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming (lowercase, 3-12 chars, alphanumeric and hyphens)"
  type        = string
  default     = "optura"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,11}$", var.project_name))
    error_message = "Project name must be 3-12 lowercase alphanumeric characters or hyphens, starting with a letter."
  }
}

variable "labels" {
  description = "Additional labels to apply to all resources"
  type        = map(string)
  default     = {}
}

# ===== Network Configuration =====

variable "vpc_cidr" {
  description = "Primary CIDR block for VPC network (used for documentation; GCP subnets define their own CIDRs)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR range for the primary node subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pods"
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE services"
  type        = string
  default     = "10.8.0.0/20"
}

variable "proxy_only_cidr" {
  description = "CIDR range for the proxy-only subnet (for internal load balancers)"
  type        = string
  default     = "10.0.32.0/24"
}

variable "database_subnet_cidr" {
  description = "CIDR range for database subnet (Cloud SQL private service connection)"
  type        = string
  default     = "10.0.48.0/24"
}

variable "enable_cloud_nat" {
  description = "Whether to create Cloud NAT for outbound internet access from private nodes"
  type        = bool
  default     = true
}

variable "create_network" {
  description = "Whether to create a new VPC network. Set to false to use an existing network."
  type        = bool
  default     = true
}

variable "existing_vpc_project" {
  description = "Project ID of the existing VPC network (for Shared VPC). Defaults to current project."
  type        = string
  default     = ""
}

variable "existing_vpc_name" {
  description = "Name of an existing VPC network to use (required when create_network = false)"
  type        = string
  default     = ""

  validation {
    condition     = var.create_network || var.existing_vpc_name != ""
    error_message = "existing_vpc_name must be set when create_network = false."
  }
}

variable "existing_subnet_name" {
  description = "Name of an existing subnet to use for GKE nodes (required when create_network = false). Must have secondary ranges named 'pods' and 'services'."
  type        = string
  default     = ""

  validation {
    condition     = var.create_network || var.existing_subnet_name != ""
    error_message = "existing_subnet_name must be set when create_network = false."
  }
}

variable "create_firewall_rules" {
  description = "Whether to create VPC firewall rules. Set to false when using an existing network with pre-configured rules."
  type        = bool
  default     = true
}

variable "egress_restricted" {
  description = "Whether to restrict node egress to only allowed external IPs (plus internal/GKE traffic)"
  type        = bool
  default     = false
}

variable "egress_allowed_ips" {
  description = "List of external IPs (CIDR notation) allowed for node egress when egress_restricted is true. Defaults to empty — supply your deployment's egress IP(s)."
  type        = list(string)
  default     = []

  validation {
    condition     = !(var.egress_restricted && length(var.egress_allowed_ips) == 0)
    error_message = "egress_allowed_ips must be non-empty when egress_restricted = true (otherwise no egress allow-list rule is created)."
  }
}

variable "create_private_service_connection" {
  description = "Whether to create a private service connection for Cloud SQL. Set to false if the existing VPC already has one."
  type        = bool
  default     = true
}

# ===== GKE Configuration =====

variable "kubernetes_version" {
  description = "Kubernetes version for GKE cluster"
  type        = string
  default     = "1.34"
}

variable "api_server_authorized_cidrs" {
  description = "CIDRs authorized to access the GKE API server (empty = unrestricted when public)"
  type        = list(string)
  default     = []
}

variable "enable_cluster_encryption" {
  description = "Whether to encrypt GKE secrets at rest with Cloud KMS (application-layer encryption)"
  type        = bool
  default     = true
}

variable "autopilot_enabled" {
  description = "Create a GKE Autopilot cluster instead of GKE Standard. Autopilot has no node pools, so node_pools is ignored. Changing this on an existing cluster replaces it."
  type        = bool
  default     = false
}

variable "release_channel" {
  description = "GKE release channel (REGULAR, RAPID, STABLE, UNSPECIFIED)"
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["REGULAR", "RAPID", "STABLE", "UNSPECIFIED"], var.release_channel)
    error_message = "Release channel must be REGULAR, RAPID, STABLE, or UNSPECIFIED."
  }
}

# ===== Node Pools =====

variable "node_pools" {
  description = "Map of GKE node pool configurations. Ignored when autopilot_enabled = true."
  type = map(object({
    machine_type  = string
    min_count     = number
    max_count     = number
    desired_count = optional(number)
    disk_size_gb  = number
    disk_type     = optional(string, "pd-standard")
    image_type    = optional(string, "COS_CONTAINERD")
    spot          = optional(bool, false)
    labels        = map(string)
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = {
    system = {
      machine_type = "e2-small"
      min_count    = 1
      max_count    = 2
      disk_size_gb = 50
      labels = {
        "workload-type" = "system"
        "node-pool"     = "system"
      }
      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]
    }
    support = {
      machine_type  = "e2-small"
      min_count     = 0
      max_count     = 2
      desired_count = 1
      disk_size_gb  = 50
      labels = {
        "workload-type" = "support"
        "node-pool"     = "support"
      }
    }
    application = {
      machine_type  = "e2-medium"
      min_count     = 0
      max_count     = 3
      desired_count = 1
      disk_size_gb  = 100
      labels = {
        "workload-type" = "application"
        "node-pool"     = "application"
      }
    }
  }
}

# ===== Artifact Registry Configuration =====

variable "registry_enabled" {
  description = "Whether to create an Artifact Registry repository"
  type        = bool
  default     = false
}

variable "registry_repository_id" {
  description = "Existing Artifact Registry repository ID (when registry_enabled = false)"
  type        = string
  default     = ""
}

variable "registry_format" {
  description = "Format of the Artifact Registry repository"
  type        = string
  default     = "DOCKER"

  validation {
    condition     = contains(["DOCKER", "MAVEN", "NPM", "PYTHON", "APT", "YUM", "GO"], var.registry_format)
    error_message = "Registry format must be one of: DOCKER, MAVEN, NPM, PYTHON, APT, YUM, GO."
  }
}

variable "registry_immutable_tags" {
  description = "Whether to enable immutable tags on the Artifact Registry"
  type        = bool
  default     = false
}

variable "registry_vulnerability_scanning" {
  description = "Whether to enable vulnerability scanning"
  type        = bool
  default     = true
}

variable "registry_cleanup_policies" {
  description = "Cleanup policies for Artifact Registry"
  type = object({
    keep_latest_images = optional(number, 3)
    expire_untagged    = optional(number, 3)
  })
  default = {
    keep_latest_images = 3
    expire_untagged    = 3
  }
}

# ===== SSL Certificate Configuration =====

variable "ssl_certificate_create" {
  description = "Whether to create a Google-managed SSL certificate"
  type        = bool
  default     = false
}

variable "ssl_certificate_domains" {
  description = "List of domains for the Google-managed SSL certificate"
  type        = list(string)
  default     = []
}

# ===== Cloud SQL Configuration =====

variable "database_enabled" {
  description = "Whether to create a Cloud SQL PostgreSQL instance"
  type        = bool
  default     = true
}

variable "database_tier" {
  description = "Cloud SQL machine tier (e.g., db-f1-micro, db-custom-1-3840, db-custom-2-7680)"
  type        = string
  default     = "db-f1-micro"
}

variable "database_edition" {
  description = "Cloud SQL edition (ENTERPRISE or ENTERPRISE_PLUS). ENTERPRISE supports db-f1-micro/db-custom tiers; ENTERPRISE_PLUS requires db-perf-optimized-N-* tiers."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.database_edition)
    error_message = "Database edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "database_version" {
  description = "PostgreSQL version for Cloud SQL"
  type        = string
  default     = "POSTGRES_17"
}

variable "database_disk_size" {
  description = "Initial disk size in GB for Cloud SQL"
  type        = number
  default     = 20
}

variable "database_disk_autoresize" {
  description = "Whether to enable disk autoresize for Cloud SQL"
  type        = bool
  default     = true
}

variable "database_disk_autoresize_limit" {
  description = "Maximum disk size in GB for autoresize (0 = unlimited)"
  type        = number
  default     = 100
}

variable "database_ha_enabled" {
  description = "Whether to enable high availability (regional) for Cloud SQL"
  type        = bool
  default     = false
}

variable "database_backup_enabled" {
  description = "Whether to enable automated backups"
  type        = bool
  default     = true
}

variable "database_backup_retention_days" {
  description = "Number of days to retain backups (1-365)"
  type        = number
  default     = 7

  validation {
    condition     = var.database_backup_retention_days >= 1 && var.database_backup_retention_days <= 365
    error_message = "Backup retention must be between 1 and 365 days."
  }
}

variable "database_deletion_protection" {
  description = "Whether to enable deletion protection for Cloud SQL"
  type        = bool
  default     = false
}

variable "database_admin_username" {
  description = "Administrator username for Cloud SQL"
  type        = string
  default     = "psqladmin"
  sensitive   = true
}

variable "database_name" {
  description = "Name of the default database to create"
  type        = string
  default     = "optura"
}

variable "database_flags" {
  description = "Additional database flags for Cloud SQL"
  type        = map(string)
  default     = {}
}

variable "database_insights_enabled" {
  description = "Whether to enable Query Insights for Cloud SQL"
  type        = bool
  default     = true
}

variable "databases" {
  description = <<-EOT
    Map of named Cloud SQL PostgreSQL instances to provision. Each key becomes part
    of the cloud-side instance name. The "core" key is reserved for the legacy
    primary instance and its on-cloud name is preserved (no -core suffix); every
    other key produces a suffixed instance ($${base}-$${each.key}).

    Per-entry overrides (all optional — fall back to top-level database_* defaults
    when omitted):
      - tier                    (string)        — Cloud SQL machine tier
      - edition                 (string)        — ENTERPRISE or ENTERPRISE_PLUS
      - disk_size               (number)        — Initial disk size in GB
      - disk_autoresize_limit   (number)        — Autoresize cap in GB (0 = unlimited)
      - ha_enabled              (bool)          — Regional high availability
      - backup_enabled          (bool)          — Automated backups + PITR
      - backup_retention_days   (number)        — Backup retention (1-365)
      - deletion_protection     (bool)          — Enable deletion protection
      - admin_username          (string)        — Built-in admin user name
      - db_name                 (string)        — Initial database name
      - database_flags          (map(string))   — Additional database flags
      - insights_enabled        (bool)          — Query Insights toggle
  EOT
  type = map(object({
    tier                  = optional(string)
    edition               = optional(string)
    disk_size             = optional(number)
    disk_autoresize_limit = optional(number)
    ha_enabled            = optional(bool)
    backup_enabled        = optional(bool)
    backup_retention_days = optional(number)
    deletion_protection   = optional(bool)
    admin_username        = optional(string)
    db_name               = optional(string)
    database_flags        = optional(map(string))
    insights_enabled      = optional(bool)
  }))
  # Default ships only `core` so existing deployments do not see a surprise
  # second Cloud SQL instance on upgrade. Add `temporal = {}` (or any other
  # key) in your tfvars when you actually need it — see example.tfvars.
  default = {
    core = {}
  }

  validation {
    condition     = contains(keys(var.databases), "core")
    error_message = "databases must include a \"core\" key. The \"core\" key is required because removing it would destroy the existing primary Cloud SQL instance (the legacy single-DB deployment migrates to var.databases[\"core\"] via a moved block). See gcp/README.md 'Upgrading from single-DB' section for migration guidance."
  }
}

# ===== Storage Configuration =====

variable "storage_logging_enabled" {
  description = "Whether to create a logging storage bucket (for Loki, Fluentd, etc.)"
  type        = bool
  default     = true
}

variable "storage_logging_namespace" {
  description = "Kubernetes namespace for logging service account"
  type        = string
  default     = "monitoring"
}

variable "storage_logging_service_account" {
  description = "Kubernetes service account name for logging storage access"
  type        = string
  default     = "loki"
}

variable "storage_logging_lifecycle_rules" {
  description = "Lifecycle rules for logging bucket"
  type = object({
    nearline_after_days = optional(number, 30)
    coldline_after_days = optional(number, 90)
    delete_after_days   = optional(number, 365)
    noncurrent_days     = optional(number, 7)
  })
  default = {}
}

variable "storage_general_enabled" {
  description = "Whether to create a general purpose storage bucket"
  type        = bool
  default     = true
}

variable "storage_general_namespace" {
  description = "Kubernetes namespace for general storage service account"
  type        = string
  default     = "default"
}

variable "storage_general_service_account" {
  description = "Kubernetes service account name for general storage access"
  type        = string
  default     = "app-storage"
}

variable "storage_general_versioning" {
  description = "Enable versioning on general storage bucket"
  type        = bool
  default     = true
}

variable "storage_general_cors_origins" {
  description = "Browser origins allowed to call the general bucket directly (presigned uploads). Empty disables CORS, which blocks every browser upload."
  type        = list(string)
  default     = []
}

variable "storage_general_lifecycle_rules" {
  description = "Lifecycle rules for general storage bucket"
  type = object({
    nearline_after_days = optional(number, 90)
    noncurrent_days     = optional(number, 30)
  })
  default = {}
}

# ===== Vertex AI Configuration =====

variable "vertex_ai_enabled" {
  description = "Whether to create a Workload Identity service account for Vertex AI access"
  type        = bool
  default     = false
}

variable "vertex_ai_workload_identities" {
  description = "Map of Kubernetes service accounts that need Vertex AI access. The key is the K8s service account name."
  type = map(object({
    namespace = string
  }))
  default = {
    intent = { namespace = "core" }
  }
}

variable "vertex_ai_roles" {
  description = "List of IAM roles to grant to the Vertex AI service account"
  type        = list(string)
  default     = ["roles/aiplatform.user"]
}

# ===== Access Configuration =====

variable "access_mode" {
  description = "Cluster access mode: 'teleport' for zero-trust access or 'vpn' for traditional VPN"
  type        = string
  default     = "vpn"

  validation {
    condition     = contains(["teleport", "vpn"], var.access_mode)
    error_message = "Access mode must be 'teleport' or 'vpn'."
  }
}

variable "teleport_proxy_address" {
  description = "Teleport proxy address as host:port (required when access_mode = teleport). Defaults to empty — supply your own Teleport proxy."
  type        = string
  default     = ""
}

variable "teleport_join_token" {
  description = "Teleport join token for Kubernetes agent"
  type        = string
  default     = ""
  sensitive   = true
}

variable "teleport_ca_pin" {
  description = "Teleport CA pin for secure joining"
  type        = string
  default     = ""
  sensitive   = true
}

variable "teleport_version" {
  description = "Teleport agent Helm chart version"
  type        = string
  default     = "18.5.1"
}

variable "teleport_agent_chart_repository" {
  description = "Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access_mode = teleport — supply your own."
  type        = string
  default     = ""
}

variable "teleport_agent_image" {
  description = "Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters)."
  type        = string
  default     = ""
}

variable "teleport_gateway_ip" {
  description = "Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP."
  type        = string
  default     = null
}

variable "teleport_db_enabled" {
  description = "Whether to enable Teleport database access agent for Cloud SQL"
  type        = bool
  default     = true
}

# ===== Private Cluster =====

variable "private_cluster_enabled" {
  description = "Whether to enable private cluster (no public endpoint). Requires TFC agent or VPN."
  type        = bool
  default     = false
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block for GKE master nodes (must be /28, cannot overlap with other subnets)"
  type        = string
  default     = "172.16.0.0/28"
}

# ===== Cluster Access Control =====

variable "cluster_admin_emails" {
  description = "List of GCP user/group/service account emails to grant cluster-admin access"
  type        = list(string)
  default     = []
}

# ===== Terraform Cloud Agent =====

variable "tfc_agent_enabled" {
  description = "Whether to deploy a Terraform Cloud agent inside the cluster"
  type        = bool
  default     = false
}

variable "tfc_agent_token" {
  description = "Terraform Cloud agent token"
  type        = string
  default     = null
  sensitive   = true
}

variable "tfc_agent_version" {
  description = "Terraform Cloud agent Docker image version"
  type        = string
  default     = "1.28.5"
}

# ===== Monitoring =====

variable "monitoring_enabled" {
  description = "Whether to enable GKE monitoring (Cloud Monitoring integration)"
  type        = bool
  default     = true
}
