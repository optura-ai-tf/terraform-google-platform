# ===== Data Sources for Existing Network =====

data "google_compute_network" "existing" {
  count   = var.create_network ? 0 : 1
  name    = var.existing_vpc_name
  project = var.existing_vpc_project != "" ? var.existing_vpc_project : var.gcp_project_id
}

data "google_compute_subnetwork" "existing" {
  count   = var.create_network ? 0 : 1
  name    = var.existing_subnet_name
  region  = var.region
  project = var.existing_vpc_project != "" ? var.existing_vpc_project : var.gcp_project_id
}

# ===== Network Resolution Locals =====

locals {
  vpc_id      = var.create_network ? google_compute_network.main[0].id : data.google_compute_network.existing[0].id
  vpc_name    = var.create_network ? google_compute_network.main[0].name : data.google_compute_network.existing[0].name
  subnet_id   = var.create_network ? google_compute_subnetwork.nodes[0].id : data.google_compute_subnetwork.existing[0].id
  subnet_cidr = var.create_network ? var.subnet_cidr : data.google_compute_subnetwork.existing[0].ip_cidr_range
}

# ===== VPC Network =====

resource "google_compute_network" "main" {
  count                   = var.create_network ? 1 : 0
  name                    = local.resource_names.vpc
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [time_sleep.api_propagation]
}

# ===== Subnets =====

# Primary node subnet with secondary ranges for pods and services
resource "google_compute_subnetwork" "nodes" {
  count         = var.create_network ? 1 : 0
  name          = "${local.name_prefix}-nodes"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main[0].id

  # Enable Private Google Access for Google APIs
  private_ip_google_access = true

  # Secondary ranges for GKE VPC-native cluster
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Proxy-only subnet for internal HTTP(S) load balancers (Envoy-based)
resource "google_compute_subnetwork" "proxy_only" {
  count         = var.create_network ? 1 : 0
  name          = "${local.name_prefix}-proxy-only"
  ip_cidr_range = var.proxy_only_cidr
  region        = var.region
  network       = google_compute_network.main[0].id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# ===== Cloud Router (required for Cloud NAT) =====

resource "google_compute_router" "main" {
  count   = var.create_network && var.enable_cloud_nat ? 1 : 0
  name    = "${local.name_prefix}-router"
  region  = var.region
  network = google_compute_network.main[0].id
}

# ===== Cloud NAT =====
# Note: Cloud NAT is regional, not per-AZ. One Cloud NAT handles all zones.

resource "google_compute_router_nat" "main" {
  count  = var.create_network && var.enable_cloud_nat ? 1 : 0
  name   = "${local.name_prefix}-nat"
  router = google_compute_router.main[0].name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ===== Private Service Connection (for Cloud SQL) =====

resource "google_compute_global_address" "private_ip_range" {
  count         = var.create_private_service_connection && var.database_enabled ? 1 : 0
  name          = "${local.name_prefix}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", var.database_subnet_cidr)[0]
  prefix_length = tonumber(split("/", var.database_subnet_cidr)[1])
  network       = local.vpc_id
}

resource "google_service_networking_connection" "private_vpc" {
  count                   = var.create_private_service_connection && var.database_enabled ? 1 : 0
  network                 = local.vpc_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range[0].name]

  # ABANDON on destroy: Cloud SQL deletion is async and the peering can't be
  # removed until the instance is fully gone. GCP cleans up the peering
  # automatically once no producers remain.
  deletion_policy = "ABANDON"

  depends_on = [time_sleep.api_propagation]
}

# ===== Cloud DNS Private Zones for Private Google Access =====
# When egress is restricted, pods resolve *.googleapis.com to public IPs which
# are blocked by the egress deny-all firewall rule. These DNS zones redirect
# Google API traffic to the private VIP range (199.36.153.8/30) that is allowed
# in the egress rules (see firewall.tf). Required for any in-cluster workload
# that calls GCP APIs (e.g. Teleport kube-agent for Cloud SQL CA cert download).

resource "google_dns_managed_zone" "googleapis" {
  count       = var.create_network && var.egress_restricted ? 1 : 0
  name        = "${local.name_prefix}-googleapis"
  dns_name    = "googleapis.com."
  description = "Private DNS zone for Google APIs via Private Google Access"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.main[0].id
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_dns_record_set" "googleapis_cname" {
  count        = var.create_network && var.egress_restricted ? 1 : 0
  managed_zone = google_dns_managed_zone.googleapis[0].name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}

resource "google_dns_record_set" "private_googleapis_a" {
  count        = var.create_network && var.egress_restricted ? 1 : 0
  managed_zone = google_dns_managed_zone.googleapis[0].name
  name         = "private.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

resource "google_dns_managed_zone" "gcr" {
  count       = var.create_network && var.egress_restricted ? 1 : 0
  name        = "${local.name_prefix}-gcr"
  dns_name    = "gcr.io."
  description = "Private DNS zone for GCR via Private Google Access"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.main[0].id
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_dns_record_set" "gcr_cname" {
  count        = var.create_network && var.egress_restricted ? 1 : 0
  managed_zone = google_dns_managed_zone.gcr[0].name
  name         = "*.gcr.io."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["gcr.io."]
}

resource "google_dns_record_set" "gcr_a" {
  count        = var.create_network && var.egress_restricted ? 1 : 0
  managed_zone = google_dns_managed_zone.gcr[0].name
  name         = "gcr.io."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}
