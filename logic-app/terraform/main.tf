terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

resource "azurerm_resource_group" "forwarder" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_eventhub_namespace" "forwarder" {
  name                = "${var.event_hub_namespace_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.forwarder.name
  location            = azurerm_resource_group.forwarder.location
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "alerts" {
  name              = var.event_hub_name
  namespace_id      = azurerm_eventhub_namespace.forwarder.id
  partition_count   = 2
  message_retention = 1
}

# Logic App (Consumption) workflow.
#
# Deployed via azapi_resource because the azurerm Logic App action resources
# don't expose the `authentication` block on HTTP actions, which is needed to
# use Managed Identity against the Event Hub REST endpoint.
#
# Flow:
#   1. HTTP request trigger (SAS-signed URL)
#   2. (Optional) Condition on X-Webhook-Secret header
#   3. HTTP action to POST the trigger body to the Event Hub REST endpoint,
#      authenticated as the workflow's System-Assigned Managed Identity
#   4. Response action returns 200
resource "azapi_resource" "forwarder" {
  type      = "Microsoft.Logic/workflows@2019-05-01"
  name      = "${var.workflow_name}-${random_string.suffix.result}"
  location  = azurerm_resource_group.forwarder.location
  parent_id = azurerm_resource_group.forwarder.id

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      state = "Enabled"
      definition = {
        "$schema"      = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
        contentVersion = "1.0.0.0"
        parameters = {
          sharedSecret = {
            type         = "SecureString"
            defaultValue = var.webhook_shared_secret
          }
        }
        triggers = {
          When_a_HTTP_request_is_received = {
            type = "Request"
            kind = "Http"
            inputs = {
              method = "POST"
              schema = {}
            }
          }
        }
        actions = {
          Check_shared_secret = {
            type = "If"
            expression = {
              or = [
                {
                  equals = [
                    "@parameters('sharedSecret')",
                    ""
                  ]
                },
                {
                  equals = [
                    "@coalesce(triggerOutputs()?['headers']?['X-Webhook-Secret'], '')",
                    "@parameters('sharedSecret')"
                  ]
                }
              ]
            }
            actions = {
              Forward_to_Event_Hub = {
                type = "Http"
                inputs = {
                  method = "POST"
                  uri    = "https://${azurerm_eventhub_namespace.forwarder.name}.servicebus.windows.net/${azurerm_eventhub.alerts.name}/messages?api-version=2014-01"
                  headers = {
                    "Content-Type" = "application/json"
                  }
                  body = "@triggerBody()"
                  authentication = {
                    type     = "ManagedServiceIdentity"
                    audience = "https://eventhubs.azure.net"
                  }
                }
              }
              Respond_OK = {
                type = "Response"
                kind = "Http"
                inputs = {
                  statusCode = 200
                  body       = "ok"
                }
                runAfter = {
                  Forward_to_Event_Hub = ["Succeeded"]
                }
              }
            }
            else = {
              actions = {
                Respond_Unauthorized = {
                  type = "Response"
                  kind = "Http"
                  inputs = {
                    statusCode = 401
                    body       = "unauthorized"
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  response_export_values = ["properties.accessEndpoint"]
}

# Grant the workflow's System-Assigned MI permission to send to the Event Hub
# namespace. Propagation typically takes 30-60 seconds after apply.
resource "azurerm_role_assignment" "forwarder_eventhub_sender" {
  scope                = azurerm_eventhub_namespace.forwarder.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azapi_resource.forwarder.identity[0].principal_id
}
