#!/bin/bash

# aPersona Identity Manager Multi-Tenant Installer - Modular Version
# This script installs aPersona Identity Manager with multi-tenant support

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Script directory for relative imports
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect repository layout:
#   Source repo (mono-repo): installer/ is at root, packages at packages/service
#   Release repo: installer is at root, packages at amfa-service-multi-tenants/
if [[ -d "$SCRIPT_DIR/../packages/service" ]]; then
    # Source repo layout (mono-repo)
    readonly APERSONAIDP_REPO_NAME=packages/service
    readonly APERSONAADM_REPO_NAME=packages/admin-portal
    readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    readonly PROJECT_DIR="$REPO_ROOT/$APERSONAIDP_REPO_NAME"
elif [[ -d "$SCRIPT_DIR/packages/service" ]]; then
    # Source repo layout — script run from repo root
    readonly APERSONAIDP_REPO_NAME=packages/service
    readonly APERSONAADM_REPO_NAME=packages/admin-portal
    readonly REPO_ROOT="$SCRIPT_DIR"
    readonly PROJECT_DIR="$REPO_ROOT/$APERSONAIDP_REPO_NAME"
elif [[ -d "$SCRIPT_DIR/amfa-service-multi-tenants" ]]; then
    # Release repo layout — script at root level
    readonly APERSONAIDP_REPO_NAME=amfa-service-multi-tenants
    readonly APERSONAADM_REPO_NAME=amfa-admin-portal-multi-tenants
    readonly REPO_ROOT="$SCRIPT_DIR"
    readonly PROJECT_DIR="$REPO_ROOT/$APERSONAIDP_REPO_NAME"
else
    echo "ERROR: Cannot detect repository layout." >&2
    echo "Expected either packages/service/ (source repo) or amfa-service-multi-tenants/ (release repo)" >&2
    exit 1
fi

# Validate project directory exists before sourcing lib scripts
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: Project directory not found: $PROJECT_DIR" >&2
    echo "Please ensure this script is run from the parent directory of $APERSONAIDP_REPO_NAME" >&2
    echo "Current script directory: $SCRIPT_DIR" >&2
    echo "Expected project directory: $PROJECT_DIR" >&2
    exit 1
fi

# Determine lib directory:
#   Source repo: installer/lib/ (same directory as this script)
#   Release repo: amfa-service-multi-tenants/lib/ (inside PROJECT_DIR)
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    readonly LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d "$PROJECT_DIR/lib" ]]; then
    readonly LIB_DIR="$PROJECT_DIR/lib"
else
    echo "ERROR: Library directory not found" >&2
    echo "Checked: $SCRIPT_DIR/lib and $PROJECT_DIR/lib" >&2
    exit 1
fi

# Ensure nvm-managed Node.js is available in PATH
# Required when running after init_deploy.sh installs Node.js via nvm
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    \. "$NVM_DIR/nvm.sh"
fi

# Verify node is available before proceeding
if ! command -v node &>/dev/null; then
    echo "ERROR: Node.js is not installed or not in PATH." >&2
    echo "Please install Node.js 22+ (e.g., run init_deploy.sh first, or: nvm install 22)" >&2
    exit 1
fi

# Global variables
declare CDK_DEPLOY_REGION
declare CDK_DEPLOY_ACCOUNT

# Import utility modules
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/validation.sh"
source "$LIB_DIR/aws-utils.sh"
source "$LIB_DIR/build-utils.sh"
source "$LIB_DIR/tenant-utils.sh"
source "$LIB_DIR/admin-portal.sh"
source "$LIB_DIR/ssm-tenant-manager.sh"

# Error handling and cleanup
cleanup() {
    log_info "Performing cleanup..."
    unset NODE_OPTIONS 2>/dev/null || true
    unset IS_BOOTSTRAP 2>/dev/null || true
    unset CDK_NEW_BOOTSTRAP 2>/dev/null || true

    # Clean up temporary files - Updated paths
    rm -f "$PROJECT_DIR/delegationRole.json" "$PROJECT_DIR/ns_record.json" 2>/dev/null || true
}

handle_error() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed at line $line_number with exit code $exit_code"
    cleanup
    exit $exit_code
}

trap 'handle_error $? $LINENO' ERR
trap cleanup EXIT

# Main execution function with enhanced flow control
main() {
    # Change to project directory for all operations
    cd "$PROJECT_DIR" || {
        log_error "Project directory not found: $PROJECT_DIR"
        log_error "Please ensure this script is run from the parent directory of $APERSONAIDP_REPO_NAME"
        exit 1
    }

    # Display header
    echo ""
    echo "=============================================="
    echo "aPersona Identity Manager Multi-Tenant Installer"
    echo "=============================================="

    # Get package information
    local amfa_name amfa_version ad_portal_name ad_portal_version
    amfa_name=$(get_package_info "$APERSONAIDP_REPO_NAME" "name")
    amfa_version=$(get_package_info "$APERSONAIDP_REPO_NAME" "version")
    ad_portal_name=$(get_package_info "$APERSONAADM_REPO_NAME" "name")
    ad_portal_version=$(get_package_info "$APERSONAADM_REPO_NAME" "version")

    log_info "This script will install aPersona Identity Manager with multi-tenant support on your AWS account."
    echo ""
    echo "aPersona Identity Manager - $amfa_name - v$amfa_version"
    echo "aPersona Admin Portal - $ad_portal_name - v$ad_portal_version"
    echo ""

    # Initial confirmation
    if ! confirm_with_timeout "It may take between 45 to 60 min to complete. Continue?" 60 "n"; then
        log_info "Installation cancelled by user"
        exit $EXIT_USER_CANCEL
    fi

    # Display terms and conditions
    echo ""
    if [[ -f "$SCRIPT_DIR/aPersona_ASM-and-aPersona_Identity_Mgr_Ts_Cs.txt" ]]; then
        cat "$SCRIPT_DIR/aPersona_ASM-and-aPersona_Identity_Mgr_Ts_Cs.txt"
    else
        log_warning "Terms and conditions file not found, skipping..."
    fi
    echo ""

    if ! confirm_with_timeout "Please review and agree to the aPersona Identity Manager Terms and Conditions" 60 "n"; then
        log_info "Terms and conditions not accepted"
        exit $EXIT_USER_CANCEL
    fi

    # Load and validate global configuration from JSON
    load_config_from_json

    # Validate global configuration
    validate_global_config

    # Validate AWS environment
    validate_aws_credentials
    detect_aws_environment

    # Resolve hosted zone ID from root domain name (via Route53 API + dig validation)
    resolve_hosted_zone_id
    validate_hosted_zone

    # Validate tenants-config.json exists and is valid
    # Look in: REPO_ROOT first, then PROJECT_DIR
    log_info "Validating tenant configuration..."
    local config_file=""
    if [[ -f "$REPO_ROOT/tenants-config.json" ]]; then
        config_file="$REPO_ROOT/tenants-config.json"
    elif [[ -f "$PROJECT_DIR/tenants-config.json" ]]; then
        config_file="$PROJECT_DIR/tenants-config.json"
    else
        log_error "tenants-config.json not found"
        log_error "Looked in: $REPO_ROOT/ and $PROJECT_DIR/"
        exit $EXIT_CONFIG_ERROR
    fi
    log_info "Using config: $config_file"
    export TENANTS_CONFIG_FILE="$config_file"

    # Validate JSON syntax
    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in $config_file"
        exit $EXIT_CONFIG_ERROR
    fi

    # Validate required fields
    local deployment_name
    deployment_name=$(jq -r '.deploymentName // empty' "$config_file")
    if [[ -z "$deployment_name" ]]; then
        log_error "Missing 'deploymentName' field in tenants-config.json"
        exit $EXIT_CONFIG_ERROR
    fi

    log_success "Tenant configuration validated successfully"
    log_info "Deployment Name: $deployment_name"

    # Set Node.js memory options for large deployments
    export NODE_OPTIONS=--max-old-space-size=8192

    # Install dependencies and build
    install_dependencies

    # # Global ASM registration (ONE-TIME for entire deployment)
    # log_info "Registering with ASM portal..."
    # if ! register_asm_global; then
    #     log_error "ASM registration failed, aborting deployment"
    #     exit $EXIT_ERROR
    # fi

    # Create DNS delegation role
    create_dns_delegation_role

    # Build CDK
    build_cdk_stack

    # Final deployment confirmation
    echo ""
    echo "=============================================="
    echo "Ready to deploy to AWS"
    echo "=============================================="
    echo "Account: $CDK_DEPLOY_ACCOUNT"
    echo "Region: $CDK_DEPLOY_REGION"
    echo "Deployment: $deployment_name"
    echo ""

    if ! confirm_with_timeout "Confirm deployment to AWS" 60 "n"; then
        log_info "Deployment cancelled by user"
        exit $EXIT_USER_CANCEL
    fi

    # Bootstrap and deploy
    bootstrap_cdk
    deploy_multi_tenant_stack "$@"

    # Deploy admin portal
    deploy_admin_portal "$@"

    # Show comprehensive summary
    show_deployment_summary

    log_success "Multi-tenant installation completed successfully!"
}

# Script entry point with error handling
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
