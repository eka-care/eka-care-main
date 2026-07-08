import importlib

from config_loader import load_client_config


def _get_integration_module(client_name=None):
    client_config = load_client_config(client_name)
    package_name = (client_config.get("integration_package") or "metropolis").lower()
    return importlib.import_module(package_name)


def send_wa_msg_yellow_ai(payload, client_name=None):
    integration_module = _get_integration_module(client_name)
    return integration_module.send_wa_msg(payload)


def send_msg_japi(mobile, text, client_name=None):
    integration_module = _get_integration_module(client_name)
    return integration_module.send_sms(mobile, text)
