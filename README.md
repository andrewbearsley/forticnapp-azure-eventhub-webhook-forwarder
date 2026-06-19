# FortiCNAPP to Azure Event Hub Webhook Shim

A lightweight HTTPS shim that lets FortiCNAPP alerts land in an Azure Event Hub via the Custom Webhook channel.

FortiCNAPP ships native alert channels for Splunk, ServiceNow, Microsoft Teams, PagerDuty, and many more, but not Azure Event Hub. When Event Hub is the standard ingest pattern for your environment (e.g. everything funnels through Event Hub on the way to Splunk, Microsoft Sentinel, or a data lake), the recommended approach is to put a small HTTPS shim in front of Event Hub. This repo is that shim, packaged as Terraform + a minimal Python Azure Function.

## Architecture

```
FortiCNAPP Custom Webhook  ─POST JSON─►  Azure Function (HTTPS)  ─►  Azure Event Hub  ─►  Splunk / Sentinel / data lake
```

- FortiCNAPP posts the alert JSON to the Function's HTTPS endpoint
- The Function validates the function key (and optionally a shared secret header), then forwards the body to Event Hub
- Downstream consumers (Splunk Add-on for Microsoft Cloud Services, Sentinel data connectors, etc.) read from the same Event Hub

The Function authenticates to Event Hub via System-Assigned Managed Identity with the `Azure Event Hubs Data Sender` role. No connection strings.

## What gets deployed

| Resource | Notes |
|---|---|
| Resource Group | Container for everything below |
| Event Hub Namespace + Event Hub | Standard tier, 1 throughput unit, 2 partitions, 1-day retention |
| Storage Account | Backing storage for the Function App (required) |
| App Service Plan | Linux Consumption (Y1), scales to zero |
| Linux Function App | Python 3.11, System-Assigned Managed Identity, HTTPS only |
| Role assignment | Function App MI gets `Azure Event Hubs Data Sender` at the namespace |

Approximate cost in `australiaeast`: ~AUD 20/month at low traffic (Event Hub Standard is the dominant cost; Function Consumption is effectively free for this workload).

## Prerequisites

1. Azure CLI logged in (`az login --tenant <tenant_id>`)
2. Terraform 1.9+
3. Azure Functions Core Tools 4.x (for `func azure functionapp publish`)
   - macOS: `brew install azure/functions/azure-functions-core-tools@4`
   - Windows: `winget install Microsoft.AzureFunctionsCoreTools`
4. Python 3.11 locally (the Function uses Python 3.11; matching the local version avoids surprises during the publish step)

## Deploy

### Step 1: Provision the Azure resources

```bash
git clone https://github.com/andrewbearsley/forticnapp-azure-eventhub-webhook-shim.git
cd forticnapp-azure-eventhub-webhook-shim/terraform

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set subscription_id, location, webhook_shared_secret

terraform init
terraform plan
terraform apply
```

Terraform outputs the Function App name, webhook endpoint, and Event Hub namespace FQDN. Capture them:

```bash
terraform output -raw function_app_name
terraform output -raw webhook_endpoint
terraform output -raw event_hub_namespace_fqdn
```

### Step 2: Deploy the Function code

From the repo root:

```bash
cd function
func azure functionapp publish $(terraform -chdir=../terraform output -raw function_app_name)
```

This packages the Python code, pushes it to the Function App, and installs the dependencies in `requirements.txt`. First publish takes 1-2 minutes.

### Step 3: Get the function key

```bash
az functionapp keys list \
  --resource-group $(terraform -chdir=../terraform output -raw resource_group_name) \
  --name $(terraform -chdir=../terraform output -raw function_app_name) \
  --query "functionKeys.default" -o tsv
```

Save the key. You'll paste it into FortiCNAPP next.

## Wire FortiCNAPP

In the FortiCNAPP console:

1. **Settings > Notifications > Alert Channels > Add New > Custom Webhook**
2. **Webhook URL**: paste the `webhook_endpoint` output and append `?code=<function-key>`. The full URL looks like:
   ```
   https://fcnapp-eventhub-shim-abc123.azurewebsites.net/api/forward?code=<function-key>
   ```
3. If you set a `webhook_shared_secret` in Terraform, add a custom header:
   - Header name: `X-Webhook-Secret`
   - Header value: the same secret
4. Click **Test**. The Function logs an entry and forwards a sample payload to Event Hub. Verify in Event Hub's **Process Data > Capture** preview or via `az eventhubs eventhub` queries.
5. Bind the channel to alert rules under **Settings > Notifications > Alert Rules** by severity, integration source, or resource group.

## Wire the downstream consumer

The shim doesn't know or care what reads from Event Hub. Common patterns:

| Downstream | How it reads from Event Hub |
|---|---|
| **Splunk** | Splunk Add-on for Microsoft Cloud Services configured with an Event Hub input |
| **Microsoft Sentinel** | Data Connector with an Event Hub source |
| **Azure Data Explorer / Fabric** | Event Hub data connection |
| **Custom consumer** | Any AMQP / Kafka-compatible client using the Event Hub SDK |

Connection details for the consumer:

- Namespace FQDN: see `event_hub_namespace_fqdn` Terraform output
- Event Hub name: see `event_hub_name` Terraform output (default: `fcnapp-alerts`)
- Auth: create a separate Shared Access Policy with `Listen` permission, or grant the consumer's identity `Azure Event Hubs Data Receiver` at the Event Hub or namespace scope

## Operations

### Rotating the shared secret

```bash
# Update Terraform variable
# edit terraform/terraform.tfvars: set new webhook_shared_secret
cd terraform
terraform apply
# Then update the X-Webhook-Secret header on the FortiCNAPP Custom Webhook channel
```

### Rotating the function key

```bash
az functionapp keys set \
  --resource-group <rg> \
  --name <function-app> \
  --key-type functionKeys \
  --key-name default
```

A new default key value is returned. Update the `?code=` parameter on the FortiCNAPP Custom Webhook channel.

### Monitoring

The Function logs to Application Insights if connected (not provisioned here by default; add `azurerm_application_insights` to `main.tf` if you want it). For lightweight monitoring, use `az functionapp log tail`.

### Locking down the inbound

For tighter posture, restrict the Function App to known FortiCNAPP egress IPs via `site_config.ip_restriction`. Lacework's documented SaaS egress IPs are listed in the FortiCNAPP docs and change occasionally; pin them carefully.

### Locking down the Event Hub

Add `azurerm_eventhub_namespace_network_rules` to constrain who can produce / consume from the namespace. The Function's Managed Identity uses the Azure backbone and is unaffected by IP rules, but external consumers (Splunk on-prem, Sentinel in another tenant) will need their IPs allowlisted.

## Local development

```bash
cd function
cp local.settings.json.example local.settings.json
# edit local.settings.json: set EVENT_HUB_NAMESPACE_FQDN, EVENT_HUB_NAME, optional WEBHOOK_SHARED_SECRET

# install deps in a venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# run locally
func start
```

Note: local runs use `DefaultAzureCredential`, which falls through to `az login` credentials. You'll need `Azure Event Hubs Data Sender` on the namespace for the local user identity to test the full path.

## Related guides

- <a href="https://github.com/andrewbearsley/forticnapp-azure-integration-guide" target="_blank">FortiCNAPP Azure Integration Guide</a> (Config + Activity Log + DSPM + FortiGate + Alert Channels)
- <a href="https://github.com/andrewbearsley/forticnapp-azure-agentless-workload-scanning-guide" target="_blank">FortiCNAPP Azure Agentless Workload Scanning Guide</a>

## References

- <a href="https://docs.fortinet.com/document/forticnapp/26.2.0/administration-guide/659277/datadog-alert-channel" target="_blank">FortiCNAPP Administration Guide: Alert Channels</a>
- <a href="https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-python" target="_blank">Azure Functions Python Developer Guide</a>
- <a href="https://learn.microsoft.com/en-us/azure/event-hubs/authenticate-managed-identity" target="_blank">Authenticate a managed identity with Microsoft Entra ID to access Event Hubs</a>
