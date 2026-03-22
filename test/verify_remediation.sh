#!/bin/bash

# ============================================================================
# Verify Remediation Script - Check if Auto-Remediation Worked
# ============================================================================
# This script verifies that the AIOps system successfully remediated
# the OOM errors by checking if Lambda memory was increased.
#
# Usage: ./verify_remediation.sh [function-name] [expected-min-memory]
# ============================================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FUNCTION_NAME=${1:-"aiops-log-analyzer-dev-demo-app"}
EXPECTED_MIN_MEMORY=${2:-768}  # Should be increased from 512
REGION=${AWS_REGION:-"us-east-1"}
INCIDENTS_TABLE=${3:-"aiops-log-analyzer-dev-incidents"}

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Verify Remediation Script${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo "Function: $FUNCTION_NAME"
echo "Expected Min Memory: ${EXPECTED_MIN_MEMORY}MB"
echo "Region: $REGION"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

HAS_JQ=false
if command -v jq &> /dev/null; then
    HAS_JQ=true
fi

echo -e "${YELLOW}Step 1: Checking Lambda Configuration${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get current Lambda configuration
if ! LAMBDA_CONFIG=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" 2>&1); then
    echo -e "${RED}❌ Failed to get function configuration${NC}"
    echo "$LAMBDA_CONFIG"
    exit 1
fi

CURRENT_MEMORY=$(echo "$LAMBDA_CONFIG" | jq -r '.MemorySize' 2>/dev/null || \
    echo "$LAMBDA_CONFIG" | grep -oP 'MemorySize[": ]+\K\d+')
LAST_MODIFIED=$(echo "$LAMBDA_CONFIG" | jq -r '.LastModified' 2>/dev/null || \
    echo "$LAMBDA_CONFIG" | grep -oP 'LastModified[": ]+\K[^"]+')
FUNCTION_STATE=$(echo "$LAMBDA_CONFIG" | jq -r '.State' 2>/dev/null || echo "Unknown")

echo "Current Memory: ${CURRENT_MEMORY}MB"
echo "Last Modified: $LAST_MODIFIED"
echo "State: $FUNCTION_STATE"
echo ""

# Check if memory was increased
if [ "$CURRENT_MEMORY" -ge "$EXPECTED_MIN_MEMORY" ]; then
    echo -e "${GREEN}✓ Memory increased successfully!${NC}"
    echo "  Expected: ≥${EXPECTED_MIN_MEMORY}MB"
    echo "  Actual: ${CURRENT_MEMORY}MB"
    REMEDIATION_SUCCESS=true
else
    echo -e "${RED}✗ Memory not increased${NC}"
    echo "  Expected: ≥${EXPECTED_MIN_MEMORY}MB"
    echo "  Actual: ${CURRENT_MEMORY}MB"
    REMEDIATION_SUCCESS=false
fi

echo ""
echo -e "${YELLOW}Step 2: Checking CloudWatch Alarm${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ALARM_NAME="aiops-log-analyzer-dev-oom-$FUNCTION_NAME"

if ALARM_STATUS=$(aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" \
    --region "$REGION" 2>&1); then
    
    ALARM_STATE=$(echo "$ALARM_STATUS" | jq -r '.MetricAlarms[0].StateValue' 2>/dev/null || echo "Unknown")
    STATE_REASON=$(echo "$ALARM_STATUS" | jq -r '.MetricAlarms[0].StateReason' 2>/dev/null || echo "Unknown")
    STATE_UPDATED=$(echo "$ALARM_STATUS" | jq -r '.MetricAlarms[0].StateUpdatedTimestamp' 2>/dev/null || echo "Unknown")
    
    echo "Alarm: $ALARM_NAME"
    echo "State: $ALARM_STATE"
    echo "Reason: $STATE_REASON"
    echo "Updated: $STATE_UPDATED"
    
    if [ "$ALARM_STATE" = "ALARM" ]; then
        echo -e "${GREEN}✓ Alarm triggered (as expected)${NC}"
    elif [ "$ALARM_STATE" = "OK" ]; then
        echo -e "${YELLOW}⚠ Alarm in OK state (errors may have been resolved)${NC}"
    else
        echo -e "${YELLOW}⚠ Alarm state: $ALARM_STATE${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Could not retrieve alarm status${NC}"
    echo "$ALARM_STATUS"
fi

echo ""
echo -e "${YELLOW}Step 3: Checking DynamoDB Incidents${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Query DynamoDB for recent incidents
if INCIDENTS=$(aws dynamodb scan \
    --table-name "$INCIDENTS_TABLE" \
    --filter-expression "function_name = :fn" \
    --expression-attribute-values "{\":fn\":{\"S\":\"$FUNCTION_NAME\"}}" \
    --region "$REGION" \
    --max-items 5 2>&1); then
    
    INCIDENT_COUNT=$(echo "$INCIDENTS" | jq '.Items | length' 2>/dev/null || echo "0")
    
    if [ "$INCIDENT_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found $INCIDENT_COUNT incident(s) in DynamoDB${NC}"
        echo ""
        
        # Show most recent incident
        if [ "$HAS_JQ" = true ]; then
            echo "Most Recent Incident:"
            LATEST_INCIDENT=$(echo "$INCIDENTS" | jq -r '.Items[0]')
            
            INCIDENT_ID=$(echo "$LATEST_INCIDENT" | jq -r '.incident_id.S // "N/A"')
            ERROR_TYPE=$(echo "$LATEST_INCIDENT" | jq -r '.error_type.S // "N/A"')
            CONFIDENCE=$(echo "$LATEST_INCIDENT" | jq -r '.confidence.N // "N/A"')
            REMEDIATION_STATUS=$(echo "$LATEST_INCIDENT" | jq -r '.remediation_status.S // "N/A"')
            CREATED_AT=$(echo "$LATEST_INCIDENT" | jq -r '.created_at.S // "N/A"')
            
            echo "  ID: $INCIDENT_ID"
            echo "  Type: $ERROR_TYPE"
            echo "  Confidence: $CONFIDENCE"
            echo "  Remediation: $REMEDIATION_STATUS"
            echo "  Created: $CREATED_AT"
            
            if [ "$REMEDIATION_STATUS" = "SUCCESS" ]; then
                echo -e "  ${GREEN}✓ Remediation successful${NC}"
                
                # Try to get remediation details
                RESULTS=$(echo "$LATEST_INCIDENT" | jq -r '.remediation_results.L[0].M // empty')
                if [ -n "$RESULTS" ]; then
                    OLD_MEM=$(echo "$RESULTS" | jq -r '.current_memory.N // "N/A"')
                    NEW_MEM=$(echo "$RESULTS" | jq -r '.new_memory.N // "N/A"')
                    echo "  Memory Change: ${OLD_MEM}MB → ${NEW_MEM}MB"
                fi
            elif [ "$REMEDIATION_STATUS" = "FAILED" ]; then
                echo -e "  ${RED}✗ Remediation failed${NC}"
            elif [ "$REMEDIATION_STATUS" = "N/A" ]; then
                echo -e "  ${YELLOW}⚠ No remediation status (may still be processing)${NC}"
            fi
        else
            echo "$INCIDENTS" | grep -E "incident_id|error_type|confidence|remediation_status" | head -20
        fi
    else
        echo -e "${YELLOW}⚠ No incidents found in DynamoDB${NC}"
        echo "This could mean:"
        echo "  - Analyzer hasn't run yet"
        echo "  - Alarm hasn't triggered"
        echo "  - Incidents expired (30-day TTL)"
    fi
else
    echo -e "${YELLOW}⚠ Could not query DynamoDB${NC}"
    echo "$INCIDENTS"
fi

echo ""
echo -e "${YELLOW}Step 4: Checking Recent Lambda Invocations${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check CloudWatch Logs for recent errors
END_TIME=$(date +%s)000
START_TIME=$((END_TIME - 600000))  # Last 10 minutes

if RECENT_ERRORS=$(aws logs filter-log-events \
    --log-group-name "/aws/lambda/$FUNCTION_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --filter-pattern "ERROR" \
    --region "$REGION" \
    --max-items 10 2>&1); then
    
    ERROR_COUNT=$(echo "$RECENT_ERRORS" | jq '.events | length' 2>/dev/null || echo "0")
    
    echo "Recent Errors (last 10 min): $ERROR_COUNT"
    
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Still seeing errors${NC}"
        echo "  This could mean remediation didn't work or errors are from before fix"
    else
        echo -e "${GREEN}✓ No recent errors${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Could not query CloudWatch Logs${NC}"
fi

echo ""
echo -e "${YELLOW}Step 5: Testing Function${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Would you like to test the function now? (yes/no)"
read -p "> " TEST_NOW

if [ "$TEST_NOW" = "yes" ]; then
    echo ""
    echo "Testing with same payload that caused OOM..."
    
    TEMP_FILE=$(mktemp)
    trap "rm -f $TEMP_FILE" EXIT
    
    if aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload '{"pattern":"gradual","target_mb":600}' \
        --region "$REGION" \
        "$TEMP_FILE" 2>&1 | grep -q "200"; then
        
        if grep -q "errorMessage\|ERROR" "$TEMP_FILE"; then
            echo -e "${RED}✗ Function still failing with error${NC}"
            cat "$TEMP_FILE"
        else
            echo -e "${GREEN}✓ Function completed successfully!${NC}"
            cat "$TEMP_FILE" | jq . 2>/dev/null || cat "$TEMP_FILE"
        fi
    else
        echo -e "${RED}✗ Failed to invoke function${NC}"
    fi
fi

echo ""
echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""

# Overall assessment
PASS_COUNT=0
TOTAL_CHECKS=4

# Check 1: Memory increased
if [ "$REMEDIATION_SUCCESS" = true ]; then
    echo -e "${GREEN}✓${NC} Memory Configuration: ${CURRENT_MEMORY}MB (increased)"
    ((PASS_COUNT++))
else
    echo -e "${RED}✗${NC} Memory Configuration: ${CURRENT_MEMORY}MB (not increased)"
fi

# Check 2: Alarm triggered
if [ "$ALARM_STATE" = "ALARM" ] || [ "$ALARM_STATE" = "OK" ]; then
    echo -e "${GREEN}✓${NC} CloudWatch Alarm: $ALARM_STATE"
    ((PASS_COUNT++))
else
    echo -e "${YELLOW}⚠${NC} CloudWatch Alarm: $ALARM_STATE"
fi

# Check 3: Incidents recorded
if [ "$INCIDENT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} DynamoDB Incidents: $INCIDENT_COUNT found"
    ((PASS_COUNT++))
else
    echo -e "${YELLOW}⚠${NC} DynamoDB Incidents: None found"
fi

# Check 4: No recent errors
if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Recent Errors: None (last 10 min)"
    ((PASS_COUNT++))
else
    echo -e "${YELLOW}⚠${NC} Recent Errors: $ERROR_COUNT (last 10 min)"
fi

echo ""
echo "Result: $PASS_COUNT/$TOTAL_CHECKS checks passed"
echo ""

if [ "$PASS_COUNT" -ge 3 ]; then
    echo -e "${GREEN}✓ Remediation appears successful!${NC}"
    exit 0
elif [ "$PASS_COUNT" -ge 2 ]; then
    echo -e "${YELLOW}⚠ Remediation partially successful${NC}"
    echo "Some checks failed - review logs for details"
    exit 0
else
    echo -e "${RED}✗ Remediation may have failed${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check Analyzer logs:"
    echo "   aws logs tail /aws/lambda/aiops-log-analyzer-dev-analyzer --since 30m"
    echo ""
    echo "2. Check Remediator logs:"
    echo "   aws logs tail /aws/lambda/aiops-log-analyzer-dev-remediator --since 30m"
    echo ""
    echo "3. Verify alarm triggered:"
    echo "   aws cloudwatch describe-alarm-history --alarm-name $ALARM_NAME --max-items 5"
    echo ""
    echo "4. Check if enough time passed (need ~5 minutes after alarm)"
    exit 1
fi
