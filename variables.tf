variable "schedule_start_cron" {
  description = "Cron expression for when to start the OpenProject environment (UTC). Default is 22:00 UTC (8:00 AM AEST)."
  type        = string
  default     = "0 22 * * *"
}

variable "schedule_stop_cron" {
  description = "Cron expression for when to stop the OpenProject environment (UTC). Default is 13:00 UTC (11:00 PM AEST)."
  type        = string
  default     = "0 13 * * *"
}

variable "deploy_sha" {
  description = "A unique identifier (like a Git commit SHA) used to force the Launch Template to update on new deployments."
  type        = string
  default     = "manual-deploy"
}
