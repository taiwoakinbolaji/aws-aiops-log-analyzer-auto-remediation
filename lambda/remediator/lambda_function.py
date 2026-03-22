"""
Remediator Lambda Function - Auto-Remediation Executor
=======================================================

This Lambda function executes approved remediation actions for Lambda OOM errors.
It receives instructions from the Analyzer Lambda and performs the actual fixes.

Primary Actions:
- Update Lambda function memory size
- Verify the fix was applied
- Update incident records
- Send completion notifications

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
import logging
from urllib import request as urllib_request
from urllib import error as urllib_error

# Configure logging
log_level = os.environ.get('LOG_LEVEL', 'INFO')
logger = logging.getLogger()
logger.setLevel(getattr(logging, log_level))

# AWS Clients
lambda_client = boto3.client('lambda')
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')
secretsmanager = boto3.client('secretsmanager')

# Environment Variables
INCIDENTS_TABLE = os.environ['INCIDENTS_TABLE_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
DRY_RUN = os.environ.get('DRY_RUN', 'false').lower() == 'true'
MAX_MEMORY_MB = int(os.environ.get('MAX_MEMORY_MB', '3008'))
MIN_MEMORY_MB = int(os.environ.get('MIN_MEMORY_MB', '128'))
MEMORY_INCREMENT_MB = int(os.environ.get('MEMORY_INCREMENT_MB', '256'))
SLACK_WEBHOOK_SECRET = os.environ['SLACK_WEBHOOK_SECRET']
_SLACK_WEBHOOK_URL: Optional[str] = None

# DynamoDB table
incidents_table = dynamodb.Table(INCIDENTS_TABLE)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler - executes remediation actions.
    
    Event format (from Analyzer Lambda):
    {
        "incident_id": "inc-1234567890-my-function",
        "function_name": "my-lambda-function",
        "analysis": {
            "root_cause": {...},
            "remediation_actions": [...]
        },
        "source": "analyzer"
    }
    """
    logger.info(f"Received remediation request: {json.dumps(event)}")
    
    try:
        # Extract event data
        incident_id = event.get('incident_id')
        function_name = event.get('function_name')
        analysis = event.get('analysis', {})
        
        if not incident_id or not function_name:
            logger.error("Missing required fields: incident_id or function_name")
            return create_error_response("Missing required fields")
        
        logger.info(f"Processing remediation for incident: {incident_id}")
        logger.info(f"Target function: {function_name}")
        
        # Get current function configuration
        current_config = get_function_config(function_name)
        if not current_config:
            logger.error(f"Could not retrieve config for {function_name}")
            return create_error_response("Function not found")
        
        current_memory = current_config['MemorySize']
        logger.info(f"Current memory: {current_memory} MB")
        
        # Extract remediation actions
        actions = analysis.get('remediation_actions', [])
        if not actions:
            logger.warning("No remediation actions found in analysis")
            return create_success_response(incident_id, "No actions to execute")
        
        # Filter for Lambda update actions
        lambda_updates = [
            action for action in actions 
            if action.get('action_type') == 'LAMBDA_UPDATE'
        ]
        
        if not lambda_updates:
            logger.info("No LAMBDA_UPDATE actions found")
            return create_success_response(incident_id, "No Lambda updates needed")
        
        # Execute remediation
        results = []
        for action in lambda_updates:
            logger.info(f"Executing action: {action.get('description', 'Unknown')}")
            
            result = execute_memory_update(
                function_name=function_name,
                current_memory=current_memory,
                action=action,
                incident_id=incident_id
            )
            
            results.append(result)
        
        # Update incident record with remediation results
        update_incident_record(incident_id, results)
        
        # Send notification
        send_completion_notification(
            incident_id=incident_id,
            function_name=function_name,
            results=results
        )
        
        # Determine overall success
        all_successful = all(r['success'] for r in results)
        
        return create_success_response(
            incident_id=incident_id,
            message="Remediation completed",
            results=results,
            success=all_successful
        )
        
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}", exc_info=True)
        
        # Try to update incident with failure
        try:
            if incident_id:
                update_incident_record(incident_id, [{
                    'success': False,
                    'error': str(e)
                }])
        except:
            pass
        
        return create_error_response(str(e))


def get_function_config(function_name: str) -> Optional[Dict[str, Any]]:
    """
    Get current Lambda function configuration.
    """
    try:
        response = lambda_client.get_function_configuration(
            FunctionName=function_name
        )
        
        logger.info(f"Retrieved config for {function_name}")
        logger.debug(f"Memory: {response['MemorySize']} MB, Timeout: {response['Timeout']}s")
        
        return response
        
    except lambda_client.exceptions.ResourceNotFoundException:
        logger.error(f"Lambda function not found: {function_name}")
        return None
    except Exception as e:
        logger.error(f"Error getting function config: {e}", exc_info=True)
        return None


def execute_memory_update(
    function_name: str,
    current_memory: int,
    action: Dict[str, Any],
    incident_id: str
) -> Dict[str, Any]:
    """
    Execute memory size update for Lambda function.
    
    Returns:
        Result dict with success status and details
    """
    try:
        # Calculate new memory size
        new_memory = calculate_new_memory(
            current_memory=current_memory,
            action=action
        )
        
        if not new_memory:
            return {
                'success': False,
                'action': action.get('description', 'Memory update'),
                'error': 'Could not calculate new memory size',
                'current_memory': current_memory
            }
        
        # Validate new memory size
        if new_memory < MIN_MEMORY_MB:
            logger.warning(f"New memory {new_memory} MB is below min {MIN_MEMORY_MB} MB")
            return {
                'success': False,
                'action': action.get('description', 'Memory update'),
                'error': f'Below minimum allowed memory ({MIN_MEMORY_MB} MB)',
                'current_memory': current_memory,
                'requested_memory': new_memory
            }

        if new_memory > MAX_MEMORY_MB:
            logger.warning(f"New memory {new_memory} MB exceeds max {MAX_MEMORY_MB} MB")
            return {
                'success': False,
                'action': action.get('description', 'Memory update'),
                'error': f'Exceeds maximum allowed memory ({MAX_MEMORY_MB} MB)',
                'current_memory': current_memory,
                'requested_memory': new_memory
            }
        
        if new_memory == current_memory:
            logger.info(f"Memory already at target size: {new_memory} MB")
            return {
                'success': True,
                'action': action.get('description', 'Memory update'),
                'message': 'Already at target memory size',
                'current_memory': current_memory,
                'new_memory': new_memory
            }
        
        logger.info(f"Updating memory: {current_memory} MB → {new_memory} MB")
        
        # DRY RUN MODE - Don't actually update
        if DRY_RUN:
            logger.warning("DRY RUN MODE - Skipping actual update")
            return {
                'success': True,
                'action': action.get('description', 'Memory update'),
                'message': 'Dry run - no actual changes made',
                'current_memory': current_memory,
                'new_memory': new_memory,
                'dry_run': True
            }
        
        # Execute the update
        response = lambda_client.update_function_configuration(
            FunctionName=function_name,
            MemorySize=new_memory
        )
        
        logger.info(f"Memory update successful: {function_name} → {new_memory} MB")
        logger.info(f"Last modified: {response['LastModified']}")
        
        # Wait for update to complete
        wait_for_update(function_name, max_wait_seconds=30)
        
        # Verify the update
        updated_config = get_function_config(function_name)
        actual_memory = updated_config['MemorySize'] if updated_config else None
        
        if actual_memory == new_memory:
            logger.info(f"Verified: Memory successfully updated to {new_memory} MB")
        else:
            logger.warning(f"Verification mismatch: Expected {new_memory}, got {actual_memory}")
        
        return {
            'success': True,
            'action': action.get('description', 'Memory update'),
            'message': 'Memory updated successfully',
            'current_memory': current_memory,
            'new_memory': new_memory,
            'verified_memory': actual_memory,
            'timestamp': datetime.utcnow().isoformat()
        }
        
    except lambda_client.exceptions.ResourceNotFoundException:
        logger.error(f"Lambda function not found: {function_name}")
        return {
            'success': False,
            'action': action.get('description', 'Memory update'),
            'error': 'Lambda function not found',
            'current_memory': current_memory
        }
    
    except lambda_client.exceptions.ResourceConflictException:
        logger.error(f"Function update already in progress: {function_name}")
        return {
            'success': False,
            'action': action.get('description', 'Memory update'),
            'error': 'Function update already in progress',
            'current_memory': current_memory
        }
    
    except lambda_client.exceptions.InvalidParameterValueException as e:
        logger.error(f"Invalid parameter: {e}")
        return {
            'success': False,
            'action': action.get('description', 'Memory update'),
            'error': f'Invalid parameter: {str(e)}',
            'current_memory': current_memory
        }
    
    except Exception as e:
        logger.error(f"Error updating memory: {e}", exc_info=True)
        return {
            'success': False,
            'action': action.get('description', 'Memory update'),
            'error': str(e),
            'current_memory': current_memory
        }


def calculate_new_memory(current_memory: int, action: Dict[str, Any]) -> Optional[int]:
    """
    Calculate the new memory size based on current memory and action.
    
    Strategies:
    1. Parse from action description (e.g., "Increase to 768MB")
    2. Use incremental increase (current + MEMORY_INCREMENT_MB)
    3. Smart calculation based on current size
    """
    try:
        description = action.get('description', '').lower()
        
        # Strategy 1: Parse target memory from description
        # Look for patterns like "768MB", "1024 MB", "increase to 768"
        import re
        
        # Pattern: number followed by optional space and "mb"
        # For "from 512MB to 768MB", take the LAST match (target)
        matches = re.findall(r'(\d+)\s*mb', description, re.IGNORECASE)
        if matches:
            target_memory = int(matches[-1])  # Take last match (target, not source)
            logger.info(f"Extracted target memory from description: {target_memory} MB")
            return target_memory
        
        # Pattern: "increase to X" or "set to X"
        matches = re.findall(r'(?:increase|set|change)\s+to\s+(\d+)', description, re.IGNORECASE)
        if matches:
            target_memory = int(matches[0])
            logger.info(f"Extracted target memory from description: {target_memory} MB")
            return target_memory
        
        # Strategy 2: Incremental increase
        # Use smart sizing based on current memory
        if current_memory <= 512:
            # Small functions: increase by 50%
            new_memory = int(current_memory * 1.5)
        elif current_memory <= 1024:
            # Medium functions: increase by 256MB
            new_memory = current_memory + MEMORY_INCREMENT_MB
        else:
            # Large functions: increase by 512MB
            new_memory = current_memory + 512
        
        # Round to nearest 64MB (AWS Lambda memory granularity)
        new_memory = round(new_memory / 64) * 64
        
        # Ensure minimum increase of 128MB
        if new_memory - current_memory < 128:
            new_memory = current_memory + 128
        
        logger.info(f"Calculated new memory using smart sizing: {new_memory} MB")
        return new_memory
        
    except Exception as e:
        logger.error(f"Error calculating new memory: {e}")
        # Fallback: simple increment
        return current_memory + MEMORY_INCREMENT_MB


def wait_for_update(function_name: str, max_wait_seconds: int = 30) -> bool:
    """
    Wait for Lambda function update to complete.
    
    Returns:
        True if update completed, False if timeout
    """
    try:
        logger.info(f"Waiting for function update to complete (max {max_wait_seconds}s)...")
        
        start_time = time.time()
        while time.time() - start_time < max_wait_seconds:
            try:
                config = lambda_client.get_function_configuration(
                    FunctionName=function_name
                )
                
                state = config.get('State', 'Unknown')
                last_update_status = config.get('LastUpdateStatus', 'Unknown')
                
                logger.debug(f"State: {state}, LastUpdateStatus: {last_update_status}")
                
                if state == 'Active' and last_update_status == 'Successful':
                    logger.info("Function update completed successfully")
                    return True
                
                if last_update_status == 'Failed':
                    logger.error("Function update failed")
                    return False
                
                # Still updating, wait and retry
                time.sleep(2)
                
            except Exception as e:
                logger.warning(f"Error checking update status: {e}")
                time.sleep(2)
        
        logger.warning(f"Timeout waiting for function update ({max_wait_seconds}s)")
        return False
        
    except Exception as e:
        logger.error(f"Error in wait_for_update: {e}")
        return False


def update_incident_record(incident_id: str, results: List[Dict]) -> None:
    """
    Update incident record in DynamoDB with remediation results.
    """
    try:
        # Calculate overall success
        all_successful = all(r.get('success', False) for r in results)

        # The incidents table uses a composite key: incident_id + timestamp.
        # Query the item first so we can update the exact record created by the analyzer.
        query_response = incidents_table.query(
            KeyConditionExpression='incident_id = :iid',
            ExpressionAttributeValues={':iid': incident_id},
            Limit=1
        )
        items = query_response.get('Items', [])
        if not items:
            logger.warning(f"No incident record found for {incident_id}")
            return

        incident_timestamp = items[0]['timestamp']
        
        # Update incident
        incidents_table.update_item(
            Key={'incident_id': incident_id, 'timestamp': incident_timestamp},
            UpdateExpression='SET remediation_status = :status, remediation_results = :results, remediation_timestamp = :ts',
            ExpressionAttributeValues={
                ':status': 'SUCCESS' if all_successful else 'FAILED',
                ':results': results,
                ':ts': int(datetime.utcnow().timestamp())
            }
        )
        
        logger.info(f"Updated incident {incident_id} with remediation results")
        
    except Exception as e:
        logger.error(f"Error updating incident record: {e}", exc_info=True)


def send_completion_notification(
    incident_id: str,
    function_name: str,
    results: List[Dict]
) -> None:
    """
    Send notification about remediation completion.
    """
    try:
        all_successful = all(r.get('success', False) for r in results)
        
        subject = f"✅ AIOps Remediation Complete: {function_name}" if all_successful else f"❌ AIOps Remediation Failed: {function_name}"
        
        # Build message
        message_parts = [
            f"Incident ID: {incident_id}",
            f"Function: {function_name}",
            f"Status: {'SUCCESS' if all_successful else 'FAILED'}",
            f"Timestamp: {datetime.utcnow().isoformat()}",
            "",
            "Actions Executed:"
        ]
        
        for i, result in enumerate(results, 1):
            status_icon = "✅" if result.get('success') else "❌"
            action_desc = result.get('action', 'Unknown action')
            message_parts.append(f"{i}. {status_icon} {action_desc}")
            
            if result.get('success'):
                if 'new_memory' in result:
                    message_parts.append(f"   Memory: {result.get('current_memory')} MB → {result.get('new_memory')} MB")
            else:
                error = result.get('error', 'Unknown error')
                message_parts.append(f"   Error: {error}")
        
        if DRY_RUN:
            message_parts.append("")
            message_parts.append("⚠️  DRY RUN MODE - No actual changes were made")
        
        message = "\n".join(message_parts)
        
        # Publish to SNS
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message
        )
        
        logger.info("Completion notification sent to SNS")
        
        send_slack_completion_notification(
            subject=subject,
            incident_id=incident_id,
            function_name=function_name,
            results=results
        )
        
    except Exception as e:
        logger.error(f"Error sending notification: {e}", exc_info=True)


def create_success_response(
    incident_id: str,
    message: str,
    results: Optional[List[Dict]] = None,
    success: bool = True
) -> Dict[str, Any]:
    """Create success response."""
    return {
        'statusCode': 200,
        'body': json.dumps({
            'incident_id': incident_id,
            'message': message,
            'success': success,
            'results': results or [],
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


def send_slack_completion_notification(
    subject: str,
    incident_id: str,
    function_name: str,
    results: List[Dict]
) -> None:
    """Send remediation completion message to Slack."""
    webhook_url = get_slack_webhook_url()
    if not webhook_url:
        return
    
    all_successful = all(r.get('success', False) for r in results)
    lines = [
        subject,
        f"*Incident:* `{incident_id}`",
        f"*Function:* `{function_name}`",
        f"*Status:* {'SUCCESS' if all_successful else 'FAILED'}",
        f"*Timestamp:* {datetime.utcnow().isoformat()}",
        "",
        "*Actions:*"
    ]
    
    for result in results:
        status_icon = "✅" if result.get('success') else "❌"
        action_desc = result.get('action', 'Memory update')
        details = []
        if result.get('success') and 'new_memory' in result:
            details.append(f"{result.get('current_memory')}MB → {result.get('new_memory')}MB")
        if not result.get('success'):
            details.append(result.get('error', 'Unknown error'))
        detail_str = f" ({'; '.join(details)})" if details else ""
        lines.append(f"{status_icon} {action_desc}{detail_str}")
    
    if DRY_RUN:
        lines.append("")
        lines.append("⚠️  DRY RUN MODE - No changes applied")
    
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
        logger.info("Remediation notification sent to Slack")
    except urllib_error.URLError as e:
        logger.error(f"Failed to send Slack remediation notification: {e}")
