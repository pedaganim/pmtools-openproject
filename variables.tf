variable "schedule_start_cron" {
  description = "Linux Cron expression for ASG start (UTC). Default is 22:00 UTC (8:00 AM AEST)."
  type        = string
  default     = "0 22 * * *"
}

variable "schedule_stop_cron" {
  description = "Linux Cron expression for ASG stop (UTC). Default is 13:00 UTC (11:00 PM AEST)."
  type        = string
  default     = "0 13 * * *"
}

variable "schedule_start_cron_eb" {
  description = "AWS EventBridge Cron expression for RDS start (UTC). Default is 22:00 UTC."
  type        = string
  default     = "0 22 * * ? *"
}

variable "schedule_stop_cron_eb" {
  description = "AWS EventBridge Cron expression for RDS stop (UTC). Default is 13:00 UTC."
  type        = string
  default     = "0 13 * * ? *"
}

variable "deploy_sha" {
  description = "A unique identifier (like a Git commit SHA) used to force the Launch Template to update on new deployments."
  type        = string
  default     = "manual-deploy"
}
