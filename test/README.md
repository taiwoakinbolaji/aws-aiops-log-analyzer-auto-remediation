# Test Scripts

This directory contains shell scripts for exercising the Lambda OOM detection and remediation workflow.

These scripts are written for the current project defaults:

- project name: `aiops-log-analyzer`
- environment: `dev`
- region: `${AWS_REGION:-us-east-1}`
- demo function name: `aiops-log-analyzer-dev-demo-app`

Some scripts assume those names directly when checking alarms, Analyzer logs, and Remediator logs.

## Prerequisites

- Core infrastructure deployed
- Analyzer and Remediator code deployed
- Demo app deployed, or another compatible Lambda function and alarm configured
- AWS CLI installed and authenticated
- `jq` is recommended but optional for most scripts

## Scripts

### `trigger_errors.sh`

Triggers repeated Lambda invocations intended to produce OOM-style failures.

```bash
./trigger_errors.sh [function-name] [count] [pattern] [target-mb]
```

Defaults:

- function: `aiops-log-analyzer-dev-demo-app`
- count: `6`
- pattern: `sudden`
- target memory: `600`

Notes:

- prompts for confirmation before invoking
- treats 5 or more successful OOM-style failures as enough to trigger the alarm path
- if no function is passed, it can fall back to `aiops-log-analyzer-prod-demo-app` if that exists

### `verify_remediation.sh`

Checks whether memory was increased and whether related evidence exists in CloudWatch and DynamoDB.

```bash
./verify_remediation.sh [function-name] [expected-min-memory] [incidents-table]
```

Defaults:

- function: `aiops-log-analyzer-dev-demo-app`
- expected minimum memory: `768`
- incidents table: `aiops-log-analyzer-dev-incidents`

What it checks:

- current Lambda memory and state
- CloudWatch alarm state for `aiops-log-analyzer-dev-oom-<function>`
- incident records in DynamoDB
- recent log errors for the function
- optional manual retest of the function

Notes:

- the script asks whether to run a live retest at the end
- alarm and analyzer/remediator references are currently hardcoded to the `dev` naming pattern

### `load_test.sh`

Launches waves of concurrent invocations to generate many failures quickly.

```bash
./load_test.sh [function-name] [concurrent] [iterations]
```

Defaults:

- function: `aiops-log-analyzer-dev-demo-app`
- concurrent invocations per wave: `10`
- waves: `5`

Behavior:

- prompts for confirmation before running
- uses a fixed payload of `{"pattern":"sudden","target_mb":600}`
- reports basic invocation/error counts and CloudWatch metrics
- checks the alarm `aiops-log-analyzer-dev-oom-<function>`

### `e2e_test.sh`

Runs a full end-to-end validation and writes a text report in the current directory.

```bash
./e2e_test.sh [function-name]
```

Default:

- function: `aiops-log-analyzer-dev-demo-app`

Behavior:

- verifies the demo function, analyzer, remediator, and incidents table exist
- triggers 6 failures
- waits for the alarm to enter `ALARM`
- checks Analyzer and Remediator log activity
- verifies the target function memory increased
- retests the function
- checks DynamoDB for an incident record

Current assumptions:

- project name is hardcoded to `aiops-log-analyzer`
- environment is hardcoded to `dev`

### `monitor_workflow.sh`

Helps you tail the relevant log groups while the workflow runs.

```bash
./monitor_workflow.sh [function-name]
```

Default:

- function: `aiops-log-analyzer-dev-demo-app`

Behavior:

- prints the three log-tail commands you need
- on macOS, attempts to open Terminal tabs automatically
- on Linux, tries `gnome-terminal` or `xterm`
- if it cannot open terminals, it prints the commands and exits after `wait`

## Recommended Flow

### Basic manual test

```bash
cd test
chmod +x *.sh

./trigger_errors.sh
# wait for the CloudWatch alarm window to pass
./verify_remediation.sh
```

### Full workflow test

```bash
cd test
./e2e_test.sh
```

### Load test

```bash
cd test
./load_test.sh aiops-log-analyzer-dev-demo-app 10 5
```

## Important Limitations

- These scripts are not fully environment-agnostic.
- Alarm names are assumed to follow `aiops-log-analyzer-dev-oom-<function>`.
- Analyzer and Remediator function names are assumed to be `aiops-log-analyzer-dev-analyzer` and `aiops-log-analyzer-dev-remediator`.
- The scripts are best suited to the included demo deployment and the default `dev` environment.

If you deploy with different names, update the script arguments where supported and review the hardcoded `dev` references in the scripts before relying on them.
