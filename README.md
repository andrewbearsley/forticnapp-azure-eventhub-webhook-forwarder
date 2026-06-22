# FortiCNAPP to Azure Event Hub Webhook Forwarder

FortiCNAPP has no native Event Hub alert channel. If Event Hub is already your ingest pipe (everything funnels through it on the way to Splunk, Sentinel, or a data lake), the cleanest path is a tiny HTTPS forwarder in front. This repo ships two interchangeable implementations of that forwarder, both Terraform-deployed:

| Pattern | Folder | When to pick it |
|---|---|---|
| **Function App (Python)** | <a href="function-app/">function-app/</a> | Default. Code-defined behaviour, easy to extend, scales to zero, basically free on Consumption |
| **Logic App (Consumption)** | <a href="logic-app/">logic-app/</a> | Visual flow, no code, easy for non-developers to read and tweak. Cost scales linearly with action count |

Both write to the same shape of Event Hub. Downstream consumers (Splunk Add-on, Sentinel, ADX) don't know or care which one fronts it.

## Architecture (same for both patterns)

1. FortiCNAPP Custom Webhook posts the alert JSON over HTTPS to the forwarder
2. The forwarder validates the request (function key / SAS sig, plus optional shared-secret header), then writes the body to Azure Event Hub
3. Downstream consumers (Splunk, Sentinel, a data lake) read from the same Event Hub

Both patterns authenticate to Event Hub via System-Assigned Managed Identity with `Azure Event Hubs Data Sender`. No connection strings to manage.

Both run around AUD 20-30/month in `australiaeast` at low traffic. Event Hub Standard (1 TU) is most of it; costs scale with ingress volume.

## Pick a pattern

| Concern | Function App | Logic App (Consumption) |
|---|---|---|
| Code vs no-code | Python | JSON workflow, visual designer in the portal |
| Cost shape | Flat (Storage + Plan baseline) | Per-action (cheaper baseline, scales linearly) |
| Extensibility | Easy: edit `function_app.py` and republish | Edit workflow in designer or `azapi_resource` body |
| Inbound auth | Function key in URL + optional shared secret header | SAS sig in URL + optional shared secret header |
| Cold start | ~1-3s on first hit after idle | Negligible |
| Best for | Default for most teams | Teams that prefer visual flows or want minimal code |

Two self-contained setup paths follow. Pick one and ignore the other.

---

## Function App (Python)

Code-defined Python forwarder running on Linux Consumption.

### What gets deployed

| Resource | Notes |
|---|---|
| Resource Group | Container for everything below |
| Event Hub Namespace + Hub | Standard tier, 1 TU, 2 partitions, 1-day retention |
| Storage Account | Backing store for the Function App (required) |
| App Service Plan | Linux Consumption (Y1), scales to zero |
| Linux Function App | Python 3.11, System-Assigned MI, HTTPS only |
| Role assignment | Function App MI gets `Azure Event Hubs Data Sender` at the namespace |

### Prerequisites

1. Azure CLI logged in (`az login --tenant <tenant_id>`)
2. Terraform 1.9+
3. Azure Functions Core Tools 4.x (`brew install azure/functions/azure-functions-core-tools@4` on macOS, `winget install Microsoft.AzureFunctionsCoreTools` on Windows)
4. Python 3.11 locally. Matches what the Function runs, avoids publish-time surprises.

### Deploy

Provision the Azure resources:

```bash
git clone https://github.com/andrewbearsley/forticnapp-azure-eventhub-webhook-forwarder.git
cd forticnapp-azure-eventhub-webhook-forwarder/function-app/terraform

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, location, webhook_shared_secret

terraform init
terraform plan
terraform apply
```

Deploy the Function code:

```bash
cd ../function
func azure functionapp publish $(terraform -chdir=../terraform output -raw function_app_name)
```

First publish takes a minute or two.

Grab the function key:

```bash
az functionapp keys list \
  --resource-group $(terraform -chdir=../terraform output -raw resource_group_name) \
  --name $(terraform -chdir=../terraform output -raw function_app_name) \
  --query "functionKeys.default" -o tsv
```

The full webhook URL is `<webhook_endpoint>?code=<function-key>`. That goes into FortiCNAPP (see <a href="#wire-forticnapp">Wire FortiCNAPP</a>).

### Operations

**Rotate the shared secret**: edit `terraform/terraform.tfvars`, `terraform apply`, then update the `X-Webhook-Secret` header on the FortiCNAPP channel.

**Rotate the function key**:
```bash
az functionapp keys set \
  --resource-group <rg> --name <function-app> \
  --key-type functionKeys --key-name default
```
Update the `?code=` on the FortiCNAPP channel.

**Monitoring**: `az functionapp log tail` for live tail. For real observability, add `azurerm_application_insights` to `function-app/terraform/main.tf` and link it on the Function App.

**Lock down inbound**: add `site_config.ip_restriction` on the Function App to allowlist FortiCNAPP's SaaS egress IPs. See <a href="#lock-down-event-hub">Lock down Event Hub</a> below for namespace-level rules.

### Local development

```bash
cd function-app/function
cp local.settings.json.example local.settings.json
# edit: EVENT_HUB_NAMESPACE_FQDN, EVENT_HUB_NAME, optional WEBHOOK_SHARED_SECRET

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

func start
```

Local runs use `DefaultAzureCredential`, which picks up your `az login` creds. Your user needs `Azure Event Hubs Data Sender` on the namespace to test the full path.

---

## Logic App (Consumption)

No-code workflow forwarder. The workflow definition lives in the Terraform.

### What gets deployed

| Resource | Notes |
|---|---|
| Resource Group | Container for everything below |
| Event Hub Namespace + Hub | Standard tier, 1 TU, 2 partitions, 1-day retention |
| Logic App workflow (Consumption) | System-Assigned MI, HTTP trigger, posts to Event Hub REST |
| Role assignment | Workflow MI gets `Azure Event Hubs Data Sender` at the namespace |

No Storage Account, no App Service Plan.

### Prerequisites

1. Azure CLI logged in (`az login --tenant <tenant_id>`)
2. Terraform 1.9+

That's it. No language runtime, no Functions Core Tools.

### Deploy

```bash
git clone https://github.com/andrewbearsley/forticnapp-azure-eventhub-webhook-forwarder.git
cd forticnapp-azure-eventhub-webhook-forwarder/logic-app/terraform

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, location, webhook_shared_secret

terraform init
terraform plan
terraform apply
```

Grab the SAS-signed trigger URL. Logic App Consumption issues this URL on demand rather than storing it as a Terraform output:

```bash
terraform output -raw fetch_webhook_url_command | bash
```

(The Terraform output prints the exact `az rest` call. Pipe it to bash, or run it manually.)

Or simpler: open the workflow in the Azure portal, click the **When a HTTP request is received** trigger, copy the **HTTP POST URL** shown.

That URL already includes the SAS signature in the `sig` query parameter. It goes into FortiCNAPP (see <a href="#wire-forticnapp">Wire FortiCNAPP</a>).

### Operations

**Rotate the shared secret**: edit `terraform/terraform.tfvars`, `terraform apply`, then update the `X-Webhook-Secret` header on the FortiCNAPP channel.

**Rotate the inbound URL**: regenerate the SAS by rotating the workflow's access key:
```bash
az logic workflow generate-access-key \
  --resource-group <rg> --workflow-name <workflow> \
  --key-type Primary
```
Re-fetch the callback URL (see Deploy above) and update FortiCNAPP.

**Monitoring**: every run is visible in the portal under **Run history** with full input/output for each action. Add Diagnostic Settings to push runs to Log Analytics for long-term searchability.

**Lock down inbound**: add `accessControl` workflow properties to restrict caller IPs. See <a href="#lock-down-event-hub">Lock down Event Hub</a> below for namespace-level rules.

Logic App Consumption has no local runtime equivalent. Use the portal's **Run trigger** button to test.

---

## Wire FortiCNAPP

Same wiring for both patterns. After your chosen pattern's Deploy steps:

1. **Settings > Notifications > Alert Channels > Add New > Custom Webhook**
2. Paste the webhook URL (function URL with `?code=...` for Function App, or the SAS-signed trigger URL for Logic App)
3. If you set a `webhook_shared_secret`, add a custom header `X-Webhook-Secret` with the same value
4. Click **Test**. Verify the message landed in Event Hub via `az eventhubs eventhub` or the portal **Process Data** preview
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

## Lock down Event Hub

Add `azurerm_eventhub_namespace_network_rules` to constrain producers and consumers. The forwarder's MI rides the Azure backbone and ignores IP rules; external consumers (on-prem Splunk, Sentinel in another tenant) will need their IPs allowlisted.

For FortiCNAPP SaaS egress IPs (used in the inbound lock-down for either pattern), the current list lives at <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/264821/prepare-the-environment-for-lacework-forticnapp" target="_blank">FortiCNAPP: Inbound and outbound connections</a>. Changes occasionally, so pin carefully.

## Other patterns to know about

The two implementations in this repo cover most cases. A few alternatives worth knowing about if your environment pushes you toward one:

| Pattern | When it makes sense | Trade-offs |
|---|---|---|
| **Logic App (Standard)** | Single-tenant, runs on App Service Plan, predictable fixed cost. Worth it if you already run several Standard workflows | Higher baseline cost than Consumption, more moving parts |
| **APIM** | FortiCNAPP is one of many integrations already routing through APIM. Use a policy to validate the header, then `send-request` to the Event Hub REST endpoint | Overkill if this is the only integration. Developer tier ~AUD 50/month, Consumption tier per-call |
| **Container App / App Service web app** | You already have a container or web app deployment story you'd rather reuse | No real upside over Functions for this workload |

Things that look like candidates but aren't:

- **Event Grid** wrong direction. Event Grid reads from Event Hub, not the other way
- **Direct Event Hub REST from FortiCNAPP** the Custom Webhook channel can't sign requests with Entra tokens, so it can't authenticate to Event Hub directly

## Related

- <a href="https://github.com/andrewbearsley/forticnapp-azure-integration-guide" target="_blank">FortiCNAPP Azure Integration Guide</a> (Config, Activity Log, DSPM, FortiGate, Alert Channels)
- <a href="https://github.com/andrewbearsley/forticnapp-azure-agentless-workload-scanning-guide" target="_blank">FortiCNAPP Azure Agentless Workload Scanning Guide</a>

## References

- <a href="https://docs.fortinet.com/document/forticnapp/26.2.0/administration-guide/659277/datadog-alert-channel" target="_blank">FortiCNAPP Administration Guide: Alert Channels</a>
- <a href="https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-python" target="_blank">Azure Functions Python Developer Guide</a>
- <a href="https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-overview" target="_blank">Azure Logic Apps overview</a>
- <a href="https://learn.microsoft.com/en-us/azure/event-hubs/authenticate-managed-identity" target="_blank">Authenticate Managed Identity to Event Hubs</a>
