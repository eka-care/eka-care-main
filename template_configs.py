from ekacare.webhooks.enums import FetchType

event_to_api_calls = {
    "appointment.created": {
        FetchType.PATIENT,
        FetchType.APPOINTMENT,
        FetchType.DOCTOR,
        FetchType.CLINIC,
    },
    "prescription.created": {
        FetchType.PATIENT,
        FetchType.APPOINTMENT,
        FetchType.DOCTOR,
    },
    "prescription.updated": {
        FetchType.PATIENT,
        FetchType.APPOINTMENT,
        FetchType.DOCTOR,
    },
    "appointment.tele.dr_joined": {
        FetchType.DOCTOR,
        FetchType.PATIENT,
        FetchType.APPOINTMENT,
    },
}

EKA_WA_NEW_APPOINTMENT_DR_MESSAGE = "eka_wa_new_appointment_dr_message"
EKA_WA_APPOINTMENT_RESCHEDULED_DR = "eka_wa_appointment_rescheduled_dr"
EKA_WA_CANCELLATION_DR_MESSAGE = "eka_wa_cancellation_dr_message"
EKA_WA_TELECONSULTATION_CONFIRMATION_PA = "eka_wa_teleconsultation_confirmation"
EKA_WA_APPOINTMENT_CANCELLATION_PA = "eka_wa_appointment_cancellation_pa"
EKA_WA_APPOINTMENT_CONFIRMATION_PA = "eka_wa_appointment_confirmation"
EKA_WA_PRESCRIPTION_PA = "eka_prescription"
EKA_CONSULATATION_STARTED = "consultation_started1_copy"
EKA_METROPOLIS_TELE_CONSULTATION_PA = "teleconsult_new"

SMS_TELECONSULTATION_CONFIRMATION_MSG = "CONFIRMED {}'s Tele consultation with {} for Tomorrow, {}. Please call on 8422801801 to manage your appointment or visit nearest Metropolis Healthcare Clinic Thanks! Team -Metropolis"
SMS_TELECONSULTATION_CONFIRMATION_MSG_1 = "Dear Customer, Your Tele-consultation with {} is on, {}. Please join at: {}. Please call on {} to manage your appointment or visit nearest Metropolis Clinic. We look forward to seeing you soon. Thanks! Metropolis Healthcare Clinic."
SMS_INCLINIC_MSG = "CONFIRMED. {}'s appointment with {} for {} at {} Please call 8422801801 to manage your appointment or visit nearest Metropolis Healthcare Clinic Thanks! Team Metropolis"

patient_templates = [
    EKA_WA_APPOINTMENT_CONFIRMATION_PA,
    EKA_WA_PRESCRIPTION_PA,
    EKA_WA_TELECONSULTATION_CONFIRMATION_PA,
    SMS_TELECONSULTATION_CONFIRMATION_MSG,
    SMS_INCLINIC_MSG,
]
dr_templates = [EKA_WA_NEW_APPOINTMENT_DR_MESSAGE]
