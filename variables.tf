variable "subscription_id" {
  description = "The Azure subscription ID."
  type = string
}

variable "location" {
  description = "The location/region where the resources will be created."
  type = string  
}

variable "datadog_api_key" {
  description = "The Datadog API key."
  type = string
  sensitive = true   
}
