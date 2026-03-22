#!/bin/bash

# ============================================================================
# Trigger Errors Script - Automated OOM Error Generation
# ============================================================================
# This script triggers multiple OOM errors in the demo Lambda function
# to activate the AIOps workflow and test auto-remediation.
#
# Usage: ./trigger_errors.sh [function-name] [count] [pattern]
# ============================================================================

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEFAULT_FUNCTION="aiops-log-analyzer-dev-demo-app"
FALLBACK_FUNCTION="aiops-log-analyzer-prod-demo-app"
FUNCTION_NAME=${1:-"$DEFAULT_FUNCTION"}
ERROR_COUNT=${2:-6}
ERROR_PATTERN=${3:-"sudden"}
TARGET_MB=${4:-600}
REGION=${AWS_REGION:-"us-east-1"}
VERBOSE=${VERBOSE:-""}
export AWS_PAGER=""

function function_exists() {
    local fn_name=$1
    aws lambda get-function --function-name "$fn_name" --region "$REGION" &>/dev/null
}

# Calculated values
DELAY_SECONDS=2  # Delay between invocations
TOTAL_TIME=$((ERROR_COUNT * DELAY_SECONDS))

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Trigger Errors Script${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo "Function: $FUNCTION_NAME"
echo "Error Count: $ERROR_COUNT"
echo "Pattern: $ERROR_PATTERN"
echo "Target Memory: ${TARGET_MB}MB"
echo "Region: $REGION"
echo "Estimated Time: ${TOTAL_TIME}s"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

HAS_JQ=false
if command -v jq &> /dev/null; then
    HAS_JQ=true
else
    echo -e "${YELLOW}⚠ jq not found (optional, for better output)${NC}"
fi

# Verify function exists or fallback
if ! function_exists "$FUNCTION_NAME"; then
    if [ -z "${1:-}" ] && [ "$FUNCTION_NAME" != "$FALLBACK_FUNCTION" ] && function_exists "$FALLBACK_FUNCTION"; then
        echo -e "${YELLOW}⚠ Default function not found, using fallback: $FALLBACK_FUNCTION${NC}"
        FUNCTION_NAME="$FALLBACK_FUNCTION"
    else
        echo -e "${RED}❌ Function not found: $FUNCTION_NAME${NC}"
        echo "Available functions:"
        aws lambda list-functions --region "$REGION" --query 'Functions[?contains(FunctionName, `demo`)].FunctionName' --output table
        exit 1
    fi
fi

echo -e "${GREEN}✓ Function exists${NC}"
echo ""

# Get current memory configuration
CURRENT_MEMORY=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'MemorySize' \
    --output text)

echo -e "${BLUE}Current Configuration:${NC}"
echo "  Memory: ${CURRENT_MEMORY}MB"
echo ""

# Create payload
PAYLOAD=$(cat <<EOF
{
  "pattern": "$ERROR_PATTERN",
  "target_mb": $TARGET_MB,
  "duration_seconds": 10
}
EOF
)

echo -e "${YELLOW}Payload:${NC}"
echo "$PAYLOAD" | jq . 2>/dev/null || echo "$PAYLOAD"
echo ""

# Confirm action
echo -e "${YELLOW}This will trigger $ERROR_COUNT OOM errors.${NC}"
echo "CloudWatch Alarm threshold is 5 errors in 5 minutes."
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting error generation...${NC}"
echo ""

# Create temporary directory for responses
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Track statistics
SUCCESS_COUNT=0
FAILURE_COUNT=0
START_TIME=$(date +%s)

# Trigger errors
for i in $(seq 1 $ERROR_COUNT); do
    echo -e "${BLUE}[$i/$ERROR_COUNT]${NC} Triggering OOM error..."
    
    RESPONSE_FILE="$TEMP_DIR/response-$i.json"
    LOG_FILE="$TEMP_DIR/log-$i.txt"
    
    # Invoke Lambda
    if aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload "$PAYLOAD" \
        --cli-binary-format raw-in-base64-out \
        --region "$REGION" \
        --log-type Tail \
        --query 'LogResult' \
        --output text \
        "$RESPONSE_FILE" 2>"$LOG_FILE" | base64 -d > "$TEMP_DIR/decoded-log-$i.txt" 2>/dev/null; then
        
        # Check if it's actually an error (which is what we want)
        if grep -q "errorMessage\|ERROR\|Error" "$RESPONSE_FILE" 2>/dev/null || \
           grep -q "Process exited before completing\|out of memory" "$TEMP_DIR/decoded-log-$i.txt" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} OOM error triggered successfully"
            ((SUCCESS_COUNT++))
        else
            echo -e "  ${YELLOW}⚠${NC} Function completed without error (unexpected)"
            if [ "$HAS_JQ" = true ]; then
                cat "$RESPONSE_FILE" | jq -r '.body' 2>/dev/null || cat "$RESPONSE_FILE"
            fi
            ((FAILURE_COUNT++))
        fi
    else
        echo -e "  ${RED}✗${NC} Failed to invoke function"
        cat "$LOG_FILE"
        ((FAILURE_COUNT++))
    fi
    
    # Delay between invocations (except last one)
    if [ $i -lt $ERROR_COUNT ]; then
        sleep $DELAY_SECONDS
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}Error Generation Complete${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo "Summary:"
echo "  Total Errors: $ERROR_COUNT"
echo "  Successful OOMs: $SUCCESS_COUNT"
echo "  Failed: $FAILURE_COUNT"
echo "  Duration: ${DURATION}s"
echo ""

# Show next steps
if [ $SUCCESS_COUNT -ge 5 ]; then
    echo -e "${GREEN}✓ Generated enough errors to trigger CloudWatch Alarm${NC}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Wait 5 minutes for CloudWatch Alarm to trigger"
    echo "   Alarm: aiops-log-analyzer-dev-oom-$FUNCTION_NAME"
    echo ""
    echo "2. Monitor the AIOps workflow:"
    echo "   ./monitor_workflow.sh $FUNCTION_NAME"
    echo ""
    echo "3. Or manually check alarm status:"
    echo "   aws cloudwatch describe-alarms \\"
    echo "     --alarm-names aiops-log-analyzer-dev-oom-$FUNCTION_NAME \\"
    echo "     --query 'MetricAlarms[0].StateValue'"
    echo ""
    echo "4. After ~5 minutes, verify remediation:"
    echo "   ./verify_remediation.sh $FUNCTION_NAME"
    echo ""
    echo "5. View logs:"
    echo "   # Demo app logs"
    echo "   aws logs tail /aws/lambda/$FUNCTION_NAME --follow"
    echo ""
    echo "   # Analyzer logs"
    echo "   aws logs tail /aws/lambda/aiops-log-analyzer-dev-analyzer --follow"
    echo ""
    echo "   # Remediator logs"
    echo "   aws logs tail /aws/lambda/aiops-log-analyzer-dev-remediator --follow"
else
    echo -e "${YELLOW}⚠ Only $SUCCESS_COUNT errors generated (need 5+ to trigger alarm)${NC}"
    echo ""
    echo "Run again to generate more errors:"
    echo "  ./trigger_errors.sh $FUNCTION_NAME $((5 - SUCCESS_COUNT))"
fi

echo ""

# Show error details if verbose
if [ -n "$VERBOSE" ]; then
    echo -e "${BLUE}Error Details:${NC}"
    for i in $(seq 1 $SUCCESS_COUNT); do
        if [ -f "$TEMP_DIR/response-$i.json" ]; then
            echo ""
            echo "Error $i:"
            cat "$TEMP_DIR/response-$i.json" | jq . 2>/dev/null || cat "$TEMP_DIR/response-$i.json"
        fi
    done
fi
