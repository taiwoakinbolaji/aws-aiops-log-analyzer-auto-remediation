# Analyzer Lambda

The Analyzer Lambda receives CloudWatch alarm events, fetches recent Lambda error logs, analyzes them with Amazon Bedrock, and decides whether the suggested remediation is safe enough to run automatically.

In this repository, the Analyzer is primarily used for Lambda OOM incidents triggered by CloudWatch alarms whose names match the configured alarm prefix.

## What It Does

1. Receives an EventBridge event derived from a CloudWatch alarm
2. Extracts the target Lambda function name from the alarm name
3. Fetches recent error logs from the function log group
4. Reads the function configuration
5. Retrieves recent incident history from DynamoDB
6. Builds a structured analysis prompt
7. Calls Amazon Bedrock using the configured model ID
8. Falls back to rule-based analysis if Bedrock fails or returns an unusable response
9. Stores the incident and analysis result in DynamoDB
10. Sends SNS and Slack notifications
11. Invokes the Remediator Lambda if the analysis passes the auto-remediation checks

## Current Scope

- Trigger source: CloudWatch alarm state changes routed by EventBridge
- Expected alarm naming pattern: `{project}-{environment}-oom-<function-name>`
- Primary remediation path in this repo: memory increases for OOM-style failures
- Bedrock request formatting supported in code: Claude and Nova model IDs

The Analyzer does not currently fetch CloudWatch metrics such as memory trends. Its decision context comes from:

- recent error logs
- Lambda configuration
- recent incident history from DynamoDB

## Files

```text
lambda/analyzer/
├── lambda_function.py
├── prompts.py
├── requirements.txt
├── deploy.sh
└── README.md
```

## Event Format

Expected input from EventBridge:

```json
{
  "alarm_name": "aiops-log-analyzer-dev-oom-my-function",
  "timestamp": "2025-01-09T10:00:00Z",
  "region": "us-east-1",
  "source": "cloudwatch-alarm"
}
```

The function name is derived from `alarm_name` using the configured `ALARM_PREFIX`.

## Analysis Flow

```text
EventBridge
  -> Analyzer Lambda
     -> fetch recent error logs from /aws/lambda/<function>
     -> read current Lambda configuration
     -> query recent incidents from DynamoDB
     -> build prompt from logs + metadata + history
     -> call Bedrock
     -> validate JSON response
     -> decide whether to auto-remediate
     -> notify and optionally invoke remediator
```

## Bedrock And Fallback Behavior

The Analyzer chooses the request and response format based on `BEDROCK_MODEL_ID`:

- Claude / Anthropic model IDs use the Anthropic Bedrock message format
- Nova model IDs use the Nova message format

If the Bedrock call fails, returns unsupported output, or produces invalid JSON, the Analyzer falls back to local rule-based logic:

- OOM-like log patterns produce a high-confidence memory-increase recommendation
- other errors produce a lower-confidence manual-review recommendation

## Auto-Remediation Decision Rules

The Analyzer only invokes the Remediator when all of these are true:

- `AUTO_REMEDIATE` is enabled
- analysis confidence is at least `CONFIDENCE_THRESHOLD`
- at least one remediation action exists
- no action has `safety_risk` equal to `HIGH`
- no action uses `MANUAL_REVIEW_REQUIRED`

## Configuration

Environment variables used by the Lambda:

| Variable | Source | Description |
|----------|--------|-------------|
| `INCIDENTS_TABLE_NAME` | Terraform | DynamoDB incidents table |
| `SNS_TOPIC_ARN` | Terraform | SNS topic for notifications |
| `SLACK_WEBHOOK_SECRET` | Terraform | Secrets Manager secret containing the Slack webhook |
| `CONFIDENCE_THRESHOLD` | Terraform | Minimum confidence required for auto-remediation |
| `AUTO_REMEDIATE` | Terraform | Enables or disables automatic remediation |
| `REMEDIATOR_FUNCTION` | Terraform | Remediator Lambda function name |
| `MAX_LOG_LINES` | Terraform | Maximum number of log lines passed to the model |
| `BEDROCK_MODEL_ID` | Terraform | Bedrock model ID used for analysis |
| `LOG_LEVEL` | Terraform | Logging level |
| `PROJECT_NAME` | Terraform | Used for naming defaults |
| `ENVIRONMENT` | Terraform | Used for naming defaults |
| `ALARM_PREFIX` | Terraform | Prefix used to parse alarm names |

Current Terraform defaults point to Claude 3.5 Sonnet, but the analyzer code also supports Nova-formatted requests if you set `BEDROCK_MODEL_ID` accordingly.

## Deployment

### Prerequisites

- Core infrastructure already deployed from `infra/`
- AWS CLI configured
- Python 3.11+
- `zip`

### Deploy With Script

```bash
cd lambda/analyzer
./deploy.sh

# Or specify a function name directly
./deploy.sh my-custom-analyzer-function
```

### Manual Packaging

```bash
pip install -r requirements.txt -t package/
cp lambda_function.py package/
cp prompts.py package/

cd package
zip -r ../function.zip .
cd ..

aws lambda update-function-code \
  --function-name aiops-log-analyzer-dev-analyzer \
  --zip-file fileb://function.zip
```

If you deployed the stack with a different project or environment name, replace the function name accordingly.

## Prompting

`prompts.py` defines:

- the system prompt
- prompt construction from logs, metadata, and history
- heuristic guides for OOM, timeout, and permission-related patterns
- JSON schema validation for model responses

The prompts are broader than the current demo flow. The repository’s end-to-end remediation path is still centered on OOM incidents because the alarm routing and remediator implementation are optimized for that case.

## Manual Test

```bash
cat > test-event.json <<'EOF'
{
  "alarm_name": "aiops-log-analyzer-dev-oom-demo-app",
  "timestamp": "2026-01-01T12:00:00Z",
  "region": "us-east-1",
  "source": "cloudwatch-alarm"
}
EOF

aws lambda invoke \
  --function-name aiops-log-analyzer-dev-analyzer \
  --payload file://test-event.json \
  response.json
```

Use an alarm name that maps to a real Lambda function and log group in your account, otherwise the Analyzer will have nothing useful to analyze.

## Logs

```bash
aws logs tail /aws/lambda/aiops-log-analyzer-dev-analyzer --follow
```

Useful messages to look for:

- `Analyzing errors for Lambda function`
- `Calling Amazon Bedrock`
- `Analysis complete`
- `Auto-remediation decision`

## IAM And Safety Boundaries

The Terraform policy for the Analyzer allows it to:

- read Lambda log groups
- invoke supported Bedrock models
- read and write incident data in DynamoDB
- publish notifications to SNS
- read the Slack webhook secret
- read Lambda configuration
- invoke the Remediator Lambda

The Analyzer does not update Lambda configuration directly.

## Troubleshooting

### `Invalid alarm name format`

- confirm the incoming alarm name matches the configured `ALARM_PREFIX`
- confirm the EventBridge rule is forwarding the expected alarm event

### `No logs to analyze`

- confirm the target log group exists
- confirm recent error entries exist in the last 15 minutes
- confirm the CloudWatch alarm actually maps to the intended function

### Bedrock access or model failures

- confirm the configured model is enabled in Amazon Bedrock
- confirm the Analyzer IAM policy allows the selected model family
- check CloudWatch logs for response parsing or validation errors

### No remediation triggered

- inspect the returned confidence against `CONFIDENCE_THRESHOLD`
- inspect `remediation_actions` and `safety_risk`
- confirm `AUTO_REMEDIATE=true`

### No Slack notification

- confirm the secret named in `SLACK_WEBHOOK_SECRET` exists
- confirm the secret payload contains `webhook_url`

## Notes

- Incident records are stored with a 30-day TTL in the current implementation.
- Slack delivery is best-effort; notification failures are logged and do not stop analysis.
- The included demo app and `test/` scripts are the easiest way to validate the analyzer end to end.
