#!/bin/bash

# ============================================================================
# Demo App Deployment Script
# ============================================================================
# This script deploys the demo Lambda function that generates OOM errors
# Usage: ./deploy.sh [apply|destroy]
# ============================================================================

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ACTION=${1:-"apply"}
REGION=${AWS_REGION:-"us-east-1"}

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Demo App Deployment${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo "Action: $ACTION"
echo "Region: $REGION"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Terraform not found${NC}"
    echo "Install from: https://www.terraform.io/downloads"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Initialize Terraform
if [ ! -d ".terraform" ]; then
    echo -e "${YELLOW}Initializing Terraform...${NC}"
    terraform init
    echo -e "${GREEN}✓ Terraform initialized${NC}"
    echo ""
fi

# Execute action
case $ACTION in
    apply)
        echo -e "${YELLOW}Deploying demo app...${NC}"
        echo ""
        
        # Plan
        terraform plan -out=tfplan
        echo ""
        
        # Confirm
        echo -e "${YELLOW}Review the plan above.${NC}"
        read -p "Continue with deployment? (yes/no): " confirm
        
        if [ "$confirm" != "yes" ]; then
            echo -e "${RED}Deployment cancelled${NC}"
            rm -f tfplan
            exit 0
        fi
        
        # Apply
        terraform apply tfplan
        rm -f tfplan
        
        echo ""
        echo -e "${GREEN}=====================================${NC}"
        echo -e "${GREEN}✓ Demo App Deployed!${NC}"
        echo -e "${GREEN}=====================================${NC}"
        echo ""
        
        # Get outputs
        FUNCTION_NAME=$(terraform output -raw demo_app_function_name 2>/dev/null || echo "")
        
        if [ -n "$FUNCTION_NAME" ]; then
            echo "Function Name: $FUNCTION_NAME"
            echo ""
            echo "Test the demo app:"
            echo ""
            echo "1. Gradual memory growth (recommended):"
            echo "   aws lambda invoke --function-name $FUNCTION_NAME \\"
            echo "     --payload '{\"pattern\":\"gradual\",\"target_mb\":600}' response.json"
            echo ""
            echo "2. Sudden memory spike:"
            echo "   aws lambda invoke --function-name $FUNCTION_NAME \\"
            echo "     --payload '{\"pattern\":\"sudden\",\"target_mb\":600}' response.json"
            echo ""
            echo "3. Memory leak simulation:"
            echo "   aws lambda invoke --function-name $FUNCTION_NAME \\"
            echo "     --payload '{\"pattern\":\"leak\",\"target_mb\":600}' response.json"
            echo ""
            echo "4. View logs:"
            echo "   aws logs tail /aws/lambda/$FUNCTION_NAME --follow"
            echo ""
            echo "5. Trigger multiple errors (for testing):"
            echo "   ../test/trigger_errors.sh $FUNCTION_NAME"
        fi
        ;;
        
    destroy)
        echo -e "${RED}Destroying demo app...${NC}"
        echo ""
        echo -e "${YELLOW}This will delete the demo Lambda function and all associated resources.${NC}"
        read -p "Are you sure? (yes/no): " confirm
        
        if [ "$confirm" != "yes" ]; then
            echo -e "${YELLOW}Destroy cancelled${NC}"
            exit 0
        fi
        
        terraform destroy -auto-approve
        
        echo ""
        echo -e "${GREEN}✓ Demo app destroyed${NC}"
        ;;
        
    plan)
        echo -e "${YELLOW}Planning demo app deployment...${NC}"
        terraform plan
        ;;
        
    *)
        echo -e "${RED}Unknown action: $ACTION${NC}"
        echo "Usage: $0 [apply|destroy|plan]"
        exit 1
        ;;
esac
