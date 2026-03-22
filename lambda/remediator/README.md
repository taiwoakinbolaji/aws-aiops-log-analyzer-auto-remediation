# Remediator Lambda

The Remediator Lambda executes approved remediation actions from the Analyzer. In the current project, it is focused on Lambda memory updates for OOM-style incidents.

## What It Does

1. Receives an event from the Analyzer Lambda
2. Reads the target Lambda configuration
3. Filters for supported `LAMBDA_UPDATE` actions
4. Calculates or parses the target memory size
5. Validates the target against configured limits
6. Updates the Lambda configuration unless `DRY_RUN=true`
7. Waits for the update to finish and verifies the applied memory
8. Updates the incident record in DynamoDB
9. Sends SNS and Slack completion notifications

## Current Scope

- Supported remediation type: `LAMBDA_UPDATE`
- Current implementation action: update Lambda memory size
- Primary use case in this repo: remediate Lambda OOM incidents

The function does not currently perform automatic rollback.

## Files

```text
lambda/remediator/
├── lambda_function.py
├── requirements.txt
├── deploy.sh
└── README.md
```

## Memory Update Logic

The remediator determines the target memory in this order:

1. parse an explicit target from the action description, such as `Increase memory to 768MB`
2. if no explicit target exists, apply smart sizing based on current memory:
   - `<= 512MB`: increase by 50%
   - `<= 1024MB`: increase by `MEMORY_INCREMENT_MB`
   - `> 1024MB`: increase by `512MB`
3. round to the nearest `64MB`
4. ensure at least a `128MB` increase
5. reject values below `MIN_MEMORY_MB` or above `MAX_MEMORY_MB`

## Configuration

Environment variables used by the Lambda:

| Variable | Source | Description |
|----------|--------|-------------|
| `INCIDENTS_TABLE_NAME` | Terraform | DynamoDB incidents table |
| `SNS_TOPIC_ARN` | Terraform | SNS topic for notifications |
| `SLACK_WEBHOOK_SECRET` | Terraform | Secrets Manager secret containing the Slack webhook |
| `DRY_RUN` | Terraform | If `true`, calculate and report changes without applying them |
| `MAX_MEMORY_MB` | Terraform | Maximum allowed target memory |
| `MIN_MEMORY_MB` | Terraform | Minimum allowed target memory |
| `LOG_LEVEL` | Terraform | Logging level |
| `MEMORY_INCREMENT_MB` | code default | Default medium-size increment, falls back to `256` if unset |

With the current Terraform defaults, `MAX_MEMORY_MB` comes from `max_lambda_memory_size`, whose default is `10240`.

## Deployment

### Prerequisites

- Core infrastructure already deployed from `infra/`
- AWS CLI configured
- Python 3.11+
- `zip`

### Deploy With Script

```bash
cd lambda/remediator
./deploy.sh

# Or specify a function name directly
./deploy.sh my-custom-remediator-function
```

### Manual Packaging

```bash
pip install -r requirements.txt -t package/
cp lambda_function.py package/

cd package
zip -r ../function.zip .
cd ..

aws lambda update-function-code \
  --function-name aiops-log-analyzer-dev-remediator \
  --zip-file fileb://function.zip
```

If you deployed the stack with a different project or environment name, replace the function name accordingly.

## Event Format

Expected event from the Analyzer:

```json
{
  "incident_id": "inc-1234567890-my-function",
  "function_name": "my-lambda-function",
  "analysis": {
    "remediation_actions": [
      {
        "action_type": "LAMBDA_UPDATE",
        "description": "Increase memory to 768MB",
        "priority": 1,
        "safety_risk": "Low"
      }
    ]
  },
  "source": "analyzer"
}
```

## Manual Test

```bash
cat > test-event.json <<'EOF'
{
  "incident_id": "inc-test-123",
  "function_name": "aiops-log-analyzer-dev-demo-app",
  "analysis": {
    "remediation_actions": [
      {
        "action_type": "LAMBDA_UPDATE",
        "description": "Increase memory to 768MB",
        "priority": 1,
        "safety_risk": "Low"
      }
    ]
  },
  "source": "test"
}
EOF

aws lambda invoke \
  --function-name aiops-log-analyzer-dev-remediator \
  --payload file://test-event.json \
  response.json
```

Use a function name that actually exists in your account and is tagged for monitoring, otherwise the update will be rejected by IAM or by the Lambda API call.

## Dry Run

Set `DRY_RUN=true` in the function environment to test the decision and notification path without changing Lambda configuration.

When dry run is enabled, the function:

- calculates the target memory
- reports a successful dry-run result
- skips `update_function_configuration`
- still sends completion notifications

## IAM And Safety Boundaries

The Terraform policy for the remediator allows it to:

- read Lambda configuration
- update Lambda configuration on tagged functions
- query and update the incidents table
- publish to SNS
- read the Slack webhook secret

The important boundary is that Lambda updates are restricted to functions with the configured monitoring tag.

## Troubleshooting

### `Lambda function not found`

- check `function_name` in the event
- confirm the function exists in the target region

### `Function update already in progress`

- wait for the target function to return to `Active`
- retry after the earlier update completes

### `Exceeds maximum allowed memory`

- review `MAX_MEMORY_MB`
- review the target value parsed from the remediation description

### No incident record updated

- confirm the Analyzer stored the incident first
- confirm the remediator role can query and update DynamoDB

### No Slack notification

- confirm the secret named in `SLACK_WEBHOOK_SECRET` exists
- confirm the secret payload contains `webhook_url`

## Notes

- The remediator updates DynamoDB using the incident record created by the Analyzer.
- Slack delivery is best-effort; failures are logged and do not block the Lambda response.
- The included test and demo flow in this repo is the easiest way to validate the remediator end to end.
