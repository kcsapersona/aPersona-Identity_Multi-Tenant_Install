#!/bin/bash

# Logging utilities for aPersona Multi-Tenant Installer
# This file contains all logging and output functions

# Color definitions
readonly RED='\033[0;31m'
readonly BOLD="\033[1m"
readonly YELLOW='\033[38;5;11m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions with timestamps and levels
log_info() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >&2
    fi
}

# Legacy echo_time function for compatibility
echo_time() {
    log_info "$@"
}

# User confirmation with timeout and better UX
confirm_with_timeout() {
    local prompt=$1
    local timeout=${2:-30}
    local default_response=${3:-"n"}

    echo ""
    echo -e "${BOLD}${YELLOW}$prompt${NC}"
    echo -e "Press ${BOLD}y${NC} for yes, ${BOLD}n${NC} for no (timeout: ${timeout}s, default: $default_response)"

    local response
    if read -t $timeout -n 1 -s response; then
        echo "$response"
        case "$response" in
            [yY]) return 0 ;;
            [nN]) return 1 ;;
            *) 
                echo -e "\n${YELLOW}Invalid input. Please press 'y' or 'n'.${NC}"
                confirm_with_timeout "$prompt" "$timeout" "$default_response"
                ;;
        esac
    else
        echo ""
        log_warning "Timeout reached, using default response: $default_response"
        [[ "$default_response" == "y" ]] && return 0 || return 1
    fi
}

# Display comprehensive deployment summary
show_deployment_summary() {
    echo ""
    echo "=============================================="
    log_success "Multi-tenant deployment completed!"
    echo "=============================================="
    echo ""

    echo "Admin Portal:"
    echo "  • URL: https://adminportal.$ROOT_DOMAIN_NAME"
    echo "  • Admin User: $ADMIN_EMAIL"
    echo ""

    # Look up NAT Gateway Elastic IP for samlgw2 whitelisting
    echo "Lambda VPC / NAT Gateway:"
    local nat_eip=""
    if command -v aws &>/dev/null; then
        # Try to get the EIP from the VPC's NAT Gateway
        nat_eip=$(aws ec2 describe-nat-gateways \
            --filter "Name=state,Values=available" \
            --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" \
            --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
            --output text 2>/dev/null || true)
        if [[ -n "$nat_eip" && "$nat_eip" != "None" && "$nat_eip" != "null" ]]; then
            echo -e "  • NAT Gateway Elastic IP: ${BOLD}${GREEN}${nat_eip}${NC}"
        else
            echo "  • NAT Gateway Elastic IP: (could not be determined — check AWS console)"
        fi
    else
        echo "  • NAT Gateway Elastic IP: (aws cli not available — check AWS console)"
    fi
    echo ""

    # samlgw2 whitelist reminder
    echo -e "${BOLD}${YELLOW}⚠  SAML Gateway v2 (samlgw2) IP Whitelisting:${NC}"
    if [[ -n "$nat_eip" && "$nat_eip" != "None" && "$nat_eip" != "null" ]]; then
        echo "  Add the following IP to samlgw2 security.yaml allowed_ipv4 list:"
        echo -e "  ${BOLD}${nat_eip}${NC}"
    else
        echo "  Add the Lambda NAT Gateway Elastic IP to samlgw2 security.yaml."
        echo "  Find it in the AWS VPC Console → NAT Gateways → Elastic IP."
    fi
    echo "  File: /home/ec2-user/efs/samlgw2/config/security.yaml (on samlgw2 EC2)"
    echo ""

    # Next steps
    echo "Next Steps:"
    echo "1. Add NAT Gateway IP to samlgw2 whitelist (see above)"
    echo "2. Configure additional settings via the Admin Portal"
    echo "3. Test the login portals for each tenant"
    echo "4. Set up monitoring and alerts as needed"
    echo "5. Review CloudWatch logs for any issues"
    echo "6. Check DynamoDB tables for tenant configuration details"
    echo ""

    # Important notes
    echo "Important Notes:"
    echo "• DNS propagation may take up to 48 hours"
    echo "• SSL certificates are automatically provisioned by CloudFront"
    echo "• Check AWS CloudFormation console for detailed deployment status"
    echo ""
}
