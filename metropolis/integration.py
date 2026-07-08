import requests

from constants import JAPI_AUTHORIZATION, JAPI_KEY, YELLOW_AI_API_KEY


def send_wa_msg(payload):
    url = "https://app.yellow.ai/api/engagements/notifications/v2/push?bot=x1653651115382"
    headers = {
        "x-api-key": YELLOW_AI_API_KEY,
        "Content-Type": "application/json",
    }
    response = requests.request("POST", url, headers=headers, json=payload)
    response_data = response.json()
    print(response_data)
    return response_data


def send_sms(mobile, text):
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
