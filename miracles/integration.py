import os

import requests

from constants import JAPI_AUTHORIZATION, JAPI_KEY, YELLOW_AI_API_KEY


def _normalize_mobile_number(mobile):
    if not mobile:
        return ""
    mobile = str(mobile).strip()
    if mobile.startswith("+"):
        mobile = mobile[1:]
    if mobile.startswith("91"):
        return mobile
    return f"91{mobile}"


def _build_body_parameter_values(params):
    body_values = {}
    if not isinstance(params, dict):
        return body_values

    ordered_keys = sorted(
        [key for key in params if isinstance(key, str) and key.isdigit()],
        key=lambda key: int(key),
    )
    for idx, key in enumerate(ordered_keys):
        value = params[key]
        if isinstance(value, dict):
            continue
        body_values[str(idx)] = str(value)
    return body_values


def build_miracles_payload(payload):
    notification = payload.get("notification", {}) or {}
    params = notification.get("params", {}) or {}
    media_info = params.get("media", {}) or {}
    template_id = notification.get("templateId", "") or ""

    media_template = {
        "templateId": "ekaprecription" if "prescription" in str(template_id).lower() else template_id,
        "bodyParameterValues": _build_body_parameter_values(params),
    }

    if media_info.get("mediaLink"):
        media_template["media"] = {
            "type": "document",
            "url": media_info.get("mediaLink"),
            "fileName": media_info.get("filename") or "Prescription.pdf",
        }

    return {
        "message": {
            "channel": "WABA",
            "content": {
                "preview_url": False,
                "type": "MEDIA_TEMPLATE" if media_info.get("mediaLink") else "TEXT_TEMPLATE",
                "mediaTemplate": media_template,
            },
            "recipient": {
                "to": _normalize_mobile_number(payload.get("userDetails", {}).get("number")),
                "recipient_type": "individual",
                "reference": {
                    "cust_ref": "cust_ref123",
                    "messageTag1": "Message Tag 001",
                    "conversationId": "Conv_123",
                },
            },
            "sender": {
                "name": "Miracles_WABA",
                "from": "919953855061",
            },
            "preferences": {
                "webHookDNId": "1001",
            },
        },
        "metaData": {
            "version": "v1.0.9",
        },
    }


def send_wa_msg(payload):
    wa_payload = build_miracles_payload(payload)
    url = "https://rcmapi.instaalerts.zone/services/rcm/sendMessage"
    headers = {
        "Content-Type": "application/json",
        "Authentication": os.getenv("RCMAPI_API_KEY") # "Wyv7huD0i0gSMcnm33gurA==",
    }
    response = requests.request("POST", url, headers=headers, json=wa_payload)
    response_data = response.json()
    print(response_data)
    return response_data


def send_sms(mobile, text):
    raise NotImplementedError("send_sms is not implemented for miracles integration")