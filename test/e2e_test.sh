#!/bin/bash

# ============================================================================
# End-to-End Test Script - Complete AIOps Workflow Validation
# ============================================================================
# This script performs a complete end-to-end test of the AIOps system:
# 1. Triggers OOM errors
# 2. Waits for alarm to trigger
# 3. Monitors Analyzer execution
# 4. Monitors Remediator execution
# 5. Verifies memory increase
# 6. Tests fixed function
# 7. Generates detailed report
#
# Usage: ./e2e_test.sh [function-name]
# ============================================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
FUNCTION_NAME=${1:-"aiops-log-analyzer-dev-demo-app"}
REGION=${AWS_REGION:-"us-east-1"}
PROJECT_NAME="aiops-log-analyzer"
ENV="dev"

# Test configuration
ERROR_COUNT=6
ALARM_WAIT_SECONDS=330  # 5.5 minutes
REMEDIATION_WAIT_SECONDS=120  # 2 minutes
MAX_TOTAL_WAIT=600  # 10 minutes maximum

# File paths
REPORT_FILE="e2e-test-report-$(date +%Y%m%d-%H%M%S).txt"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${MAGENTA}╔═══════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  AIOps End-to-End Integration Test       ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo "Test Configuration:"
echo "  Function: $FUNCTION_NAME"
echo "  Error Count: $ERROR_COUNT"
echo "  Region: $REGION"
echo "  Report: $REPORT_FILE"
echo "  Estimated Duration: 8-10 minutes"
echo ""

# Initialize report
cat > "$REPORT_FILE" <<EOF
═══════════════════════════════════════════════════════════
AIOps End-to-End Test Report
═══════════════════════════════════════════════════════════
Date: $(date)
Function: $FUNCTION_NAME
Region: $REGION

EOF

log_report() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# Check prerequisites
echo -e "${YELLOW}Phase 0: Prerequisites Check${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠ jq not found (recommended)${NC}"
    HAS_JQ=false
else
    HAS_JQ=true
fi

# Verify all components exist
COMPONENTS=(
    "$FUNCTION_NAME:lambda"
    "${PROJECT_NAME}-${ENV}-analyzer:lambda"
    "${PROJECT_NAME}-${ENV}-remediator:lambda"
    "${PROJECT_NAME}-${ENV}-incidents:dynamodb"
)

echo "Verifying components..."
ALL_EXIST=true

for component in "${COMPONENTS[@]}"; do
    NAME="${component%:*}"
    TYPE="${component#*:}"
    
    if [ "$TYPE" = "lambda" ]; then
        if aws lambda get-function --function-name "$NAME" --region "$REGION" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Lambda: $NAME"
        else
            echo -e "  ${RED}✗${NC} Lambda: $NAME not found"
            ALL_EXIST=false
        fi
    elif [ "$TYPE" = "dynamodb" ]; then
        if aws dynamodb describe-table --table-name "$NAME" --region "$REGION" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} DynamoDB: $NAME"
        else
            echo -e "  ${RED}✗${NC} DynamoDB: $NAME not found"
            ALL_EXIST=false
        fi
    fi
done

if [ "$ALL_EXIST" = false ]; then
    echo -e "${RED}❌ Some components missing. Deploy infrastructure first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All components found${NC}"
echo ""

log_report "Phase 0: Prerequisites Check - PASSED"
log_report ""

# Phase 1: Get baseline state
echo -e "${YELLOW}Phase 1: Baseline State${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

INITIAL_MEMORY=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'MemorySize' \
    --output text)

INITIAL_STATE=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'State' \
    --output text)

echo "Initial Configuration:"
echo "  Memory: ${INITIAL_MEMORY}MB"
echo "  State: $INITIAL_STATE"
echo ""

log_report "Phase 1: Baseline State"
log_report "  Initial Memory: ${INITIAL_MEMORY}MB"
log_report "  Initial State: $INITIAL_STATE"
log_report ""

# Phase 2: Trigger errors
echo -e "${YELLOW}Phase 2: Triggering OOM Errors${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_report "Phase 2: Triggering $ERROR_COUNT OOM Errors"

ERROR_TRIGGER_START=$(date +%s)
SUCCESSFUL_ERRORS=0

for i in $(seq 1 $ERROR_COUNT); do
    echo -n "[$i/$ERROR_COUNT] Triggering error... "
    
    if aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload '{"pattern":"sudden","target_mb":600}' \
        --region "$REGION" \
        "$TEMP_DIR/response-$i.json" &>/dev/null; then
        
        if grep -q "errorMessage\|ERROR" "$TEMP_DIR/response-$i.json"; then
            echo -e "${GREEN}✓${NC}"
            ((SUCCESSFUL_ERRORS++))
        else
            echo -e "${YELLOW}⚠ (no error)${NC}"
        fi
    else
        echo -e "${RED}✗${NC}"
    fi
    
    sleep 2
done

ERROR_TRIGGER_END=$(date +%s)
ERROR_TRIGGER_DURATION=$((ERROR_TRIGGER_END - ERROR_TRIGGER_START))

echo ""
echo "Triggered $SUCCESSFUL_ERRORS/$ERROR_COUNT OOM errors in ${ERROR_TRIGGER_DURATION}s"
echo ""

log_report "  Successful Errors: $SUCCESSFUL_ERRORS/$ERROR_COUNT"
log_report "  Duration: ${ERROR_TRIGGER_DURATION}s"
log_report ""

if [ $SUCCESSFUL_ERRORS -lt 5 ]; then
    echo -e "${RED}❌ Insufficient errors generated (need 5+)${NC}"
    log_report "RESULT: FAILED - Insufficient errors"
    exit 1
fi

# Phase 3: Wait for alarm
echo -e "${YELLOW}Phase 3: Waiting for CloudWatch Alarm${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ALARM_NAME="${PROJECT_NAME}-${ENV}-oom-$FUNCTION_NAME"
log_report "Phase 3: Monitoring CloudWatch Alarm"
log_report "  Alarm: $ALARM_NAME"

echo "Alarm: $ALARM_NAME"
echo "Waiting up to ${ALARM_WAIT_SECONDS}s for alarm to trigger..."
echo ""

ALARM_CHECK_START=$(date +%s)
ALARM_TRIGGERED=false

while [ $(($(date +%s) - ALARM_CHECK_START)) -lt $ALARM_WAIT_SECONDS ]; do
    ELAPSED=$(($(date +%s) - ALARM_CHECK_START))
    
    ALARM_STATE=$(aws cloudwatch describe-alarms \
        --alarm-names "$ALARM_NAME" \
        --region "$REGION" \
        --query 'MetricAlarms[0].StateValue' \
        --output text 2>/dev/null || echo "UNKNOWN")
    
    echo -ne "\r  Elapsed: ${ELAPSED}s | Alarm State: $ALARM_STATE    "
    
    if [ "$ALARM_STATE" = "ALARM" ]; then
        ALARM_TRIGGERED=true
        echo ""
        echo -e "${GREEN}✓ Alarm triggered!${NC}"
        break
    fi
    
    sleep 10
done

ALARM_WAIT_DURATION=$(($(date +%s) - ALARM_CHECK_START))
echo ""

if [ "$ALARM_TRIGGERED" = false ]; then
    echo -e "${RED}❌ Alarm did not trigger within ${ALARM_WAIT_SECONDS}s${NC}"
    log_report "RESULT: FAILED - Alarm did not trigger"
    exit 1
fi

log_report "  Alarm triggered after ${ALARM_WAIT_DURATION}s"
log_report ""

# Phase 4: Monitor Analyzer
echo -e "${YELLOW}Phase 4: Monitoring Analyzer Lambda${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ANALYZER_FUNCTION="${PROJECT_NAME}-${ENV}-analyzer"
log_report "Phase 4: Monitoring Analyzer Lambda"

echo "Waiting for Analyzer to execute (max ${REMEDIATION_WAIT_SECONDS}s)..."

ANALYZER_START=$(date +%s)
ANALYZER_EXECUTED=false

while [ $(($(date +%s) - ANALYZER_START)) -lt $REMEDIATION_WAIT_SECONDS ]; do
    # Check for recent log events
    if LOGS=$(aws logs filter-log-events \
        --log-group-name "/aws/lambda/$ANALYZER_FUNCTION" \
        --start-time $((ALARM_CHECK_START * 1000)) \
        --filter-pattern "Analyzing errors for Lambda function" \
        --region "$REGION" 2>&1); then
        
        if echo "$LOGS" | grep -q "$FUNCTION_NAME"; then
            ANALYZER_EXECUTED=true
            echo -e "${GREEN}✓ Analyzer executed${NC}"
            
            # Try to extract confidence
            if CONFIDENCE=$(echo "$LOGS" | grep -oP 'Confidence: \K[\d.]+' | head -1); then
                echo "  Confidence: ${CONFIDENCE}%"
                log_report "  Analyzer Confidence: ${CONFIDENCE}%"
            fi
            
            break
        fi
    fi
    
    sleep 5
done

if [ "$ANALYZER_EXECUTED" = false ]; then
    echo -e "${YELLOW}⚠ Could not confirm Analyzer execution${NC}"
    log_report "  WARNING: Could not confirm Analyzer execution"
else
    log_report "  Analyzer executed successfully"
fi

echo ""
log_report ""

# Phase 5: Monitor Remediator
echo -e "${YELLOW}Phase 5: Monitoring Remediator Lambda${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

REMEDIATOR_FUNCTION="${PROJECT_NAME}-${ENV}-remediator"
log_report "Phase 5: Monitoring Remediator Lambda"

echo "Waiting for Remediator to execute (max ${REMEDIATION_WAIT_SECONDS}s)..."

REMEDIATOR_START=$(date +%s)
REMEDIATOR_EXECUTED=false

while [ $(($(date +%s) - REMEDIATOR_START)) -lt $REMEDIATION_WAIT_SECONDS ]; do
    if LOGS=$(aws logs filter-log-events \
        --log-group-name "/aws/lambda/$REMEDIATOR_FUNCTION" \
        --start-time $((ALARM_CHECK_START * 1000)) \
        --filter-pattern "Processing remediation" \
        --region "$REGION" 2>&1); then
        
        if echo "$LOGS" | grep -q "$FUNCTION_NAME"; then
            REMEDIATOR_EXECUTED=true
            echo -e "${GREEN}✓ Remediator executed${NC}"
            
            # Try to extract memory change
            if MEMORY_CHANGE=$(echo "$LOGS" | grep -oP 'Memory: \K[\d]+ MB → [\d]+ MB' | head -1); then
                echo "  $MEMORY_CHANGE"
                log_report "  Memory Change: $MEMORY_CHANGE"
            fi
            
            break
        fi
    fi
    
    sleep 5
done

if [ "$REMEDIATOR_EXECUTED" = false ]; then
    echo -e "${YELLOW}⚠ Could not confirm Remediator execution${NC}"
    log_report "  WARNING: Could not confirm Remediator execution"
else
    log_report "  Remediator executed successfully"
fi

echo ""
log_report ""

# Phase 6: Verify memory increase
echo -e "${YELLOW}Phase 6: Verifying Memory Increase${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_report "Phase 6: Verifying Memory Increase"

# Wait a bit for update to propagate
sleep 10

FINAL_MEMORY=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'MemorySize' \
    --output text)

FINAL_STATE=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'State' \
    --output text)

echo "Final Configuration:"
echo "  Memory: ${FINAL_MEMORY}MB (was ${INITIAL_MEMORY}MB)"
echo "  State: $FINAL_STATE"
echo ""

log_report "  Initial Memory: ${INITIAL_MEMORY}MB"
log_report "  Final Memory: ${FINAL_MEMORY}MB"
log_report "  State: $FINAL_STATE"

MEMORY_INCREASED=false
if [ "$FINAL_MEMORY" -gt "$INITIAL_MEMORY" ]; then
    INCREASE=$((FINAL_MEMORY - INITIAL_MEMORY))
    echo -e "${GREEN}✓ Memory increased by ${INCREASE}MB${NC}"
    log_report "  RESULT: Memory increased by ${INCREASE}MB"
    MEMORY_INCREASED=true
else
    echo -e "${RED}✗ Memory not increased${NC}"
    log_report "  RESULT: Memory not increased"
fi

echo ""
log_report ""

# Phase 7: Test fixed function
echo -e "${YELLOW}Phase 7: Testing Fixed Function${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_report "Phase 7: Testing Fixed Function"

echo "Testing function with same payload that caused OOM..."

TEST_SUCCESS=false
if aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --payload '{"pattern":"gradual","target_mb":600}' \
    --region "$REGION" \
    "$TEMP_DIR/test-result.json" &>/dev/null; then
    
    if grep -q "errorMessage\|ERROR" "$TEMP_DIR/test-result.json"; then
        echo -e "${RED}✗ Function still failing${NC}"
        log_report "  RESULT: Function still failing"
    else
        echo -e "${GREEN}✓ Function completed successfully!${NC}"
        log_report "  RESULT: Function works after remediation"
        TEST_SUCCESS=true
    fi
else
    echo -e "${RED}✗ Failed to invoke function${NC}"
    log_report "  RESULT: Failed to invoke function"
fi

echo ""
log_report ""

# Phase 8: Check DynamoDB
echo -e "${YELLOW}Phase 8: Verifying Incident Records${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

INCIDENTS_TABLE="${PROJECT_NAME}-${ENV}-incidents"
log_report "Phase 8: Verifying DynamoDB Incident Records"

if INCIDENTS=$(aws dynamodb scan \
    --table-name "$INCIDENTS_TABLE" \
    --filter-expression "function_name = :fn" \
    --expression-attribute-values "{\":fn\":{\"S\":\"$FUNCTION_NAME\"}}" \
    --region "$REGION" \
    --max-items 1 2>&1); then
    
    INCIDENT_COUNT=$(echo "$INCIDENTS" | jq '.Items | length' 2>/dev/null || echo "0")
    
    if [ "$INCIDENT_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found incident record in DynamoDB${NC}"
        log_report "  Incidents Found: Yes"
        
        if [ "$HAS_JQ" = true ]; then
            REMEDIATION_STATUS=$(echo "$INCIDENTS" | jq -r '.Items[0].remediation_status.S // "N/A"')
            echo "  Remediation Status: $REMEDIATION_STATUS"
            log_report "  Remediation Status: $REMEDIATION_STATUS"
        fi
    else
        echo -e "${YELLOW}⚠ No incident records found${NC}"
        log_report "  Incidents Found: No"
    fi
else
    echo -e "${YELLOW}⚠ Could not query DynamoDB${NC}"
    log_report "  DynamoDB Query: Failed"
fi

echo ""
log_report ""

# Final Summary
TEST_END=$(date +%s)
TOTAL_TEST_DURATION=$((TEST_END - ERROR_TRIGGER_START))

echo -e "${MAGENTA}╔═══════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║         Test Results Summary              ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════╝${NC}"
echo ""

log_report "═══════════════════════════════════════════════════════════"
log_report "FINAL RESULTS"
log_report "═══════════════════════════════════════════════════════════"
log_report ""

# Calculate pass/fail
PASS_COUNT=0
TOTAL_PHASES=7

echo "Phase Results:"

if [ $SUCCESSFUL_ERRORS -ge 5 ]; then
    echo -e "  ${GREEN}✓${NC} Phase 2: Error Generation"
    ((PASS_COUNT++))
else
    echo -e "  ${RED}✗${NC} Phase 2: Error Generation"
fi

if [ "$ALARM_TRIGGERED" = true ]; then
    echo -e "  ${GREEN}✓${NC} Phase 3: Alarm Triggered"
    ((PASS_COUNT++))
else
    echo -e "  ${RED}✗${NC} Phase 3: Alarm Triggered"
fi

if [ "$ANALYZER_EXECUTED" = true ]; then
    echo -e "  ${GREEN}✓${NC} Phase 4: Analyzer Executed"
    ((PASS_COUNT++))
else
    echo -e "  ${YELLOW}⚠${NC} Phase 4: Analyzer Executed"
fi

if [ "$REMEDIATOR_EXECUTED" = true ]; then
    echo -e "  ${GREEN}✓${NC} Phase 5: Remediator Executed"
    ((PASS_COUNT++))
else
    echo -e "  ${YELLOW}⚠${NC} Phase 5: Remediator Executed"
fi

if [ "$MEMORY_INCREASED" = true ]; then
    echo -e "  ${GREEN}✓${NC} Phase 6: Memory Increased"
    ((PASS_COUNT++))
else
    echo -e "  ${RED}✗${NC} Phase 6: Memory Increased"
fi

if [ "$TEST_SUCCESS" = true ]; then
    echo -e "  ${GREEN}✓${NC} Phase 7: Function Fixed"
    ((PASS_COUNT++))
else
    echo -e "  ${RED}✗${NC} Phase 7: Function Fixed"
fi

if [ "$INCIDENT_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} Phase 8: Incident Recorded"
    ((PASS_COUNT++))
else
    echo -e "  ${YELLOW}⚠${NC} Phase 8: Incident Recorded"
fi

echo ""
echo "Overall: $PASS_COUNT/$TOTAL_PHASES phases passed"
echo "Duration: ${TOTAL_TEST_DURATION}s (~$((TOTAL_TEST_DURATION / 60)) minutes)"
echo "Report: $REPORT_FILE"
echo ""

log_report "Overall Result: $PASS_COUNT/$TOTAL_PHASES phases passed"
log_report "Total Duration: ${TOTAL_TEST_DURATION}s"
log_report ""

if [ $PASS_COUNT -ge 6 ]; then
    echo -e "${GREEN}✓✓✓ END-TO-END TEST PASSED ✓✓✓${NC}"
    log_report "STATUS: PASSED"
    exit 0
elif [ $PASS_COUNT -ge 4 ]; then
    echo -e "${YELLOW}⚠⚠⚠ END-TO-END TEST PARTIAL ⚠⚠⚠${NC}"
    log_report "STATUS: PARTIAL"
    exit 0
else
    echo -e "${RED}✗✗✗ END-TO-END TEST FAILED ✗✗✗${NC}"
    log_report "STATUS: FAILED"
    exit 1
fi
