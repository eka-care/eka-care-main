import json
from webhook_consumer import (WebhookConsumer)
from constants import *
from template_configs import event_to_api_calls
from utils import get_templates_by_data, send_wa_message, get_message_data, send_sms

def lambda_handler(event, context):

    path = event.get('rawPath') or event.get('path')
    method = event.get('requestContext', {}).get('http', {}).get('method') or event.get('httpMethod')
    print(f"path : {path}")
    print(f"method : {method}")
    print(f"event : {event}")

    try:
        # TODO: Add better Route handling; flask ?
        if method == 'POST' and path == '/':
            escaped_json = event.get('body')
            unescaped_json = escaped_json.encode('utf-8').decode('unicode_escape')
            body = json.loads(unescaped_json)

            webhook_consumer = WebhookConsumer(body)
            signature = event.get('headers', {}).get('Eka-Webhook-Signature')
            if not signature:
                signature = event.get('headers', {}).get('eka-webhook-signature')

            print(f"signature : {signature}")

            client_id = CLIENT_ID
            client_secret = CLIENT_SECRET
            api_key = API_KEY

            if not client_id or not client_secret:
                return {
                    'statusCode': 400,
                    'body': 'Client ID or Client Secret not set'
                }

            if IS_SIGNING_KEY_IMPLEMENTED:
                status, reason =  webhook_consumer.verify_signature(signature)
                if not status:
                    return {"statusCode": 403, "body": reason}

            event_type = body["event"]
            api_calls = event_to_api_calls.get(event_type, set())
            webhook_data = webhook_consumer.get_data(
                client_id, client_secret, api_key, api_calls
            )

            if webhook_data.get("error"):
                return {"statusCode": 403, "body": webhook_data.get("error")}
            event_data = json.loads(webhook_data["data"])
            wa_templates, sms_templates = get_templates_by_data(event_data, event_type)
            message_data = get_message_data(event_data)
            for template in wa_templates:
                send_wa_message(template, message_data)
            for template in sms_templates:
                send_sms(template, message_data)

            return {"statusCode": 200, "body": webhook_data.get("data")}
        else:
            return {"statusCode": 404, "body": "Not Found"}
    except Exception as e:
        print("Exception handling webhook data:", e)
        return {
            'statusCode': 403,
            'body': 'Unhandled Exception'
        }
