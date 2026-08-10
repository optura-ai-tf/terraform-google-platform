# ===== Google-Managed SSL Certificate =====
# Google-managed SSL certificate (auto-provisioned when attached to load balancer)

resource "google_compute_managed_ssl_certificate" "main" {
  count = var.ssl_certificate_create ? 1 : 0

  name = "${local.name_prefix}-ssl-cert"

  managed {
    domains = var.ssl_certificate_domains
  }

  lifecycle {
    create_before_destroy = true
  }
}
