# ============================================================================
# VARIABLES - Intelligent Log Analyzer
# ============================================================================

# ----------------------------------------------------------------------------
# REQUIRED VARIABLES
# ----------------------------------------------------------------------------

variable "slack_webhook_url" {
  description = "Slack webhook URL for notifications"
  type        = string
  sensitive   = true
  
  validation {
    condition     = can(regex("^https://hooks\\.slack\\.com/services/", var.slack_webhook_url))
    error_message = "Must be a valid Slack webhook URL starting with https://hooks.slack.com/services/"
  }
}

# ----------------------------------------------------------------------------
# GENERAL CONFIGURATION
# ----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
  
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Must be a valid AWS region format (e.g., us-east-1)"
  }
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "aiops-log-analyzer"
  
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
  
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod"
  }
}

# ----------------------------------------------------------------------------
# MONITORING CONFIGURATION
# ----------------------------------------------------------------------------

variable "monitored_lambda_tag_key" {
  description = "Tag key to identify Lambda functions to monitor"
  type        = string
  default     = "aiops-monitor"
}

variable "monitored_lambda_tag_value" {
  description = "Tag value to identify Lambda functions to monitor"
  type        = string
  default     = "true"
}

# ----------------------------------------------------------------------------
# AI ANALYSIS CONFIGURATION
# ----------------------------------------------------------------------------

variable "confidence_threshold" {
  description = "Minimum confidence score (0-1) required for auto-remediation"
  type        = number
  default     = 0.85
  
  validation {
    condition     = var.confidence_threshold >= 0 && var.confidence_threshold <= 1
    error_message = "Confidence threshold must be between 0 and 1"
  }
}

variable "auto_remediate" {
  description = "Enable automatic remediation when confidence threshold is met"
  type        = bool
  default     = true
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID for Claude"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "max_log_lines" {
  description = "Maximum number of log lines to send to Claude for analysis"
  type        = number
  default     = 50
  
  validation {
    condition     = var.max_log_lines >= 10 && var.max_log_lines <= 200
    error_message = "Max log lines must be between 10 and 200"
  }
}

# ----------------------------------------------------------------------------
# LAMBDA CONFIGURATION
# ----------------------------------------------------------------------------

variable "analyzer_memory_size" {
  description = "Memory size (MB) for Analyzer Lambda function"
  type        = number
  default     = 512
  
  validation {
    condition     = var.analyzer_memory_size >= 128 && var.analyzer_memory_size <= 10240
    error_message = "Memory size must be between 128 and 10240 MB"
  }
}

variable "analyzer_timeout" {
  description = "Timeout (seconds) for Analyzer Lambda function"
  type        = number
  default     = 300
  
  validation {
    condition     = var.analyzer_timeout >= 60 && var.analyzer_timeout <= 900
    error_message = "Timeout must be between 60 and 900 seconds"
  }
}

variable "remediator_memory_size" {
  description = "Memory size (MB) for Remediator Lambda function"
  type        = number
  default     = 256
  
  validation {
    condition     = var.remediator_memory_size >= 128 && var.remediator_memory_size <= 10240
    error_message = "Memory size must be between 128 and 10240 MB"
  }
}

variable "remediator_timeout" {
  description = "Timeout (seconds) for Remediator Lambda function"
  type        = number
  default     = 600
  
  validation {
    condition     = var.remediator_timeout >= 60 && var.remediator_timeout <= 900
    error_message = "Timeout must be between 60 and 900 seconds"
  }
}

# ----------------------------------------------------------------------------
# REMEDIATION CONFIGURATION
# ----------------------------------------------------------------------------

variable "dry_run" {
  description = "Enable dry-run mode (simulate remediation without applying changes)"
  type        = bool
  default     = false
}

variable "max_lambda_memory_size" {
  description = "Maximum memory size (MB) allowed for Lambda remediation"
  type        = number
  default     = 10240
  
  validation {
    condition     = var.max_lambda_memory_size >= 128 && var.max_lambda_memory_size <= 10240
    error_message = "Max memory size must be between 128 and 10240 MB"
  }
}

variable "min_lambda_memory_size" {
  description = "Minimum memory size (MB) allowed for Lambda remediation"
  type        = number
  default     = 128
  
  validation {
    condition     = var.min_lambda_memory_size >= 128 && var.min_lambda_memory_size <= 10240
    error_message = "Min memory size must be between 128 and 10240 MB"
  }
}

# ----------------------------------------------------------------------------
# STORAGE CONFIGURATION
# ----------------------------------------------------------------------------

variable "incident_retention_days" {
  description = "Number of days to retain incident records in DynamoDB (via TTL)"
  type        = number
  default     = 30
  
  validation {
    condition     = var.incident_retention_days >= 1 && var.incident_retention_days <= 90
    error_message = "Retention days must be between 1 and 90"
  }
}

variable "enable_point_in_time_recovery" {
  description = "Enable point-in-time recovery for DynamoDB table"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days"
  type        = number
  default     = 7
  
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "Log retention days must be a valid CloudWatch Logs retention value"
  }
}

# ----------------------------------------------------------------------------
# NOTIFICATION CONFIGURATION
# ----------------------------------------------------------------------------

variable "notification_email" {
  description = "Email address for SNS notifications (optional)"
  type        = string
  default     = ""
  
  validation {
    condition     = var.notification_email == "" || can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.notification_email))
    error_message = "Must be a valid email address or empty string"
  }
}

# ----------------------------------------------------------------------------
# LOGGING & DEBUGGING
# ----------------------------------------------------------------------------

variable "log_level" {
  description = "Logging level for Lambda functions (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
  
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "Log level must be DEBUG, INFO, WARNING, or ERROR"
  }
}

# ----------------------------------------------------------------------------
# COST OPTIMIZATION
# ----------------------------------------------------------------------------

variable "enable_cost_alerts" {
  description = "Enable CloudWatch alarms for cost monitoring"
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly budget in USD for cost alerts"
  type        = number
  default     = 100
  
  validation {
    condition     = var.monthly_budget_usd >= 10
    error_message = "Monthly budget must be at least $10"
  }
}
