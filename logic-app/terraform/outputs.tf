output "workflow_name" {
  value       = azapi_resource.forwarder.name
  description = "Logic App workflow resource name."
}

output "event_hub_namespace_fqdn" {
  value       = "${azurerm_eventhub_namespace.forwarder.name}.servicebus.windows.net"
  description = "Fully qualified domain name of the Event Hub namespace. Use this when wiring downstream consumers."
}

output "event_hub_name" {
  value       = azurerm_eventhub.alerts.name
  description = "Name of the Event Hub that receives forwarded alerts."
}

output "resource_group_name" {
  value       = azurerm_resource_group.forwarder.name
  description = "Resource group containing all forwarder resources."
}

output "fetch_webhook_url_command" {
  value = <<-EOT
    az rest --method post \
      --uri "https://management.azure.com/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_resource_group.forwarder.name}/providers/Microsoft.Logic/workflows/${azapi_resource.forwarder.name}/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01" \
      --query value -o tsv
  EOT
  description = "Run this command to fetch the SAS-signed webhook URL to paste into FortiCNAPP. The URL is issued on demand rather than stored, so it isn't a Terraform output value."
}
