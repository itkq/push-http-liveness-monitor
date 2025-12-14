variable "name_prefix" {
  description = "Prefix for API Gateway and related resources"
  type        = string
  default     = "push-http-liveness-monitor"
}

variable "targets" {
  description = "heartbeat targets"
  type        = list(string)
}

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (optional)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to taggable resources"
  type        = map(string)
  default     = {}
}
