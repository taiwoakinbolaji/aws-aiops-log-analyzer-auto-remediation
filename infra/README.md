# Terraform Infrastructure

This directory contains the Terraform configuration for the core AWS infrastructure used by the project.

It provisions the shared AIOps components, but it does not by itself create per-function CloudWatch alarms for every Lambda you want to monitor.

## What Terraform Creates

A single `terraform apply` in this directory creates:

- Analyzer Lambda with placeholder code
- Remediator Lambda with placeholder code
- DynamoDB incidents table with TTL enabled
- SNS topic for notifications
- optional SNS email subscription if `notification_email` is set
- Secrets Manager secret for the Slack webhook
- IAM roles and policies for Analyzer and Remediator
- CloudWatch log groups for Analyzer and Remediator
- EventBridge rule that listens for matching CloudWatch alarm state changes
- CloudWatch dashboard
- CloudWatch alarms for Analyzer and Remediator error rates

## Important Scope Notes

- The Lambda functions created here start as placeholders. You must deploy the real code from `../lambda/analyzer` and `../lambda/remediator` after Terraform finishes.
- The EventBridge rule only listens for CloudWatch alarm names with the prefix `{project}-{environment}-oom-`.
- Tagging a Lambda function is not enough by itself to make it fully monitored end to end.
- To trigger the Analyzer for one of your own functions, you still need a compatible CloudWatch alarm that emits the expected alarm event.
- The included `../demo-app` Terraform creates a compatible alarm for testing.

## Prerequisites

- Terraform `>= 1.5.0`
- AWS CLI configured
- Amazon Bedrock model access if you want AI analysis
- Slack webhook URL for notifications

## Quick Start

### 1. Configure variables

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

At minimum, set:

```hcl
slack_webhook_url = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

### 2. Initialize and deploy

```bash
terraform init
terraform plan
terraform apply
```

### 3. Check outputs

```bash
terraform output
terraform output -raw analyzer_function_name
terraform output -raw remediator_function_name
terraform output -raw cloudwatch_dashboard_url
```

## Post-Deployment Steps

### 1. Deploy the real Lambda code

```bash
cd ../lambda/analyzer
./deploy.sh

cd ../remediator
./deploy.sh
```

### 2. Tag functions you want the Remediator to be allowed to update

```bash
cd ../../infra

TAG_KEY=$(terraform output -json monitored_lambda_tag | jq -r '.key')
TAG_VALUE=$(terraform output -json monitored_lambda_tag | jq -r '.value')

aws lambda tag-resource \
  --resource arn:aws:lambda:REGION:ACCOUNT:function:YOUR_FUNCTION \
  --tags "${TAG_KEY}=${TAG_VALUE}"
```

This tag is important because the Remediator IAM policy only allows updates to tagged Lambda functions.

### 3. Provide a compatible alarm source

For the included demo path:

```bash
cd ../demo-app
./deploy.sh apply
```

For your own functions, create a CloudWatch alarm whose name matches:

```text
{project}-{environment}-oom-{function-name}
```

### 4. Run a test

```bash
cd ../test
./trigger_errors.sh
./verify_remediation.sh
```

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `project_name` | `aiops-log-analyzer` | Naming prefix |
| `environment` | `dev` | Environment name |
| `confidence_threshold` | `0.85` | Minimum confidence for auto-remediation |
| `auto_remediate` | `true` | Enables automatic remediation |
| `bedrock_model_id` | `anthropic.claude-3-5-sonnet-20241022-v2:0` | Analyzer Bedrock model |
| `max_log_lines` | `50` | Max log lines sent to the model |
| `dry_run` | `false` | Simulate remediator changes only |
| `max_lambda_memory_size` | `10240` | Maximum memory the remediator can set |
| `min_lambda_memory_size` | `128` | Minimum memory the remediator will allow |
| `incident_retention_days` | `30` | DynamoDB TTL period |
| `notification_email` | `""` | Optional SNS email subscription |

## Outputs

Useful outputs include:

- `analyzer_function_name`
- `remediator_function_name`
- `incidents_table_name`
- `sns_topic_arn`
- `cloudwatch_dashboard_url`
- `monitored_lambda_tag`
- `deployment_summary`

## What This Terraform Does Not Currently Create

- per-target CloudWatch log metric filters for arbitrary Lambda functions
- per-target CloudWatch alarms for every tagged Lambda
- Budgets or cost-alert resources, even though some variables in `variables.tf` refer to cost settings
- deployment of the real Lambda application code

## Troubleshooting

### Bedrock access errors

- confirm the configured Bedrock model is enabled in your AWS account
- confirm you are deploying in a region where the selected model is available

### Placeholder Lambdas still running

Terraform only creates placeholder Lambda packages. Deploy the real code after `terraform apply`:

```bash
cd ../lambda/analyzer
./deploy.sh

cd ../remediator
./deploy.sh
```

### EventBridge rule exists but Analyzer never runs

- confirm the upstream CloudWatch alarm name matches `{project}-{environment}-oom-...`
- confirm the alarm enters the `ALARM` state
- confirm the event is in the same region as the deployed stack

### Remediator cannot update a function

- confirm the target Lambda has the configured monitoring tag
- confirm the function name in the incident matches the intended target

### Secret already exists

Secrets Manager uses a recovery window, so a recently deleted secret name may still be reserved. The quickest workaround is usually to deploy with a different `project_name` or wait for the recovery window to pass.

## Updating Infrastructure

To change Terraform-managed infrastructure:

```bash
cd infra
terraform plan
terraform apply
```

To update Analyzer or Remediator code only, use the deployment scripts in `../lambda/analyzer` and `../lambda/remediator` instead of Terraform.

## Destroy

```bash
cd infra
terraform plan -destroy
terraform destroy
```

Be aware that this removes the shared infrastructure, including the incidents table and notification resources. Secrets Manager deletion still follows its recovery window.

## Notes

- Local Terraform state can contain sensitive values. Do not commit `terraform.tfstate*` or `terraform.tfvars`.
- X-Ray tracing is enabled for the Analyzer and Remediator Lambdas created here.
- The easiest validation path is: deploy `infra/`, deploy the Lambda code, deploy `../demo-app`, then run the scripts in `../test`.
