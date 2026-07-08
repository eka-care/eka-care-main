import os
from pathlib import Path
from typing import Any, Dict, Optional

import yaml


ROOT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG_PATH = os.getenv("CLIENT_CONFIG_PATH", str(ROOT_DIR / "config.yaml"))


def _load_yaml_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    path = Path(config_path or DEFAULT_CONFIG_PATH)
    if not path.exists():
        return {}

    with path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def load_client_config(client_name: Optional[str] = None) -> Dict[str, Any]:
    config_data = _load_yaml_config()
    clients = config_data.get("clients", {}) or {}
    selected_client = client_name or os.getenv("CLIENT_NAME") or config_data.get("default_client", "metropolis")
    client_config = clients.get(selected_client, {}) or {}

    return {
        "name": selected_client,
        "integration_package": client_config.get("integration_package") or config_data.get("integration_package", selected_client),
        "contact_no": client_config.get("contact_no") or config_data.get("contact_no", "8422-801-801"),
        "tele_url_base": client_config.get("tele_url_base") or config_data.get("tele_url_base", "https://consultation.metropolisindia.com"),
        "event_triggers": client_config.get("event_triggers") or config_data.get("event_triggers", []),
        "templates": client_config.get("templates") or {},
        "channels": client_config.get("channels") or {},
    }


def should_process_event(event_name: str, client_config: Optional[Dict[str, Any]] = None) -> bool:
    if not client_config:
        client_config = load_client_config()

    event_triggers = client_config.get("event_triggers", []) or []
    if not event_triggers:
        return True

    return event_name in event_triggers
