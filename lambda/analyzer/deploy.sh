#!/bin/bash

# ============================================================================
# Analyzer Lambda Deployment Script
# ============================================================================
# This script packages and deploys the Analyzer Lambda function code
# Usage: ./deploy.sh [function-name]
# ============================================================================

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
FUNCTION_NAME=${1:-"aiops-log-analyzer-dev-analyzer"}
REGION=${AWS_REGION:-"us-east-1"}
PACKAGE_FILE="analyzer-deployment-package.zip"
export AWS_PAGER=""

echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}Analyzer Lambda Deployment${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo "Function: $FUNCTION_NAME"
echo "Region: $REGION"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found${NC}"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}❌ Python 3 not found${NC}"
    exit 1
fi

if ! command -v zip &> /dev/null; then
    echo -e "${RED}❌ zip not found${NC}"
    exit 1
fi

# Prefer pip3 but fall back to pip if needed
PIP_CMD=$(command -v pip3 || command -v pip || true)
if [ -z "$PIP_CMD" ]; then
    echo -e "${RED}❌ pip/pip3 not found (install pip for Python 3)${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Clean previous build
echo -e "${YELLOW}Cleaning previous build...${NC}"
rm -rf package
rm -f $PACKAGE_FILE
echo -e "${GREEN}✓ Cleaned${NC}"
echo ""

# Create package directory
echo -e "${YELLOW}Creating package directory...${NC}"
mkdir -p package
echo -e "${GREEN}✓ Created${NC}"
echo ""

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${NC}"
if [ -f requirements.txt ]; then
    "$PIP_CMD" install -r requirements.txt -t package/ \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --upgrade \
        --quiet
    echo -e "${GREEN}✓ Dependencies installed${NC}"
else
    echo -e "${YELLOW}⚠ No requirements.txt found${NC}"
fi
echo ""

# Copy Lambda code
echo -e "${YELLOW}Copying Lambda code...${NC}"
cp lambda_function.py package/
cp prompts.py package/
echo -e "${GREEN}✓ Code copied${NC}"
echo ""

# Create deployment package
echo -e "${YELLOW}Creating deployment package...${NC}"
cd package
zip -r ../$PACKAGE_FILE . -q
cd ..
echo -e "${GREEN}✓ Package created: $PACKAGE_FILE${NC}"

# Get package size
PACKAGE_SIZE=$(du -h $PACKAGE_FILE | cut -f1)
echo "Package size: $PACKAGE_SIZE"
echo ""

# Check if function exists
echo -e "${YELLOW}Checking if function exists...${NC}"
if aws lambda get-function --function-name $FUNCTION_NAME --region $REGION &>/dev/null; then
    echo -e "${GREEN}✓ Function exists, updating code...${NC}"
    
    # Update function code
    aws lambda update-function-code \
        --function-name $FUNCTION_NAME \
        --zip-file fileb://$PACKAGE_FILE \
        --region $REGION \
        --output text \
        --query 'LastModified'
    
    echo -e "${GREEN}✓ Function code updated${NC}"
else
    echo -e "${RED}❌ Function not found: $FUNCTION_NAME${NC}"
    echo -e "${YELLOW}Please deploy Terraform infrastructure first${NC}"
    exit 1
fi
echo ""

# Wait for update to complete
echo -e "${YELLOW}Waiting for update to complete...${NC}"
sleep 3

# Verify deployment
echo -e "${YELLOW}Verifying deployment...${NC}"
RUNTIME=$(aws lambda get-function-configuration \
    --function-name $FUNCTION_NAME \
    --region $REGION \
    --query 'Runtime' \
    --output text)

LAST_MODIFIED=$(aws lambda get-function-configuration \
    --function-name $FUNCTION_NAME \
    --region $REGION \
    --query 'LastModified' \
    --output text)

echo "Runtime: $RUNTIME"
echo "Last Modified: $LAST_MODIFIED"
echo ""

# Clean up
echo -e "${YELLOW}Cleaning up...${NC}"
rm -rf package
rm -f $PACKAGE_FILE
echo -e "${GREEN}✓ Cleaned up${NC}"
echo ""

# Success message
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}✓ Deployment Successful!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo "Function: $FUNCTION_NAME"
echo "Region: $REGION"
echo ""
echo "Next steps:"
echo "1. Test the function:"
echo "   aws lambda invoke --function-name $FUNCTION_NAME --payload '{\"test\":true}' response.json"
echo ""
echo "2. View logs:"
echo "   aws logs tail /aws/lambda/$FUNCTION_NAME --follow"
echo ""
echo "3. Monitor via CloudWatch dashboard"
