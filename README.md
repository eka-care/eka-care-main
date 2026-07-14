# EkaCare Webhook SDK

## Overview
The EkaCare Webhook SDK processes appointment events through webhooks, validates webhook signatures, and handles appointment data securely.

## Choose your deployment target

- **AWS** (Lambda + API Gateway via CloudFormation): see [docs/aws.md](./docs/aws.md), run `./deploy-aws.sh deploy --version <tag>`.
- **Bare metal / VM / local** (any Linux host, no AWS dependency): see [docs/bare-metal.md](./docs/bare-metal.md), run `./deploy-local.sh install`.

Both paths run the same application and share the environment variables below.

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

Make sure to properly set these environment variables before deploying or running the application.

## Signature Verification

The SDK supports signature verification to ensure webhook security, controlled in `constants.py`:

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

- `True`: Enable signature verification (recommended for production)
- `False`: Disable signature verification (use only for testing)
