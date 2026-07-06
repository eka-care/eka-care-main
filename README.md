# EkaCare Webhook SDK

## Overview
The EkaCare Webhook SDK processes appointment events through webhooks, validates webhook signatures, and handles appointment data securely.

## Environment Variables

The following environment variables need to be set for the application to function properly:

### Mandatory Variables
- `CLIENT_ID`: Your client ID for authentication (required in all cases)
- `CLIENT_SECRET`: Your client secret for authentication (required in all cases)

### Conditional Variables
- `SIGNING_KEY`: 
  - **Required** when `IS_SIGNING_KEY_IMPLEMENTED` is set to `True` in `constants.py`
  - Used for verifying webhook signatures

- `API_KEY`: 
  - **Required** for business use cases
  - Used for making authorized API calls to the EkaCare services

### Configuration
If you need to disable signature verification, you can set `IS_SIGNING_KEY_IMPLEMENTED = False` in the `constants.py` file.

Make sure to properly set these environment variables before deploying or running the application.

## Configuration

### Signature Verification
The SDK supports signature verification to ensure webhook security:

1. In `constants.py`, set `IS_SIGNING_KEY_IMPLEMENTED`:
   - `True`: Enable signature verification (recommended for production)
   - `False`: Disable signature verification (use only for testing)

```python
import os

# Set to True if you want to implement signature verification
IS_SIGNING_KEY_IMPLEMENTED = True

# Provide signing key here
SIGNING_KEY = os.getenv("SIGNING_KEY")

# Client ID (Mandatory)
CLIENT_ID = os.getenv("CLIENT_ID")

# Client Secret (Mandatory)
CLIENT_SECRET = os.getenv("CLIENT_SECRET")

# Api Key (Optional, Required when you need to represent use case for business id)
API_KEY = os.getenv("API_KEY")
```


# How to Deploy `eka-webhook` Python Lambda in an AWS Environment

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- `curl` and `unzip` installed on your system
- `Docker` installed and running
- `AWS Credentials` and necessary Permissions to deploy the required Resources. (API GW, Cloudformation, Lambda, ECR) via CloudFormation

## The Script will create the following Resources in AWS
- ECR
- Lambda Function using Docker Image
- API Gateway
- Custom Domain Name
- Route 53 Entry
- IAM Role
- Security Group (Optional)

## Step-by-Step Setup

1. **Fork this Project and git clone it**
2. **Configure AWS Credentials**

   ```bash
   aws configure
   ```
   or export your AWS credentials if you are using IAM Identity Center

3. **Configure Environment Variables**

   Edit the `config.env` file with the necessary configuration values. For more detailed configuration setup, refer to [detailed.md](./detailed.md).
   ```bash
   vim config.env
   ```

4. **Make the Deployment Script Executable**

   ```bash
   chmod +x deploy.sh
   ```

## Deployment Commands

- **To Deploy:**

  ```bash
  ./deploy.sh deploy --version <version-tag>
  ```

- **To Delete:**

  ```bash
  ./deploy.sh delete
  ```

- **To Upgrade:**

  ```bash
  ./deploy.sh upgrade --version <version-tag>
  ```

- **help:**

  ```bash
  ./deploy.sh help
  ```  
