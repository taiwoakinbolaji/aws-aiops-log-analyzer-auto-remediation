#!/bin/bash

# ============================================================================
# Monitor Workflow Script - Real-time AIOps Workflow Monitoring
# ============================================================================
# This script monitors the AIOps workflow in real-time by tailing logs
# from all components simultaneously.
#
# Usage: ./monitor_workflow.sh [function-name]
# ============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
FUNCTION_NAME=${1:-"aiops-log-analyzer-dev-demo-app"}
REGION=${AWS_REGION:-"us-east-1"}
PROJECT_NAME="aiops-log-analyzer"
ENV="dev"

echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  AIOps Workflow Monitor            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
echo "Monitoring function: $FUNCTION_NAME"
echo "Region: $REGION"
echo ""
echo "This will open 3 terminal tabs/windows to monitor:"
echo "  1. Demo App logs"
echo "  2. Analyzer Lambda logs"
echo "  3. Remediator Lambda logs"
echo ""

# Check if we're on macOS or Linux
if [[ "$OSTYPE" == "darwin"* ]]; then
    TERMINAL_CMD="osascript"
    IS_MAC=true
else
    IS_MAC=false
fi

# Generate monitoring commands
DEMO_CMD="aws logs tail /aws/lambda/$FUNCTION_NAME --follow --region $REGION"
ANALYZER_CMD="aws logs tail /aws/lambda/${PROJECT_NAME}-${ENV}-analyzer --follow --region $REGION --filter-pattern 'Analyzing|Confidence|remediation'"
REMEDIATOR_CMD="aws logs tail /aws/lambda/${PROJECT_NAME}-${ENV}-remediator --follow --region $REGION --filter-pattern 'Processing|Memory|update'"

echo "Commands to run in separate terminals:"
echo ""
echo -e "${BLUE}Terminal 1 - Demo App:${NC}"
echo "$DEMO_CMD"
echo ""
echo -e "${BLUE}Terminal 2 - Analyzer:${NC}"
echo "$ANALYZER_CMD"
echo ""
echo -e "${BLUE}Terminal 3 - Remediator:${NC}"
echo "$REMEDIATOR_CMD"
echo ""

# Try to open terminals automatically
if [ "$IS_MAC" = true ]; then
    echo "Opening Terminal tabs on macOS..."
    
    # Open new tabs in Terminal.app
    osascript <<EOF
tell application "Terminal"
    activate
    tell application "System Events" to keystroke "t" using {command down}
    do script "$DEMO_CMD" in selected tab of the front window
    delay 1
    tell application "System Events" to keystroke "t" using {command down}
    do script "$ANALYZER_CMD" in selected tab of the front window
    delay 1
    tell application "System Events" to keystroke "t" using {command down}
    do script "$REMEDIATOR_CMD" in selected tab of the front window
end tell
EOF
    
    echo -e "${GREEN}✓ Opened 3 monitoring tabs${NC}"
else
    # For Linux, try different terminal emulators
    if command -v gnome-terminal &> /dev/null; then
        echo "Opening GNOME Terminal tabs..."
        gnome-terminal --tab -- bash -c "$DEMO_CMD; exec bash" \
                      --tab -- bash -c "$ANALYZER_CMD; exec bash" \
                      --tab -- bash -c "$REMEDIATOR_CMD; exec bash" &
        echo -e "${GREEN}✓ Opened 3 monitoring tabs${NC}"
    elif command -v xterm &> /dev/null; then
        echo "Opening xterm windows..."
        xterm -e "$DEMO_CMD" &
        xterm -e "$ANALYZER_CMD" &
        xterm -e "$REMEDIATOR_CMD" &
        echo -e "${GREEN}✓ Opened 3 monitoring windows${NC}"
    else
        echo -e "${YELLOW}⚠ Could not auto-open terminals${NC}"
        echo "Please run the commands above in separate terminal windows"
    fi
fi

echo ""
echo "Press Ctrl+C to stop monitoring"
echo ""

# Keep script running
wait
