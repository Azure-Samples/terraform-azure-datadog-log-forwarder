variable "resource_group_name" {
  description = "The name of the resource group in which to create the resources."
  type = string
}

variable "location" {
  description = "The location/region where the resources will be created."
  type = string  
}

variable "event_hub_namespace_name" {
  description = "The name of the Event Hub Namespace."
  type = string  
}

variable "event_hub_name" {
  description = "The name of the Event Hub."
  type = string  
}