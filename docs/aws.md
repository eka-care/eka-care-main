# Deploying `eka-webhook` to AWS (Lambda + API Gateway)

`deploy-aws.sh` provisions everything via CloudFormation (`eka-webhook-cf-template.yaml`).
For bare metal / a VM / local instead, see [bare-metal.md](./bare-metal.md).

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- `curl` and `unzip` installed on your system
- `Docker` installed and running
- `jq` installed
- AWS credentials with permissions to deploy via CloudFormation: API Gateway, Lambda, ECR, IAM, Route53

The script verifies all of this itself before touching anything, scoped to
what the action you're running actually needs:

- `deploy`/`upgrade` require AWS CLI, Docker (and a *running* daemon - it
  checks `docker info`, not just that the binary exists), and a working AWS
  session (`aws sts get-caller-identity`, verified before any ECR/Docker Hub
  login). If `AWS_ACCOUNT_ID` is pre-filled in `config-aws.env` but doesn't
  match the currently authenticated account/profile, it warns (doesn't
  fail) rather than silently deploying into the wrong account.
- `register-webhook` needs none of that - it's a plain `curl` call to
  `api.eka.care`, so it only requires `curl`/`jq` and never touches AWS.
- `delete` requires AWS CLI/auth (it deletes real resources) but not Docker.
- Outbound HTTPS (443) connectivity is checked up front for every endpoint
  the running action will actually hit - `public.ecr.aws` (the Lambda base
  image) and your account's ECR registry for `deploy`/`upgrade`, and
  `api.eka.care` for `deploy`/`register-webhook` - retrying with backoff and
  reporting every blocked endpoint together (with the exact reason: DNS
  failure, connection refused, timeout, ...) instead of dying mid-deploy.

## Resources the script creates

- ECR repository
- Lambda function (Docker image)
- API Gateway
- Custom domain name
- Route 53 record
- IAM role
- Security group (optional)

## Step-by-step setup

1. **Clone this repository**
2. **Configure AWS credentials**

   ```bash
   aws configure
   ```
   or export your AWS credentials if you're using IAM Identity Center.

3. **Configure environment variables**

   `config-aws.env` isn't tracked in git - `deploy-aws.sh` creates it from
   `config-aws.env.example` the first time you run it, then exits so you can
   fill in real values (see the [parameter reference](#configuration-parameters)
   below):
   ```bash
   ./deploy-aws.sh deploy --version <version-tag>   # creates config-aws.env, exits
   vim config-aws.env                               # fill in real values
   ```

4. **Make the deployment script executable**

   ```bash
   chmod +x deploy-aws.sh
   ```

## Deployment commands

```bash
./deploy-aws.sh deploy --version <version-tag>     # deploy
./deploy-aws.sh upgrade --version <version-tag>    # update the Lambda image only
./deploy-aws.sh delete                             # tear down the stack
./deploy-aws.sh register-webhook                   # (re-)register the webhook only
./deploy-aws.sh help
```

## Configuration parameters

`config-aws.env` fields, all consumed by `deploy-aws.sh` and passed to the CloudFormation template:

### Stack configuration
- **STACK_NAME**: CloudFormation stack name
- **TEMPLATE_FILE**: CloudFormation template file path
- **REGION**: AWS region to deploy into

### Docker image configuration
- **DOCKER_IMAGE_VERSION**: Version tag of the Docker image to deploy - see available tags at
  https://hub.docker.com/repository/docker/ekacare/ekapython-webhook-sdk/general

### CloudFormation parameters
- **STAGE_NAME**: Deployment environment (e.g., dev, prod)
- **EXTERNAL_URL**: Public URL where the webhook will be accessible
- **CERTIFICATE_ARN**: ARN of the ACM certificate for HTTPS

### VPC configuration
- **VPC_ID** (required): VPC to deploy into
- **SUBNET_IDS** (required): comma-separated subnet IDs within that VPC
- **SECURITY_GROUP_ID** (optional): existing security group; a new one is created if left blank

### Registration details
- **CLIENT_ID**, **CLIENT_SECRET** (required): Eka Care client credentials
- **API_KEY** (required for business use cases): used for authorized Eka Care API calls
- **SIGNING_KEY** (required when `IS_SIGNING_KEY_IMPLEMENTED = True` in `constants.py`): webhook signature verification key
