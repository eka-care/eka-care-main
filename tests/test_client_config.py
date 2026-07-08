import unittest

from config_loader import load_client_config
from template_configs import (
    EKA_WA_APPOINTMENT_CONFIRMATION_PA,
    EKA_WA_NEW_APPOINTMENT_DR_MESSAGE,
    SMS_INCLINIC_MSG,
)
from utils import get_templates_by_data, get_integration_module
from miracles.integration import build_miracles_payload


class ClientConfigTests(unittest.TestCase):
    def test_metropolis_appointment_created_templates_follow_client_config(self):
        client_config = load_client_config("metropolis")
        event_data = {"appointment_details": {"mode": "in-clinic"}}

        wa_templates, sms_templates = get_templates_by_data(
            event_data, "appointment.created", client_config
        )

        self.assertEqual(
            wa_templates,
            [EKA_WA_NEW_APPOINTMENT_DR_MESSAGE, EKA_WA_APPOINTMENT_CONFIRMATION_PA],
        )
        self.assertEqual(sms_templates, [SMS_INCLINIC_MSG])

    def test_get_integration_module_returns_client_package(self):
        metropolis_module = get_integration_module({"name": "metropolis"})
        miracles_module = get_integration_module({"name": "miracles"})

        self.assertEqual(metropolis_module.__name__, "metropolis")
        self.assertEqual(miracles_module.__name__, "miracles")

    def test_build_miracles_payload_uses_waba_media_template_shape(self):
        incoming_payload = {
            "userDetails": {"number": "9876543210"},
            "notification": {
                "templateId": "eka_prescription",
                "params": {
                    "1": "Dr. Jane",
                    "media": {
                        "filename": "Prescription.pdf",
                        "mediaLink": "https://example.com/prescription.pdf",
                    },
                },
            },
        }

        built_payload = build_miracles_payload(incoming_payload)

        self.assertEqual(built_payload["message"]["channel"], "WABA")
        self.assertEqual(built_payload["message"]["recipient"]["to"], "919876543210")
        self.assertEqual(built_payload["message"]["content"]["type"], "MEDIA_TEMPLATE")
        self.assertEqual(
            built_payload["message"]["content"]["mediaTemplate"]["media"]["url"],
            "https://example.com/prescription.pdf",
        )
        self.assertEqual(
            built_payload["message"]["content"]["mediaTemplate"]["bodyParameterValues"]["0"],
            "Dr. Jane",
        )


if __name__ == "__main__":
    unittest.main()
