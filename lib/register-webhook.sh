#!/bin/bash
# Shared webhook-registration logic for the eka-webhook Eka Care API.
# Sourced by both deploy-aws.sh (AWS) and deploy-local.sh (bare metal/VM/local).
# Requires CLIENT_ID, CLIENT_SECRET, API_KEY, SIGNING_KEY, EXTERNAL_URL to be set by the caller.

register_webhook(){
    # Register the webhook with the specified URL
    echo "Getting Auth Token"

    # Check if required variables are set
    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$API_KEY" ]; then
        echo "Error: CLIENT_ID, CLIENT_SECRET, and API_KEY must be set in your config file"
        return 1
    fi

    if [ -z "$SIGNING_KEY" ]; then
        echo "Error: SIGNING_KEY must be set in your config file"
        return 1
    fi

    AUTH_TOKEN=$(curl --request POST \
        --url 'https://api.eka.care/connect-auth/v1/account/login' \
        --header 'Content-Type: application/json' \
        --data "{
        \"client_id\": \"${CLIENT_ID}\",
        \"client_secret\": \"${CLIENT_SECRET}\",
        \"api_key\": \"${API_KEY}\"
        }" | jq -r '.access_token')

    if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" == "null" ]; then
        echo "Error: Failed to obtain auth token. Check your CLIENT_ID, CLIENT_SECRET, and API_KEY."
        return 1
    fi

    echo "Registering webhook with URL: $EXTERNAL_URL"

    # Store HTTP status code and response body separately
    HTTP_STATUS=$(curl --silent --output response.txt --write-out "%{http_code}" \
        --request POST \
        --url https://api.eka.care/notification/v1/connect/webhook/subscriptions \
        --header "Authorization: Bearer ${AUTH_TOKEN}" \
        --header 'Content-Type: application/json' \
        --data "{
        \"event_names\": [
            \"appointment.created\",
            \"appointment.updated\",
            \"prescription.created\",
            \"prescription.updated\"
        ],
        \"endpoint\": \"${EXTERNAL_URL}\",
        \"signing_key\": \"${SIGNING_KEY}\",
        \"protocol\": \"https\"
        }")

    RESPONSE_BODY=$(cat response.txt)
    rm -f response.txt  # Clean up temporary file

    # Check the HTTP status code
    if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
        echo "Webhook registered successfully! (HTTP $HTTP_STATUS)"
        echo "Response: $RESPONSE_BODY"
        return 0
    else
        echo "Failed to register webhook. HTTP Status: $HTTP_STATUS"
        echo "Response: $RESPONSE_BODY"
        return 1
    fi
}
