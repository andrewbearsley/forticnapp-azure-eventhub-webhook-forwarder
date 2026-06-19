output "function_app_name" {
  value       = azurerm_linux_function_app.shim.name
  description = "Function App resource name. Used by `func azure functionapp publish` and `az functionapp keys list`."
}

output "function_app_default_hostname" {
  value       = azurerm_linux_function_app.shim.default_hostname
  description = "Default hostname of the Function App, e.g. fcnapp-eventhub-shim-abc123.azurewebsites.net."
}

output "webhook_endpoint" {
  value       = "https://${azurerm_linux_function_app.shim.default_hostname}/api/forward"
  description = "Endpoint to paste into the FortiCNAPP Custom Webhook channel. Append the function key as ?code=<key> or send it as an x-functions-key header."
}

output "event_hub_namespace_fqdn" {
  value       = "${azurerm_eventhub_namespace.shim.name}.servicebus.windows.net"
  description = "Fully qualified domain name of the Event Hub namespace. Use this when wiring downstream consumers (Splunk Add-on for Microsoft Cloud Services, Sentinel data connectors, etc.)."
}

output "event_hub_name" {
  value       = azurerm_eventhub.alerts.name
  description = "Name of the Event Hub that receives forwarded alerts."
}

output "resource_group_name" {
  value       = azurerm_resource_group.shim.name
  description = "Resource group containing all shim resources."
}
