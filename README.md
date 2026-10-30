# GCP GKE Platform Module

A production-ready GKE platform as a reusable Terraform module: a VPC, a regional
GKE cluster with the standard three-tier node pool layout, Artifact Registry,
Cloud Load Balancing, optional Cloud SQL PostgreSQL (single or multiple named
databases), GCS storage buckets wired to Workload Identity, and zero-trust access
via Teleport.

This is the **module** view of the platform: everything below is reframed for a
consuming root configuration that *calls* this module, rather than a live root you
`terraform apply` directly. The consuming root owns the backend and provider
authentication; the module owns the resources.

## Usage

### Terraform Registry

```hcl
module "platform" {
  source  = "optura-ai-tf/platform/google"
  version = "~> 0.5"

  gcp_project_id = "my-project-id"
  environment    = "dev"
  region         = "us-central1"
  project_name   = "optura"

  cluster_admin_emails = ["user:platform-team@optura.ai"]
}
```

### Git source

To pin directly to a tag without the registry:

```hcl
module "platform" {
  source = "git::https://github.com/optura-ai-tf/terraform-google-platform.git?ref=v0.5.0"

  gcp_project_id = "my-project-id"
  environment    = "dev"
  region         = "us-central1"
  project_name   = "optura"

  cluster_admin_emails = ["user:platform-team@optura.ai"]
}
```

### Complete example

A full worked example — Teleport access, Cloud SQL, three-tier node pools — lives
in [`examples/complete/`](examples/complete/). It is the fastest way to see every
input wired together:

```hcl
module "platform" {
  source = "../../"

  # Core identity
  gcp_project_id = var.gcp_project_id
  region         = "us-central1"
  environment    = "dev"
  project_name   = "optura"

  labels = {
    cost_center = "engineering"
    owner       = "platform-team"
  }

  # Three-tier node pools
  node_pools = {
    system = {
      machine_type = "e2-standard-2"
      min_count    = 1
      max_count    = 2
      disk_size_gb = 50
      labels       = { "workload-type" = "system", "node-pool" = "system" }
      taints       = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    support = {
      machine_type  = "e2-standard-2"
      min_count     = 0
      max_count     = 4
      desired_count = 1
      disk_size_gb  = 50
      labels        = { "workload-type" = "support", "node-pool" = "support" }
    }
    application = {
      machine_type  = "e2-standard-2"
      min_count     = 0
      max_count     = 5
      desired_count = 1
      disk_size_gb  = 100
      labels        = { "workload-type" = "application", "node-pool" = "application" }
    }
  }

  # Cloud SQL
  database_tier                  = "db-custom-2-7680"
  database_ha_enabled            = false
  database_deletion_protection   = false
  database_disk_autoresize_limit = 100

  # Access via Teleport
  access_mode            = "teleport"
  teleport_proxy_address = "teleport.example.com:443"
  teleport_join_token    = var.teleport_join_token
  teleport_db_enabled    = true
}
```

### Backend and provider authentication (consumer-owned)

The module declares **no** backend and **no** `google` provider credentials — that
is the responsibility of the consuming root. Configure them in your root, not on
the module call:

```hcl
# In the consuming root configuration:
terraform {
  # HCP-managed state (cloud block) ...
  cloud {
    organization = "optura-ai"
    workspaces { name = "gke-dev" }
  }
  # ... or a GCS backend:
  # backend "gcs" {
  #   bucket = "optura-terraform-state"
  #   prefix = "gcp/gke/dev"
  # }
}

# Provider auth (project / credentials) lives in the root, too.
# The module reads project and region from its own gcp_project_id / region inputs.
provider "google" {
  project = "my-project-id"
  region  = "us-central1"
}
```

Required GCP APIs are enabled by the module itself, but pre-enabling them in your
project speeds up the first apply:

```bash
gcloud services enable \
  compute.googleapis.com container.googleapis.com sqladmin.googleapis.com \
  artifactregistry.googleapis.com cloudkms.googleapis.com \
  servicenetworking.googleapis.com containerscanning.googleapis.com \
  iam.googleapis.com cloudresourcemanager.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com dns.googleapis.com
```

After apply (≈15 minutes), configure `kubectl` using the emitted command:

```bash
$(terraform output -raw kubectl_config_command)
kubectl get nodes
```

---

## Configuration

All settings below are **inputs on the module call** (`module "platform" { ... }`),
not entries in a `*.tfvars` file. Sensitive values such as
`teleport_join_token`, `tfc_agent_token`, and `database_admin_password` should be
sourced from your root's variables or a secrets backend, never hard-coded.

### Core Variables

Always set these:

| Input | Required | Default | Description |
|---|---|---|---|
| `gcp_project_id` | yes | — | Your GCP project ID |
| `environment` | yes | — | `dev`, `stg`, `uat`, or `prod` |
| `region` | no | `us-central1` | GCP region |
| `project_name` | no | `optura` | Used in all resource names (lowercase, 3–12 chars) |
| `cluster_admin_emails` | recommended | `[]` | GCP user/group/SA emails to grant `cluster-admin` (e.g. `user:me@optura.ai`). Without this, only the deploying principal has access. |
| `api_server_authorized_cidrs` | no | `[]` (open) | Restrict API access to specific CIDRs. Only applies when `private_cluster_enabled = false`. |

### Feature: Database (`database_enabled`)

Default: **`true`** — a Cloud SQL PostgreSQL instance is created.

Set `database_enabled = false` on the module call to skip it. All `database_*`
inputs are ignored when disabled.

When enabled, the top-level `database_*` inputs configure the default `core`
instance:

| Input | Default | Description |
|---|---|---|
| `database_tier` | `db-f1-micro` | Machine tier. Use `db-custom-2-7680` or higher for production. |
| `database_disk_size` | `20` | Initial disk size in GB |
| `database_disk_autoresize` | `true` | Grow disk automatically under pressure |
| `database_disk_autoresize_limit` | `100` | Autoresize cap in GB (`0` = unlimited) |
| `database_ha_enabled` | `false` | Enable regional HA (standby replica) for production |
| `database_backup_enabled` | `true` | Enable automated backups |
| `database_backup_retention_days` | `7` | Days to retain backups (1–365) |
| `database_deletion_protection` | `false` | Set `true` for production |
| `database_edition` | `ENTERPRISE` | `ENTERPRISE` (supports `db-f1-micro`/`db-custom-*`) or `ENTERPRISE_PLUS` (requires `db-perf-optimized-N-*` tiers) |
| `database_version` | `POSTGRES_17` | PostgreSQL major version |
| `database_admin_username` | `psqladmin` | Administrator username |
| `database_name` | `optura` | Default database name |
| `database_insights_enabled` | `true` | Query Insights |

#### Multiple named databases (`databases`)

The module provisions one Cloud SQL instance per entry in the `databases` input
(default: `core` only). Each map key becomes part of the cloud-side instance name:

- `core` is reserved for the primary instance — its instance name keeps the
  unsuffixed form (`sql-{project}-{env}` / legacy `optura-{env}-cloudsql`) so an
  existing deployment does not destroy and recreate the production database.
- Every other key is suffixed unconditionally (e.g. `…-temporal`).

Per-entry overrides (all optional) fall back to the top-level `database_*` defaults
when omitted, so a `{}` entry produces exactly the legacy single-instance config:

```hcl
module "platform" {
  source  = "optura-ai-tf/platform/google"
  version = "~> 0.5"

  # ... core inputs ...

  databases = {
    # core inherits all top-level database_* defaults
    core = {}

    # temporal sized independently — recommended for dev to keep costs flat
    temporal = {
      tier      = "db-f1-micro"
      disk_size = 20
      db_name   = "temporal"
      ha_enabled = false
    }
  }
}
```

Supported per-entry fields: `tier`, `edition`, `disk_size`,
`disk_autoresize_limit`, `ha_enabled`, `backup_enabled`, `backup_retention_days`,
`deletion_protection`, `admin_username`, `db_name`, `database_flags`,
`insights_enabled`.

> **Validation:** the `databases` map MUST contain a `core` key. The module
> enforces this — removing `core` would change the state address of the existing
> primary instance and Terraform would destroy + recreate it.

##### Cost impact

Each named instance is a full Cloud SQL server (compute, storage, KMS key, backups).
Adding a `temporal` entry **doubles** the Cloud SQL line item. For dev, override the
second instance to the smallest tier; if you do not need a second database, keep the
default `databases = { core = {} }`.

##### Connection-name outputs

Legacy singular outputs (`database_endpoint`, `database_admin_username`,
`database_admin_password`, `database_name`, `database_server_name`,
`database_address`, `database_port`) are preserved as **aliases for the `core`
entry**, so existing consumers see no change.

For multiple databases, the canonical outputs are maps keyed by `databases` key.
Cloud SQL connection names follow the `project:region:instance` form:

| Output | Type | Description |
|---|---|---|
| `database_endpoints` | `map(string)` | DB key → connection name (`project:region:instance`) |
| `database_names` | `map(string)` | DB key → initial database name |
| `database_admin_usernames` | `map(string)` (sensitive) | DB key → administrator username |
| `database_admin_passwords` | `map(string)` (sensitive) | DB key → administrator password |

```bash
terraform output database_endpoints
# {
#   "core"     = "my-project:us-central1:optura-prod-cloudsql"
#   "temporal" = "my-project:us-central1:optura-prod-cloudsql-temporal"
# }
```

##### Teleport access for named DBs (known limitation)

Each named database is registered with the Teleport DB agent under a distinct name
(`{project}-{env}-cloudsql-{key}` for non-core; `core` keeps the unsuffixed legacy
name). Each registration also sets a Teleport `static_labels.db = <key>` field.

However, the default RBAC roles shipped by this module (`teleport-admins`,
`teleport-viewers`) grant access to **all** registered databases — they are not
scoped per-DB. Any user who can `tsh db connect optura-prod-cloudsql` can also
connect to `optura-prod-cloudsql-temporal`. The `static_labels.db` field is the
intended hook for future per-DB role restrictions (e.g. `db_labels: { db: ["core"] }`).

### Feature: Network (`create_network`)

Default: **`true`** — a new VPC, subnets, Cloud Router, and Cloud NAT are created.

Set `create_network = false` to deploy into an existing VPC. When set, also configure:

| Input | Required | Description |
|---|---|---|
| `existing_vpc_name` | yes | Name of the existing VPC |
| `existing_subnet_name` | yes | Subnet for GKE nodes. Must have secondary ranges named `pods` and `services`, and Private Google Access enabled. |
| `existing_vpc_project` | no | Set only for Shared VPC (defaults to current project) |

When using an existing network, also review:

| Input | Default | Description |
|---|---|---|
| `create_firewall_rules` | `true` | Set `false` if your VPC already has the required firewall rules |
| `create_private_service_connection` | `true` | Set `false` if your VPC already has `servicenetworking.googleapis.com` peered |

The subnet CIDR inputs must match the existing subnet configuration:

| Input | Default | Description |
|---|---|---|
| `subnet_cidr` | `10.0.0.0/20` | Node subnet CIDR |
| `pods_cidr` | `10.4.0.0/14` | Secondary range for pods |
| `services_cidr` | `10.8.0.0/20` | Secondary range for services |
| `master_ipv4_cidr_block` | `172.16.0.0/28` | GKE control plane CIDR (`/28`, must not overlap other subnets) |

### Feature: SSL Certificate (`ssl_certificate_create`)

Default: **`false`** — no managed SSL certificate is created.

Set `ssl_certificate_create = true` to provision a Google-managed SSL certificate.
When enabled, also set:

| Input | Required | Description |
|---|---|---|
| `ssl_certificate_domains` | yes | List of domains (e.g., `["example.com", "*.example.com"]`) |

### Feature: Logging Storage (`storage_logging_enabled`)

Default: **`true`** — a GCS bucket for log storage (Loki) is created.

Set `storage_logging_enabled = false` to skip. When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `storage_logging_namespace` | `monitoring` | Kubernetes namespace for the logging workload |
| `storage_logging_service_account` | `loki` | Service account that gets bucket access via Workload Identity |

The emitted `logging_storage_role_id` output is the GCP service account email to
annotate your Kubernetes service account with for Workload Identity.

### Feature: General Storage (`storage_general_enabled`)

Default: **`true`** — a GCS bucket for application data is created.

Set `storage_general_enabled = false` to skip. When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `storage_general_namespace` | `default` | Kubernetes namespace for the storage workload |
| `storage_general_service_account` | `app-storage` | Service account that gets bucket access via Workload Identity |
| `storage_general_versioning` | `true` | Enable object versioning |

### Feature: Cluster Access via Teleport (`access_mode`)

Default: **`vpn`** — assumes an existing VPN or public endpoint access.

Set `access_mode = "teleport"` to deploy a Teleport agent. When set, also configure:

| Input | Required | Description |
|---|---|---|
| `teleport_proxy_address` | yes | The Teleport proxy to connect to (e.g., `teleport.example.com:443`) |
| `teleport_agent_chart_repository` | yes | Helm repo for the teleport-kube-agent chart (e.g. `https://charts.releases.teleport.dev`, or an OCI mirror) |
| `teleport_agent_image` | no | Agent image; empty uses the chart's default |
| `teleport_join_token` | yes | Source from a root variable / secret, not hard-coded |
| `teleport_ca_pin` | recommended (prod) | CA pin for secure agent joining |
| `teleport_db_enabled` | `true` | Also enable Teleport database access. Requires `database_enabled = true`. |

The module ships two RBAC roles bound through Teleport: `teleport-admins` (full
cluster access) and `teleport-viewers` (read-only).

### Feature: Private Cluster (`private_cluster_enabled`)

Default: **`false`** — the API server has a public endpoint.

Set `private_cluster_enabled = true` to remove the public endpoint. This requires
either a VPN/Cloud Interconnect or an in-cluster Terraform Cloud agent
(`tfc_agent_enabled = true`).

Because a private cluster has no public API endpoint, Terraform itself can no longer
reach the control plane from outside. The module solves this with a **two-phase
bootstrap** using an in-cluster TFC agent:

**Phase 1 — Bootstrap (public API).** Deploy the agent while the API is still public:

```hcl
module "platform" {
  # ... core inputs ...
  tfc_agent_enabled       = true
  tfc_organization        = "optura-ai"
  tfc_agent_pool_name     = "optura-dev-gke"
  private_cluster_enabled = false
}
```

Provide `tfc_agent_token` via a root variable / secret, apply, then confirm the
agent is running:

```bash
kubectl get pods -n terraform-cloud
```

**Phase 2 — Lock down.** In HCP Terraform, set the workspace execution mode to
Agent and select the pool created above. Then flip the input:

```hcl
private_cluster_enabled = true
```

Subsequent plans/applies run from the in-cluster agent, which reaches the API
server over the private endpoint.

When `tfc_agent_enabled = true`, configure:

| Input | Required | Description |
|---|---|---|
| `tfc_agent_token` | yes | Source from a root variable / secret |
| `tfc_organization` | yes | Your HCP Terraform organization name |
| `tfc_agent_pool_name` | yes | Name for the agent pool |

### Node Pools

The `node_pools` input configures all three standardized pools. Each pool carries
both a `workload-type` and a `node-pool` label; the `system` pool is tainted with
`CriticalAddonsOnly=true:NoSchedule`. Workloads target a pool via
`nodeSelector.workload-type` (`system`, `support`, or `application`).

```hcl
node_pools = {
  system = {
    machine_type = "e2-medium"
    min_count    = 2
    max_count    = 4
    disk_size_gb = 50
    labels       = { "workload-type" = "system", "node-pool" = "system" }
    taints       = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
  }
  support = {
    machine_type  = "e2-standard-4"
    min_count     = 1
    max_count     = 4
    desired_count = 2
    disk_size_gb  = 50
    labels        = { "workload-type" = "support", "node-pool" = "support" }
  }
  application = {
    machine_type  = "e2-standard-8"
    min_count     = 2
    max_count     = 10
    desired_count = 3
    disk_size_gb  = 100
    labels        = { "workload-type" = "application", "node-pool" = "application" }
  }
}
```

### GKE Autopilot (`autopilot_enabled`)

The module creates a GKE Standard cluster by default. Set `autopilot_enabled = true`
to create an Autopilot cluster instead. This is a create time choice: flipping it on
an existing cluster replaces the cluster.

On Autopilot:

- `node_pools` is ignored. Google provisions nodes per pod, running as the module's
  node service account and carrying the `gke-<cluster>` network tag the firewall
  rules target.
- Calico, the NodeLocal DNSCache toggle and the Managed Prometheus toggle are not
  set. Autopilot always runs Dataplane V2 network policy, NodeLocal DNSCache and
  Managed Prometheus.
- `release_channel` must not be `UNSPECIFIED`.
- The Cloud SQL IAM bootstrap Job runs in a `cloudsql-bootstrap` namespace instead
  of `kube-system`, and it, the TFC agent and the Teleport agent drop their
  `workload-type: support` placement.
- Workloads that pin `workload-type: <tier>` must also tolerate
  `workload-type=<tier>:NoSchedule`, which makes Autopilot create separate nodes
  for that tier. The gitops bases already carry both; scaffold the customer with
  `opctl new customer --cloud gcp --autopilot`.

```hcl
autopilot_enabled = true
```

---

## Database Access

The Cloud SQL instance has no public endpoint. Connect via a pod, using the
module's `database_endpoint` output (or `database_endpoints["<key>"]` for a named DB):

```bash
kubectl run -it --rm psql --image=postgres:17 --restart=Never -- \
  psql -h $(terraform output -raw database_endpoint) -U psqladmin -d optura
```

Or via Teleport (when `access_mode = "teleport"` and `teleport_db_enabled = true`):

```bash
tsh db ls
tsh db connect optura-dev-cloudsql --db-user=psqladmin --db-name=optura
```

## Push Images to Artifact Registry

Set `registry_enabled = true` on the module call to have it create the repository.
The `registry_url` output gives the push target:

```bash
gcloud auth configure-docker $(terraform output -raw registry_url | cut -d/ -f1)
docker tag myapp:latest $(terraform output -raw registry_url)/myapp:latest
docker push $(terraform output -raw registry_url)/myapp:latest
```

---

## Module notes

A few behaviors are specific to how this module is packaged:

- **Provider blocks are retained in-module (Path A).** The module declares its own
  `kubernetes` and `helm` providers (configured against the cluster it creates).
  As a consequence, the module call **cannot** use `count`, `for_each`, or
  `depends_on` — Terraform forbids those meta-arguments on modules that contain
  provider configurations. Instantiate the module as a plain, single call.
- **In-cluster auto-detection.** `main.tf` detects whether it is running inside a
  TFC agent pod (by probing for the in-cluster service-account token) versus an
  external runner, and switches the `kubernetes`/`helm` provider auth accordingly —
  service-account token in-cluster, GKE cluster auth externally. This is what makes
  the private-cluster two-phase bootstrap work without configuration changes.
- **Provider versions use permissive `>=` floors.** The module sets lower bounds
  (e.g. `google >= 6.0`, `kubernetes >= 2.38`) rather than pessimistic pins, so a
  consuming root can resolve the latest compatible major. Pin exact versions in
  **your own** `.terraform.lock.hcl`, not by editing the module.

---

## Reference

The tables below are generated by `terraform-docs` from `variables.tf`,
`outputs.tf`, and `main.tf`. Do not edit anything between the markers by hand —
regenerate from the repo root with:

```bash
terraform-docs --config .terraform-docs.yml ./gcp
```

<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | >= 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.1 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.4 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.38 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.7 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.12 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_google-beta"></a> [google-beta](#provider\_google-beta) | >= 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.1 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.38 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.7 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.12 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google-beta_google_project_service_identity.cloudsql_sa](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_project_service_identity) | resource |
| [google_artifact_registry_repository.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository) | resource |
| [google_compute_firewall.egress_allow_external](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.egress_allow_internal](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.egress_deny_all](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.gke_master_to_nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.health_checks](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.iap](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.internal](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_global_address.private_ip_range](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_managed_ssl_certificate.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_managed_ssl_certificate) | resource |
| [google_compute_network.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_router.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_subnetwork.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_compute_subnetwork.proxy_only](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_container_cluster.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) | resource |
| [google_container_node_pool.pools](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |
| [google_dns_managed_zone.gcr](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_managed_zone) | resource |
| [google_dns_managed_zone.googleapis](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_managed_zone) | resource |
| [google_dns_record_set.gcr_a](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_dns_record_set.gcr_cname](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_dns_record_set.googleapis_cname](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_dns_record_set.private_googleapis_a](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_kms_crypto_key.cloudsql](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key.gke](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.cloudsql_encrypt](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.gke_encrypt](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.storage_encrypt](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_project_iam_member.cluster_admins](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gke_nodes_artifact_registry_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gke_nodes_log_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gke_nodes_metric_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gke_nodes_monitoring_viewer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gke_nodes_resource_metadata_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.teleport_db_cloudsql_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.teleport_db_cloudsql_instance_user](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.teleport_db_cloudsql_viewer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.vertex_ai](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_service.apis](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_project_service.artifact_registry_api](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_project_service.container_scanning](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_project_service.vertex_ai_api](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_service_account.gke_nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.logging](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.teleport_db](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.vertex_ai](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.logging_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.storage_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.teleport_db_token_creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.teleport_db_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.vertex_ai_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_networking_connection.private_vpc](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_connection) | resource |
| [google_sql_database.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database) | resource |
| [google_sql_database_instance.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance) | resource |
| [google_sql_user.admin](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_user) | resource |
| [google_sql_user.teleport_iam](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_user) | resource |
| [google_storage_bucket.logging](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.logging_object_admin](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_bucket_iam_member.storage_object_admin](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [helm_release.teleport_kube_agent](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.cloudsql_bootstrap_creds](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.cloudsql_bootstrap_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.cloudsql_iam_setup](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_admin_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_admin_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_viewer_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.teleport_viewer_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_cluster_role_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_service_account](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tfc_agent_token](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_job_v1.cloudsql_iam_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [random_password.cloudsql](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.cloudsql_iam_setup_hash](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.teleport_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.tfc_agent_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [time_sleep.api_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.artifact_registry_api_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.vertex_ai_api_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_compute_network.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_network) | data source |
| [google_compute_subnetwork.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_subnetwork) | data source |
| [google_project.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [google_storage_project_service_account.gcs_sa](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/storage_project_service_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_mode"></a> [access\_mode](#input\_access\_mode) | Cluster access mode: 'teleport' for zero-trust access or 'vpn' for traditional VPN | `string` | `"vpn"` | no |
| <a name="input_api_server_authorized_cidrs"></a> [api\_server\_authorized\_cidrs](#input\_api\_server\_authorized\_cidrs) | CIDRs authorized to access the GKE API server (empty = unrestricted when public) | `list(string)` | `[]` | no |
| <a name="input_autopilot_enabled"></a> [autopilot\_enabled](#input\_autopilot\_enabled) | Create a GKE Autopilot cluster instead of GKE Standard. Autopilot has no node pools, so node\_pools is ignored. Changing this on an existing cluster replaces it. | `bool` | `false` | no |
| <a name="input_cluster_admin_emails"></a> [cluster\_admin\_emails](#input\_cluster\_admin\_emails) | List of GCP user/group/service account emails to grant cluster-admin access | `list(string)` | `[]` | no |
| <a name="input_create_firewall_rules"></a> [create\_firewall\_rules](#input\_create\_firewall\_rules) | Whether to create VPC firewall rules. Set to false when using an existing network with pre-configured rules. | `bool` | `true` | no |
| <a name="input_create_network"></a> [create\_network](#input\_create\_network) | Whether to create a new VPC network. Set to false to use an existing network. | `bool` | `true` | no |
| <a name="input_create_private_service_connection"></a> [create\_private\_service\_connection](#input\_create\_private\_service\_connection) | Whether to create a private service connection for Cloud SQL. Set to false if the existing VPC already has one. | `bool` | `true` | no |
| <a name="input_database_admin_username"></a> [database\_admin\_username](#input\_database\_admin\_username) | Administrator username for Cloud SQL | `string` | `"psqladmin"` | no |
| <a name="input_database_backup_enabled"></a> [database\_backup\_enabled](#input\_database\_backup\_enabled) | Whether to enable automated backups | `bool` | `true` | no |
| <a name="input_database_backup_retention_days"></a> [database\_backup\_retention\_days](#input\_database\_backup\_retention\_days) | Number of days to retain backups (1-365) | `number` | `7` | no |
| <a name="input_database_deletion_protection"></a> [database\_deletion\_protection](#input\_database\_deletion\_protection) | Whether to enable deletion protection for Cloud SQL | `bool` | `false` | no |
| <a name="input_database_disk_autoresize"></a> [database\_disk\_autoresize](#input\_database\_disk\_autoresize) | Whether to enable disk autoresize for Cloud SQL | `bool` | `true` | no |
| <a name="input_database_disk_autoresize_limit"></a> [database\_disk\_autoresize\_limit](#input\_database\_disk\_autoresize\_limit) | Maximum disk size in GB for autoresize (0 = unlimited) | `number` | `100` | no |
| <a name="input_database_disk_size"></a> [database\_disk\_size](#input\_database\_disk\_size) | Initial disk size in GB for Cloud SQL | `number` | `20` | no |
| <a name="input_database_edition"></a> [database\_edition](#input\_database\_edition) | Cloud SQL edition (ENTERPRISE or ENTERPRISE\_PLUS). ENTERPRISE supports db-f1-micro/db-custom tiers; ENTERPRISE\_PLUS requires db-perf-optimized-N-* tiers. | `string` | `"ENTERPRISE"` | no |
| <a name="input_database_enabled"></a> [database\_enabled](#input\_database\_enabled) | Whether to create a Cloud SQL PostgreSQL instance | `bool` | `true` | no |
| <a name="input_database_flags"></a> [database\_flags](#input\_database\_flags) | Additional database flags for Cloud SQL | `map(string)` | `{}` | no |
| <a name="input_database_ha_enabled"></a> [database\_ha\_enabled](#input\_database\_ha\_enabled) | Whether to enable high availability (regional) for Cloud SQL | `bool` | `false` | no |
| <a name="input_database_insights_enabled"></a> [database\_insights\_enabled](#input\_database\_insights\_enabled) | Whether to enable Query Insights for Cloud SQL | `bool` | `true` | no |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | Name of the default database to create | `string` | `"optura"` | no |
| <a name="input_database_subnet_cidr"></a> [database\_subnet\_cidr](#input\_database\_subnet\_cidr) | CIDR range for database subnet (Cloud SQL private service connection) | `string` | `"10.0.48.0/24"` | no |
| <a name="input_database_tier"></a> [database\_tier](#input\_database\_tier) | Cloud SQL machine tier (e.g., db-f1-micro, db-custom-1-3840, db-custom-2-7680) | `string` | `"db-f1-micro"` | no |
| <a name="input_database_version"></a> [database\_version](#input\_database\_version) | PostgreSQL version for Cloud SQL | `string` | `"POSTGRES_17"` | no |
| <a name="input_databases"></a> [databases](#input\_databases) | Map of named Cloud SQL PostgreSQL instances to provision. Each key becomes part<br/>of the cloud-side instance name. The "core" key is reserved for the legacy<br/>primary instance and its on-cloud name is preserved (no -core suffix); every<br/>other key produces a suffixed instance (${base}-${each.key}).<br/><br/>Per-entry overrides (all optional — fall back to top-level database\_* defaults<br/>when omitted):<br/>  - tier                    (string)        — Cloud SQL machine tier<br/>  - edition                 (string)        — ENTERPRISE or ENTERPRISE\_PLUS<br/>  - disk\_size               (number)        — Initial disk size in GB<br/>  - disk\_autoresize\_limit   (number)        — Autoresize cap in GB (0 = unlimited)<br/>  - ha\_enabled              (bool)          — Regional high availability<br/>  - backup\_enabled          (bool)          — Automated backups + PITR<br/>  - backup\_retention\_days   (number)        — Backup retention (1-365)<br/>  - deletion\_protection     (bool)          — Enable deletion protection<br/>  - admin\_username          (string)        — Built-in admin user name<br/>  - db\_name                 (string)        — Initial database name<br/>  - database\_flags          (map(string))   — Additional database flags<br/>  - insights\_enabled        (bool)          — Query Insights toggle | <pre>map(object({<br/>    tier                  = optional(string)<br/>    edition               = optional(string)<br/>    disk_size             = optional(number)<br/>    disk_autoresize_limit = optional(number)<br/>    ha_enabled            = optional(bool)<br/>    backup_enabled        = optional(bool)<br/>    backup_retention_days = optional(number)<br/>    deletion_protection   = optional(bool)<br/>    admin_username        = optional(string)<br/>    db_name               = optional(string)<br/>    database_flags        = optional(map(string))<br/>    insights_enabled      = optional(bool)<br/>  }))</pre> | <pre>{<br/>  "core": {}<br/>}</pre> | no |
| <a name="input_egress_allowed_ips"></a> [egress\_allowed\_ips](#input\_egress\_allowed\_ips) | List of external IPs (CIDR notation) allowed for node egress when egress\_restricted is true. Defaults to empty — supply your deployment's egress IP(s). | `list(string)` | `[]` | no |
| <a name="input_egress_restricted"></a> [egress\_restricted](#input\_egress\_restricted) | Whether to restrict node egress to only allowed external IPs (plus internal/GKE traffic) | `bool` | `false` | no |
| <a name="input_enable_cloud_nat"></a> [enable\_cloud\_nat](#input\_enable\_cloud\_nat) | Whether to create Cloud NAT for outbound internet access from private nodes | `bool` | `true` | no |
| <a name="input_enable_cluster_encryption"></a> [enable\_cluster\_encryption](#input\_enable\_cluster\_encryption) | Whether to encrypt GKE secrets at rest with Cloud KMS (application-layer encryption) | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (dev, stg, uat, prod) | `string` | n/a | yes |
| <a name="input_existing_subnet_name"></a> [existing\_subnet\_name](#input\_existing\_subnet\_name) | Name of an existing subnet to use for GKE nodes (required when create\_network = false). Must have secondary ranges named 'pods' and 'services'. | `string` | `""` | no |
| <a name="input_existing_vpc_name"></a> [existing\_vpc\_name](#input\_existing\_vpc\_name) | Name of an existing VPC network to use (required when create\_network = false) | `string` | `""` | no |
| <a name="input_existing_vpc_project"></a> [existing\_vpc\_project](#input\_existing\_vpc\_project) | Project ID of the existing VPC network (for Shared VPC). Defaults to current project. | `string` | `""` | no |
| <a name="input_gcp_project_id"></a> [gcp\_project\_id](#input\_gcp\_project\_id) | GCP project ID for all resources | `string` | n/a | yes |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version for GKE cluster | `string` | `"1.35"` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | Additional labels to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_master_ipv4_cidr_block"></a> [master\_ipv4\_cidr\_block](#input\_master\_ipv4\_cidr\_block) | CIDR block for GKE master nodes (must be /28, cannot overlap with other subnets) | `string` | `"172.16.0.0/28"` | no |
| <a name="input_monitoring_enabled"></a> [monitoring\_enabled](#input\_monitoring\_enabled) | Whether to enable GKE monitoring (Cloud Monitoring integration) | `bool` | `true` | no |
| <a name="input_node_pools"></a> [node\_pools](#input\_node\_pools) | Map of GKE node pool configurations. Ignored when autopilot\_enabled = true. | <pre>map(object({<br/>    machine_type  = string<br/>    min_count     = number<br/>    max_count     = number<br/>    desired_count = optional(number)<br/>    disk_size_gb  = number<br/>    disk_type     = optional(string, "pd-standard")<br/>    image_type    = optional(string, "COS_CONTAINERD")<br/>    spot          = optional(bool, false)<br/>    labels        = map(string)<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = string<br/>      effect = string<br/>    })), [])<br/>  }))</pre> | <pre>{<br/>  "application": {<br/>    "desired_count": 1,<br/>    "disk_size_gb": 100,<br/>    "labels": {<br/>      "node-pool": "application",<br/>      "workload-type": "application"<br/>    },<br/>    "machine_type": "e2-medium",<br/>    "max_count": 3,<br/>    "min_count": 0<br/>  },<br/>  "support": {<br/>    "desired_count": 1,<br/>    "disk_size_gb": 50,<br/>    "labels": {<br/>      "node-pool": "support",<br/>      "workload-type": "support"<br/>    },<br/>    "machine_type": "e2-small",<br/>    "max_count": 2,<br/>    "min_count": 0<br/>  },<br/>  "system": {<br/>    "disk_size_gb": 50,<br/>    "labels": {<br/>      "node-pool": "system",<br/>      "workload-type": "system"<br/>    },<br/>    "machine_type": "e2-small",<br/>    "max_count": 2,<br/>    "min_count": 1,<br/>    "taints": [<br/>      {<br/>        "effect": "NO_SCHEDULE",<br/>        "key": "CriticalAddonsOnly",<br/>        "value": "true"<br/>      }<br/>    ]<br/>  }<br/>}</pre> | no |
| <a name="input_pods_cidr"></a> [pods\_cidr](#input\_pods\_cidr) | Secondary CIDR range for GKE pods | `string` | `"10.4.0.0/14"` | no |
| <a name="input_private_cluster_enabled"></a> [private\_cluster\_enabled](#input\_private\_cluster\_enabled) | Whether to enable private cluster (no public endpoint). Requires TFC agent or VPN. | `bool` | `false` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used for resource naming (lowercase, 3-12 chars, alphanumeric and hyphens) | `string` | `"optura"` | no |
| <a name="input_proxy_only_cidr"></a> [proxy\_only\_cidr](#input\_proxy\_only\_cidr) | CIDR range for the proxy-only subnet (for internal load balancers) | `string` | `"10.0.32.0/24"` | no |
| <a name="input_region"></a> [region](#input\_region) | GCP region for all resources (e.g., us-central1, us-east1, europe-west1) | `string` | `"us-central1"` | no |
| <a name="input_registry_cleanup_policies"></a> [registry\_cleanup\_policies](#input\_registry\_cleanup\_policies) | Cleanup policies for Artifact Registry | <pre>object({<br/>    keep_latest_images = optional(number, 3)<br/>    expire_untagged    = optional(number, 3)<br/>  })</pre> | <pre>{<br/>  "expire_untagged": 3,<br/>  "keep_latest_images": 3<br/>}</pre> | no |
| <a name="input_registry_enabled"></a> [registry\_enabled](#input\_registry\_enabled) | Whether to create an Artifact Registry repository | `bool` | `false` | no |
| <a name="input_registry_format"></a> [registry\_format](#input\_registry\_format) | Format of the Artifact Registry repository | `string` | `"DOCKER"` | no |
| <a name="input_registry_immutable_tags"></a> [registry\_immutable\_tags](#input\_registry\_immutable\_tags) | Whether to enable immutable tags on the Artifact Registry | `bool` | `false` | no |
| <a name="input_registry_repository_id"></a> [registry\_repository\_id](#input\_registry\_repository\_id) | Existing Artifact Registry repository ID (when registry\_enabled = false) | `string` | `""` | no |
| <a name="input_registry_vulnerability_scanning"></a> [registry\_vulnerability\_scanning](#input\_registry\_vulnerability\_scanning) | Whether to enable vulnerability scanning | `bool` | `true` | no |
| <a name="input_release_channel"></a> [release\_channel](#input\_release\_channel) | GKE release channel (REGULAR, RAPID, STABLE, UNSPECIFIED) | `string` | `"REGULAR"` | no |
| <a name="input_services_cidr"></a> [services\_cidr](#input\_services\_cidr) | Secondary CIDR range for GKE services | `string` | `"10.8.0.0/20"` | no |
| <a name="input_ssl_certificate_create"></a> [ssl\_certificate\_create](#input\_ssl\_certificate\_create) | Whether to create a Google-managed SSL certificate | `bool` | `false` | no |
| <a name="input_ssl_certificate_domains"></a> [ssl\_certificate\_domains](#input\_ssl\_certificate\_domains) | List of domains for the Google-managed SSL certificate | `list(string)` | `[]` | no |
| <a name="input_storage_general_cors_origins"></a> [storage\_general\_cors\_origins](#input\_storage\_general\_cors\_origins) | Browser origins allowed to call the general bucket directly (presigned uploads). Empty disables CORS, which blocks every browser upload. | `list(string)` | `[]` | no |
| <a name="input_storage_general_enabled"></a> [storage\_general\_enabled](#input\_storage\_general\_enabled) | Whether to create a general purpose storage bucket | `bool` | `true` | no |
| <a name="input_storage_general_lifecycle_rules"></a> [storage\_general\_lifecycle\_rules](#input\_storage\_general\_lifecycle\_rules) | Lifecycle rules for general storage bucket | <pre>object({<br/>    nearline_after_days = optional(number, 90)<br/>    noncurrent_days     = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_storage_general_namespace"></a> [storage\_general\_namespace](#input\_storage\_general\_namespace) | Kubernetes namespace for general storage service account | `string` | `"default"` | no |
| <a name="input_storage_general_service_account"></a> [storage\_general\_service\_account](#input\_storage\_general\_service\_account) | Kubernetes service account name for general storage access | `string` | `"app-storage"` | no |
| <a name="input_storage_general_versioning"></a> [storage\_general\_versioning](#input\_storage\_general\_versioning) | Enable versioning on general storage bucket | `bool` | `true` | no |
| <a name="input_storage_logging_enabled"></a> [storage\_logging\_enabled](#input\_storage\_logging\_enabled) | Whether to create a logging storage bucket (for Loki, Fluentd, etc.) | `bool` | `true` | no |
| <a name="input_storage_logging_lifecycle_rules"></a> [storage\_logging\_lifecycle\_rules](#input\_storage\_logging\_lifecycle\_rules) | Lifecycle rules for logging bucket | <pre>object({<br/>    nearline_after_days = optional(number, 30)<br/>    coldline_after_days = optional(number, 90)<br/>    delete_after_days   = optional(number, 365)<br/>    noncurrent_days     = optional(number, 7)<br/>  })</pre> | `{}` | no |
| <a name="input_storage_logging_namespace"></a> [storage\_logging\_namespace](#input\_storage\_logging\_namespace) | Kubernetes namespace for logging service account | `string` | `"monitoring"` | no |
| <a name="input_storage_logging_service_account"></a> [storage\_logging\_service\_account](#input\_storage\_logging\_service\_account) | Kubernetes service account name for logging storage access | `string` | `"loki"` | no |
| <a name="input_subnet_cidr"></a> [subnet\_cidr](#input\_subnet\_cidr) | CIDR range for the primary node subnet | `string` | `"10.0.0.0/20"` | no |
| <a name="input_teleport_agent_chart_repository"></a> [teleport\_agent\_chart\_repository](#input\_teleport\_agent\_chart\_repository) | Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access\_mode = teleport — supply your own. | `string` | `""` | no |
| <a name="input_teleport_agent_image"></a> [teleport\_agent\_image](#input\_teleport\_agent\_image) | Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters). | `string` | `""` | no |
| <a name="input_teleport_ca_pin"></a> [teleport\_ca\_pin](#input\_teleport\_ca\_pin) | Teleport CA pin for secure joining | `string` | `""` | no |
| <a name="input_teleport_db_enabled"></a> [teleport\_db\_enabled](#input\_teleport\_db\_enabled) | Whether to enable Teleport database access agent for Cloud SQL | `bool` | `true` | no |
| <a name="input_teleport_gateway_ip"></a> [teleport\_gateway\_ip](#input\_teleport\_gateway\_ip) | Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP. | `string` | `null` | no |
| <a name="input_teleport_join_token"></a> [teleport\_join\_token](#input\_teleport\_join\_token) | Teleport join token for Kubernetes agent | `string` | `""` | no |
| <a name="input_teleport_proxy_address"></a> [teleport\_proxy\_address](#input\_teleport\_proxy\_address) | Teleport proxy address as host:port (required when access\_mode = teleport). Defaults to empty — supply your own Teleport proxy. | `string` | `""` | no |
| <a name="input_teleport_version"></a> [teleport\_version](#input\_teleport\_version) | Teleport agent Helm chart version | `string` | `"18.5.1"` | no |
| <a name="input_tfc_agent_enabled"></a> [tfc\_agent\_enabled](#input\_tfc\_agent\_enabled) | Whether to deploy a Terraform Cloud agent inside the cluster | `bool` | `false` | no |
| <a name="input_tfc_agent_token"></a> [tfc\_agent\_token](#input\_tfc\_agent\_token) | Terraform Cloud agent token | `string` | `null` | no |
| <a name="input_tfc_agent_version"></a> [tfc\_agent\_version](#input\_tfc\_agent\_version) | Terraform Cloud agent Docker image version | `string` | `"1.28.5"` | no |
| <a name="input_vertex_ai_enabled"></a> [vertex\_ai\_enabled](#input\_vertex\_ai\_enabled) | Whether to create a Workload Identity service account for Vertex AI access | `bool` | `false` | no |
| <a name="input_vertex_ai_roles"></a> [vertex\_ai\_roles](#input\_vertex\_ai\_roles) | List of IAM roles to grant to the Vertex AI service account | `list(string)` | <pre>[<br/>  "roles/aiplatform.user"<br/>]</pre> | no |
| <a name="input_vertex_ai_workload_identities"></a> [vertex\_ai\_workload\_identities](#input\_vertex\_ai\_workload\_identities) | Map of Kubernetes service accounts that need Vertex AI access. The key is the K8s service account name. | <pre>map(object({<br/>    namespace = string<br/>  }))</pre> | <pre>{<br/>  "intent": {<br/>    "namespace": "core"<br/>  }<br/>}</pre> | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | Primary CIDR block for VPC network (used for documentation; GCP subnets define their own CIDRs) | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_mode"></a> [access\_mode](#output\_access\_mode) | Configured access mode (teleport or vpn) |
| <a name="output_api_endpoint_access_type"></a> [api\_endpoint\_access\_type](#output\_api\_endpoint\_access\_type) | Whether the API server endpoint is public or private |
| <a name="output_cluster_ca_certificate"></a> [cluster\_ca\_certificate](#output\_cluster\_ca\_certificate) | Base64 encoded cluster CA certificate |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Endpoint for GKE cluster API server |
| <a name="output_cluster_id"></a> [cluster\_id](#output\_cluster\_id) | ID of the GKE cluster |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the GKE cluster |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Not applicable for GCP (uses VPC firewall rules) |
| <a name="output_cluster_subnet_ids"></a> [cluster\_subnet\_ids](#output\_cluster\_subnet\_ids) | IDs of cluster subnets (node subnet) |
| <a name="output_database_address"></a> [database\_address](#output\_database\_address) | Private IP address of the "core" Cloud SQL instance (legacy alias) |
| <a name="output_database_admin_password"></a> [database\_admin\_password](#output\_database\_admin\_password) | Administrator password for the "core" Cloud SQL instance (legacy alias) |
| <a name="output_database_admin_passwords"></a> [database\_admin\_passwords](#output\_database\_admin\_passwords) | Map of named DB key → administrator password |
| <a name="output_database_admin_username"></a> [database\_admin\_username](#output\_database\_admin\_username) | Administrator username for the "core" Cloud SQL instance (legacy alias) |
| <a name="output_database_admin_usernames"></a> [database\_admin\_usernames](#output\_database\_admin\_usernames) | Map of named DB key → administrator username |
| <a name="output_database_endpoint"></a> [database\_endpoint](#output\_database\_endpoint) | Connection name of the "core" Cloud SQL instance — project:region:instance (legacy alias) |
| <a name="output_database_endpoints"></a> [database\_endpoints](#output\_database\_endpoints) | Map of named DB key → connection name (project:region:instance) |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Name of the default database on the "core" instance (legacy alias) |
| <a name="output_database_names"></a> [database\_names](#output\_database\_names) | Map of named DB key → initial database name |
| <a name="output_database_port"></a> [database\_port](#output\_database\_port) | Port of the "core" Cloud SQL instance (legacy alias) |
| <a name="output_database_server_name"></a> [database\_server\_name](#output\_database\_server\_name) | Name of the "core" Cloud SQL instance (legacy alias) |
| <a name="output_database_subnet_ids"></a> [database\_subnet\_ids](#output\_database\_subnet\_ids) | IDs of database subnets |
| <a name="output_estimated_monthly_cost"></a> [estimated\_monthly\_cost](#output\_estimated\_monthly\_cost) | Rough monthly cost estimate based on configuration |
| <a name="output_general_storage_id"></a> [general\_storage\_id](#output\_general\_storage\_id) | ID of the general storage bucket |
| <a name="output_general_storage_name"></a> [general\_storage\_name](#output\_general\_storage\_name) | Name of the general storage bucket |
| <a name="output_general_storage_region"></a> [general\_storage\_region](#output\_general\_storage\_region) | Region of the general storage bucket |
| <a name="output_general_storage_role_id"></a> [general\_storage\_role\_id](#output\_general\_storage\_role\_id) | Service account email for general storage workload access |
| <a name="output_ingress_subnet_ids"></a> [ingress\_subnet\_ids](#output\_ingress\_subnet\_ids) | IDs of ingress subnets (proxy-only subnet for load balancers) |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl access |
| <a name="output_logging_storage_id"></a> [logging\_storage\_id](#output\_logging\_storage\_id) | ID of the logging storage bucket |
| <a name="output_logging_storage_name"></a> [logging\_storage\_name](#output\_logging\_storage\_name) | Name of the logging storage bucket |
| <a name="output_logging_storage_region"></a> [logging\_storage\_region](#output\_logging\_storage\_region) | Region of the logging storage bucket |
| <a name="output_logging_storage_role_id"></a> [logging\_storage\_role\_id](#output\_logging\_storage\_role\_id) | Service account email for logging workload access |
| <a name="output_network_cidr"></a> [network\_cidr](#output\_network\_cidr) | Primary CIDR block of the node subnet |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | ID of the VPC network |
| <a name="output_network_name"></a> [network\_name](#output\_network\_name) | Name of the VPC network |
| <a name="output_node_pool_service_account"></a> [node\_pool\_service\_account](#output\_node\_pool\_service\_account) | Service account email used by node pools |
| <a name="output_registry_created"></a> [registry\_created](#output\_registry\_created) | Whether the Artifact Registry was created by this module |
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | ID of the Artifact Registry repository |
| <a name="output_registry_name"></a> [registry\_name](#output\_registry\_name) | Name of the Artifact Registry repository |
| <a name="output_registry_url"></a> [registry\_url](#output\_registry\_url) | URL of the Artifact Registry repository |
| <a name="output_ssl_certificate_created"></a> [ssl\_certificate\_created](#output\_ssl\_certificate\_created) | Whether the SSL certificate was created by this module |
| <a name="output_ssl_certificate_domains"></a> [ssl\_certificate\_domains](#output\_ssl\_certificate\_domains) | Domains associated with the SSL certificate |
| <a name="output_ssl_certificate_id"></a> [ssl\_certificate\_id](#output\_ssl\_certificate\_id) | ID of the Google-managed SSL certificate |
| <a name="output_teleport_db_agent_service_account"></a> [teleport\_db\_agent\_service\_account](#output\_teleport\_db\_agent\_service\_account) | Service account email for Teleport database agent |
| <a name="output_tfc_agent_status"></a> [tfc\_agent\_status](#output\_tfc\_agent\_status) | Terraform Cloud agent deployment status |
| <a name="output_vertex_ai_service_account_email"></a> [vertex\_ai\_service\_account\_email](#output\_vertex\_ai\_service\_account\_email) | GCP service account email for Vertex AI workload identity (use as iam.gke.io/gcp-service-account annotation) |
| <a name="output_vertex_ai_workload_identities"></a> [vertex\_ai\_workload\_identities](#output\_vertex\_ai\_workload\_identities) | Map of Kubernetes service accounts bound to the Vertex AI GCP service account |
| <a name="output_workload_identity_pool"></a> [workload\_identity\_pool](#output\_workload\_identity\_pool) | Workload Identity pool for the GKE cluster |
<!-- END_TF_DOCS -->