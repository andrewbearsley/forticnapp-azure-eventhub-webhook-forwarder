import json
import logging
import os

import azure.functions as func
from azure.eventhub import EventData, EventHubProducerClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

EVENT_HUB_NAMESPACE_FQDN = os.environ["EVENT_HUB_NAMESPACE_FQDN"]
EVENT_HUB_NAME = os.environ["EVENT_HUB_NAME"]
SHARED_SECRET = os.environ.get("WEBHOOK_SHARED_SECRET", "")

producer = EventHubProducerClient(
    fully_qualified_namespace=EVENT_HUB_NAMESPACE_FQDN,
    eventhub_name=EVENT_HUB_NAME,
    credential=DefaultAzureCredential(),
)


@app.route(route="forward", methods=["POST"])
def forward(req: func.HttpRequest) -> func.HttpResponse:
    if SHARED_SECRET and req.headers.get("X-Webhook-Secret") != SHARED_SECRET:
        logging.warning("rejected: missing or bad X-Webhook-Secret header")
        return func.HttpResponse("unauthorized", status_code=401)

    body = req.get_body()
    if not body:
        return func.HttpResponse("empty body", status_code=400)

    try:
        json.loads(body)
    except json.JSONDecodeError as e:
        logging.error("invalid json body: %s", e)
        return func.HttpResponse("bad request: body is not valid json", status_code=400)

    try:
        batch = producer.create_batch()
        batch.add(EventData(body))
        producer.send_batch(batch)
    except Exception:
        logging.exception("event hub send failed")
        return func.HttpResponse("event hub send failed", status_code=502)

    return func.HttpResponse("ok", status_code=200)
