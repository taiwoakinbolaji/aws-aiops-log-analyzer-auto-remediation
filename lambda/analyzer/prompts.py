"""
Prompt Templates for Claude 3.5 Sonnet Analysis
================================================

This module contains the prompt engineering logic for analyzing
AWS Lambda errors using Claude via Amazon Bedrock.

Key principles:
- Clear, structured prompts
- JSON output format with schema validation
- Context-rich analysis
- Safety-aware recommendations
"""

import json
from typing import Dict, List, Optional, Any
from jsonschema import validate, ValidationError

# ============================================================================
# SYSTEM PROMPT - Defines Claude's Role and Behavior
# ============================================================================

SYSTEM_PROMPT = """You are an expert DevOps/SRE AI assistant specializing in AWS Lambda error analysis and automated remediation.

Your responsibilities:
1. Analyze Lambda function error logs to identify root causes
2. Provide confident, evidence-based diagnosis
3. Recommend safe, actionable remediation steps
4. Assess the safety risk of each remediation action

Guidelines:
- Be precise and specific - avoid generic responses
- Base confidence scores on concrete evidence from logs
- Prioritize non-disruptive remediation actions
- Consider Lambda memory limits, timeout constraints, and dependencies
- For OOM errors: analyze memory growth patterns and recommend appropriate increases
- For permission errors: NEVER recommend auto-remediation (security risk)
- Always respond in valid JSON format matching the provided schema

Context awareness:
- You have access to recent error logs (last 15 minutes)
- You may have historical incident data for pattern matching
- Target is AWS Lambda functions in production
- Safety is critical - when uncertain, recommend manual review

Response requirements:
- Root cause must be specific (not "check logs" or "investigate further")
- Confidence scores must honestly reflect uncertainty
- Remediation actions must be executable via AWS Lambda API
- Include clear reasoning for transparency"""


# ============================================================================
# PROMPT BUILDER - Creates Context-Rich Analysis Prompts
# ============================================================================

def build_analysis_prompt(
    error_logs: List[Dict],
    log_group: str,
    function_name: str,
    lambda_metadata: Dict,
    historical_context: Optional[Dict] = None
) -> str:
    """
    Build a comprehensive prompt for Claude analysis.
    
    Args:
        error_logs: List of error log entries
        log_group: CloudWatch log group name
        function_name: Lambda function name
        lambda_metadata: Function configuration (memory, timeout, etc.)
        historical_context: Past similar incidents
        
    Returns:
        Formatted prompt string
    """
    
    # Format logs for readability
    formatted_logs = format_logs(error_logs)
    
    # Build prompt
    prompt = f"""Analyze the following AWS Lambda error logs and provide root cause analysis.

## Incident Context

**Lambda Function:** {function_name}
**Log Group:** {log_group}
**Error Count:** {len(error_logs)} errors in last 15 minutes
**Time Window:** {error_logs[0]['timestamp']} to {error_logs[-1]['timestamp']}

**Function Configuration:**
- Memory Size: {lambda_metadata.get('memory_size', 'unknown')} MB
- Timeout: {lambda_metadata.get('timeout', 'unknown')} seconds
- Runtime: {lambda_metadata.get('runtime', 'unknown')}
- Handler: {lambda_metadata.get('handler', 'unknown')}

## Error Logs

```
{formatted_logs}
```
"""

    # Add historical context if available
    if historical_context:
        prompt += f"""
## Historical Context

This function has experienced **{historical_context['total_incidents']} similar incidents** in the past 30 days.

**Most Recent Incident:**
- Root Cause: {historical_context['most_recent']['root_cause']}
- Confidence: {historical_context['most_recent']['confidence']:.0%}
- Remediation Successful: {historical_context['most_recent']['remediation_successful']}

**Common Patterns:** {historical_context['patterns']}
"""

    # Add specific guidance based on log patterns
    if contains_oom_pattern(error_logs):
        prompt += OOM_ANALYSIS_GUIDE
    elif contains_timeout_pattern(error_logs):
        prompt += TIMEOUT_ANALYSIS_GUIDE
    elif contains_permission_pattern(error_logs):
        prompt += PERMISSION_ANALYSIS_GUIDE

    # Add output format requirements
    prompt += """

## Required Analysis Format

Respond with a JSON object matching this EXACT structure:

{
  "root_cause": {
    "summary": "Brief 1-2 sentence description of the root cause",
    "category": "OOM|Timeout|PermissionError|DependencyFailure|ResourceExhaustion|ConfigError|CodeBug",
    "confidence": 0.0-1.0,
    "evidence": [
      "Specific log line or pattern supporting this conclusion",
      "Another piece of evidence"
    ],
    "reasoning": "Step-by-step explanation of how you reached this conclusion"
  },
  "impact_assessment": {
    "severity": "Critical|High|Medium|Low",
    "affected_users": "Estimated number or percentage of affected users",
    "business_impact": "Description of business impact"
  },
  "remediation_actions": [
    {
      "action_type": "LAMBDA_UPDATE|SSM_RUN_COMMAND|SCALE_OUT|RESTART|MANUAL_REVIEW_REQUIRED",
      "description": "Clear description of what this action does",
      "target": "Lambda function ARN or resource identifier",
      "command": "Specific AWS API call or command",
      "priority": 1-5,
      "safety_risk": "Low|Medium|High",
      "estimated_duration": "Time estimate (e.g., '30 seconds', '2 minutes')",
      "success_criteria": "How to verify the fix worked"
    }
  ],
  "preventive_measures": [
    "Long-term fix to prevent recurrence",
    "Another preventive measure"
  ]
}

## Critical Instructions

1. **Be specific** - Root cause must identify the actual problem, not symptoms
2. **Evidence-based** - Confidence scores must reflect the strength of evidence in logs
3. **Safety first** - If uncertain or risky, set safety_risk="High" or use MANUAL_REVIEW_REQUIRED
4. **Actionable** - Remediation commands must be executable via AWS APIs
5. **JSON only** - Output ONLY the JSON object, no markdown formatting, no explanations outside JSON

Analyze the logs now and provide your response as valid JSON."""

    return prompt


def format_logs(logs: List[Dict]) -> str:
    """Format logs for display in prompt."""
    formatted = []
    for i, log in enumerate(logs, 1):
        timestamp = log['timestamp']
        message = log['message'][:500]  # Truncate very long messages
        formatted.append(f"[{i}] {timestamp} | {message}")
    
    return "\n".join(formatted)


def contains_oom_pattern(logs: List[Dict]) -> bool:
    """Check if logs contain OOM error patterns."""
    oom_keywords = ['out of memory', 'oom', 'memory exhausted', 'malloc failed', 'cannot allocate']
    log_text = ' '.join([log['message'].lower() for log in logs])
    return any(keyword in log_text for keyword in oom_keywords)


def contains_timeout_pattern(logs: List[Dict]) -> bool:
    """Check if logs contain timeout patterns."""
    timeout_keywords = ['timeout', 'timed out', 'task timed out', 'deadline exceeded']
    log_text = ' '.join([log['message'].lower() for log in logs])
    return any(keyword in log_text for keyword in timeout_keywords)


def contains_permission_pattern(logs: List[Dict]) -> bool:
    """Check if logs contain permission error patterns."""
    permission_keywords = ['access denied', 'permission', 'unauthorized', 'forbidden', 'iam']
    log_text = ' '.join([log['message'].lower() for log in logs])
    return any(keyword in log_text for keyword in permission_keywords)


# ============================================================================
# ERROR-SPECIFIC GUIDANCE
# ============================================================================

OOM_ANALYSIS_GUIDE = """

### OOM Analysis Guidelines

When analyzing Out of Memory errors:

1. **Check Memory Growth Pattern:**
   - Gradual increase → Memory leak (objects not garbage collected)
   - Sudden spike → Large data processing without chunking
   - Consistent maxing out → Undersized memory allocation

2. **Evidence to Look For:**
   - "Memory Size: X MB, Max Memory Used: X MB" → Hard limit reached
   - Stack traces showing large object allocations
   - Repeated errors at similar memory usage levels

3. **Recommended Actions (in order):**
   - **Immediate:** Increase Lambda memory (if current < 1GB)
   - **Short-term:** Implement pagination or streaming
   - **Long-term:** Fix memory leak, optimize data structures

4. **Memory Sizing Logic:**
   - If maxed at 512MB: increase to 768MB or 1024MB
   - If maxed at 1024MB: increase to 1536MB
   - Never exceed 3008MB without investigating code
   - Consider peak usage + 30% buffer

5. **Safety Assessment:**
   - Memory increase: Low risk (safe to auto-remediate)
   - Code changes: High risk (manual review required)
"""

TIMEOUT_ANALYSIS_GUIDE = """

### Timeout Analysis Guidelines

When analyzing timeout errors:

1. **Identify Timeout Source:**
   - Lambda execution timeout → Check duration vs configured timeout
   - External API timeout → Look for HTTP client errors
   - Database query timeout → Check connection pool logs

2. **Root Cause Patterns:**
   - Cold start delays → Provisioned concurrency needed
   - Slow external API → Increase timeout + add retry logic
   - Database query → Optimize query or add caching
   - Infinite loop → Code bug, manual review required

3. **Recommended Actions:**
   - If external dependency slow: Increase timeout + circuit breaker
   - If cold start: Enable provisioned concurrency
   - If database slow: Add caching layer
   - If consistent timeout: Optimize code (manual)

4. **Safety Assessment:**
   - Increasing timeout: Medium risk (may hide underlying issues)
   - Adding retry logic: Low risk
   - Code optimization: High risk (manual review)
"""

PERMISSION_ANALYSIS_GUIDE = """

### Permission Error Analysis Guidelines

When analyzing permission/access errors:

1. **Identify Resource and Action:**
   - What resource? (S3 bucket, DynamoDB table, etc.)
   - What action? (GetObject, PutItem, etc.)
   - What identity? (Lambda execution role)

2. **Common Causes:**
   - Missing IAM policy statement
   - Resource policy blocking access
   - Wrong resource ARN in policy
   - KMS key policy issue

3. **CRITICAL - Never Auto-Remediate:**
   - Set action_type: "MANUAL_REVIEW_REQUIRED"
   - Set safety_risk: "High"
   - Provide specific IAM policy to add
   - Explain security implications

4. **Response Format:**
   ```json
   {
     "action_type": "MANUAL_REVIEW_REQUIRED",
     "description": "Add S3 GetObject permission to Lambda role",
     "safety_risk": "High",
     "command": "See IAM policy recommendation in preventive_measures"
   }
   ```
"""


# ============================================================================
# RESPONSE VALIDATION
# ============================================================================

RESPONSE_SCHEMA = {
    "type": "object",
    "required": ["root_cause", "impact_assessment", "remediation_actions"],
    "properties": {
        "root_cause": {
            "type": "object",
            "required": ["summary", "category", "confidence", "evidence", "reasoning"],
            "properties": {
                "summary": {"type": "string", "minLength": 10},
                "category": {
                    "type": "string",
                    "enum": ["OOM", "Timeout", "PermissionError", "DependencyFailure",
                            "ResourceExhaustion", "ConfigError", "CodeBug"]
                },
                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                "evidence": {
                    "type": "array",
                    "items": {"type": "string"},
                    "minItems": 1
                },
                "reasoning": {"type": "string", "minLength": 20}
            }
        },
        "impact_assessment": {
            "type": "object",
            "required": ["severity", "affected_users", "business_impact"],
            "properties": {
                "severity": {
                    "type": "string",
                    "enum": ["Critical", "High", "Medium", "Low"]
                },
                "affected_users": {"type": "string"},
                "business_impact": {"type": "string"}
            }
        },
        "remediation_actions": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["action_type", "description", "priority", "safety_risk"],
                "properties": {
                    "action_type": {"type": "string"},
                    "description": {"type": "string"},
                    "target": {"type": "string"},
                    "command": {"type": "string"},
                    "priority": {"type": "integer", "minimum": 1, "maximum": 5},
                    "safety_risk": {
                        "type": "string",
                        "enum": ["Low", "Medium", "High"]
                    },
                    "estimated_duration": {"type": "string"},
                    "success_criteria": {"type": "string"}
                }
            }
        },
        "preventive_measures": {
            "type": "array",
            "items": {"type": "string"}
        }
    }
}


def validate_response(response: Dict[str, Any]) -> None:
    """
    Validate Claude response against schema.
    
    Raises:
        ValidationError: If response doesn't match schema
    """
    try:
        validate(instance=response, schema=RESPONSE_SCHEMA)
    except ValidationError as e:
        raise ValueError(f"Invalid response format: {e.message}")
