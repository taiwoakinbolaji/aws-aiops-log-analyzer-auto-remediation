"""
Analyzer Lambda Function - Intelligent Log Analyzer with Auto-Remediation
==========================================================================

This Lambda function is the core intelligence of the AIOps system. It:
1. Receives error notifications from EventBridge
2. Fetches relevant logs from CloudWatch
3. Analyzes logs using Claude 3.5 Sonnet (via Amazon Bedrock)
4. Makes autonomous decisions on remediation
5. Invokes remediation or alerts humans

Author: AWS Community Builder
Version: 1.0.0
Runtime: Python 3.11
"""

import json
import os
import boto3
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any
from decimal import Decimal
import logging
from urllib import request as urllib_request
from urllib import error as urllib_error

# Import prompt templates
from prompts import (
    SYSTEM_PROMPT,
    build_analysis_prompt,
    RESPONSE_SCHEMA,
    validate_response
)

# Configure logging
log_level = os.environ.get('LOG_LEVEL', 'INFO')
logger = logging.getLogger()
logger.setLevel(getattr(logging, log_level))

# AWS Clients
bedrock = boto3.client('bedrock-runtime', region_name=os.environ.get('AWS_REGION', 'us-east-1'))
dynamodb = boto3.resource('dynamodb')
logs_client = boto3.client('logs')
lambda_client = boto3.client('lambda')
secretsmanager = boto3.client('secretsmanager')
sns = boto3.client('sns')

# Environment Variables
INCIDENTS_TABLE = os.environ['INCIDENTS_TABLE_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
SLACK_WEBHOOK_SECRET = os.environ['SLACK_WEBHOOK_SECRET']
CONFIDENCE_THRESHOLD = float(os.environ.get('CONFIDENCE_THRESHOLD', '0.85'))
AUTO_REMEDIATE = os.environ.get('AUTO_REMEDIATE', 'true').lower() == 'true'
REMEDIATOR_FUNCTION = os.environ['REMEDIATOR_FUNCTION']
MAX_LOG_LINES = int(os.environ.get('MAX_LOG_LINES', '50'))
BEDROCK_MODEL_ID = os.environ['BEDROCK_MODEL_ID']
PROJECT_NAME = os.environ.get('PROJECT_NAME', 'aiops-log-analyzer')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'dev')
ALARM_PREFIX = os.environ.get('ALARM_PREFIX', f"{PROJECT_NAME}-{ENVIRONMENT}-oom-")
_SLACK_WEBHOOK_URL: Optional[str] = None

# DynamoDB table
incidents_table = dynamodb.Table(INCIDENTS_TABLE)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler - analyzes errors and triggers remediation.
    
    Event format (from EventBridge):
    {
        "alarm_name": "aiops-log-analyzer-dev-oom-my-function",
        "timestamp": "2025-01-09T10:00:00Z",
        "region": "us-east-1",
        "source": "cloudwatch-alarm"
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        # Extract alarm information
        alarm_name = event.get('alarm_name', '')
        event_timestamp = event.get('timestamp', datetime.utcnow().isoformat())
        
        # Parse alarm name to extract function name
        # Format: {ALARM_PREFIX}{function_name}
        function_name = extract_function_name(alarm_name)
        if not function_name:
            logger.error(f"Could not extract function name from alarm: {alarm_name}")
            return create_error_response("Invalid alarm name format")
        
        logger.info(f"Analyzing errors for Lambda function: {function_name}")
        
        # Generate incident ID
        incident_id = f"inc-{int(time.time())}-{function_name}"
        
        # Step 1: Fetch error logs from CloudWatch
        log_group = f"/aws/lambda/{function_name}"
        error_logs = fetch_error_logs(log_group, minutes=15, max_lines=MAX_LOG_LINES)
        
        if not error_logs:
            logger.warning(f"No error logs found for {function_name}")
            return create_success_response(incident_id, "No logs to analyze")
        
        logger.info(f"Retrieved {len(error_logs)} error log entries")
        
        # Step 2: Get Lambda function metadata
        lambda_metadata = get_lambda_metadata(function_name)
        
        # Step 3: Get historical context (similar past incidents)
        historical_context = get_historical_context(log_group, error_type="OOM")
        
        # Step 4: Call Bedrock for analysis
        logger.info(f"Calling Amazon Bedrock model for analysis: {BEDROCK_MODEL_ID}")
        analysis = analyze_with_claude(
            error_logs=error_logs,
            log_group=log_group,
            function_name=function_name,
            lambda_metadata=lambda_metadata,
            historical_context=historical_context
        )

        # Fallback: Create basic analysis if Bedrock unavailable
        if not analysis:
            logger.warning("Claude analysis failed - using fallback analysis")
            analysis = create_fallback_analysis(
                error_logs=error_logs,
                function_name=function_name,
                lambda_metadata=lambda_metadata
            )
        
        logger.info(f"Analysis complete. Confidence: {analysis['root_cause']['confidence']:.2%}")
        
        # Step 5: Store analysis in DynamoDB
        store_incident(
            incident_id=incident_id,
            function_name=function_name,
            log_group=log_group,
            analysis=analysis,
            error_logs=error_logs,
            lambda_metadata=lambda_metadata
        )
        
        # Step 6: Make remediation decision
        should_remediate = should_auto_remediate(analysis)
        
        logger.info(f"Auto-remediation decision: {should_remediate}")
        
        # Step 7: Send notification
        send_notification(
            incident_id=incident_id,
            function_name=function_name,
            analysis=analysis,
            will_remediate=should_remediate
        )
        
        # Step 8: Trigger remediation if approved
        if should_remediate:
            logger.info(f"Invoking remediator for incident {incident_id}")
            invoke_remediator(
                incident_id=incident_id,
                function_name=function_name,
                analysis=analysis
            )
        
        return create_success_response(
            incident_id=incident_id,
            message="Analysis complete",
            analysis=analysis,
            auto_remediate=should_remediate
        )
        
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}", exc_info=True)
        return create_error_response(str(e))


def extract_function_name(alarm_name: str) -> Optional[str]:
    """
    Extract Lambda function name from CloudWatch alarm name.
    
    Expected format: {ALARM_PREFIX}{function_name}
    """
    try:
        # Remove prefix to get function name
        if alarm_name.startswith(ALARM_PREFIX):
            return alarm_name[len(ALARM_PREFIX):]
        
        # Fallback: try to parse as generic alarm
        parts = alarm_name.split('-')
        if len(parts) >= 2:
            return '-'.join(parts[-2:])  # Last two parts
        
        return None
    except Exception as e:
        logger.error(f"Error extracting function name: {e}")
        return None


def fetch_error_logs(
    log_group: str,
    minutes: int = 15,
    max_lines: int = 50
) -> List[Dict[str, Any]]:
    """
    Fetch error logs from CloudWatch Logs.
    
    Args:
        log_group: CloudWatch log group name
        minutes: Time window to search (default: 15 minutes)
        max_lines: Maximum number of log lines to return
        
    Returns:
        List of log entries with timestamp and message
    """
    try:
        # Calculate time range
        end_time = int(time.time() * 1000)  # Current time in milliseconds
        start_time = end_time - (minutes * 60 * 1000)
        
        logger.info(f"Fetching logs from {log_group} (last {minutes} minutes)")
        
        # Filter pattern for errors (includes Lambda OOM errors)
        filter_pattern = '?"Runtime.OutOfMemory" ?ERROR ?Error ?error ?EXCEPTION ?Exception ?CRITICAL ?Fatal ?OOM'
        
        # Query logs
        response = logs_client.filter_log_events(
            logGroupName=log_group,
            startTime=start_time,
            endTime=end_time,
            filterPattern=filter_pattern,
            limit=max_lines
        )
        
        # Format logs
        error_logs = []
        for event in response.get('events', []):
            error_logs.append({
                'timestamp': datetime.fromtimestamp(event['timestamp'] / 1000).isoformat(),
                'message': event['message'].strip(),
                'log_stream': event.get('logStreamName', '')
            })
        
        # Sort by timestamp (oldest first)
        error_logs.sort(key=lambda x: x['timestamp'])
        
        return error_logs
        
    except logs_client.exceptions.ResourceNotFoundException:
        logger.warning(f"Log group not found: {log_group}")
        return []
    except Exception as e:
        logger.error(f"Error fetching logs: {e}", exc_info=True)
        return []


def get_lambda_metadata(function_name: str) -> Dict[str, Any]:
    """
    Get Lambda function metadata (memory, timeout, etc.)
    """
    try:
        response = lambda_client.get_function_configuration(
            FunctionName=function_name
        )
        
        return {
            'function_name': response['FunctionName'],
            'memory_size': response['MemorySize'],
            'timeout': response['Timeout'],
            'runtime': response['Runtime'],
            'last_modified': response['LastModified'],
            'handler': response.get('Handler', 'unknown')
        }
    except Exception as e:
        logger.error(f"Error getting Lambda metadata: {e}")
        return {
            'function_name': function_name,
            'memory_size': 'unknown',
            'timeout': 'unknown',
            'runtime': 'unknown'
        }


def get_historical_context(
    log_group: str,
    error_type: str,
    limit: int = 5
) -> Optional[Dict[str, Any]]:
    """
    Query DynamoDB for similar past incidents.
    """
    try:
        # Calculate 30 days ago timestamp
        thirty_days_ago = int((datetime.utcnow() - timedelta(days=30)).timestamp())
        
        # Query by log_group using GSI
        response = incidents_table.query(
            IndexName='log-group-timestamp-index',
            KeyConditionExpression='log_group = :lg AND #ts > :cutoff',
            ExpressionAttributeNames={
                '#ts': 'timestamp'
            },
            ExpressionAttributeValues={
                ':lg': log_group,
                ':cutoff': thirty_days_ago
            },
            Limit=limit,
            ScanIndexForward=False  # Most recent first
        )
        
        incidents = response.get('Items', [])
        
        if not incidents:
            return None
        
        # Format for Claude
        return {
            'total_incidents': len(incidents),
            'most_recent': {
                'root_cause': incidents[0].get('analysis', {}).get('root_cause', {}).get('summary', 'Unknown'),
                'confidence': incidents[0].get('analysis', {}).get('root_cause', {}).get('confidence', 0),
                'remediation_successful': incidents[0].get('remediation_status') == 'SUCCESS'
            },
            'patterns': summarize_patterns(incidents)
        }
        
    except Exception as e:
        logger.error(f"Error fetching historical context: {e}")
        return None


def summarize_patterns(incidents: List[Dict]) -> str:
    """Summarize common patterns from past incidents."""
    try:
        categories = [
            inc.get('analysis', {}).get('root_cause', {}).get('category', 'Unknown')
            for inc in incidents
        ]
        
        if not categories:
            return "No historical patterns"
        
        # Count occurrences
        from collections import Counter
        counter = Counter(categories)
        most_common = counter.most_common(3)
        
        summary = ", ".join([f"{cat} ({count}x)" for cat, count in most_common])
        return summary
        
    except Exception as e:
        logger.error(f"Error summarizing patterns: {e}")
        return "Unable to summarize patterns"


def analyze_with_claude(
    error_logs: List[Dict],
    log_group: str,
    function_name: str,
    lambda_metadata: Dict,
    historical_context: Optional[Dict]
) -> Optional[Dict[str, Any]]:
    """
    Call Amazon Bedrock (Claude 3.5 Sonnet) to analyze error logs.
    """
    try:
        # Build prompt using templates
        prompt = build_analysis_prompt(
            error_logs=error_logs,
            log_group=log_group,
            function_name=function_name,
            lambda_metadata=lambda_metadata,
            historical_context=historical_context
        )
        
        logger.debug(f"Prompt length: {len(prompt)} characters")

        # Determine model format based on model ID
        is_nova = 'nova' in BEDROCK_MODEL_ID.lower()
        is_claude = 'claude' in BEDROCK_MODEL_ID.lower() or 'anthropic' in BEDROCK_MODEL_ID.lower()

        # Build request body based on model type
        if is_nova:
            # Amazon Nova format
            request_body = {
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"text": f"{SYSTEM_PROMPT}\n\n{prompt}"}
                        ]
                    }
                ],
                "inferenceConfig": {
                    "max_new_tokens": 4000,
                    "temperature": 0.0
                }
            }
        elif is_claude:
            # Anthropic Claude format
            request_body = {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 4000,
                "temperature": 0.0,
                "system": SYSTEM_PROMPT,
                "messages": [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            }
        else:
            logger.error(f"Unsupported model type: {BEDROCK_MODEL_ID}")
            return None

        # Call Bedrock
        start_time = time.time()
        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps(request_body)
        )
        latency = time.time() - start_time
        
        # Parse response based on model type
        response_body = json.loads(response['body'].read())

        if is_nova:
            # Nova response format
            content = response_body['output']['message']['content'][0]['text']
        elif is_claude:
            # Claude response format
            content = response_body['content'][0]['text']
        else:
            logger.error("Unable to parse response - unknown model format")
            return None
        
        logger.info(f"Bedrock response received in {latency:.2f}s")
        logger.debug(f"Response: {content[:500]}...")
        
        # Clean markdown formatting if present
        content = content.strip()
        if content.startswith('```json'):
            content = content[7:]
        if content.startswith('```'):
            content = content[3:]
        if content.endswith('```'):
            content = content[:-3]
        content = content.strip()
        
        # Parse JSON
        analysis = json.loads(content)
        
        # Validate response format
        validate_response(analysis)
        
        # Add metadata (handle different response formats)
        metadata = {
            'model_id': BEDROCK_MODEL_ID,
            'latency_seconds': latency,
            'timestamp': datetime.utcnow().isoformat()
        }

        # Add token usage if available
        if is_claude and 'usage' in response_body:
            metadata['input_tokens'] = response_body['usage']['input_tokens']
            metadata['output_tokens'] = response_body['usage']['output_tokens']
        elif is_nova and 'usage' in response_body:
            metadata['input_tokens'] = response_body['usage']['inputTokens']
            metadata['output_tokens'] = response_body['usage']['outputTokens']

        analysis['_metadata'] = metadata
        
        return analysis
        
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Claude response as JSON: {e}")
        logger.error(f"Raw response: {content}")
        return None
    except Exception as e:
        logger.error(f"Error calling Bedrock: {e}", exc_info=True)
        return None


def create_fallback_analysis(
    error_logs: List[Dict],
    function_name: str,
    lambda_metadata: Dict
) -> Dict[str, Any]:
    """
    Create a basic analysis when Bedrock is unavailable.
    Detects OOM errors and suggests memory increase.
    """
    try:
        current_memory = lambda_metadata.get('memory_size', 512)

        # Check if logs contain OOM indicators
        oom_count = sum(1 for log in error_logs
                       if 'Runtime.OutOfMemory' in log.get('message', '')
                       or 'out of memory' in log.get('message', '').lower()
                       or 'OOM' in log.get('message', ''))

        if oom_count > 0:
            # Calculate recommended memory (50% increase)
            recommended_memory = min(int(current_memory * 1.5), 10240)
            # Round to nearest 64MB
            recommended_memory = round(recommended_memory / 64) * 64

            return {
                "root_cause": {
                    "summary": f"Lambda function out of memory - detected {oom_count} OOM errors in logs",
                    "category": "RESOURCE_EXHAUSTION",
                    "confidence": 0.90,  # High confidence for OOM detection
                    "technical_details": f"Function configured with {current_memory}MB exceeded memory limit. "
                                       f"Found {oom_count} Runtime.OutOfMemory errors."
                },
                "impact_assessment": {
                    "severity": "HIGH",
                    "user_impact": "Function invocations are failing",
                    "business_impact": "Service degradation"
                },
                "remediation_actions": [
                    {
                        "action_type": "LAMBDA_UPDATE",
                        "description": f"Increase Lambda memory from {current_memory}MB to {recommended_memory}MB",
                        "priority": 1,
                        "safety_risk": "LOW",
                        "estimated_fix_time": "Immediate (automated)",
                        "rollback_plan": f"Revert to {current_memory}MB if issues persist"
                    }
                ],
                "_metadata": {
                    "model_id": "fallback-rule-based",
                    "analysis_method": "pattern-matching",
                    "timestamp": datetime.utcnow().isoformat(),
                    "note": "AI analysis unavailable - using rule-based detection"
                }
            }
        else:
            # Generic error analysis
            return {
                "root_cause": {
                    "summary": f"Lambda function errors detected - {len(error_logs)} error entries found",
                    "category": "UNKNOWN",
                    "confidence": 0.50,
                    "technical_details": f"Found {len(error_logs)} error log entries"
                },
                "impact_assessment": {
                    "severity": "MEDIUM",
                    "user_impact": "Function may be experiencing issues",
                    "business_impact": "Potential service degradation"
                },
                "remediation_actions": [
                    {
                        "action_type": "MANUAL_REVIEW_REQUIRED",
                        "description": "Manual investigation needed - error type unclear",
                        "priority": 1,
                        "safety_risk": "NONE",
                        "estimated_fix_time": "Manual review required"
                    }
                ],
                "_metadata": {
                    "model_id": "fallback-rule-based",
                    "analysis_method": "basic-detection",
                    "timestamp": datetime.utcnow().isoformat(),
                    "note": "AI analysis unavailable - manual review recommended"
                }
            }
    except Exception as e:
        logger.error(f"Error in fallback analysis: {e}")
        return None


def should_auto_remediate(analysis: Dict[str, Any]) -> bool:
    """
    Determine if auto-remediation should proceed.
    
    Criteria:
    1. AUTO_REMEDIATE is enabled
    2. Confidence >= threshold
    3. At least one remediation action exists
    4. No high-risk actions
    """
    if not AUTO_REMEDIATE:
        logger.info("Auto-remediation is disabled")
        return False
    
    confidence = analysis.get('root_cause', {}).get('confidence', 0)
    if confidence < CONFIDENCE_THRESHOLD:
        logger.info(f"Confidence {confidence:.2%} below threshold {CONFIDENCE_THRESHOLD:.2%}")
        return False
    
    actions = analysis.get('remediation_actions', [])
    if not actions:
        logger.info("No remediation actions suggested")
        return False
    
    # Check for high-risk or manual-review actions
    for action in actions:
        if action.get('safety_risk', '').upper() == 'HIGH':
            logger.info("High-risk action detected - manual review required")
            return False
        if action.get('action_type', '') == 'MANUAL_REVIEW_REQUIRED':
            logger.info("Manual review required")
            return False
    
    logger.info("All criteria met for auto-remediation")
    return True


def convert_floats_to_decimal(obj):
    """
    Recursively convert float values to Decimal for DynamoDB compatibility.
    """
    if isinstance(obj, list):
        return [convert_floats_to_decimal(item) for item in obj]
    elif isinstance(obj, dict):
        return {k: convert_floats_to_decimal(v) for k, v in obj.items()}
    elif isinstance(obj, float):
        return Decimal(str(obj))
    else:
        return obj


def store_incident(
    incident_id: str,
    function_name: str,
    log_group: str,
    analysis: Dict,
    error_logs: List[Dict],
    lambda_metadata: Dict
) -> None:
    """Store incident analysis in DynamoDB."""
    try:
        # Calculate TTL (30 days from now)
        ttl = int((datetime.utcnow() + timedelta(days=30)).timestamp())
        
        item = {
            'incident_id': incident_id,
            'timestamp': int(datetime.utcnow().timestamp()),
            'function_name': function_name,
            'log_group': log_group,
            'error_type': analysis.get('root_cause', {}).get('category', 'Unknown'),
            'analysis': convert_floats_to_decimal(analysis),
            'error_log_count': len(error_logs),
            'lambda_metadata': convert_floats_to_decimal(lambda_metadata),
            'confidence': Decimal(str(analysis.get('root_cause', {}).get('confidence', 0))),
            'created_at': datetime.utcnow().isoformat(),
            'ttl': ttl
        }

        incidents_table.put_item(Item=item)
        logger.info(f"Stored incident {incident_id} in DynamoDB")
        
    except Exception as e:
        logger.error(f"Error storing incident: {e}", exc_info=True)


def send_notification(
    incident_id: str,
    function_name: str,
    analysis: Dict,
    will_remediate: bool
) -> None:
    """Send notification via SNS and Slack."""
    try:
        # Build notification message
        root_cause = analysis.get('root_cause', {})
        impact = analysis.get('impact_assessment', {})
        actions = analysis.get('remediation_actions', [])
        
        subject = f"🚨 AIOps Alert: {function_name}"
        if will_remediate:
            subject = f"✅ AIOps Auto-Fix: {function_name}"
        
        message = {
            'incident_id': incident_id,
            'function_name': function_name,
            'root_cause': root_cause.get('summary', 'Unknown'),
            'category': root_cause.get('category', 'Unknown'),
            'confidence': root_cause.get('confidence', 0),
            'severity': impact.get('severity', 'Unknown'),
            'auto_remediate': will_remediate,
            'actions': [a.get('description', '') for a in actions[:3]],
            'timestamp': datetime.utcnow().isoformat()
        }
        
        # Publish to SNS
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps(message, indent=2)
        )
        
        logger.info("Notification sent to SNS")
        
        send_slack_notification(
            subject=subject,
            incident_id=incident_id,
            function_name=function_name,
            analysis=analysis,
            will_remediate=will_remediate
        )
        
    except Exception as e:
        logger.error(f"Error sending notification: {e}", exc_info=True)


def get_slack_webhook_url() -> Optional[str]:
    """Fetch Slack webhook URL from Secrets Manager (cached)."""
    global _SLACK_WEBHOOK_URL
    if _SLACK_WEBHOOK_URL:
        return _SLACK_WEBHOOK_URL
    
    try:
        secret_value = secretsmanager.get_secret_value(
            SecretId=SLACK_WEBHOOK_SECRET
        )
        secret_string = secret_value.get('SecretString', '{}')
        secret = json.loads(secret_string)
        _SLACK_WEBHOOK_URL = secret.get('webhook_url')
        if not _SLACK_WEBHOOK_URL:
            logger.error("Slack webhook URL not found in secret payload")
        return _SLACK_WEBHOOK_URL
    except Exception as e:
        logger.error(f"Error retrieving Slack webhook secret: {e}")
        return None


def send_slack_notification(
    subject: str,
    incident_id: str,
    function_name: str,
    analysis: Dict,
    will_remediate: bool
) -> None:
    """Send nicely formatted Slack notification."""
    webhook_url = get_slack_webhook_url()
    if not webhook_url:
        return
    
    root_cause = analysis.get('root_cause', {})
    impact = analysis.get('impact_assessment', {})
    confidence = root_cause.get('confidence', 0)
    severity = impact.get('severity', 'Unknown')
    
    lines = [
        subject,
        f"*Incident:* `{incident_id}`",
        f"*Function:* `{function_name}`",
        f"*Root Cause:* {root_cause.get('summary', 'Unknown')}",
        f"*Category:* {root_cause.get('category', 'Unknown')}",
        f"*Severity:* {severity}",
        f"*Confidence:* {confidence:.0%}",
        f"*Auto-Remediate:* {'Yes' if will_remediate else 'No'}",
        f"*Timestamp:* {datetime.utcnow().isoformat()}",
    ]
    
    slack_payload = {
        "text": "\n".join(lines)
    }
    
    try:
        data = json.dumps(slack_payload).encode('utf-8')
        req = urllib_request.Request(
            url=webhook_url,
            data=data,
            headers={'Content-Type': 'application/json'}
        )
        urllib_request.urlopen(req, timeout=5)
        logger.info("Notification sent to Slack")
    except urllib_error.URLError as e:
        logger.error(f"Failed to send Slack notification: {e}")


def invoke_remediator(
    incident_id: str,
    function_name: str,
    analysis: Dict
) -> None:
    """Invoke the Remediator Lambda function."""
    try:
        payload = {
            'incident_id': incident_id,
            'function_name': function_name,
            'analysis': analysis,
            'source': 'analyzer'
        }
        
        response = lambda_client.invoke(
            FunctionName=REMEDIATOR_FUNCTION,
            InvocationType='Event',  # Async invocation
            Payload=json.dumps(payload)
        )
        
        logger.info(f"Remediator invoked. Status: {response['StatusCode']}")
        
    except Exception as e:
        logger.error(f"Error invoking remediator: {e}", exc_info=True)


def create_success_response(
    incident_id: str,
    message: str,
    analysis: Optional[Dict] = None,
    auto_remediate: bool = False
) -> Dict[str, Any]:
    """Create success response."""
    return {
        'statusCode': 200,
        'body': json.dumps({
            'incident_id': incident_id,
            'message': message,
            'auto_remediate': auto_remediate,
            'analysis': analysis,
            'timestamp': datetime.utcnow().isoformat()
        })
    }


def create_error_response(error_message: str) -> Dict[str, Any]:
    """Create error response."""
    return {
        'statusCode': 500,
        'body': json.dumps({
            'error': error_message,
            'timestamp': datetime.utcnow().isoformat()
        })
    }
