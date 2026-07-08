# Deploying `eka-webhook` to AWS (Lambda + API Gateway)

`deploy-aws.sh` provisions everything via CloudFormation (`eka-webhook-cf-template.yaml`).
For bare metal / a VM / local instead, see [bare-metal.md](./bare-metal.md).

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- `curl` and `unzip` installed on your system
- `Docker` installed and running
- `jq` installed
- AWS credentials with permissions to deploy via CloudFormation: API Gateway, Lambda, ECR, IAM, Route53

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

   `config.env` isn't tracked in git - `deploy-aws.sh` creates it from
   `config.env.example` the first time you run it, then exits so you can
   fill in real values (see the [parameter reference](#configuration-parameters)
   below):
   ```bash
   ./deploy-aws.sh deploy --version <version-tag>   # creates config.env, exits
   vim config.env                               # fill in real values
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

`config.env` fields, all consumed by `deploy-aws.sh` and passed to the CloudFormation template:

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
