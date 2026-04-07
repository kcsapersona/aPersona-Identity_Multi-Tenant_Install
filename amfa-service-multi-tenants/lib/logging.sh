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

    # Next steps
    echo "Next Steps:"
    echo "1. Configure additional settings via the Admin Portal"
    echo "2. Test the login portals for each tenant"
    echo "3. Set up monitoring and alerts as needed"
    echo "4. Review CloudWatch logs for any issues"
    echo "5. Check DynamoDB tables for tenant configuration details"
    echo ""

    # Important notes
    echo "Important Notes:"
    echo "• DNS propagation may take up to 48 hours"
    echo "• SSL certificates are automatically provisioned by CloudFront"
    echo "• Check AWS CloudFormation console for detailed deployment status"
    echo ""
}
