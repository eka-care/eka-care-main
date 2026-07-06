import requests
import json

from constants import YELLOW_AI_API_KEY, JAPI_KEY, JAPI_AUTHORIZATION


def send_wa_msg_yellow_ai(payload):
    url = "https://app.yellow.ai/api/engagements/notifications/v2/push?bot=x1653651115382"
    headers = {
        "x-api-key": YELLOW_AI_API_KEY,
        "Content-Type": "application/json",
    }
    response = requests.request("POST", url, headers=headers, json=payload)
    response_data = response.json()
    print(response_data)
    return response_data


def send_msg_japi(mobile, text):
    url = "https://japi.instaalerts.zone/httpapi/JsonReceiver"
    mobile = f"91{mobile}"
    payload = {
        "ver": "1.0",
        "key": JAPI_KEY,
        "messages": [
            {
                "dest": [mobile],
                "text": text,
                "send": "METLAB",
            }
        ],
    }

    headers = {
        "Authorization": JAPI_AUTHORIZATION,
        "Content-Type": "application/json",
    }

    response = requests.request("POST", url, headers=headers, json=payload)
    response_data = response.json()
    print(response_data)
    return response_data
