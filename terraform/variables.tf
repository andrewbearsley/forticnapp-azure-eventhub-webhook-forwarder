variable "subscription_id" {
  type        = string
  description = "Azure subscription ID where the shim resources are deployed."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name to create for the shim resources."
  default     = "fcnapp-eventhub-shim"
}

variable "location" {
  type        = string
  description = "Azure region for all shim resources (e.g. australiaeast). Must be set explicitly."

  validation {
    condition     = length(var.location) > 0
    error_message = "location must be set explicitly."
  }
}

variable "event_hub_namespace_name" {
  type        = string
  description = "Event Hub namespace base name. A 6-character random suffix is appended for global uniqueness."
  default     = "fcnapp-eventhub-shim"
}

variable "event_hub_name" {
  type        = string
  description = "Name of the Event Hub that receives FortiCNAPP alerts."
  default     = "fcnapp-alerts"
}

variable "function_app_name" {
  type        = string
  description = "Function App base name. A 6-character random suffix is appended for global uniqueness."
  default     = "fcnapp-eventhub-shim"
}

variable "webhook_shared_secret" {
  type        = string
  description = "Optional shared secret. If set, the Function rejects any inbound request whose X-Webhook-Secret header does not match this value. Leave empty to disable the header check (function key authorization still applies)."
  default     = ""
  sensitive   = true
}
