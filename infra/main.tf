# ============================================================================
# Intelligent Log Analyzer with Auto-Remediation on AWS
# Terraform Infrastructure as Code
# ============================================================================
# This deploys a complete AIOps system that automatically detects, analyzes,
# and remediates AWS Lambda out-of-memory errors using AI (Claude 3.5 Sonnet)
#
# Author: AWS Community Builder
# Version: 1.0.0
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Purpose     = "AIOps-Intelligent-Log-Analyzer"
    }
  }
}

# ============================================================================
# LOCAL VARIABLES
# ============================================================================

locals {
  # Naming convention: {project}-{component}-{environment}
  name_prefix = "${var.project_name}-${var.environment}"
  
  # Common tags
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
  
  # Lambda function names
  analyzer_function_name    = "${local.name_prefix}-analyzer"
  remediator_function_name  = "${local.name_prefix}-remediator"
  
  # DynamoDB table name
  incidents_table_name = "${local.name_prefix}-incidents"
  
  # EventBridge rule name
  eventbridge_rule_name = "${local.name_prefix}-error-detection"
  
  # SNS topic name
  sns_topic_name = "${local.name_prefix}-notifications"
  
  # CloudWatch Log Groups
  analyzer_log_group    = "/aws/lambda/${local.analyzer_function_name}"
  remediator_log_group  = "/aws/lambda/${local.remediator_function_name}"
}

# ============================================================================
# DATA SOURCES
# ============================================================================

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get current AWS region
data "aws_region" "current" {}

# ============================================================================
# SECRETS MANAGER - Slack Webhook URL
# ============================================================================

resource "aws_secretsmanager_secret" "slack_webhook" {
  name        = "${local.name_prefix}-slack-webhook2"
  description = "Slack webhook URL for AIOps notifications"
  
  recovery_window_in_days = 7
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-slack-webhook"
  })
}

resource "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id     = aws_secretsmanager_secret.slack_webhook.id
  secret_string = jsonencode({
    webhook_url = var.slack_webhook_url
  })
}

# ============================================================================
# DYNAMODB TABLE - Incident History
# ============================================================================

resource "aws_dynamodb_table" "incidents" {
  name           = local.incidents_table_name
  billing_mode   = "PAY_PER_REQUEST"  # On-demand pricing for cost optimization
  hash_key       = "incident_id"
  range_key      = "timestamp"
  
  # Enable point-in-time recovery for production
  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }
  
  # Enable encryption at rest
  server_side_encryption {
    enabled = true
  }
  
  # Primary key
  attribute {
    name = "incident_id"
    type = "S"
  }
  
  attribute {
    name = "timestamp"
    type = "N"
  }
  
  # GSI for querying by log group
  attribute {
    name = "log_group"
    type = "S"
  }
  
  attribute {
    name = "error_type"
    type = "S"
  }
  
  # Global Secondary Index for querying incidents by log group
  global_secondary_index {
    name            = "log-group-timestamp-index"
    hash_key        = "log_group"
    range_key       = "timestamp"
    projection_type = "ALL"
  }
  
  # Global Secondary Index for querying by error type
  global_secondary_index {
    name            = "error-type-timestamp-index"
    hash_key        = "error_type"
    range_key       = "timestamp"
    projection_type = "ALL"
  }
  
  # TTL to automatically delete old incidents (cost optimization)
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  
  tags = merge(local.common_tags, {
    Name = local.incidents_table_name
  })
}

# ============================================================================
# SNS TOPIC - Notifications
# ============================================================================

resource "aws_sns_topic" "notifications" {
  name              = local.sns_topic_name
  display_name      = "AIOps Incident Notifications"
  
  # Enable encryption at rest
  kms_master_key_id = "alias/aws/sns"
  
  tags = merge(local.common_tags, {
    Name = local.sns_topic_name
  })
}

# SNS Topic Policy - Allow Lambda to publish
resource "aws_sns_topic_policy" "notifications" {
  arn = aws_sns_topic.notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaPublish"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.notifications.arn
      }
    ]
  })
}

# Optional: Email subscription for notifications
resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ============================================================================
# IAM ROLE - Analyzer Lambda
# ============================================================================

# Trust policy for Lambda
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    
    actions = ["sts:AssumeRole"]
  }
}

# Analyzer Lambda Role
resource "aws_iam_role" "analyzer" {
  name               = "${local.name_prefix}-analyzer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-analyzer-role"
  })
}

# Analyzer Lambda Policy
data "aws_iam_policy_document" "analyzer" {
  # CloudWatch Logs - Read access to monitored Lambda logs
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    
    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:DescribeLogStreams"
    ]
    
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*:*"
    ]
  }
  
  # CloudWatch Logs - Write access for own logs
  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.analyzer_log_group}:*"
    ]
  }
  
  # Amazon Bedrock - Invoke Claude model
  statement {
    sid    = "BedrockInvokeModel"
    effect = "Allow"
    
    actions = [
      "bedrock:InvokeModel"
    ]
    
    resources = [
      "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/anthropic.claude-3-5-sonnet-*",
      "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/amazon.nova-*"
    ]
  }
  
  # DynamoDB - Read/Write incidents
  statement {
    sid    = "DynamoDBAccess"
    effect = "Allow"
    
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem"
    ]
    
    resources = [
      aws_dynamodb_table.incidents.arn,
      "${aws_dynamodb_table.incidents.arn}/index/*"
    ]
  }
  
  # SNS - Publish notifications
  statement {
    sid    = "SNSPublish"
    effect = "Allow"
    
    actions = [
      "sns:Publish"
    ]
    
    resources = [
      aws_sns_topic.notifications.arn
    ]
  }
  
  # Secrets Manager - Read Slack webhook
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    
    resources = [
      aws_secretsmanager_secret.slack_webhook.arn
    ]
  }
  
  # Lambda - Invoke remediator
  statement {
    sid    = "InvokeRemediator"
    effect = "Allow"
    
    actions = [
      "lambda:InvokeFunction"
    ]
    
    resources = [
      aws_lambda_function.remediator.arn
    ]
  }
  
  # Lambda - List and describe functions (for monitoring)
  statement {
    sid    = "LambdaDescribe"
    effect = "Allow"
    
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:ListTags"
    ]
    
    resources = [
      "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"
    ]
  }
}

resource "aws_iam_policy" "analyzer" {
  name        = "${local.name_prefix}-analyzer-policy"
  description = "Policy for Analyzer Lambda function"
  policy      = data.aws_iam_policy_document.analyzer.json
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-analyzer-policy"
  })
}

resource "aws_iam_role_policy_attachment" "analyzer" {
  role       = aws_iam_role.analyzer.name
  policy_arn = aws_iam_policy.analyzer.arn
}

# ============================================================================
# IAM ROLE - Remediator Lambda
# ============================================================================

resource "aws_iam_role" "remediator" {
  name               = "${local.name_prefix}-remediator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-remediator-role"
  })
}

# Remediator Lambda Policy
data "aws_iam_policy_document" "remediator" {
  # CloudWatch Logs - Write access for own logs
  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.remediator_log_group}:*"
    ]
  }
  
  # CloudWatch Logs - Read access for verification
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    
    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents"
    ]
    
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*:*"
    ]
  }
  
  # Lambda - Update function configuration (for OOM remediation)
  statement {
    sid    = "LambdaUpdateConfig"
    effect = "Allow"
    
    actions = [
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:ListTags"
    ]
    
    resources = [
      "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"
    ]
    
    # Only allow updates to tagged Lambdas
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.monitored_lambda_tag_key}"
      values   = [var.monitored_lambda_tag_value]
    }
  }
  
  # DynamoDB - Update incident records
  statement {
    sid    = "DynamoDBUpdate"
    effect = "Allow"
    
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    
    resources = [
      aws_dynamodb_table.incidents.arn
    ]
  }
  
  # SNS - Publish notifications
  statement {
    sid    = "SNSPublish"
    effect = "Allow"
    
    actions = [
      "sns:Publish"
    ]
    
    resources = [
      aws_sns_topic.notifications.arn
    ]
  }
  
  # Secrets Manager - Read Slack webhook
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    
    resources = [
      aws_secretsmanager_secret.slack_webhook.arn
    ]
  }
}

resource "aws_iam_policy" "remediator" {
  name        = "${local.name_prefix}-remediator-policy"
  description = "Policy for Remediator Lambda function"
  policy      = data.aws_iam_policy_document.remediator.json
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-remediator-policy"
  })
}

resource "aws_iam_role_policy_attachment" "remediator" {
  role       = aws_iam_role.remediator.name
  policy_arn = aws_iam_policy.remediator.arn
}

# ============================================================================
# LAMBDA FUNCTION - Analyzer (Placeholder)
# ============================================================================
# Note: This creates a placeholder. You'll update with actual code later.

# Create a placeholder zip file for initial deployment
data "archive_file" "analyzer_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_analyzer_placeholder.zip"
  
  source {
    content  = <<-EOT
      def lambda_handler(event, context):
          print("Placeholder - Deploy actual code from ../lambda/analyzer/")
          return {"statusCode": 200, "body": "Placeholder"}
    EOT
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "analyzer" {
  filename         = data.archive_file.analyzer_placeholder.output_path
  function_name    = local.analyzer_function_name
  role            = aws_iam_role.analyzer.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.analyzer_placeholder.output_base64sha256
  
  runtime = "python3.11"
  timeout = var.analyzer_timeout
  memory_size = var.analyzer_memory_size
  
  environment {
    variables = {
      INCIDENTS_TABLE_NAME   = aws_dynamodb_table.incidents.name
      SNS_TOPIC_ARN         = aws_sns_topic.notifications.arn
      SLACK_WEBHOOK_SECRET  = aws_secretsmanager_secret.slack_webhook.name
      CONFIDENCE_THRESHOLD  = var.confidence_threshold
      AUTO_REMEDIATE        = var.auto_remediate ? "true" : "false"
      REMEDIATOR_FUNCTION   = aws_lambda_function.remediator.function_name
      MAX_LOG_LINES         = var.max_log_lines
      BEDROCK_MODEL_ID      = var.bedrock_model_id
      LOG_LEVEL             = var.log_level
      PROJECT_NAME          = var.project_name
      ENVIRONMENT           = var.environment
      ALARM_PREFIX          = "${local.name_prefix}-oom-"
    }
  }
  
  # Enable X-Ray tracing for observability
  tracing_config {
    mode = "Active"
  }
  
  tags = merge(local.common_tags, {
    Name = local.analyzer_function_name
  })
  
  # Ignore changes to source code (will be updated separately)
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash
    ]
  }
}

# CloudWatch Log Group for Analyzer
resource "aws_cloudwatch_log_group" "analyzer" {
  name              = local.analyzer_log_group
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Name = local.analyzer_log_group
  })
}

# ============================================================================
# LAMBDA FUNCTION - Remediator (Placeholder)
# ============================================================================

data "archive_file" "remediator_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_remediator_placeholder.zip"
  
  source {
    content  = <<-EOT
      def lambda_handler(event, context):
          print("Placeholder - Deploy actual code from ../lambda/remediator/")
          return {"statusCode": 200, "body": "Placeholder"}
    EOT
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "remediator" {
  filename         = data.archive_file.remediator_placeholder.output_path
  function_name    = local.remediator_function_name
  role            = aws_iam_role.remediator.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.remediator_placeholder.output_base64sha256
  
  runtime = "python3.11"
  timeout = var.remediator_timeout
  memory_size = var.remediator_memory_size
  
  environment {
    variables = {
      INCIDENTS_TABLE_NAME = aws_dynamodb_table.incidents.name
      SNS_TOPIC_ARN       = aws_sns_topic.notifications.arn
      SLACK_WEBHOOK_SECRET = aws_secretsmanager_secret.slack_webhook.name
      DRY_RUN             = var.dry_run ? "true" : "false"
      MAX_MEMORY_MB       = var.max_lambda_memory_size
      MIN_MEMORY_MB       = var.min_lambda_memory_size
      LOG_LEVEL           = var.log_level
    }
  }
  
  # Enable X-Ray tracing
  tracing_config {
    mode = "Active"
  }
  
  tags = merge(local.common_tags, {
    Name = local.remediator_function_name
  })
  
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash
    ]
  }
}

# CloudWatch Log Group for Remediator
resource "aws_cloudwatch_log_group" "remediator" {
  name              = local.remediator_log_group
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Name = local.remediator_log_group
  })
}

# ============================================================================
# CLOUDWATCH ALARMS - OOM Detection
# ============================================================================
# Note: These alarms will be created for Lambda functions with the monitoring tag

# Metric filter for OOM errors (will be applied to monitored Lambdas)
# This is a template - actual filters created via subscription in EventBridge

# ============================================================================
# EVENTBRIDGE RULE - Error Detection
# ============================================================================

# EventBridge rule to trigger analyzer on CloudWatch Alarms
resource "aws_cloudwatch_event_rule" "error_detection" {
  name        = local.eventbridge_rule_name
  description = "Triggers analyzer Lambda when CloudWatch alarm for Lambda errors fires"
  
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{
        prefix = "${local.name_prefix}-oom-"
      }]
      state = {
        value = ["ALARM"]
      }
    }
  })
  
  tags = merge(local.common_tags, {
    Name = local.eventbridge_rule_name
  })
}

# EventBridge target - Analyzer Lambda
resource "aws_cloudwatch_event_target" "analyzer" {
  rule      = aws_cloudwatch_event_rule.error_detection.name
  target_id = "AnalyzerLambda"
  arn       = aws_lambda_function.analyzer.arn
  
  # Transform CloudWatch Alarm event to analyzer input format
  input_transformer {
    input_paths = {
      alarm_name = "$.detail.alarmName"
      timestamp  = "$.time"
      region     = "$.region"
    }
    
    input_template = <<-EOT
      {
        "alarm_name": <alarm_name>,
        "timestamp": <timestamp>,
        "region": <region>,
        "source": "cloudwatch-alarm"
      }
    EOT
  }
}

# Allow EventBridge to invoke Analyzer Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyzer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.error_detection.arn
}

# ============================================================================
# CLOUDWATCH DASHBOARD - Monitoring
# ============================================================================

resource "aws_cloudwatch_dashboard" "aiops" {
  dashboard_name = "${local.name_prefix}-dashboard"
  
  dashboard_body = jsonencode({
    widgets = [
      # Analyzer Lambda metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Invocations" }],
            [".", "Errors", { stat = "Sum", label = "Errors" }],
            [".", "Duration", { stat = "Average", label = "Avg Duration (ms)" }],
            [".", "ConcurrentExecutions", { stat = "Maximum", label = "Concurrent" }]
          ]
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Analyzer Lambda Metrics"
          period  = 300
          dimensions = {
            FunctionName = [local.analyzer_function_name]
          }
        }
      },
      # Remediator Lambda metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Invocations" }],
            [".", "Errors", { stat = "Sum", label = "Errors" }],
            [".", "Duration", { stat = "Average", label = "Avg Duration (ms)" }]
          ]
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Remediator Lambda Metrics"
          period  = 300
          dimensions = {
            FunctionName = [local.remediator_function_name]
          }
        }
      },
      # DynamoDB metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", { stat = "Sum" }],
            [".", "ConsumedWriteCapacityUnits", { stat = "Sum" }]
          ]
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "DynamoDB Capacity"
          period  = 300
          dimensions = {
            TableName = [local.incidents_table_name]
          }
        }
      },
      # Recent logs widget
      {
        type = "log"
        properties = {
          query   = "SOURCE '${local.analyzer_log_group}' | fields @timestamp, @message | sort @timestamp desc | limit 20"
          region  = data.aws_region.current.name
          title   = "Recent Analyzer Logs"
        }
      }
    ]
  })
}

# ============================================================================
# CLOUDWATCH ALARMS - System Health
# ============================================================================

# Alarm: Analyzer Lambda errors
resource "aws_cloudwatch_metric_alarm" "analyzer_errors" {
  alarm_name          = "${local.name_prefix}-analyzer-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Analyzer Lambda has too many errors"
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    FunctionName = aws_lambda_function.analyzer.function_name
  }
  
  alarm_actions = [aws_sns_topic.notifications.arn]
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-analyzer-errors"
  })
}

# Alarm: Remediator Lambda errors
resource "aws_cloudwatch_metric_alarm" "remediator_errors" {
  alarm_name          = "${local.name_prefix}-remediator-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Remediator Lambda has too many errors"
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    FunctionName = aws_lambda_function.remediator.function_name
  }
  
  alarm_actions = [aws_sns_topic.notifications.arn]
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-remediator-errors"
  })
}

# ============================================================================
# OUTPUTS
# ============================================================================
# See outputs.tf for all output definitions
