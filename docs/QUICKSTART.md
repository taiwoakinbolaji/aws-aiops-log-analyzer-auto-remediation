# Quick Start

This is the fastest accurate path to validate the project end to end with the included demo app.

## Prerequisites

- Terraform `>= 1.5.0`
- AWS CLI configured
- Python `>= 3.11`
- `jq`
- Bedrock model access if you want AI analysis instead of fallback analysis

## 1. Deploy Core Infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at least:

```hcl
slack_webhook_url = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

Then deploy:

```bash
terraform init
terraform apply
```

## 2. Deploy The Real Lambda Code

Terraform creates placeholder Lambdas first, so deploy the actual application code next:

```bash
cd ../lambda/analyzer
./deploy.sh

cd ../remediator
./deploy.sh
```

## 3. Deploy The Demo App

The demo app creates:

- a test Lambda function
- a matching CloudWatch log metric filter
- a matching CloudWatch alarm named `{project}-{environment}-oom-<function>`

Deploy it with:

```bash
cd ../../demo-app
./deploy.sh apply
```

## 4. Trigger The Workflow

```bash
cd ../test
chmod +x *.sh

./trigger_errors.sh
```

If you use the default deployment names, the script targets the demo app automatically.

## 5. Verify Remediation

```bash
./verify_remediation.sh
```

This checks:

- whether the demo app memory increased
- whether the alarm triggered
- whether an incident record exists in DynamoDB
- whether recent errors stopped

## 6. Optional: Run The Full End-To-End Test

```bash
./e2e_test.sh
```

## Useful Checks

### Show outputs

```bash
cd ../infra
terraform output
```

### Show dashboard URL

```bash
terraform output -raw cloudwatch_dashboard_url
```

### Tail analyzer logs

```bash
aws logs tail /aws/lambda/aiops-log-analyzer-dev-analyzer --follow
```

### Tail remediator logs

```bash
aws logs tail /aws/lambda/aiops-log-analyzer-dev-remediator --follow
```

## Important Notes

- The easiest supported path is the included demo path above.
- Tagging a Lambda function alone is not enough for end-to-end automation. A compatible CloudWatch alarm is also required.
- If Bedrock is unavailable, the Analyzer can still use fallback logic for OOM detection.
- If you deployed with different project or environment names, adjust the function names and commands accordingly.

## Troubleshooting

### Bedrock access denied

- enable the configured model in Amazon Bedrock
- confirm the model is available in the deployment region

### Analyzer does not run

- confirm the CloudWatch alarm enters `ALARM`
- confirm the alarm name matches the expected prefix
- confirm the real Analyzer code was deployed after Terraform

### Remediation does not happen

- confirm `AUTO_REMEDIATE=true`
- confirm the analysis confidence meets the threshold
- confirm the target function is tagged with the configured monitoring tag
