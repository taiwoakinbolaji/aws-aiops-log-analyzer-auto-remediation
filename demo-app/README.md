# Demo App

This directory contains a Lambda function that intentionally produces OOM-style failures so you can test the Analyzer and Remediator end to end.

## What It Is For

The demo app is the easiest way to validate the project because it creates both:

- a Lambda function that can be forced into failure
- a compatible CloudWatch alarm that the core infrastructure can react to

## What It Deploys

The Terraform in this directory creates:

- demo Lambda function
- IAM role with basic Lambda execution permissions
- CloudWatch log group
- CloudWatch log metric filter for error patterns
- CloudWatch alarm named `{project}-{environment}-oom-<function-name>`

The function is also tagged with `aiops-monitor=true`, which matters because the Remediator IAM policy only allows updates to tagged functions.

## Important Dependency

The demo app by itself is only a test target.

To exercise the full workflow, you must already have:

- the core infrastructure from `../infra`
- the real Analyzer code deployed
- the real Remediator code deployed

Without those, the demo app still runs, but nothing will analyze or remediate its failures.

## Error Patterns

The demo Lambda supports these event patterns:

- `gradual`
- `sudden`
- `leak`
- `spike`

Event shape:

```json
{
  "pattern": "gradual|sudden|leak|spike",
  "target_mb": 600,
  "duration_seconds": 10
}
```

## Deploy

```bash
cd demo-app
./deploy.sh apply
```

To destroy it later:

```bash
./deploy.sh destroy
```

## Useful Outputs

After deployment:

```bash
terraform output
terraform output -raw demo_app_function_name
terraform output -raw demo_app_alarm_name
```

## Manual Invocation

Get the function name:

```bash
FUNCTION_NAME=$(terraform output -raw demo_app_function_name)
```

Trigger a gradual memory-growth run:

```bash
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{"pattern":"gradual","target_mb":600}' \
  response.json
```

Other examples:

```bash
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{"pattern":"sudden","target_mb":600}' \
  response.json

aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{"pattern":"leak","target_mb":600,"duration_seconds":15}' \
  response.json
```

## Recommended End-To-End Flow

### 1. Deploy the demo app

```bash
cd demo-app
./deploy.sh apply
```

### 2. Trigger enough failures to trip the alarm

```bash
cd ../test
./trigger_errors.sh
```

If you use the default names, the test script targets the demo app automatically.

### 3. Verify remediation

```bash
./verify_remediation.sh
```

### 4. Optional full workflow test

```bash
./e2e_test.sh
```

## Monitoring

### Tail demo app logs

```bash
FUNCTION_NAME=$(cd ../demo-app && terraform output -raw demo_app_function_name)

aws logs tail /aws/lambda/$FUNCTION_NAME --follow
```

### Check alarm state

```bash
ALARM_NAME=$(cd ../demo-app && terraform output -raw demo_app_alarm_name)

aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[0].StateValue'
```

## Configuration

Terraform variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `project_name` | `aiops-log-analyzer` | Naming prefix |
| `environment` | `dev` | Environment name |
| `demo_memory_size` | `512` | Initial Lambda memory |
| `demo_timeout` | `60` | Lambda timeout |

Lambda environment defaults:

| Variable | Default |
|----------|---------|
| `MEMORY_PATTERN` | `gradual` |
| `TARGET_MB` | `600` |

## Troubleshooting

### The function succeeds instead of failing

- the current memory may already have been increased by remediation
- the selected pattern may not be aggressive enough for the current memory size
- redeploy with lower `demo_memory_size` or use a higher `target_mb`

Example:

```bash
terraform apply -var="demo_memory_size=256"
```

### The alarm does not trigger

- you need at least 5 matching errors in a 5-minute window
- use `../test/trigger_errors.sh` instead of a single manual invocation
- confirm the alarm name and state from Terraform output

### Analyzer or Remediator never reacts

- confirm the core infrastructure is deployed
- confirm the real Analyzer and Remediator code was deployed after Terraform
- confirm everything is in the same AWS region

## Notes

- The Terraform path in this directory is the supported demo path for full end-to-end testing.
- A standalone manual Lambda created outside this Terraform will not automatically have the compatible metric filter and alarm needed for the full workflow.
