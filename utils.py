from datetime import datetime, timezone, timedelta
from message_integration import send_wa_msg_yellow_ai, send_msg_japi
from template_configs import *


def get_templates_by_data(event_data, event):
    appointment_details = event_data.get("appointment_details", {})
    wa_templates = []
    sms_templates = []
    if event == "appointment.created":
        if appointment_details.get("mode") in ["in-clinic", "in_clinic"]:
            wa_templates.append(EKA_WA_NEW_APPOINTMENT_DR_MESSAGE)
            wa_templates.append(EKA_WA_APPOINTMENT_CONFIRMATION_PA)
            sms_templates.append(SMS_INCLINIC_MSG)
        elif appointment_details.get("mode") == "tele":
            wa_templates.append(
                EKA_METROPOLIS_TELE_CONSULTATION_PA,
            )
            wa_templates.append(EKA_WA_NEW_APPOINTMENT_DR_MESSAGE)
            # sms_templates.append(SMS_TELECONSULTATION_CONFIRMATION_MSG)
            sms_templates.append(SMS_TELECONSULTATION_CONFIRMATION_MSG_1)

    elif event in ["prescription.created", "prescription.updated"]:
        wa_templates.append(EKA_WA_PRESCRIPTION_PA)
    elif event in ["appointment.tele.dr_joined"]:
        wa_templates.append(EKA_CONSULATATION_STARTED)

        # if appointment_details.get("status") == "BK" and appointment_details.get("mode") == "in-clinic":
        #     wa_templates.append(
        #         EKA_WA_APPOINTMENT_CONFIRMATION_PA, EKA_WA_NEW_APPOINTMENT_DR_MESSAGE
        #     )
        #     msg_templates.append()
        # elif appointment_details.get("rescheduled") and appointment_details.get("status") == "BK" and appointment_details.get("old_appointment_details",{}).get("status") in ["RED","RES"]:
        #     wa_templates.append(EKA_WA_APPOINTMENT_RESCHEDULED_DR)
        # elif appointment_details.get("status") == "BK" and appointment_details.get("mode") == "tele":
        #     wa_templates.append(
        #         EKA_WA_TELECONSULTATION_CONFIRMATION_PA,
        #         EKA_WA_NEW_APPOINTMENT_DR_MESSAGE,
        #     )
    # elif event == "appointment.updated":
    #     if appointment_details.get("status") in ["CND","CN","CNS"]:
    #         wa_templates.append(EKA_WA_CANCELLATION_DR_MESSAGE)

    return wa_templates, sms_templates


template_name_to_params = {
    EKA_WA_NEW_APPOINTMENT_DR_MESSAGE: {
        "wa_msg_params": ["pt_name", "appointment_start_time"]
    },
    EKA_WA_APPOINTMENT_CONFIRMATION_PA: {
        "wa_msg_params": ["pt_name", "dr_name", "appointment_start_time", "contact_no"]
    },
    EKA_WA_TELECONSULTATION_CONFIRMATION_PA: {
        "wa_msg_params": ["pt_name", "dr_name", "appointment_start_time", "contact_no"]
    },
    EKA_WA_PRESCRIPTION_PA: {
        "wa_msg_params": ["pt_name", "dr_name"],
        "media_params": ["prescription_url"],
    },
    EKA_CONSULATATION_STARTED: {"wa_msg_params": ["dr_name", "tele_url"]},
    EKA_METROPOLIS_TELE_CONSULTATION_PA: {
        "wa_msg_params": [
            "dr_name",
            "appointment_time_str",
            "appointment_date_str",
            "tele_url",
            "contact_no",
        ]
    },
    SMS_TELECONSULTATION_CONFIRMATION_MSG: {
        "sms_params": ["pt_name", "dr_name", "appointment_start_time"]
    },
    SMS_INCLINIC_MSG: {
        "sms_params": ["pt_name", "dr_name", "appointment_start_time", "clinic_name"]
    },
    SMS_TELECONSULTATION_CONFIRMATION_MSG_1: {
        "sms_params": ["dr_name", "appointment_start_time", "tele_url", "contact_no"]
    },
}


def enrich_params(template_name, message_data):
    params_data = {}
    cnt = 0
    for param in template_name_to_params[template_name]["wa_msg_params"]:
        cnt += 1
        params_data[str(cnt)] = message_data[param]

    for param in template_name_to_params[template_name].get("media_params", []):
        params_data["media"] = {"filename": param, "mediaLink": message_data[param]}

    return params_data


def format_epoch_to_ist(epoch):
    # Convert to IST
    ist = timezone(timedelta(hours=5, minutes=30))
    dt = datetime.fromtimestamp(epoch, tz=ist)

    # Add ordinal suffix to day
    day = dt.day
    if 10 < day % 100 < 14:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")

    formatted = dt.strftime(f"%-d{suffix} %b %y at %I:%M %p")
    return formatted


def get_appointment_date_and_time(appointment_start_time_epoch):
    # Define IST manually using timezone
    ist = timezone(timedelta(hours=5, minutes=30))

    # Convert epoch to datetime in IST
    dt = datetime.fromtimestamp(appointment_start_time_epoch, tz=ist)

    # Format date and time separately
    date_str = dt.date().isoformat()  # e.g. '2025-07-07'
    time_str = dt.strftime("%I:%M %p")  # e.g. '02:30 PM'

    return date_str, time_str


def get_message_data(event_data):
    appointment_details = event_data.get("appointment_details", {})
    aid = appointment_details.get("appointment_id", "")
    patient_details = event_data.get("patient_details", {})
    doctor_details = event_data.get("doctor_details", {})
    clinic_details = event_data.get("clinic_details", {})
    clinic_name = clinic_details.get("data", {}).get("clinic", {}).get("name", "")
    dr_personal_details = doctor_details.get("profile", {}).get("personal", {})
    dr_mobile = dr_personal_details.get("mobile") or ""
    dr_mobile = dr_mobile[-10:]
    dr_first_name = dr_personal_details.get("first_name", "")
    dr_name = "Dr. " + dr_first_name
    dr_last_name = dr_personal_details.get("last_name")
    if dr_last_name:
        dr_name += f" {dr_last_name}"
    px_url = appointment_details.get("prescription_url", "")
    pt_mobile = patient_details.get("mobile") or ""
    pt_mobile = pt_mobile[-10:]
    pt_first_name = patient_details.get("first_name")
    pt_last_name = patient_details.get("last_name")
    pt_name = pt_first_name
    tele_url = f"https://consultation.metropolisindia.com?apptid={aid}"
    if pt_last_name:
        pt_name += f" {pt_last_name}"

    appointment_start_time_epoch = appointment_details.get("start_time")
    appointment_start_time = format_epoch_to_ist(appointment_start_time_epoch)
    appointment_date_str, appointment_time_str = get_appointment_date_and_time(
        appointment_start_time_epoch
    )

    message_data = {
        "dr_mobile": dr_mobile,
        "dr_name": dr_name,
        "pt_mobile": pt_mobile,
        "pt_name": pt_name,
        "clinic_name": clinic_name,
        "appointment_start_time": appointment_start_time,
        "contact_no": "8422-801-801",
        "prescription_url": px_url,
        "tele_url": tele_url,
        "appointment_date_str": appointment_date_str,
        "appointment_time_str": appointment_time_str,
    }
    return message_data


def send_wa_message(template_name, message_data):
    dr_mobile = message_data["dr_mobile"]
    pt_mobile = message_data["pt_mobile"]
    mobile = dr_mobile if template_name in dr_templates else pt_mobile
    template_payload = {
        "userDetails": {"number": mobile},
        "notification": {
            "templateId": template_name,
            "params": enrich_params(template_name, message_data),
            "type": "whatsapp",
            "sender": "918422801801",
            "language": "en",
            "namespace": "8b0dac33_a4d2_4e1b_a199_65417d3a394c",
        },
    }
    send_wa_msg_yellow_ai(template_payload)


def send_sms(sms_template_name, message_data):
    dr_mobile = message_data["dr_mobile"]
    pt_mobile = message_data["pt_mobile"]
    mobile = dr_mobile if sms_template_name in dr_templates else pt_mobile
    sms_text = sms_template_name
    sms_text_args = template_name_to_params[sms_template_name]["sms_params"]
    args_values = [message_data[arg] for arg in sms_text_args]
    formatted_sms = sms_text.format(*args_values)
    send_msg_japi(mobile, formatted_sms)
