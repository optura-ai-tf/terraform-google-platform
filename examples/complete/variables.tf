variable "gcp_project_id" {
  description = "GCP project ID to deploy the example into"
  type        = string
}

variable "teleport_join_token" {
  description = "Teleport join token for the in-cluster agent (set via TF_VAR_teleport_join_token)"
  type        = string
  default     = ""
  sensitive   = true
}
