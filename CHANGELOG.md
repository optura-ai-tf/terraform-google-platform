# Changelog

All notable changes to the GCP GKE platform module are documented here. This
module is versioned independently of the rest of the repository; tags are of the
form `gcp/platform/vX.Y.Z`.

## Unreleased

## 0.8.1 — 2026-11-13

### Added

- **`max_pods_per_node`** sets the maximum pods per node on every node pool.
  Defaults to `110`, the GKE Standard default, so existing pools plan no
  change. Set it before the first apply: changing it later destroys every
  node pool, system included, before creating the new ones, so the cluster
  has no nodes and all workloads are down until they are ready. Ignored on
  Autopilot.

### Changed

- **The Teleport agent runs the Enterprise image** (`teleport-ent-distroless`),
  since Optura's Teleport Cloud cluster is Enterprise. The chart's `enterprise`
  flag is set, and `teleport_agent_image` now sets the chart's `enterpriseImage`.
  If you mirror the agent image, mirror `teleport-ent-distroless` and point
  `teleport_agent_image` at it.
- **`teleport_version` defaults to `18.11.7`** (was `18.5.1`), matching the
  Teleport Cloud control plane. Agents must never be newer than it. Picks up
  the Kubernetes Access RBAC bypass fix from 18.10.7. The agent pod restarts
  on apply, so Teleport access to the cluster drops for about a minute.

## 0.8.0 — 2026-10-30

### Changed

- **Default `kubernetes_version` is now `1.35`** (was `1.34`). It sets the
  cluster's `min_master_version`, so a cluster that relies on the default
  upgrades in place on its next apply. Pin `kubernetes_version = "1.34"` to
  stay.
