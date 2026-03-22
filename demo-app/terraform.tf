# Demo App Terraform Configuration
# Separate from main infrastructure for easy testing

terraform {
  required_version = ">= 1.0"
  
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
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================================
# VARIABLES
# ============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "aiops-log-analyzer"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "demo_memory_size" {
  description = "Initial memory size for demo app (MB) - should be small to trigger OOM"
  type        = number
  default     = 512
}

variable "demo_timeout" {
  description = "Demo app timeout (seconds)"
  type        = number
  default     = 60
}

# ============================================================================
# IAM ROLE FOR DEMO APP
# ============================================================================

resource "aws_iam_role" "demo_app" {
  name = "${var.project_name}-${var.environment}-demo-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-demo-app-role"
    Environment = var.environment
    Purpose     = "Demo/Testing"
  }
}

# Basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "demo_app_basic" {
  role       = aws_iam_role.demo_app.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================================
# LAMBDA FUNCTION - DEMO APP
# ============================================================================

# Package the Lambda function
data "archive_file" "demo_app" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/demo-app-package.zip"
}

resource "aws_lambda_function" "demo_app" {
  filename         = data.archive_file.demo_app.output_path
  function_name    = "${var.project_name}-${var.environment}-demo-app"
  role            = aws_iam_role.demo_app.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.demo_app.output_base64sha256
  runtime         = "python3.11"
  timeout         = var.demo_timeout
  memory_size     = var.demo_memory_size

  environment {
    variables = {
      MEMORY_PATTERN = "gradual"
      TARGET_MB      = "600"
    }
  }

  tags = {
    Name           = "${var.project_name}-${var.environment}-demo-app"
    Environment    = var.environment
    Purpose        = "Demo/Testing"
    aiops-monitor  = "true"  # IMPORTANT: Tag for monitoring
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "demo_app" {
  name              = "/aws/lambda/${aws_lambda_function.demo_app.function_name}"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-${var.environment}-demo-app-logs"
    Environment = var.environment
  }
}

# ============================================================================
# CLOUDWATCH ALARM FOR DEMO APP
# ============================================================================

resource "aws_cloudwatch_log_metric_filter" "demo_app_errors" {
  name           = "${var.project_name}-${var.environment}-demo-app-errors"
  log_group_name = aws_cloudwatch_log_group.demo_app.name
  pattern        = "?ERROR ?Error ?error ?Exception ?EXCEPTION ?OOM"

  metric_transformation {
    name      = "DemoAppErrors"
    namespace = "${var.project_name}/${var.environment}"
    value     = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "demo_app_oom" {
  alarm_name          = "${var.project_name}-${var.environment}-oom-${aws_lambda_function.demo_app.function_name}"
  alarm_description   = "Triggers when demo app encounters errors (for AIOps testing)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DemoAppErrors"
  namespace           = "${var.project_name}/${var.environment}"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = []  # Will be configured by main infrastructure

  tags = {
    Name        = "${var.project_name}-${var.environment}-demo-app-alarm"
    Environment = var.environment
    Purpose     = "Demo/Testing"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "demo_app_function_name" {
  description = "Name of the demo Lambda function"
  value       = aws_lambda_function.demo_app.function_name
}

output "demo_app_function_arn" {
  description = "ARN of the demo Lambda function"
  value       = aws_lambda_function.demo_app.arn
}

output "demo_app_log_group" {
  description = "CloudWatch log group for demo app"
  value       = aws_cloudwatch_log_group.demo_app.name
}

output "demo_app_alarm_name" {
  description = "CloudWatch alarm name for demo app"
  value       = aws_cloudwatch_metric_alarm.demo_app_oom.alarm_name
}

output "test_command" {
  description = "Command to test the demo app"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.demo_app.function_name} --payload '{\"pattern\":\"gradual\",\"target_mb\":600}' response.json"
}
