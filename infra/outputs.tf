# ============================================================================
# OUTPUTS - Intelligent Log Analyzer
# ============================================================================

# ----------------------------------------------------------------------------
# LAMBDA FUNCTIONS
# ----------------------------------------------------------------------------

output "analyzer_function_name" {
  description = "Name of the Analyzer Lambda function"
  value       = aws_lambda_function.analyzer.function_name
}

output "analyzer_function_arn" {
  description = "ARN of the Analyzer Lambda function"
  value       = aws_lambda_function.analyzer.arn
}

output "remediator_function_name" {
  description = "Name of the Remediator Lambda function"
  value       = aws_lambda_function.remediator.function_name
}

output "remediator_function_arn" {
  description = "ARN of the Remediator Lambda function"
  value       = aws_lambda_function.remediator.arn
}

# ----------------------------------------------------------------------------
# DYNAMODB
# ----------------------------------------------------------------------------

output "incidents_table_name" {
  description = "Name of the DynamoDB incidents table"
  value       = aws_dynamodb_table.incidents.name
}

output "incidents_table_arn" {
  description = "ARN of the DynamoDB incidents table"
  value       = aws_dynamodb_table.incidents.arn
}

# ----------------------------------------------------------------------------
# SNS
# ----------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "ARN of the SNS notification topic"
  value       = aws_sns_topic.notifications.arn
}

output "sns_topic_name" {
  description = "Name of the SNS notification topic"
  value       = aws_sns_topic.notifications.name
}

# ----------------------------------------------------------------------------
# SECRETS MANAGER
# ----------------------------------------------------------------------------

output "slack_webhook_secret_arn" {
  description = "ARN of the Slack webhook secret"
  value       = aws_secretsmanager_secret.slack_webhook.arn
  sensitive   = true
}

output "slack_webhook_secret_name" {
  description = "Name of the Slack webhook secret"
  value       = aws_secretsmanager_secret.slack_webhook.name
}

# ----------------------------------------------------------------------------
# EVENTBRIDGE
# ----------------------------------------------------------------------------

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule for error detection"
  value       = aws_cloudwatch_event_rule.error_detection.name
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule for error detection"
  value       = aws_cloudwatch_event_rule.error_detection.arn
}

# ----------------------------------------------------------------------------
# CLOUDWATCH
# ----------------------------------------------------------------------------

output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.aiops.dashboard_name
}

output "cloudwatch_dashboard_url" {
  description = "URL to view the CloudWatch dashboard"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.aiops.dashboard_name}"
}

output "analyzer_log_group" {
  description = "CloudWatch Log Group for Analyzer Lambda"
  value       = aws_cloudwatch_log_group.analyzer.name
}

output "remediator_log_group" {
  description = "CloudWatch Log Group for Remediator Lambda"
  value       = aws_cloudwatch_log_group.remediator.name
}

# ----------------------------------------------------------------------------
# IAM ROLES
# ----------------------------------------------------------------------------

output "analyzer_role_arn" {
  description = "ARN of the Analyzer Lambda IAM role"
  value       = aws_iam_role.analyzer.arn
}

output "analyzer_role_name" {
  description = "Name of the Analyzer Lambda IAM role"
  value       = aws_iam_role.analyzer.name
}

output "remediator_role_arn" {
  description = "ARN of the Remediator Lambda IAM role"
  value       = aws_iam_role.remediator.arn
}

output "remediator_role_name" {
  description = "Name of the Remediator Lambda IAM role"
  value       = aws_iam_role.remediator.name
}

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------

output "monitored_lambda_tag" {
  description = "Tag key/value used to identify monitored Lambda functions"
  value = {
    key   = var.monitored_lambda_tag_key
    value = var.monitored_lambda_tag_value
  }
}

output "confidence_threshold" {
  description = "Configured confidence threshold for auto-remediation"
  value       = var.confidence_threshold
}

output "auto_remediate_enabled" {
  description = "Whether auto-remediation is enabled"
  value       = var.auto_remediate
}

# ----------------------------------------------------------------------------
# AWS ACCOUNT INFO
# ----------------------------------------------------------------------------

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = data.aws_region.current.name
}

output "aws_account_id" {
  description = "AWS account ID where resources are deployed"
  value       = data.aws_caller_identity.current.account_id
}

# ----------------------------------------------------------------------------
# DEPLOYMENT SUMMARY
# ----------------------------------------------------------------------------

output "deployment_summary" {
  description = "Summary of the deployed AIOps infrastructure"
  value = <<-EOT
  
  ═══════════════════════════════════════════════════════════════════
  🤖 Intelligent Log Analyzer - Deployment Complete!
  ═══════════════════════════════════════════════════════════════════
  
  📊 Dashboard:
     ${aws_cloudwatch_dashboard.aiops.dashboard_name}
     https://console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.aiops.dashboard_name}
  
  🧠 Analyzer Lambda:
     Name: ${aws_lambda_function.analyzer.function_name}
     ARN:  ${aws_lambda_function.analyzer.arn}
  
  🔧 Remediator Lambda:
     Name: ${aws_lambda_function.remediator.function_name}
     ARN:  ${aws_lambda_function.remediator.arn}
  
  💾 DynamoDB Table:
     Name: ${aws_dynamodb_table.incidents.name}
     TTL:  ${var.incident_retention_days} days
  
  ⚙️  Configuration:
     Confidence Threshold: ${var.confidence_threshold}
     Auto-Remediate:      ${var.auto_remediate}
     Monitored Tag:       ${var.monitored_lambda_tag_key}=${var.monitored_lambda_tag_value}
     Max Log Lines:       ${var.max_log_lines}
  
  📝 Next Steps:
  
     1. Deploy Lambda function code:
        cd ../lambda/analyzer
        ./deploy.sh
        
        cd ../lambda/remediator
        ./deploy.sh
  
     2. Tag your Lambda functions for monitoring:
        aws lambda tag-resource \
          --resource <lambda-arn> \
          --tags ${var.monitored_lambda_tag_key}=${var.monitored_lambda_tag_value}
  
     3. (Optional) Deploy demo app for testing:
        cd ../demo-app
        ./deploy.sh
  
     4. Test the system:
        cd ../test
        ./trigger_errors.sh oom 1
  
     5. Monitor results:
        - Check Slack for notifications
        - View dashboard: ${aws_cloudwatch_dashboard.aiops.dashboard_name}
        - Query DynamoDB: ${aws_dynamodb_table.incidents.name}
  
  ═══════════════════════════════════════════════════════════════════
  💰 Estimated Monthly Cost: $25-50 (100 incidents/month)
  📖 Documentation: See README.md for details
  ═══════════════════════════════════════════════════════════════════
  
  EOT
}
