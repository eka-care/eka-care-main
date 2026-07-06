import requests
import json


def send_wa_msg_yellow_ai(payload):
    url = "https://app.yellow.ai/api/engagements/notifications/v2/push?bot=x1653651115382"
    headers = {
        "x-api-key": "dZTnwScEuyw33i0XPmXky2w8IYb0zfkbn-z-RCiJ",
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
        "key": "6HpAHyzAwpy0R9Ulic1Jnw==",
        "messages": [
            {
                "dest": [mobile],
                "text": text,
                "send": "METLAB",
            }
        ],
    }

    headers = {
        "Authorization": "bWV0cm9fYXBpOnZWdUFwRGtaMzV6QkRkcWJJcnNFMXc9PQ==",
        "Content-Type": "application/json",
    }

    response = requests.request("POST", url, headers=headers, json=payload)
    response_data = response.json()
    print(response_data)
    return response_data
