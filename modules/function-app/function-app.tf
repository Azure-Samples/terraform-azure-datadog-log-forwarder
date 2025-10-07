#######################
# Create Function App #
#######################

# App service plan
resource "azurerm_service_plan" "app_service_plan" {
  name                = var.app_service_plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Windows"
  sku_name            = "EP1"
}

# Function app
resource "azurerm_windows_function_app" "function_app" {
  name                = var.function_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.app_service_plan.id
  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE"                    = "1",
    "FUNCTIONS_WORKER_RUNTIME"                    = "node",
    "AzureWebJobsDisableHomepage"                 = "true",
    "WEBSITE_NODE_DEFAULT_VERSION"                = "~20",
    "EventHubConnection__credential"              = "managedidentity",
    "EventHubConnection__fullyQualifiedNamespace" = format("%s.servicebus.windows.net", var.event_hub_namespace_name),
    "DD_API_KEY"                                  = var.datadog_api_key,
    "DD_SITE"                                     = var.datadog_site
  }
  site_config {}
  storage_account_name          = var.storage_account_name
  storage_uses_managed_identity = true
  identity {
    type = "SystemAssigned"
  }
  public_network_access_enabled = false
  virtual_network_subnet_id     = var.fa_outbound_subnet_id
}

#########################
# Network Configuration #
#########################

# Private dns zone for function app default dns zone
resource "azurerm_private_dns_zone" "private_dns_zone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link" {
  name                  = format("dnslink-fa-001")
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

# Private endpoint for Function app
resource "azurerm_private_endpoint" "pep-functionapp" {
  name                = format("pep-fa-001")
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.fa_pep_subnet_id
  private_service_connection {
    name                           = format("psc-pep-fa-001")
    private_connection_resource_id = azurerm_windows_function_app.function_app.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }
  private_dns_zone_group {
    name                 = format("pdnszg-pep-fa-001")
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone.id]
  }
}

#######################
# Role Assignments    #
#######################

# Role Assignment for storage account - https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference?tabs=eventhubs&pivots=programming-language-javascript#connecting-to-host-storage-with-an-identity
resource "azurerm_role_assignment" "role_assignment_storage" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_windows_function_app.function_app.identity[0].principal_id
}

# Role Assignment for event hub - https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference?tabs=eventhubs&pivots=programming-language-javascript#grant-permission-to-the-identity
resource "azurerm_role_assignment" "role_assignment_event_hub" {
  scope                = var.event_hub_namespace_id
  role_definition_name = "Azure Event Hubs Data Owner"
  principal_id         = azurerm_windows_function_app.function_app.identity[0].principal_id
}

#######################
# Zip Deploy Function #
#######################

locals {
  function_json = templatefile("${path.module}/functions/dd-log-forwarder/function.json", { event_hub_name = var.event_hub_name })
  index_js      = file("${path.module}/functions/dd-log-forwarder/index.js")
  host_json     = file("${path.module}/functions/host.json")
}

# Create zip folder with functions
data "archive_file" "functions_zip" {
  type        = "zip"
  output_path = "${path.module}/functions.zip"
  source {
    content  = local.function_json
    filename = "dd-log-forwarder/function.json"
  }
  source {
    content  = local.index_js
    filename = "dd-log-forwarder/index.js"
  }
  source {
    content  = local.host_json
    filename = "host.json"
  }
}

# Publish code to function app
locals {
  allow_public_access_command = "az functionapp update --resource-group ${var.resource_group_name} -n ${azurerm_windows_function_app.function_app.name} --set publicNetworkAccess=Enabled siteConfig.publicNetworkAccess=Enabled"
  publish_code_command        = "az webapp deploy --resource-group ${var.resource_group_name} --name ${azurerm_windows_function_app.function_app.name} --src-path ${data.archive_file.functions_zip.output_path}"
  deny_public_access_command  = "az functionapp update --resource-group ${var.resource_group_name} -n ${azurerm_windows_function_app.function_app.name} --set publicNetworkAccess=Disabled siteConfig.publicNetworkAccess=Disabled"
}

resource "null_resource" "function_app_publish" {
  depends_on = [local.publish_code_command, azurerm_role_assignment.role_assignment_storage, azurerm_role_assignment.role_assignment_event_hub]
  triggers = {
    # input_json                  = filemd5(data.archive_file.functions_zip.output_path)
    publish_has                 = data.archive_file.functions_zip.output_base64sha256
    publish_code_command        = local.publish_code_command
    allow_public_access_command = local.allow_public_access_command
    deny_public_access_command  = local.deny_public_access_command
  }
  provisioner "local-exec" {
    command = local.allow_public_access_command
  }
  provisioner "local-exec" {
    command = local.publish_code_command
  }
  provisioner "local-exec" {
    command = local.deny_public_access_command
  }
}
