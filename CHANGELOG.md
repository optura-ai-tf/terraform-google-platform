# Changelog

All notable changes to the GCP GKE platform module are documented here. This
module is versioned independently of the rest of the repository; tags are of the
form `gcp/platform/vX.Y.Z`.

## Unreleased

## 0.8.0 — 2026-10-30

### Changed

- **Default `kubernetes_version` is now `1.35`** (was `1.34`). It sets the
  cluster's `min_master_version`, so a cluster that relies on the default
  upgrades in place on its next apply. Pin `kubernetes_version = "1.34"` to
  stay.
