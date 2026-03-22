# Intelligent Log Analyzer for AWS Lambda

An AIOps project for detecting Lambda failures from CloudWatch alarms, analyzing recent error logs with Amazon Bedrock, and auto-remediating supported out-of-memory incidents by increasing Lambda memory.

For the fastest end-to-end setup, see [docs/QUICKSTART.md](https://github.com/taiwoakinbolaji/aws-aiops-log-analyzer-auto-remediation/blob/main/docs/QUICKSTART.md).

## Overview

This repository implements an event-driven incident workflow for AWS Lambda:

1. CloudWatch alarms fire for monitored Lambda failures
2. EventBridge routes matching alarm events to the Analyzer Lambda
3. The Analyzer fetches recent CloudWatch log entries and Lambda configuration
4. Amazon Bedrock analyzes the incident, with a rule-based fallback if Bedrock is unavailable
5. The system decides whether the suggested remediation is safe enough to run automatically
6. The Remediator Lambda applies supported fixes, currently focused on Lambda memory updates
7. Incident analysis and remediation results are stored in DynamoDB
8. Notifications are sent through SNS and an optional Slack webhook

The current implementation is primarily designed for Lambda OOM remediation. The demo app and test scripts exercise that path end to end.

## What The Project Does Today

- AI-assisted analysis of recent Lambda error logs using Amazon Bedrock
- Rule-based fallback analysis when Bedrock is unavailable
- Confidence-based remediation decisions
- Automatic Lambda memory increases for supported OOM incidents
- Incident storage in DynamoDB with TTL-based retention
- SNS notifications, with Slack webhook support via Secrets Manager
- Demo application and shell scripts for end-to-end testing

## Important Scope Notes

- The system does not monitor every tagged Lambda by itself. In the current repo, EventBridge listens for CloudWatch alarms whose names start with `{project}-{environment}-oom-`.
- The included `demo-app/` Terraform creates a compatible CloudWatch alarm for testing.
- Terraform deploys placeholder Analyzer and Remediator Lambdas first. You then deploy the real Lambda code from `lambda/analyzer/` and `lambda/remediator/`.
- The Analyzer code supports Claude and Nova request formats. The default Terraform configuration uses Claude 3.5 Sonnet, with IAM permissions allowing either Claude 3.5 Sonnet or Amazon Nova models.

## Architecture

```text
Monitored Lambda + CloudWatch Alarm
              |
              v
         EventBridge Rule
              |
              v
        Analyzer Lambda
          - fetch recent error logs
          - read Lambda configuration
          - query recent incident history
          - call Bedrock or fallback analyzer
          - decide whether to auto-remediate
              |
     +--------+--------+
     |                 |
     v                 v
Remediator Lambda   DynamoDB
  - increase memory   - incident history
  - verify update     - analysis output
  - record result     - remediation status
     |
     v
SNS + optional Slack webhook
```

## How It Works

### Detection

CloudWatch alarms detect repeated failures on a target Lambda. EventBridge matches alarm names with the configured prefix and forwards the alarm event to the Analyzer Lambda.

### Analysis

The Analyzer Lambda:

- extracts the target function name from the alarm
- fetches recent CloudWatch log entries
- reads the Lambda configuration
- queries recent incidents from DynamoDB for additional context
- calls Amazon Bedrock for structured analysis
- falls back to pattern-based analysis if Bedrock fails

The Analyzer does not currently fetch CloudWatch metrics such as memory trends. Its analysis context is based on recent logs, Lambda configuration, and incident history.

### Decision

Auto-remediation runs only when:

- `AUTO_REMEDIATE` is enabled
- the model confidence meets the configured threshold
- remediation actions are present
- no action is marked `HIGH` risk
- no action requires manual review

### Remediation

The Remediator currently handles `LAMBDA_UPDATE` actions for Lambda memory changes. It:

- reads the current function configuration
- calculates or parses the target memory size
- updates the Lambda configuration
- waits for the update to complete
- verifies the applied memory size
- records remediation status in DynamoDB
- sends SNS and Slack notifications

The current implementation does not perform an automatic rollback.

## Example Analysis Flow

```python
try:
    analysis = analyze_with_bedrock(
        model_id=BEDROCK_MODEL_ID,
        error_logs=recent_error_logs,
        lambda_metadata=current_settings,
        historical_context=past_incidents,
    )
except Exception:
    analysis = create_fallback_analysis(
        error_logs=recent_error_logs,
        function_name=function_name,
        lambda_metadata=current_settings,
    )

if should_auto_remediate(analysis):
    invoke_remediator(incident_id, function_name, analysis)
```

## Repository Layout

```text
infra/               Terraform for core AIOps infrastructure
lambda/analyzer/     Analyzer Lambda source and deployment script
lambda/remediator/   Remediator Lambda source and deployment script
demo-app/            Demo Lambda plus compatible OOM alarm
test/                Shell scripts for validation and end-to-end testing
docs/                Additional setup and usage notes
```

## Prerequisites

### AWS

- AWS account with permission to create Lambda, CloudWatch, EventBridge, DynamoDB, SNS, IAM, and Secrets Manager resources
- AWS CLI configured locally
- Amazon Bedrock model access enabled if you want AI analysis

### Bedrock Models

- Recommended: `anthropic.claude-3-5-sonnet-20241022-v2:0`
- Supported by the Analyzer request formatting: Claude and Nova model IDs
- If Bedrock is unavailable, the system falls back to rule-based analysis for OOM detection

### Local Tools

- Terraform `>= 1.5.0`
- AWS CLI `>= 2.x`
- Python `>= 3.11`
- `jq`
- `zip`

## Quick Start

### 1. Deploy Core Infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars and set at least:
# slack_webhook_url = "https://hooks.slack.com/services/..."

terraform init
terraform apply
```

### 2. Deploy The Real Lambda Code

```bash
cd ../lambda/analyzer
./deploy.sh

cd ../remediator
./deploy.sh
```

### 3. Deploy The Demo App

```bash
cd ../../demo-app
./deploy.sh apply
```

### 4. Run A Test

```bash
cd ../test
./trigger_errors.sh
./verify_remediation.sh
```

## Configuration Highlights

- `confidence_threshold`: minimum confidence required for auto-remediation
- `auto_remediate`: enables or disables automatic fixes
- `bedrock_model_id`: Bedrock model used by the Analyzer
- `max_log_lines`: max number of log entries sent to the model
- `dry_run`: simulate remediation without updating Lambda configuration

## Notes On Notifications

- SNS is always used for incident and remediation notifications
- Slack notifications are sent directly from the Lambda functions when a webhook secret is configured
- Email notifications can be added by subscribing an email endpoint to the SNS topic

## Testing

The easiest way to validate the project is the included demo path:

1. deploy `infra/`
2. deploy `lambda/analyzer/` and `lambda/remediator/`
3. deploy `demo-app/`
4. use the scripts in `test/`

## Documentation

- `infra/README.md`
- `lambda/analyzer/README.md`
- `lambda/remediator/README.md`
- `demo-app/README.md`
- `test/README.md`
