#!/bin/bash

# ============================================================================
# Load Test Script - Stress Test the AIOps System
# ============================================================================
# This script performs load testing by triggering many concurrent errors
# to test system scalability and performance under load.
#
# Usage: ./load_test.sh [function-name] [concurrent] [iterations]
# ============================================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
FUNCTION_NAME=${1:-"aiops-log-analyzer-dev-demo-app"}
CONCURRENT=${2:-10}  # Number of concurrent invocations
ITERATIONS=${3:-5}   # Number of waves
REGION=${AWS_REGION:-"us-east-1"}

# Calculated values
TOTAL_INVOCATIONS=$((CONCURRENT * ITERATIONS))
WAVE_DELAY=5  # Seconds between waves

echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     AIOps Load Test Suite         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
echo "Configuration:"
echo "  Function: $FUNCTION_NAME"
echo "  Concurrent: $CONCURRENT invocations per wave"
echo "  Waves: $ITERATIONS"
echo "  Total Invocations: $TOTAL_INVOCATIONS"
echo "  Wave Delay: ${WAVE_DELAY}s"
echo "  Region: $REGION"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

# Verify function exists
if ! aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
    echo -e "${RED}❌ Function not found: $FUNCTION_NAME${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Get initial state
INITIAL_MEMORY=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query 'MemorySize' \
    --output text)

echo -e "${BLUE}Initial State:${NC}"
echo "  Memory: ${INITIAL_MEMORY}MB"
echo ""

# Confirm
echo -e "${YELLOW}This will trigger $TOTAL_INVOCATIONS Lambda invocations.${NC}"
echo "This may incur AWS charges. Continue? (yes/no)"
read -p "> " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting load test...${NC}"
echo ""

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Statistics
TOTAL_SUCCESS=0
TOTAL_ERRORS=0
TOTAL_FAILURES=0
declare -a WAVE_DURATIONS

START_TIME=$(date +%s)

# Run waves
for wave in $(seq 1 $ITERATIONS); do
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Wave $wave/$ITERATIONS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    WAVE_START=$(date +%s)
    
    # Launch concurrent invocations
    for i in $(seq 1 $CONCURRENT); do
        INVOCATION_ID="wave${wave}-inv${i}"
        RESPONSE_FILE="$TEMP_DIR/response-${INVOCATION_ID}.json"
        
        (
            aws lambda invoke \
                --function-name "$FUNCTION_NAME" \
                --payload '{"pattern":"sudden","target_mb":600}' \
                --region "$REGION" \
                "$RESPONSE_FILE" &>/dev/null
            
            # Check if it's an error (what we want)
            if grep -q "errorMessage\|ERROR" "$RESPONSE_FILE" 2>/dev/null; then
                echo "error" > "$TEMP_DIR/status-${INVOCATION_ID}"
            else
                echo "success" > "$TEMP_DIR/status-${INVOCATION_ID}"
            fi
        ) &
    done
    
    # Show progress
    echo -n "Launching $CONCURRENT concurrent invocations... "
    
    # Wait for all invocations to complete
    wait
    
    WAVE_END=$(date +%s)
    WAVE_DURATION=$((WAVE_END - WAVE_START))
    WAVE_DURATIONS+=("$WAVE_DURATION")
    
    # Count results for this wave
    WAVE_ERRORS=0
    WAVE_SUCCESS=0
    WAVE_FAILURES=0
    
    for i in $(seq 1 $CONCURRENT); do
        INVOCATION_ID="wave${wave}-inv${i}"
        STATUS_FILE="$TEMP_DIR/status-${INVOCATION_ID}"
        
        if [ -f "$STATUS_FILE" ]; then
            STATUS=$(cat "$STATUS_FILE")
            if [ "$STATUS" = "error" ]; then
                ((WAVE_ERRORS++))
                ((TOTAL_ERRORS++))
            elif [ "$STATUS" = "success" ]; then
                ((WAVE_SUCCESS++))
                ((TOTAL_SUCCESS++))
            fi
        else
            ((WAVE_FAILURES++))
            ((TOTAL_FAILURES++))
        fi
    done
    
    echo -e "${GREEN}Done${NC}"
    echo ""
    echo "Wave Results:"
    echo "  OOM Errors: $WAVE_ERRORS (desired)"
    echo "  Successful: $WAVE_SUCCESS"
    echo "  Failed: $WAVE_FAILURES"
    echo "  Duration: ${WAVE_DURATION}s"
    echo ""
    
    # Delay between waves (except last one)
    if [ $wave -lt $ITERATIONS ]; then
        echo "Waiting ${WAVE_DELAY}s before next wave..."
        sleep $WAVE_DELAY
        echo ""
    fi
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

# Calculate statistics
AVG_WAVE_DURATION=0
for duration in "${WAVE_DURATIONS[@]}"; do
    AVG_WAVE_DURATION=$((AVG_WAVE_DURATION + duration))
done
AVG_WAVE_DURATION=$((AVG_WAVE_DURATION / ITERATIONS))

INVOCATIONS_PER_SECOND=$(echo "scale=2; $TOTAL_INVOCATIONS / $TOTAL_DURATION" | bc 2>/dev/null || echo "N/A")

echo ""
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Load Test Complete             ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
echo "Summary:"
echo "  Total Invocations: $TOTAL_INVOCATIONS"
echo "  OOM Errors: $TOTAL_ERRORS (${TOTAL_ERRORS}/${TOTAL_INVOCATIONS})"
echo "  Successful: $TOTAL_SUCCESS"
echo "  Failed: $TOTAL_FAILURES"
echo "  Total Duration: ${TOTAL_DURATION}s"
echo "  Avg Wave Duration: ${AVG_WAVE_DURATION}s"
echo "  Throughput: ${INVOCATIONS_PER_SECOND} invocations/sec"
echo ""

# Check CloudWatch metrics
echo -e "${YELLOW}Checking CloudWatch Metrics...${NC}"
echo ""

# Get Lambda invocations
METRIC_END=$(date -u +%Y-%m-%dT%H:%M:%S)
METRIC_START=$(date -u -d "$((TOTAL_DURATION + 60)) seconds ago" +%Y-%m-%dT%H:%M:%S)

if INVOCATIONS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Invocations \
    --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
    --start-time "$METRIC_START" \
    --end-time "$METRIC_END" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" 2>&1); then
    
    METRIC_SUM=$(echo "$INVOCATIONS" | jq -r '[.Datapoints[].Sum] | add // 0' 2>/dev/null || echo "0")
    echo "CloudWatch Invocations: $METRIC_SUM"
fi

# Get Lambda errors
if ERRORS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Errors \
    --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
    --start-time "$METRIC_START" \
    --end-time "$METRIC_END" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" 2>&1); then
    
    ERROR_SUM=$(echo "$ERRORS" | jq -r '[.Datapoints[].Sum] | add // 0' 2>/dev/null || echo "0")
    echo "CloudWatch Errors: $ERROR_SUM"
fi

# Get Lambda throttles
if THROTTLES=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Throttles \
    --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
    --start-time "$METRIC_START" \
    --end-time "$METRIC_END" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" 2>&1); then
    
    THROTTLE_SUM=$(echo "$THROTTLES" | jq -r '[.Datapoints[].Sum] | add // 0' 2>/dev/null || echo "0")
    echo "CloudWatch Throttles: $THROTTLE_SUM"
    
    if [ "$THROTTLE_SUM" != "0" ]; then
        echo -e "  ${YELLOW}⚠ Function was throttled during load test${NC}"
        echo "  Consider increasing concurrency limits"
    fi
fi

echo ""

# Check alarm status
echo -e "${YELLOW}Checking Alarm Status...${NC}"
echo ""

ALARM_NAME="aiops-log-analyzer-dev-oom-$FUNCTION_NAME"

if ALARM_STATUS=$(aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" \
    --region "$REGION" 2>&1); then
    
    ALARM_STATE=$(echo "$ALARM_STATUS" | jq -r '.MetricAlarms[0].StateValue' 2>/dev/null || echo "Unknown")
    
    echo "Alarm: $ALARM_NAME"
    echo "State: $ALARM_STATE"
    
    if [ "$ALARM_STATE" = "ALARM" ]; then
        echo -e "${GREEN}✓ Alarm triggered (AIOps workflow should activate)${NC}"
    else
        echo -e "${YELLOW}⚠ Alarm not in ALARM state yet${NC}"
        echo "  Wait a few minutes for metrics to propagate"
    fi
fi

echo ""

# Performance assessment
echo -e "${CYAN}Performance Assessment:${NC}"
echo ""

ERROR_RATE=$(echo "scale=2; ($TOTAL_ERRORS * 100) / $TOTAL_INVOCATIONS" | bc 2>/dev/null || echo "N/A")
SUCCESS_RATE=$(echo "scale=2; ($TOTAL_SUCCESS * 100) / $TOTAL_INVOCATIONS" | bc 2>/dev/null || echo "N/A")

echo "Error Rate: ${ERROR_RATE}% (target: >80% for OOM testing)"
echo "Success Rate: ${SUCCESS_RATE}%"
echo "Failure Rate: $((TOTAL_FAILURES * 100 / TOTAL_INVOCATIONS))%"
echo ""

if [ "$TOTAL_ERRORS" -ge $((TOTAL_INVOCATIONS * 8 / 10)) ]; then
    echo -e "${GREEN}✓ Load test successful - generated sufficient errors${NC}"
elif [ "$TOTAL_ERRORS" -ge $((TOTAL_INVOCATIONS / 2)) ]; then
    echo -e "${YELLOW}⚠ Moderate error rate - some invocations succeeded${NC}"
else
    echo -e "${RED}✗ Low error rate - most invocations succeeded${NC}"
    echo "  Function may already be remediated or memory is sufficient"
fi

echo ""
echo "Next Steps:"
echo ""
echo "1. Wait 5 minutes for alarm to trigger"
echo ""
echo "2. Monitor AIOps workflow:"
echo "   ./monitor_workflow.sh $FUNCTION_NAME"
echo ""
echo "3. Check if system handles the load:"
echo "   aws logs tail /aws/lambda/aiops-log-analyzer-dev-analyzer --follow"
echo ""
echo "4. Verify remediation after workflow completes:"
echo "   ./verify_remediation.sh $FUNCTION_NAME"
echo ""
echo "5. Check for any throttling or errors in Analyzer/Remediator"
echo ""

# Cost estimate
COST_PER_INVOCATION=0.0000002  # Rough estimate
ESTIMATED_COST=$(echo "scale=4; $TOTAL_INVOCATIONS * $COST_PER_INVOCATION" | bc 2>/dev/null || echo "N/A")

echo "Estimated Cost: \$${ESTIMATED_COST} (Lambda invocations only)"
echo ""
