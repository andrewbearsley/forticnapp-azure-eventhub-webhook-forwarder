terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

resource "azurerm_resource_group" "shim" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_eventhub_namespace" "shim" {
  name                = "${var.event_hub_namespace_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shim.name
  location            = azurerm_resource_group.shim.location
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "alerts" {
  name              = var.event_hub_name
  namespace_id      = azurerm_eventhub_namespace.shim.id
  partition_count   = 2
  message_retention = 1
}

resource "azurerm_storage_account" "function" {
  name                            = "fcnappshim${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.shim.name
  location                        = azurerm_resource_group.shim.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_service_plan" "shim" {
  name                = "fcnapp-eventhub-shim-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shim.name
  location            = azurerm_resource_group.shim.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "shim" {
  name                = "${var.function_app_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shim.name
  location            = azurerm_resource_group.shim.location
  service_plan_id     = azurerm_service_plan.shim.id

  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key

  https_only = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    EVENT_HUB_NAMESPACE_FQDN = "${azurerm_eventhub_namespace.shim.name}.servicebus.windows.net"
    EVENT_HUB_NAME           = azurerm_eventhub.alerts.name
    WEBHOOK_SHARED_SECRET    = var.webhook_shared_secret
  }
}

# Grant the Function App's managed identity permission to send to the Event Hub
# namespace. Role propagation typically takes 30-60 seconds after apply.
resource "azurerm_role_assignment" "shim_eventhub_sender" {
  scope                = azurerm_eventhub_namespace.shim.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_linux_function_app.shim.identity[0].principal_id
}
