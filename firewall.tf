# ===== Firewall Rules =====
# VPC-level firewall rules

# Allow internal communication within the VPC
resource "google_compute_firewall" "internal" {
  count   = var.create_firewall_rules ? 1 : 0
  name    = "${local.name_prefix}-allow-internal"
  network = local.vpc_id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [local.subnet_cidr, var.pods_cidr, var.services_cidr]
}

# Allow GKE master to reach nodes (for webhooks, exec, logs, etc.)
resource "google_compute_firewall" "gke_master_to_nodes" {
  count   = var.create_firewall_rules ? 1 : 0
  name    = "${local.name_prefix}-gke-master-nodes"
  network = local.vpc_id

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "10250"]
  }

  source_ranges = [var.master_ipv4_cidr_block]
  target_tags   = ["gke-${local.resource_names.gke}"]
}

# Allow health checks from Google Cloud load balancers
resource "google_compute_firewall" "health_checks" {
  count   = var.create_firewall_rules ? 1 : 0
  name    = "${local.name_prefix}-allow-health-checks"
  network = local.vpc_id

  allow {
    protocol = "tcp"
  }

  # Google health check IP ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["gke-${local.resource_names.gke}"]
}

# Allow IAP (Identity-Aware Proxy) for debugging/SSH if needed
resource "google_compute_firewall" "iap" {
  count   = var.create_firewall_rules ? 1 : 0
  name    = "${local.name_prefix}-allow-iap"
  network = local.vpc_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google IAP IP range
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["gke-${local.resource_names.gke}"]
}

# ===== Egress Restriction Rules =====
# When enabled, deny all egress except internal traffic, GKE control plane,
# Google APIs, and explicitly allowed external IPs.
#
# Google API access relies on Private Google Access + Cloud DNS private zones
# (see network.tf) to route *.googleapis.com traffic to the private VIP ranges
# (199.36.153.4/30 and 199.36.153.8/30) allowed below. Without these DNS zones,
# pods resolve googleapis.com to public IPs which are blocked by egress_deny_all.

# Allow internal + GKE essential egress
resource "google_compute_firewall" "egress_allow_internal" {
  count     = var.create_network && var.create_firewall_rules && var.egress_restricted ? 1 : 0
  name      = "${local.name_prefix}-egress-allow-internal"
  network   = local.vpc_id
  direction = "EGRESS"
  priority  = 900

  allow {
    protocol = "all"
  }

  destination_ranges = compact([
    local.subnet_cidr,                                    # Node subnet
    var.pods_cidr,                                        # Pod CIDR
    var.services_cidr,                                    # Service CIDR
    var.master_ipv4_cidr_block,                           # GKE control plane
    "169.254.169.254/32",                                 # GCE metadata server
    "35.199.192.0/19",                                    # GKE metadata server proxy (node-to-GKE services)
    "199.36.153.4/30",                                    # Private Google Access (restricted.googleapis.com)
    "199.36.153.8/30",                                    # Private Google Access (private.googleapis.com)
    var.database_enabled ? var.database_subnet_cidr : "", # Cloud SQL private service connection
  ])

  target_tags = ["gke-${local.resource_names.gke}"]
}

# Allow egress to specific external IPs
resource "google_compute_firewall" "egress_allow_external" {
  count     = var.create_network && var.create_firewall_rules && var.egress_restricted && length(var.egress_allowed_ips) > 0 ? 1 : 0
  name      = "${local.name_prefix}-egress-allow-external"
  network   = local.vpc_id
  direction = "EGRESS"
  priority  = 800

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = var.egress_allowed_ips

  target_tags = ["gke-${local.resource_names.gke}"]
}

# Deny all other egress
resource "google_compute_firewall" "egress_deny_all" {
  count     = var.create_network && var.create_firewall_rules && var.egress_restricted ? 1 : 0
  name      = "${local.name_prefix}-egress-deny-all"
  network   = local.vpc_id
  direction = "EGRESS"
  priority  = 1000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]

  target_tags = ["gke-${local.resource_names.gke}"]
}
