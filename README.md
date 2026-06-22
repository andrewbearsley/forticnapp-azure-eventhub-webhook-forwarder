# FortiCNAPP to Azure Event Hub Webhook Forwarder

FortiCNAPP has no native Event Hub alert channel. If Event Hub is already your ingest pipe (everything funnels through it on the way to Splunk, Sentinel, or a data lake), the cleanest path is a tiny HTTPS forwarder in front. This repo is that forwarder: Terraform + a small Python Azure Function.

## Architecture

1. FortiCNAPP Custom Webhook posts the alert JSON over HTTPS to the Azure Function
2. The Function checks the function key (and optionally a shared secret header), then writes the body to Azure Event Hub
3. Downstream consumers (Splunk, Sentinel, a data lake) read from the same Event Hub

The Function uses a System-Assigned Managed Identity with `Azure Event Hubs Data Sender`, so there's no connection string to manage.

## What gets deployed

| Resource | Notes |
|---|---|
| Resource Group | Container for everything below |
| Event Hub Namespace + Hub | Standard tier, 1 TU, 2 partitions, 1-day retention |
| Storage Account | Backing store for the Function App |
| App Service Plan | Linux Consumption (Y1), scales to zero |
| Linux Function App | Python 3.11, System-Assigned MI, HTTPS only |
| Role assignment | Function App MI gets `Azure Event Hubs Data Sender` at the namespace |

Roughly AUD 20-30/month in `australiaeast` at low traffic. Event Hub Standard (1 TU) is most of it; the Function on Consumption is basically free for this workload. Costs scale with ingress volume.

## Prerequisites

1. Azure CLI logged in (`az login --tenant <tenant_id>`)
2. Terraform 1.9+
3. Azure Functions Core Tools 4.x (`brew install azure/functions/azure-functions-core-tools@4` on macOS, `winget install Microsoft.AzureFunctionsCoreTools` on Windows)
4. Python 3.11 locally. Matches what the Function runs, avoids publish-time surprises.

## Deploy

### Step 1: Provision the Azure resources

```bash
git clone https://github.com/andrewbearsley/forticnapp-azure-eventhub-webhook-forwarder.git
cd forticnapp-azure-eventhub-webhook-forwarder/terraform

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, location, webhook_shared_secret

terraform init
terraform plan
terraform apply
```

Terraform outputs the Function App name, webhook endpoint, and Event Hub namespace FQDN.

### Step 2: Deploy the Function code

```bash
cd ../function
func azure functionapp publish $(terraform -chdir=../terraform output -raw function_app_name)
```

First publish takes a minute or two. It packages the Python, pushes it up, installs the deps in `requirements.txt`.

### Step 3: Grab the function key

```bash
az functionapp keys list \
  --resource-group $(terraform -chdir=../terraform output -raw resource_group_name) \
  --name $(terraform -chdir=../terraform output -raw function_app_name) \
  --query "functionKeys.default" -o tsv
```

Save it. Goes into FortiCNAPP next.

## Wire FortiCNAPP

In the FortiCNAPP console:

1. **Settings > Notifications > Alert Channels > Add New > Custom Webhook**
2. Paste the `webhook_endpoint` output and append `?code=<function-key>`:
   ```
   https://fcnapp-eventhub-forwarder-abc123.azurewebsites.net/api/forward?code=<function-key>
   ```
3. If you set a `webhook_shared_secret` in Terraform, add a custom header `X-Webhook-Secret` with the same value
4. Click **Test**. The Function logs an entry and pushes a sample to Event Hub. Verify via `az eventhubs eventhub` or the portal **Process Data** preview.
5. Bind the channel to alert rules under **Settings > Notifications > Alert Rules**

## Wire the downstream consumer

The forwarder doesn't care who reads from Event Hub. Pick your poison:

| Downstream | How it reads |
|---|---|
| **Splunk** | Splunk Add-on for Microsoft Cloud Services with an Event Hub input |
| **Microsoft Sentinel** | Data Connector with an Event Hub source |
| **Azure Data Explorer / Fabric** | Event Hub data connection |
| **Custom** | Any AMQP / Kafka-compatible client via the Event Hub SDK |

Connection details:

- Namespace FQDN from the `event_hub_namespace_fqdn` output
- Event Hub name from `event_hub_name` (default `fcnapp-alerts`)
- Auth: separate SAS policy with `Listen`, or grant the consumer's identity `Azure Event Hubs Data Receiver`

## Operations

### Rotate the shared secret

Edit `terraform/terraform.tfvars`, `terraform apply`, then update the `X-Webhook-Secret` header on the FortiCNAPP channel.

### Rotate the function key

```bash
az functionapp keys set \
  --resource-group <rg> --name <function-app> \
  --key-type functionKeys --key-name default
```

A new value comes back. Update the `?code=` on the FortiCNAPP channel.

### Monitoring

`az functionapp log tail` for live tail. For real observability, add `azurerm_application_insights` to `main.tf` and link it on the Function App.

### Lock down inbound

Add `site_config.ip_restriction` on the Function App to allowlist FortiCNAPP's documented SaaS egress IPs. The current list lives at <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/264821/prepare-the-environment-for-lacework-forticnapp" target="_blank">FortiCNAPP: Inbound and outbound connections</a> and changes occasionally, so pin carefully.

### Lock down Event Hub

Add `azurerm_eventhub_namespace_network_rules` to constrain producers and consumers. The Function's MI rides the Azure backbone and ignores IP rules; external consumers (on-prem Splunk, Sentinel in another tenant) will need their IPs allowlisted.

## Local development

```bash
cd function
cp local.settings.json.example local.settings.json
# edit: EVENT_HUB_NAMESPACE_FQDN, EVENT_HUB_NAME, optional WEBHOOK_SHARED_SECRET

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

func start
```

Local runs use `DefaultAzureCredential`, which picks up your `az login` creds. Your user needs `Azure Event Hubs Data Sender` on the namespace to test the full path.

## Related

- <a href="https://github.com/andrewbearsley/forticnapp-azure-integration-guide" target="_blank">FortiCNAPP Azure Integration Guide</a> (Config, Activity Log, DSPM, FortiGate, Alert Channels)
- <a href="https://github.com/andrewbearsley/forticnapp-azure-agentless-workload-scanning-guide" target="_blank">FortiCNAPP Azure Agentless Workload Scanning Guide</a>

## References

- <a href="https://docs.fortinet.com/document/forticnapp/26.2.0/administration-guide/659277/datadog-alert-channel" target="_blank">FortiCNAPP Administration Guide: Alert Channels</a>
- <a href="https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-python" target="_blank">Azure Functions Python Developer Guide</a>
- <a href="https://learn.microsoft.com/en-us/azure/event-hubs/authenticate-managed-identity" target="_blank">Authenticate Managed Identity to Event Hubs</a>
