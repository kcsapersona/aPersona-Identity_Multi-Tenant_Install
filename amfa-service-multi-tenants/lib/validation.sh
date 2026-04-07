#!/bin/bash

# Validation utilities for aPersona Multi-Tenant Installer
# This file contains all validation functions

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_USER_CANCEL=2
readonly EXIT_CONFIG_ERROR=3
readonly EXIT_AWS_ERROR=4

# ASM Portal URLs — hardcoded per environment
# Source repo uses dev server; release repo uses prod server (swapped by CI strip-source.sh)
# Must be 'export' (not just 'readonly') so CDK child processes can read them
# as process.env.ASM_PORTAL_URL / process.env.ASM_SERVICE_URL
# release shall use https://asm.apersona.com/asm_portal
export ASM_PORTAL_URL='https://asm.apersona.com/asm_portal'
export ASM_SERVICE_URL='https://asm.apersona.com/asm'

# Load configuration from tenants-config.json
load_config_from_json() {
    # Use TENANTS_CONFIG_FILE if set, otherwise search REPO_ROOT then PROJECT_DIR
    local config_file="${TENANTS_CONFIG_FILE:-}"
    if [[ -z "$config_file" ]]; then
        if [[ -f "${REPO_ROOT:-}/tenants-config.json" ]]; then
            config_file="${REPO_ROOT}/tenants-config.json"
        elif [[ -f "${PROJECT_DIR}/tenants-config.json" ]]; then
            config_file="${PROJECT_DIR}/tenants-config.json"
        fi
    fi
    
    log_info "Loading configuration from $config_file..."
    
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_error "Configuration file not found (tenants-config.json)"
        log_error "Looked in: ${REPO_ROOT:-} and ${PROJECT_DIR}"
        exit $EXIT_CONFIG_ERROR
    fi
    
    # Validate JSON syntax
    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in $config_file"
        exit $EXIT_CONFIG_ERROR
    fi
    
    # AWS Configuration (optional - can be auto-detected)
    local aws_region aws_account
    aws_region=$(jq -r '.aws.region // empty' "$config_file")
    aws_account=$(jq -r '.aws.account // empty' "$config_file")
    
    if [[ -n "$aws_region" ]]; then
        export AWS_REGION="$aws_region"
    fi
    if [[ -n "$aws_account" ]]; then
        export AWS_ACCOUNT="$aws_account"
    fi
    
    # DNS Configuration
    export ROOT_DOMAIN_NAME=$(jq -r '.dns.rootDomain' "$config_file")
    
    # ASM Configuration (portalUrl/serviceUrl are hardcoded constants, not from config)
    export ASM_INSTAL_KEY=$(jq -r '.asm.installKey' "$config_file")
    export ADMIN_EMAIL=$(jq -r '.asm.adminEmail' "$config_file")
    local installer_email
    installer_email=$(jq -r '.asm.installerEmail // empty' "$config_file")
    export INSTALLER_EMAIL="${installer_email:-$ADMIN_EMAIL}"
    export ASM_SALT=$(jq -r '.asm.salt' "$config_file")
    
    # SMTP Configuration
    export SMTP_HOST=$(jq -r '.smtp.host' "$config_file")
    export SMTP_USER=$(jq -r '.smtp.user' "$config_file")
    export SMTP_PASS=$(jq -r '.smtp.pass' "$config_file")
    export SMTP_SECURE=$(jq -r '.smtp.secure' "$config_file")
    export SMTP_PORT=$(jq -r '.smtp.port' "$config_file")
    
    # reCAPTCHA Configuration (optional)
    local recaptcha_key recaptcha_secret
    recaptcha_key=$(jq -r '.recaptcha.key // empty' "$config_file")
    recaptcha_secret=$(jq -r '.recaptcha.secret // empty' "$config_file")
    export RECAPTCHA_KEY="${recaptcha_key}"
    export RECAPTCHA_SECRET="${recaptcha_secret}"
    
    log_success "Configuration loaded successfully from tenants-config.json"
    
    # Store ASM install key in Secrets Manager for use by admin portal Lambdas
    if [[ -n "$ASM_INSTAL_KEY" && "$ASM_INSTAL_KEY" != "null" ]]; then
        log_info "Storing ASM install key in Secrets Manager..."
        local install_key_secret='{"installKey":"'"$ASM_INSTAL_KEY"'"}'
        if aws secretsmanager describe-secret --secret-id "apersona/asm/installkey" --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1; then
            aws secretsmanager put-secret-value \
                --secret-id "apersona/asm/installkey" \
                --secret-string "$install_key_secret" \
                --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1 || true
            log_info "ASM install key updated in Secrets Manager"
        else
            aws secretsmanager create-secret \
                --name "apersona/asm/installkey" \
                --secret-string "$install_key_secret" \
                --description "ASM install key for createServiceProvider API" \
                --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1 || true
            log_info "ASM install key stored in Secrets Manager"
        fi
    fi

    # Store samlgw2 admin token in Secrets Manager for use by samlgw2-calling Lambdas
    # (organizationslist, provision-tenant, samlslist, samls)
    local samlgw2_admin_token
    samlgw2_admin_token=$(jq -r '.samlgw2.adminToken // empty' "$config_file")
    if [[ -n "$samlgw2_admin_token" && "$samlgw2_admin_token" != "null" ]]; then
        log_info "Storing samlgw2 admin token in Secrets Manager..."
        local samlgw2_secret='{"adminToken":"'"$samlgw2_admin_token"'"}'
        if aws secretsmanager describe-secret --secret-id "apersona/samlgw2/admin-token" --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1; then
            aws secretsmanager put-secret-value \
                --secret-id "apersona/samlgw2/admin-token" \
                --secret-string "$samlgw2_secret" \
                --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1 || true
            log_info "samlgw2 admin token updated in Secrets Manager"
        else
            aws secretsmanager create-secret \
                --name "apersona/samlgw2/admin-token" \
                --secret-string "$samlgw2_secret" \
                --description "SAML Gateway v2 admin API token for X-Admin-Token header" \
                --region "${CDK_DEPLOY_REGION:-$AWS_REGION}" >/dev/null 2>&1 || true
            log_info "samlgw2 admin token stored in Secrets Manager"
        fi
    else
        log_warning "samlgw2.adminToken not found in tenants-config.json — samlgw2 integration will not work until token is configured"
    fi
}

# Validation functions
validate_required_var() {
    local var_name=$1
    local var_value=$2
    local config_file=${3:-"tenants-config.json"}
    
    if [[ -z "$var_value" ]]; then
        log_error "$var_name is not set, please set $var_name in $config_file"
        exit $EXIT_CONFIG_ERROR
    fi
}

validate_email() {
    local email=$1
    local var_name=$2
    
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log_error "Invalid email format for $var_name: $email"
        return 1
    fi
}

validate_domain_name() {
    local domain=$1
    
    if [[ ! "$domain" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
        log_error "Invalid domain format: $domain"
        return 1
    fi
}

# Validate global configuration
validate_global_config() {
    # Validate required global configuration
    validate_required_var "ASM_PORTAL_URL" "$ASM_PORTAL_URL"
    validate_required_var "ASM_SERVICE_URL" "$ASM_SERVICE_URL"
    validate_required_var "ROOT_DOMAIN_NAME" "$ROOT_DOMAIN_NAME"
    validate_required_var "ASM_INSTAL_KEY" "$ASM_INSTAL_KEY"
    validate_required_var "SMTP_HOST" "$SMTP_HOST"
    validate_required_var "SMTP_USER" "$SMTP_USER"
    validate_required_var "SMTP_PASS" "$SMTP_PASS"
    validate_required_var "ASM_SALT" "$ASM_SALT"
    validate_required_var "ADMIN_EMAIL" "$ADMIN_EMAIL"
    validate_email "$ADMIN_EMAIL" "ADMIN_EMAIL"
    
    if [[ -n "$INSTALLER_EMAIL" && "$INSTALLER_EMAIL" != "null" ]]; then
        validate_email "$INSTALLER_EMAIL" "INSTALLER_EMAIL"
    else
        export INSTALLER_EMAIL="$ADMIN_EMAIL"
    fi
    
    # Validate domain format
    validate_domain_name "$ROOT_DOMAIN_NAME"
    
    # Set defaults for optional variables
    export SMTP_SECURE=${SMTP_SECURE:-"false"}
    export SMTP_PORT=${SMTP_PORT:-587}
}
