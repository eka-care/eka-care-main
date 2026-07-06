# EkaPython Webhook Deployment Guide

This repository contains tools to deploy the EkaPython Webhook service to AWS using CloudFormation. This guide explains the configuration parameters needed for successful deployment.

## Configuration Parameters

The deployment script uses the following parameters, which should be customized according to your environment:

### Stack Configuration

- **STACK_NAME**: The name of your CloudFormation stack
- **TEMPLATE_FILE**: CloudFormation template file path
- **REGION**: AWS region where the stack will be deployed

### Docker Image Configuration

- **DOCKER_IMAGE_VERSION**: Version tag of the Docker image to deploy
  - Update this value when deploying a new version of the webhook service which can be found here: https://hub.docker.com/repository/docker/ekacare/ekapython-webhook-sdk/general

### CloudFormation Parameters

- **STAGE_NAME**: Deployment environment (e.g., dev, prod)
- **EXTERNAL_URL**: Public URL where the webhook will be accessible
- **CERTIFICATE_ARN**: ARN of the SSL certificate in AWS Certificate Manager for HTTPS

### VPC Configuration

- **VPC_ID**: The ID of the VPC where the service will be deployed (Required)
- **SUBNET_IDS**: A comma-separated list of subnet IDs within the specified VPC (Required)
- **SECURITY_GROUP_ID**: The ID of an existing security group to associate with the service. If left blank, a new security group will be created (Optional)

### API Registration Details

- **CLIENT_ID**: Your client ID for authentication (required in all cases)
- **CLIENT_SECRET**: Your client secret for authentication (required in all cases)
- **SIGNING_KEY**: 
  - **Required** when `IS_SIGNING_KEY_IMPLEMENTED` is set to `True` in `constants.py`
  - Used for verifying webhook signatures
- **API_KEY**: 
  - **Required** for business use cases
  - Used for making authorized API calls to the EkaCare services

## Deployment Instructions

1. Clone this repository
2. Copy the configuration template to a `.env` file
3. Update all placeholder values with your actual configuration
4. Run the deployment script:
   ```bash
   cd webhook-deployment
   ./deploy.sh
```