import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

from webhook_consumer import WebhookConsumer
from constants import *
from template_configs import event_to_api_calls
from utils import get_templates_by_data, send_wa_message, get_message_data, send_sms
from config_loader import load_client_config, should_process_event


def _normalize_event_input(event):
    if event is None:
        return None, {}, "/", "POST", None

    if hasattr(event, "headers") and hasattr(event, "method") and hasattr(event, "path"):
        headers = dict(event.headers.items()) if hasattr(event.headers, "items") else event.headers or {}
        method = getattr(event, "method", "POST") or "POST"
        path = getattr(event, "path", "/") or "/"
        body = None
        if hasattr(event, "get_json"):
            try:
                body = event.get_json(silent=True)
            except Exception:
                body = None
        if body is None and hasattr(event, "get_data"):
            try:
                body = event.get_data(as_text=True)
            except Exception:
                body = None
        if body is None and hasattr(event, "body"):
            body = event.body
        return body, headers, path, method, None

    if isinstance(event, dict):
        if "rawPath" in event or "path" in event or "requestContext" in event or "httpMethod" in event:
            path = event.get("rawPath") or event.get("path") or "/"
            method = (
                event.get("requestContext", {}).get("http", {}).get("method")
                or event.get("httpMethod")
                or "POST"
            )
            headers = event.get("headers") or {}
            body = event.get("body")
            client_name = event.get("client_name") or event.get("client") or headers.get("X-Client-Name") or headers.get("x-client-name")
            return body, headers, path, method, client_name

        headers = event.get("headers") or {}
        path = event.get("path") or "/"
        method = event.get("method") or "POST"
        body = event.get("body", event)
        client_name = event.get("client_name") or event.get("client") or headers.get("X-Client-Name") or headers.get("x-client-name")
        return body, headers, path, method, client_name

    return event, {}, "/", "POST", None


def _coerce_body(body):
    if body is None:
        return {}
    if isinstance(body, dict):
        return body
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    if isinstance(body, str):
        stripped = body.strip()
        if not stripped:
            return {}
        try:
            return json.loads(stripped)
        except json.JSONDecodeError:
            try:
                return json.loads(stripped.encode("utf-8").decode("unicode_escape"))
            except Exception:
                return {"raw": stripped}
    return body


def _normalize_request_path(path):
    if not path:
        return "/"
    path = str(path).split("?", 1)[0]
    if path != "/":
        path = path.rstrip("/") or "/"
    return path


def generic_handler(event, context=None):
    payload, headers, path, method, client_name = _normalize_event_input(event)
    headers = headers or {}
    method = (method or "POST").upper()
    path = _normalize_request_path(path or "/")

    print(f"path : {path}")
    print(f"method : {method}")
    print(f"event : {event}")

    try:
        if method == "POST" and path == "/communication/webhook/v1/events":
            body = _coerce_body(payload)
            if not isinstance(body, dict):
                return {"statusCode": 400, "body": "Webhook body must decode to a JSON object"}

            webhook_consumer = WebhookConsumer(body)
            signature = headers.get("Eka-Webhook-Signature") or headers.get("eka-webhook-signature")
            print(f"signature : {signature}")

            client_id = CLIENT_ID
            client_secret = CLIENT_SECRET
            api_key = API_KEY or ""

            if not client_id or not client_secret:
                return {"statusCode": 400, "body": "Client ID or Client Secret not set"}

            client_config = load_client_config(client_name)
            event_type = body.get("event")
            if not event_type:
                return {"statusCode": 400, "body": "Missing webhook event"}

            if not should_process_event(event_type, client_config):
                return {
                    "statusCode": 200,
                    "body": json.dumps({"message": "skipped", "client": client_config.get("name"), "event": event_type}),
                }

            if IS_SIGNING_KEY_IMPLEMENTED:
                status, reason = webhook_consumer.verify_signature(signature)
                if not status:
                    return {"statusCode": 403, "body": reason}

            api_calls = event_to_api_calls.get(event_type, set())
            webhook_data = webhook_consumer.get_data(client_id, client_secret, api_key, api_calls)

            if webhook_data.get("error"):
                return {"statusCode": 403, "body": webhook_data.get("error")}

            event_data = json.loads(webhook_data["data"])
            wa_templates, sms_templates = get_templates_by_data(event_data, event_type, client_config)
            message_data = get_message_data(event_data, client_config)
            for template in wa_templates:
                send_wa_message(template, message_data, client_config)
            for template in sms_templates:
                send_sms(template, message_data, client_config)

            return {"statusCode": 200, "body": webhook_data.get("data")}

        return {"statusCode": 404, "body": "Not Found"}
    except Exception as e:
        print("Exception handling webhook data:", e)
        return {"statusCode": 403, "body": "Unhandled Exception"}


class WebhookRequestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body_bytes = self.rfile.read(content_length) if content_length else b""
        event = {
            "body": body_bytes.decode("utf-8"),
            "headers": {key: value for key, value in self.headers.items()},
            "path": self.path,
            "method": self.command,
            "rawPath": self.path,
        }
        response = generic_handler(event, None)
        self.send_response(int(response.get("statusCode", 200)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(response.get("body", "").encode("utf-8"))

    def do_GET(self):
        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not Found")


def run_server(host="0.0.0.0", port=None):
    port = port or int(os.getenv("PORT", "8080"))
    server = HTTPServer((host, port), WebhookRequestHandler)
    print(f"Listening on http://{host}:{port}")
    server.serve_forever()


lambda_handler = generic_handler


if __name__ == "__main__":
    run_server()
