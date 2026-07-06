#!/bin/bash

set -e

# Default config file location
CONFIG_FILE="config.env"

# Disable AWS CLI pager to prevent prompts
export AWS_PAGER=""

# Function to display usage
usage() {
    echo "Usage: $0 [deploy|upgrade|delete|register-webhook] [--version VERSION]"
    echo "Deploy, upgrade, delete CloudFormation stack, or register webhook for the Eka webhook"
    echo ""
    echo "  deploy                    Deploy the CloudFormation stack (default)"
    echo "  upgrade                   Update only the Lambda function with a new Docker image"
    echo "  delete                    Delete the CloudFormation stack"
    echo "  register-webhook          Register the webhook with Eka API (without deployment)"
    echo "  --version VERSION         Specify Docker image version"
    echo "  -h, --help                Display this help message"
    echo ""
}

# Add this function at the beginning of the script, after the usage function
detect_architecture() {
    # Get the host machine architecture
    local HOST_ARCH=$(uname -m)
    
    # Map host architecture to Lambda architecture
    if [[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "aarch64" ]]; then
        echo "arm64"
    else
        echo "x86_64"
    fi
}

# Check for command as first argument
ACTION="deploy"  # Default action
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "deploy" || "$1" == "upgrade" || "$1" == "delete" || "$1" == "register-webhook" ]]; then
        ACTION="$1"
        shift
    elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    else
        echo "Error: Unknown command '$1'"
        usage
        exit 1
    fi
fi

# Process additional command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: --version requires a value"
                usage
                exit 1
            fi
            CMD_DOCKER_IMAGE_VERSION="$2"
            echo "Using Docker image version from command line: $CMD_DOCKER_IMAGE_VERSION"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            exit 1
            ;;
    esac
done

# Load environment variables from config file
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
else
    echo "Error: Config file '$CONFIG_FILE' not found!"
    echo "Please create a config.env file with the required configuration parameters."
    echo "Example:"
    echo "STACK_NAME=eka-webhook-stack"
    echo "TEMPLATE_FILE=eka-webhook-cf-template.yaml"
    echo "REGION=ap-south-1"
    echo "STAGE_NAME=prod"
    echo "EXTERNAL_URL=https://eka-webhook.example.com"
    echo "CERTIFICATE_ARN=arn:aws:acm:ap-south-1:123456789012:certificate/abcd1234-5678-90ef-ghij-klmnopqrstuv"
    echo "VPC_ID=vpc-12345678"
    echo "SUBNET_IDS=subnet-12345678,subnet-87654321"
    echo "SECURITY_GROUP_ID=sg-12345678 # Optional - will be created if not specified"
    exit 1
fi

# Use command line version if provided, otherwise use config file version
if [[ -n "$CMD_DOCKER_IMAGE_VERSION" ]]; then
    DOCKER_IMAGE_VERSION="$CMD_DOCKER_IMAGE_VERSION"
fi

# Check if Docker image version is set for actions that require it
if [[ "$ACTION" == "deploy" || "$ACTION" == "upgrade" ]] && [[ -z "$DOCKER_IMAGE_VERSION" ]]; then
    echo "Error: DOCKER_IMAGE_VERSION must be specified  via --version parameter"
    exit 1
fi

# Auto-detect Lambda architecture if not specified
if [[ -z "$LAMBDA_ARCHITECTURE" ]]; then
    LAMBDA_ARCHITECTURE=$(detect_architecture)
    echo "Auto-detected Lambda architecture: $LAMBDA_ARCHITECTURE"
fi

# Set resource names based on stack name
LAMBDA_NAME="${STACK_NAME}"
API_GW_NAME="${STACK_NAME}"
# Use stack name as the ECR repository name
ECR_REPO_NAME="${STACK_NAME}"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if jq is installed (needed for JSON processing)
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it first with 'brew install jq'."
    exit 1
fi

# Get AWS account ID if not specified
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    echo "AWS_ACCOUNT_ID not specified in config, retrieving from AWS..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [[ $? -ne 0 || -z "$AWS_ACCOUNT_ID" ]]; then
        echo "Error: Failed to retrieve AWS account ID. Please ensure you're authenticated with AWS CLI."
        exit 1
    fi
    echo "Using AWS Account ID: $AWS_ACCOUNT_ID"
fi

# Set ECR repository URL 
ECR_REPO_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}:${DOCKER_IMAGE_VERSION}"

# Function to set up ECR and deploy Docker image
setup_ecr_and_deploy_image() {
    # Login to ECR
    echo "Logging in to Amazon ECR..."
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
    
    # Create ECR repository if it doesn't exist
    echo "Checking if ECR repository ${ECR_REPO_NAME} exists..."
    ECR_REPO_CREATED=false
    if ! aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" --no-cli-pager &>/dev/null; then
        echo "Creating ECR repository ${ECR_REPO_NAME}..."
        aws ecr create-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" --no-cli-pager || {
            echo "Error: Failed to create ECR repository. Exiting."
            exit 1
        }
        ECR_REPO_CREATED=true
    else
        echo "ECR repository ${ECR_REPO_NAME} already exists."
    fi
    
    # Build the Docker image from local code
    echo "Building Docker image with version tag $DOCKER_IMAGE_VERSION..."
    docker build -t ekapython-webhook-sdk:$DOCKER_IMAGE_VERSION . || {
        echo "Error: Failed to build Docker image. Exiting."
        # Clean up ECR repository if we created it in this run
        if $ECR_REPO_CREATED; then
            echo "Cleaning up newly created ECR repository ${ECR_REPO_NAME}..."
            aws ecr delete-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" --force --no-cli-pager || echo "Warning: Failed to delete ECR repository."
        fi
        exit 1
    }
    
    # Tag and push the image to ECR
    echo "Tagging and pushing to ECR: $ECR_REPO_URL"
    docker tag ekapython-webhook-sdk:$DOCKER_IMAGE_VERSION $ECR_REPO_URL || {
        echo "Error: Failed to tag Docker image. Exiting."
        # Clean up ECR repository if we created it in this run
        if $ECR_REPO_CREATED; then
            echo "Cleaning up newly created ECR repository ${ECR_REPO_NAME}..."
            aws ecr delete-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" --force --no-cli-pager || echo "Warning: Failed to delete ECR repository."
        fi
        exit 1
    }
    docker push $ECR_REPO_URL || {
        echo "Error: Failed to push Docker image to ECR. Exiting."
        # Clean up ECR repository if we created it in this run
        if $ECR_REPO_CREATED; then
            echo "Cleaning up newly created ECR repository ${ECR_REPO_NAME}..."
            aws ecr delete-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" --force --no-cli-pager || echo "Warning: Failed to delete ECR repository."
        fi
        exit 1
    }
    
    echo "Docker image successfully pushed to ECR."
}

# Extract domain name from EXTERNAL_URL
if [[ -n "$EXTERNAL_URL" ]]; then
    DOMAIN_NAME=$(echo "$EXTERNAL_URL" | sed -E 's|^https?://||' | sed -E 's|/.*$||')
    echo "Extracted domain name: $DOMAIN_NAME"
    
    # Try to find the hosted zone ID for the domain
    if [[ -z "$HOSTED_ZONE_ID" ]]; then
        echo "Looking up hosted zone ID for domain $DOMAIN_NAME..."
        
        # Get all hosted zones
        ZONES_JSON=$(aws route53 list-hosted-zones --output json)
        
        # Find the most specific matching zone for the domain
        LONGEST_MATCH=""
        MATCHED_ZONE_ID=""
        
        # Process each zone
        ZONES=$(echo "$ZONES_JSON" | jq -r '.HostedZones[] | .Name + ":" + .Id')
        
        for ZONE in $ZONES; do
            ZONE_NAME=$(echo "$ZONE" | cut -d':' -f1)
            ZONE_ID=$(echo "$ZONE" | cut -d':' -f2 | sed 's|/hostedzone/||')
            
            # Remove trailing dot from zone name
            ZONE_NAME=${ZONE_NAME%.}
            
            # Check if domain ends with zone name
            if [[ "$DOMAIN_NAME" == *"$ZONE_NAME"* || "$DOMAIN_NAME" == "$ZONE_NAME" ]]; then
                if [[ ${#ZONE_NAME} -gt ${#LONGEST_MATCH} ]]; then
                    LONGEST_MATCH="$ZONE_NAME"
                    MATCHED_ZONE_ID="$ZONE_ID"
                fi
            fi
        done
        
        if [[ -n "$MATCHED_ZONE_ID" ]]; then
            HOSTED_ZONE_ID="$MATCHED_ZONE_ID"
            echo "Found hosted zone ID: $HOSTED_ZONE_ID for domain $DOMAIN_NAME"
        else
            echo "Warning: Could not find a hosted zone for domain $DOMAIN_NAME"
            echo "Please specify HOSTED_ZONE_ID manually in the config file."
        fi
    fi
fi

# Generate parameters file from environment variables
generate_parameters() {
    # Set a default parameters file path in the current directory
    PARAMS_FILE="parameters.json"
    
    # Verify all required parameters are set
    local REQUIRED_PARAMS=(STAGE_NAME EXTERNAL_URL CERTIFICATE_ARN CLIENT_ID CLIENT_SECRET API_KEY SIGNING_KEY VPC_ID SUBNET_IDS)
    local MISSING_PARAMS=0
    
    for PARAM in "${REQUIRED_PARAMS[@]}"; do
        if [ -z "${!PARAM}" ]; then
            echo "Error: Required parameter $PARAM is not set in config file!"
            MISSING_PARAMS=1
        fi
    done
    
    # Check if HOSTED_ZONE_ID was found
    if [ -z "$HOSTED_ZONE_ID" ]; then
        echo "Error: Could not determine HOSTED_ZONE_ID. Please specify it in the config file."
        MISSING_PARAMS=1
    fi
    
    # Check if ECR_REPO_URL is properly set
    if [ -z "$ECR_REPO_URL" ]; then
        echo "Error: ECR_REPO_URL is not properly set. Check REGION and DOCKER_IMAGE_VERSION."
        MISSING_PARAMS=1
    fi
    
    # Exit if any parameters are missing
    if [ $MISSING_PARAMS -eq 1 ]; then
        echo "Error: Missing required parameters. Please check your config file."
        exit 1
    fi
    
    echo "Generating CloudFormation parameters file at $PARAMS_FILE..."
    cat > "$PARAMS_FILE" << EOF
[
  {
    "ParameterKey": "StageName",
    "ParameterValue": "${STAGE_NAME}"
  },
  {
    "ParameterKey": "ExternalUrl",
    "ParameterValue": "${EXTERNAL_URL}"
  },
  {
    "ParameterKey": "HostedZoneID",
    "ParameterValue": "${HOSTED_ZONE_ID}"
  },
  {
    "ParameterKey": "DockerImage",
    "ParameterValue": "${ECR_REPO_URL}"
  },
  {
    "ParameterKey": "CertificateARN",
    "ParameterValue": "${CERTIFICATE_ARN}"
  },
  {
    "ParameterKey": "SigningKey",
    "ParameterValue": "${SIGNING_KEY}"
  },
  {
    "ParameterKey": "ClientID",
    "ParameterValue": "${CLIENT_ID}"
  },
  {
    "ParameterKey": "ClientSecret",
    "ParameterValue": "${CLIENT_SECRET}"
  },
  {
    "ParameterKey": "APIKey",
    "ParameterValue": "${API_KEY}"
  },
  {
    "ParameterKey": "LambdaName",
    "ParameterValue": "${LAMBDA_NAME}"
  },
  {
    "ParameterKey": "LambdaArchitecture",
    "ParameterValue": "${LAMBDA_ARCHITECTURE:-x86_64}"
  },
  {
    "ParameterKey": "VpcId",
    "ParameterValue": "${VPC_ID}"
  },
  {
    "ParameterKey": "SubnetIds",
    "ParameterValue": "${SUBNET_IDS}"
  },
  {
    "ParameterKey": "SecurityGroupId",
    "ParameterValue": "${SECURITY_GROUP_ID:-}"
  }
]
EOF
    echo "Parameters file generated successfully at $PARAMS_FILE"
}

# Check if template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file '$TEMPLATE_FILE' not found!"
    exit 1
fi

# Function to deploy stack - will now run after ECR operations
deploy_stack() {
    # Generate parameters from environment variables
    generate_parameters
    
    echo "Validating template..."
    aws cloudformation validate-template \
        --template-body file://$TEMPLATE_FILE \
        --region $REGION --no-cli-pager || {
        echo "Error: Template validation failed. Exiting."
        exit 1
    }

    echo "Deploying stack '$STACK_NAME' using template '$TEMPLATE_FILE' in region '$REGION'..."
    
    DEPLOY_CMD="aws cloudformation deploy \
        --template-file $TEMPLATE_FILE \
        --stack-name $STACK_NAME \
        --region $REGION \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --parameter-overrides file://$PARAMS_FILE \
        --no-cli-pager"
    
    echo "Running: $DEPLOY_CMD"
    eval $DEPLOY_CMD
    
    # Check if the deployment was successful
    if [ $? -ne 0 ]; then
        echo "Error: CloudFormation deployment failed. Exiting."
        exit 1
    fi
    
    echo "Stack deployment completed successfully."
    
    # After successful deployment, get the outputs
    get_stack_outputs
}

# Function to get and display stack outputs
get_stack_outputs() {
    echo "Retrieving stack outputs..."
    
    # Get all stack outputs as JSON
    OUTPUTS_JSON=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query "Stacks[0].Outputs" \
        --output json \
        --no-cli-pager)
    
    if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "null" ]]; then
        echo "No outputs found for stack $STACK_NAME"
        return
    fi
    
    # Display all outputs in a table format
    echo "Stack outputs:"
    aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query "Stacks[0].Outputs" \
        --output table \
        --no-cli-pager
}

# Function to delete stack
delete_stack() {
    # Display stack outputs before deletion
    get_stack_outputs
    
    # Delete ECR repository if it exists
    echo "Checking if ECR repository ${ECR_REPO_NAME} exists..."
    if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" --no-cli-pager &>/dev/null; then
        echo "Deleting ECR repository ${ECR_REPO_NAME}..."
        aws ecr delete-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" --force --no-cli-pager || {
            echo "Warning: Failed to delete ECR repository. Continuing with stack deletion..."
        }
    else
        echo "ECR repository ${ECR_REPO_NAME} does not exist or has already been deleted."
    fi
    
    echo "Deleting stack '$STACK_NAME' in region '$REGION'..."
    aws cloudformation delete-stack \
        --stack-name $STACK_NAME \
        --region $REGION \
        --no-cli-pager
    
    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name $STACK_NAME \
        --region $REGION
    
    echo "Stack deletion complete."
}

# Function to upgrade Lambda function
upgrade_lambda() {
    echo "Starting Lambda upgrade process..."
    
    # Validate Docker image version is provided
    if [ -z "$DOCKER_IMAGE_VERSION" ]; then
        echo "Error: DOCKER_IMAGE_VERSION must be specified via --version parameter or in config.env"
        exit 1
    fi
    
    echo "Using Docker image version: $DOCKER_IMAGE_VERSION"
    
    # Set up ECR and deploy the new image
    setup_ecr_and_deploy_image
    
    # Generate parameters file from config.env, just like in deploy_stack
    generate_parameters
    
    # Update the CloudFormation stack with the new parameters
    echo "Updating stack '$STACK_NAME' with new Docker image..."
    aws cloudformation update-stack \
        --stack-name $STACK_NAME \
        --template-body file://$TEMPLATE_FILE \
        --region $REGION \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --parameters file://$PARAMS_FILE \
        --no-cli-pager
    
    # Wait for the update to complete
    echo "Waiting for stack update to complete..."
    aws cloudformation wait stack-update-complete \
        --stack-name $STACK_NAME \
        --region $REGION
    
    # Check if the update was successful
    if [ $? -ne 0 ]; then
        echo "Error: CloudFormation stack update failed."
        exit 1
    fi
    
    echo "Lambda function upgraded successfully with Docker image version $DOCKER_IMAGE_VERSION."
    get_stack_outputs
}

register_webhook(){
    # Register the webhook with the specified URL
    echo "Getting Auth Token"

    # Check if required variables are set
    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$API_KEY" ]; then
        echo "Error: CLIENT_ID, CLIENT_SECRET, and API_KEY must be set in config.env"
        return 1
    fi

    if [ -z "$SIGNING_KEY" ]; then
        echo "Error: SIGNING_KEY must be set in config.env"
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

# Execute the specified action based on the ACTION variable
case $ACTION in
    deploy)
        # First set up ECR and deploy the image, then run CloudFormation
        setup_ecr_and_deploy_image
        deploy_stack
        echo "Deployment completed successfully!"
        register_webhook
        ;;
    upgrade)
        # Only update the Lambda function with a new Docker image
        upgrade_lambda
        ;;
    delete)
        delete_stack
        ;;
    register-webhook)
        # Only register the webhook with Eka API
        echo "Registering webhook only..."
        if [ -z "$EXTERNAL_URL" ]; then
            echo "Error: EXTERNAL_URL must be set in config.env"
            exit 1
        fi
        register_webhook
        if [ $? -eq 0 ]; then
            echo "Webhook registration successful!"
        else
            echo "Webhook registration failed!"
            exit 1
        fi
        ;;
    *)
        echo "Error: Invalid action '$ACTION'. Use 'deploy', 'upgrade', 'delete', or 'register-webhook'."
        usage
        exit 1
        ;;
esac

