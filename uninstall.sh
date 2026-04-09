#!/bin/bash

# aPersona Identity Manager Multi-Tenant Uninstaller
# This script completely removes all aPersona Identity Manager resources
# including per-tenant runtime resources, shared infrastructure, and external registrations.
#
# Usage:
#   ./uninstall.sh              # Interactive mode with confirmations
#   ./uninstall.sh --force      # Skip confirmations (use with caution)
#   ./uninstall.sh --dry-run    # Show what would be deleted without actually deleting

set -uo pipefail
# Note: We intentionally do NOT use `set -e` because the uninstaller must
# continue through failures in individual phases to clean up as much as possible.

# Repository names
readonly APERSONAIDP_REPO_NAME=amfa-service-multi-tenants
readonly APERSONAADM_REPO_NAME=amfa-admin-portal-multi-tenants

# Script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect repository layout (same logic as install script)
if [[ -d "$SCRIPT_DIR/../packages/service" ]]; then
    # Source repo layout (mono-repo) — uninstall.sh is in installer/
    readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    readonly PROJECT_DIR="$REPO_ROOT/packages/service"
    readonly PARENT_DIR="$REPO_ROOT"
elif [[ -d "$SCRIPT_DIR/packages/service" ]]; then
    # Source repo — running from root
    readonly REPO_ROOT="$SCRIPT_DIR"
    readonly PROJECT_DIR="$REPO_ROOT/packages/service"
    readonly PARENT_DIR="$REPO_ROOT"
elif [[ -d "$SCRIPT_DIR/$APERSONAIDP_REPO_NAME" ]]; then
    # Release repo layout
    readonly REPO_ROOT="$SCRIPT_DIR"
    readonly PROJECT_DIR="$SCRIPT_DIR/$APERSONAIDP_REPO_NAME"
    readonly PARENT_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/lib/logging.sh" ]]; then
    # Running from within amfa-service-multi-tenants/
    readonly REPO_ROOT="$(dirname "$SCRIPT_DIR")"
    readonly PROJECT_DIR="$SCRIPT_DIR"
    readonly PARENT_DIR="$(dirname "$SCRIPT_DIR")"
else
    echo "ERROR: Cannot find library files. Run from the installer/ directory or the repo root." >&2
    exit 1
fi

# Determine lib directory
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    readonly LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d "$PROJECT_DIR/lib" ]]; then
    readonly LIB_DIR="$PROJECT_DIR/lib"
else
    echo "ERROR: Library directory not found" >&2
    exit 1
fi

# Global variables
declare CDK_DEPLOY_REGION
declare CDK_DEPLOY_ACCOUNT
FORCE_MODE=false
DRY_RUN=false

# Parse command-line arguments
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE_MODE=true ;;
        --dry-run|-n) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f     Skip all confirmation prompts"
            echo "  --dry-run, -n   Show what would be deleted without deleting"
            echo "  --help, -h      Show this help message"
            exit 0
        ;;
    esac
done

# Import utility modules
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/validation.sh"
source "$LIB_DIR/aws-utils.sh"

# SAML proxy constants
readonly SAMLPROXY_API_URL="https://api.samlproxy.apersona-id.com/samlproxy"

# Counters for summary
declare -i TOTAL_SUCCESS=0
declare -i TOTAL_FAILED=0
declare -i TOTAL_SKIPPED=0
declare -a FAILED_ITEMS=()

# ============================================================================
# Configuration Loader (no Secrets Manager side effects)
# ============================================================================

# Lightweight config loader for uninstall - reads tenants-config.json
# WITHOUT creating/updating secrets in Secrets Manager (which load_config_from_json does)
load_config_for_uninstall() {
    # Search REPO_ROOT first, then PROJECT_DIR
    local config_file=""
    if [[ -f "${REPO_ROOT}/tenants-config.json" ]]; then
        config_file="${REPO_ROOT}/tenants-config.json"
    elif [[ -f "${PROJECT_DIR}/tenants-config.json" ]]; then
        config_file="${PROJECT_DIR}/tenants-config.json"
    fi
    
    log_info "Loading configuration from tenants-config.json (read-only)..."
    
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_error "Configuration file not found (tenants-config.json)"
        log_error "Looked in: ${REPO_ROOT}/ and ${PROJECT_DIR}/"
        exit 1
    fi
    log_info "Using config: $config_file"
    
    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in $config_file"
        exit 1
    fi
    
    # DNS Configuration
    export ROOT_DOMAIN_NAME=$(jq -r '.dns.rootDomain' "$config_file")
    
    # ASM Configuration
    # ASM Portal URLs — hardcoded per environment (not from config)
    # Source repo uses dev server; release repo uses prod server (swapped by CI)
    export ASM_PORTAL_URL='https://asmdev.apersonadev2.com:8443/asm_portal'
    export ASM_SERVICE_URL='https://asmdev.apersonadev2.com:8443/asm'
    export ASM_INSTAL_KEY=$(jq -r '.asm.installKey' "$config_file")
    export ADMIN_EMAIL=$(jq -r '.asm.adminEmail' "$config_file")
    local installer_email
    installer_email=$(jq -r '.asm.installerEmail // empty' "$config_file")
    export INSTALLER_EMAIL="${installer_email:-$ADMIN_EMAIL}"
    export ASM_SALT=$(jq -r '.asm.salt' "$config_file")
    
    # SMTP Configuration (needed for validate_global_config)
    export SMTP_HOST=$(jq -r '.smtp.host' "$config_file")
    export SMTP_USER=$(jq -r '.smtp.user' "$config_file")
    export SMTP_PASS=$(jq -r '.smtp.pass' "$config_file")
    export SMTP_SECURE=$(jq -r '.smtp.secure' "$config_file")
    export SMTP_PORT=$(jq -r '.smtp.port' "$config_file")
    
    # reCAPTCHA Configuration (optional)
    export RECAPTCHA_KEY=$(jq -r '.recaptcha.key // empty' "$config_file")
    export RECAPTCHA_SECRET=$(jq -r '.recaptcha.secret // empty' "$config_file")
    
    # Validate required fields for uninstall
    if [[ -z "$ROOT_DOMAIN_NAME" || "$ROOT_DOMAIN_NAME" == "null" ]]; then
        log_error "ROOT_DOMAIN_NAME is required in tenants-config.json"
        exit 1
    fi
    if [[ -z "$ASM_PORTAL_URL" || "$ASM_PORTAL_URL" == "null" ]]; then
        log_error "ASM_PORTAL_URL is required in tenants-config.json"
        exit 1
    fi
    if [[ -z "$ADMIN_EMAIL" || "$ADMIN_EMAIL" == "null" ]]; then
        log_error "ADMIN_EMAIL is required in tenants-config.json"
        exit 1
    fi
    
    log_success "Configuration loaded successfully (no secrets written)"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Track success/failure
record_success() {
    TOTAL_SUCCESS+=1
    log_success "$*"
}

record_failure() {
    TOTAL_FAILED+=1
    FAILED_ITEMS+=("$*")
    log_error "$*"
}

record_skip() {
    TOTAL_SKIPPED+=1
    log_warning "SKIPPED: $*"
}

# Execute or dry-run
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    eval "$@"
}

# Confirm action (respects --force flag)
confirm_action() {
    local prompt=$1
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    confirm_with_timeout "$prompt" 60 "n"
}

# Wait for CloudFormation stack deletion
wait_for_stack_deletion() {
    local stack_name=$1
    local region=${2:-$CDK_DEPLOY_REGION}
    local max_wait=${3:-1800} # 30 minutes default
    local interval=10
    local elapsed=0
    
    log_info "Waiting for stack '$stack_name' deletion in $region..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND")
        
        case "$status" in
            DELETE_COMPLETE|STACK_NOT_FOUND)
                record_success "Stack '$stack_name' deleted successfully"
                return 0
            ;;
            DELETE_FAILED)
                record_failure "Stack '$stack_name' deletion FAILED"
                return 1
            ;;
            DELETE_IN_PROGRESS)
                echo -n "."
                sleep $interval
                elapsed=$((elapsed + interval))
            ;;
            *)
                log_warning "Stack '$stack_name' in unexpected state: $status"
                sleep $interval
                elapsed=$((elapsed + interval))
            ;;
        esac
    done
    
    echo ""
    record_failure "Stack '$stack_name' deletion timed out after ${max_wait}s"
    return 1
}

# Delete a CloudFormation stack with wait
delete_stack() {
    local stack_name=$1
    local region=${2:-$CDK_DEPLOY_REGION}
    
    if ! aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" >/dev/null 2>&1; then
        record_skip "Stack '$stack_name' not found in $region"
        return 0
    fi
    
    log_info "Deleting stack '$stack_name' in $region..."
    if run_cmd "aws cloudformation delete-stack --stack-name '$stack_name' --region '$region'"; then
        if [[ "$DRY_RUN" != "true" ]]; then
            wait_for_stack_deletion "$stack_name" "$region"
        else
            record_success "[DRY-RUN] Would delete stack '$stack_name' in $region"
        fi
    else
        record_failure "Failed to initiate deletion of stack '$stack_name' in $region"
        return 1
    fi
}

# Delete a DynamoDB table safely
delete_dynamodb_table() {
    local table_name=$1
    
    if ! aws dynamodb describe-table --table-name "$table_name" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
        record_skip "DynamoDB table '$table_name' not found"
        return 0
    fi
    
    log_info "Deleting DynamoDB table: $table_name"
    if run_cmd "aws dynamodb delete-table --table-name '$table_name' --region '$CDK_DEPLOY_REGION' >/dev/null 2>&1"; then
        if [[ "$DRY_RUN" != "true" ]]; then
            # Wait for table deletion
            local max_wait=120
            local elapsed=0
            while [[ $elapsed -lt $max_wait ]]; do
                if ! aws dynamodb describe-table --table-name "$table_name" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
                    record_success "DynamoDB table '$table_name' deleted"
                    return 0
                fi
                sleep 5
                elapsed=$((elapsed + 5))
            done
            record_failure "DynamoDB table '$table_name' deletion timed out"
        else
            record_success "[DRY-RUN] Would delete DynamoDB table '$table_name'"
        fi
    else
        record_failure "Failed to delete DynamoDB table '$table_name'"
    fi
}

# Delete a secret from Secrets Manager
delete_secret() {
    local secret_id=$1
    
    if ! aws secretsmanager describe-secret --secret-id "$secret_id" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
        return 0 # Silent skip - secrets may not exist
    fi
    
    log_info "Deleting secret: $secret_id"
    if run_cmd "aws secretsmanager delete-secret --secret-id '$secret_id' --force-delete-without-recovery --region '$CDK_DEPLOY_REGION' >/dev/null 2>&1"; then
        record_success "Secret '$secret_id' deleted"
    else
        record_failure "Failed to delete secret '$secret_id'"
    fi
}

# Empty an S3 bucket recursively
empty_s3_bucket() {
    local bucket_name=$1
    
    # Check if bucket exists (suppress JSON output)
    if ! aws s3api head-bucket --bucket "$bucket_name" >/dev/null 2>&1; then
        record_skip "S3 bucket '$bucket_name' not found"
        return 0
    fi
    
    log_info "Emptying S3 bucket: $bucket_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local count
        count=$(aws s3 ls "s3://$bucket_name" --recursive --summarize 2>/dev/null | grep "Total Objects" | awk '{print $3}' || echo "unknown")
        log_info "[DRY-RUN] Would delete $count objects from s3://$bucket_name"
        return 0
    fi
    
    # Delete all object versions (for versioned buckets)
    aws s3api list-object-versions --bucket "$bucket_name" --output json 2>/dev/null | \
    jq -r '.Versions[]? | "aws s3api delete-object --bucket '"$bucket_name"' --key \"\(.Key)\" --version-id \(.VersionId)"' | \
    while IFS= read -r cmd; do
        eval "$cmd" >/dev/null 2>&1 || true
    done
    
    # Delete all delete markers
    aws s3api list-object-versions --bucket "$bucket_name" --output json 2>/dev/null | \
    jq -r '.DeleteMarkers[]? | "aws s3api delete-object --bucket '"$bucket_name"' --key \"\(.Key)\" --version-id \(.VersionId)"' | \
    while IFS= read -r cmd; do
        eval "$cmd" >/dev/null 2>&1 || true
    done
    
    # Fallback: use s3 rm for non-versioned objects
    aws s3 rm "s3://$bucket_name" --recursive >/dev/null 2>&1 || true

    # Delete the bucket itself (required for RETAIN policy buckets that survive stack deletion)
    if aws s3 rb "s3://$bucket_name" --force >/dev/null 2>&1; then
        record_success "S3 bucket '$bucket_name' emptied and deleted"
    else
        # Bucket may still have objects or delete markers; try force removal
        log_warning "Could not delete bucket '$bucket_name' directly, retrying..."
        aws s3 rb "s3://$bucket_name" >/dev/null 2>&1 || true
        record_success "S3 bucket '$bucket_name' emptied (bucket deletion attempted)"
    fi
}

# ============================================================================
# Phase 1: Read Tenant Data from DynamoDB
# ============================================================================

read_tenant_data() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 1: Reading tenant data from DynamoDB"
    log_info "═══════════════════════════════════════════════════════"
    
    # Check if tenant table exists
    if ! aws dynamodb describe-table --table-name "amfa-tenanttable" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
        log_warning "amfa-tenanttable not found - no tenant data to process"
        TENANT_DATA="[]"
        ORG_IDS=()
        return 0
    fi
    
    # Scan all records from amfa-tenanttable (both tenants and organizations)
    local ALL_DATA
    ALL_DATA=$(aws dynamodb scan \
        --table-name "amfa-tenanttable" \
        --region "$CDK_DEPLOY_REGION" \
    --output json 2>/dev/null || echo '{"Items": []}')
    
    # Extract tenant records (type = "tenant")
    TENANT_DATA=$(echo "$ALL_DATA" | jq '{ Items: [.Items[] | select(.type.S == "tenant")] }')
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    log_info "Found $tenant_count tenant(s) in DynamoDB"
    
    # Extract organization records (type = "organization")
    ORG_DATA=$(echo "$ALL_DATA" | jq '{ Items: [.Items[] | select(.type.S == "organization")] }')
    local org_count
    org_count=$(echo "$ORG_DATA" | jq '.Items | length')
    log_info "Found $org_count organization(s) in DynamoDB"
    
    # Build ORG_IDS from both:
    # 1. org_id references in tenant records
    # 2. organization records themselves (id field with ORG# prefix)
    ORG_IDS=()
    while IFS= read -r org_id_line; do
        if [[ -n "$org_id_line" ]]; then
            ORG_IDS+=("$org_id_line")
        fi
        done < <({
            # From tenant records: org_id field
            echo "$TENANT_DATA" | jq -r '.Items[].org_id.S // empty' 2>/dev/null
            # From organization records: strip ORG# prefix from id field
            echo "$ORG_DATA" | jq -r '.Items[].id.S // empty' 2>/dev/null | sed 's/^ORG#//'
    } | sort -u)
    
    log_info "Found ${#ORG_IDS[@]} unique organization(s) to clean up"
    
    # Display tenant summary
    if [[ $tenant_count -gt 0 ]]; then
        echo ""
        echo "  Tenants to be removed:"
        echo "  ─────────────────────────────────────────────"
        echo "$TENANT_DATA" | jq -r '.Items[] | "  • \(.id.S // "?" | sub("TENANT#"; ""))  (Org: \(.org_id.S // "N/A"), ASM Client: \(.asmClientId.S // "N/A"))"'
        echo ""
    fi
    
    if [[ ${#ORG_IDS[@]} -gt 0 ]]; then
        echo "  Organizations to be removed:"
        echo "  ─────────────────────────────────────────────"
        for org_id in "${ORG_IDS[@]}"; do
            echo "  • $org_id"
        done
        echo ""
    fi
}

# ============================================================================
# Phase 2: SAML Proxy Cleanup
# ============================================================================

cleanup_saml_proxy() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 2: Cleaning up SAML Proxy registrations"
    log_info "═══════════════════════════════════════════════════════"
    
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    
    if [[ $tenant_count -eq 0 ]]; then
        record_skip "No tenants found for SAML proxy cleanup"
        return 0
    fi
    
    # Iterate over each tenant
    for row in $(echo "$TENANT_DATA" | jq -c '.Items[]'); do
        local tenant_id saml_client_id saml_client_secret saml_enabled
        
        tenant_id=$(echo "$row" | jq -r '.id.S // ""' | sed 's/^TENANT#//')
        saml_client_id=$(echo "$row" | jq -r '.samlClientId.S // ""')
        saml_client_secret=$(echo "$row" | jq -r '.samlClientSecret.S // ""')
        saml_enabled=$(echo "$row" | jq -r '.samlproxy.BOOL // true')
        
        if [[ -z "$tenant_id" ]]; then
            continue
        fi
        
        if [[ "$saml_enabled" == "false" ]]; then
            record_skip "SAML proxy disabled for tenant '$tenant_id'"
            continue
        fi
        
        log_info "Deleting SAML proxy registration for tenant: $tenant_id"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would DELETE $SAMLPROXY_API_URL/$tenant_id"
            continue
        fi
        
        local response
        response=$(curl -s -w "\n%{http_code}" -X DELETE \
            "$SAMLPROXY_API_URL/$tenant_id" \
            -d "{\"uninstall\":\"True\", \"clientId\":\"$saml_client_id\", \"clientSecret\":\"$saml_client_secret\"}" \
        2>/dev/null || echo -e "\n000")
        
        local http_code body
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')
        
        if [[ "$http_code" == "200" || "$http_code" == "204" || "$http_code" == "404" ]]; then
            record_success "SAML proxy deleted for tenant '$tenant_id'"
        else
            record_failure "SAML proxy deletion failed for tenant '$tenant_id' (HTTP $http_code): $body"
        fi
    done
}

# ============================================================================
# Phase 3: ASM Tenant Deregistration
# ============================================================================

cleanup_asm_tenants() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 3: Deregistering tenants from ASM portal"
    log_info "═══════════════════════════════════════════════════════"
    
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    
    if [[ $tenant_count -eq 0 ]]; then
        record_skip "No tenants found for ASM deregistration"
        return 0
    fi
    
    for row in $(echo "$TENANT_DATA" | jq -c '.Items[]'); do
        local tenant_id asm_client_id org_id admin_email tenant_name
        tenant_id=$(echo "$row" | jq -r '.id.S // ""' | sed 's/^TENANT#//')
        asm_client_id=$(echo "$row" | jq -r '.asmClientId.S // ""')
        org_id=$(echo "$row" | jq -r '.org_id.S // ""')
        admin_email=$(echo "$row" | jq -r '.adminEmail.S // .contact.S // ""')
        tenant_name=$(echo "$row" | jq -r '.name.S // ""')
        
        if [[ -z "$tenant_id" ]]; then
            continue
        fi
        
        log_info "Processing ASM deregistration for tenant: $tenant_id"
        
        # Get org credentials from Secrets Manager
        local asm_secret_key=""
        if [[ -n "$org_id" ]]; then
            local org_secret
            org_secret=$(aws secretsmanager get-secret-value \
                --secret-id "apersona/asm/org/$org_id" \
                --region "$CDK_DEPLOY_REGION" \
            --query 'SecretString' --output text 2>/dev/null || echo "")
            if [[ -n "$org_secret" ]]; then
                asm_secret_key=$(echo "$org_secret" | jq -r '.asmSecretKey // ""')
            fi
        fi
        
        # Fallback: try tenant-level secret
        local asm_client_secret_key=""
        local tenant_secret
        tenant_secret=$(aws secretsmanager get-secret-value \
            --secret-id "apersona/asm/tenant/$tenant_id" \
            --region "$CDK_DEPLOY_REGION" \
        --query 'SecretString' --output text 2>/dev/null || echo "")
        if [[ -n "$tenant_secret" ]]; then
            asm_client_secret_key=$(echo "$tenant_secret" | jq -r '.asmClientSecretKey // ""')
            # Fallback for asm_client_id
            if [[ -z "$asm_client_id" ]]; then
                asm_client_id=$(echo "$tenant_secret" | jq -r '.asmClientId // ""')
            fi
        fi
        
        if [[ -z "$asm_secret_key" ]]; then
            record_failure "No ASM secret key found for tenant '$tenant_id' (org: $org_id), skipping ASM deregistration"
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would call tenantAdmin.ap (action=remove) for tenant '$tenant_id'"
            log_info "[DRY-RUN] Would call deleteAsmClient.ap for ASM client '$asm_client_id'"
            continue
        fi
        
        # Step 3a: Remove TA admin via tenantAdmin.ap
        if [[ -n "$admin_email" && -n "$asm_client_id" ]]; then
            log_info "  Removing tenant admin '$admin_email' from ASM..."
            local decoded_tenant_name
            decoded_tenant_name=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$tenant_name'))" 2>/dev/null || echo "$tenant_name")
            
            local ta_response
            ta_response=$(curl -s -X POST "$ASM_PORTAL_URL/tenantAdmin.ap" \
                -d "tenantId=$asm_client_id" \
                -d "tenantName=$(jq -rn --arg v "$decoded_tenant_name" '$v | @uri')" \
                -d "tenantAdminEmail=$admin_email" \
                -d "action=remove" \
                -d "requestedBy=$INSTALLER_EMAIL" \
                -d "awsAccountId=$CDK_DEPLOY_ACCOUNT" \
                -d "asmSecretKey=$asm_secret_key" \
            -H "Accept:application/json" 2>/dev/null || echo '{"code": 0}')
            
            local ta_code
            ta_code=$(echo "$ta_response" | jq -r '.code // 0')
            if [[ "$ta_code" == "200" ]]; then
                log_info "  ✓ Tenant admin removed from ASM"
            else
                log_warning "  tenantAdmin.ap returned code $ta_code: $ta_response"
            fi
        fi
        
        # Step 3b: Delete ASM client via deleteAsmClient.ap
        if [[ -n "$asm_client_id" ]]; then
            log_info "  Deleting ASM client '$asm_client_id'..."
            local del_response
            del_response=$(curl -s -X POST "$ASM_PORTAL_URL/deleteAsmClient.ap" \
                -d "asmClientId=$asm_client_id" \
                -d "requestedBy=$INSTALLER_EMAIL" \
                -d "asmSecretKey=$asm_secret_key" \
                -d "asmClientSecretKey=${asm_client_secret_key:-$asm_secret_key}" \
            -H "Accept:application/json" 2>/dev/null || echo '{"code": 0}')
            
            local del_code
            del_code=$(echo "$del_response" | jq -r '.code // 0')
            if [[ "$del_code" == "200" ]]; then
                record_success "ASM client '$asm_client_id' deleted for tenant '$tenant_id'"
            else
                record_failure "Failed to delete ASM client '$asm_client_id' for tenant '$tenant_id' (code $del_code): $del_response"
            fi
        else
            record_skip "No ASM client ID for tenant '$tenant_id'"
        fi
    done
}

# ============================================================================
# Phase 4: ASM Service Provider Deletion
# ============================================================================

cleanup_asm_service_providers() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 4: Deleting ASM Service Providers (per org)"
    log_info "═══════════════════════════════════════════════════════"
    
    if [[ ${#ORG_IDS[@]} -eq 0 ]]; then
        record_skip "No organizations found for ASM Service Provider cleanup"
        return 0
    fi
    
    for org_id in "${ORG_IDS[@]}"; do
        log_info "Processing ASM Service Provider for org: $org_id"
        
        local org_secret
        org_secret=$(aws secretsmanager get-secret-value \
            --secret-id "apersona/asm/org/$org_id" \
            --region "$CDK_DEPLOY_REGION" \
        --query 'SecretString' --output text 2>/dev/null || echo "")
        
        if [[ -z "$org_secret" ]]; then
            record_failure "No credentials found for org '$org_id', skipping SP deletion"
            continue
        fi
        
        local sp_id asm_secret_key
        sp_id=$(echo "$org_secret" | jq -r '.serviceProviderId // ""')
        asm_secret_key=$(echo "$org_secret" | jq -r '.asmSecretKey // ""')
        
        if [[ -z "$sp_id" || -z "$asm_secret_key" ]]; then
            record_failure "Incomplete credentials for org '$org_id' (SP ID: $sp_id)"
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would call deleteServiceProvider.ap for SP '$sp_id' (org: $org_id)"
            continue
        fi
        
        log_info "  Deleting Service Provider '$sp_id' for org '$org_id'..."
        local sp_response
        sp_response=$(curl -s -X POST "$ASM_PORTAL_URL/deleteServiceProvider.ap" \
            -d "serviceProviderId=$sp_id" \
            -d "awsAccountId=$CDK_DEPLOY_ACCOUNT" \
            -d "awsSecretKey=$asm_secret_key" \
            -d "requestedBy=$INSTALLER_EMAIL" \
        -H "Accept:application/json" 2>/dev/null || echo '{"code": 0}')
        
        local sp_code
        sp_code=$(echo "$sp_response" | jq -r '.code // 0')
        if [[ "$sp_code" == "200" ]]; then
            record_success "ASM Service Provider '$sp_id' deleted for org '$org_id'"
        else
            record_failure "Failed to delete ASM SP '$sp_id' for org '$org_id' (code $sp_code): $sp_response"
        fi
    done
}

# ============================================================================
# Phase 5: Delete Per-Tenant Cognito UserPools
# ============================================================================

cleanup_cognito_userpools() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 5: Deleting per-tenant Cognito UserPools"
    log_info "═══════════════════════════════════════════════════════"
    
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    
    if [[ $tenant_count -eq 0 ]]; then
        record_skip "No tenants found for Cognito cleanup"
        return 0
    fi
    
    for row in $(echo "$TENANT_DATA" | jq -c '.Items[]'); do
        local tenant_id user_pool_id oauth_domain
        tenant_id=$(echo "$row" | jq -r '.id.S // ""' | sed 's/^TENANT#//')
        user_pool_id=$(echo "$row" | jq -r '.userpool.S // ""')
        oauth_domain=$(echo "$row" | jq -r '.oauthDomain.S // ""')
        
        if [[ -z "$user_pool_id" || "$user_pool_id" == "null" ]]; then
            record_skip "No UserPool ID for tenant '$tenant_id'"
            continue
        fi
        
        # Verify UserPool exists
        if ! aws cognito-idp describe-user-pool --user-pool-id "$user_pool_id" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
            record_skip "UserPool '$user_pool_id' for tenant '$tenant_id' not found"
            continue
        fi
        
        log_info "Deleting Cognito UserPool for tenant '$tenant_id': $user_pool_id"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would delete UserPool domain and UserPool '$user_pool_id'"
            continue
        fi
        
        # Step 5a: Delete UserPool domain first (required before pool deletion)
        # Extract domain prefix from oauthDomain (e.g., "tenantid-abc123.auth.us-east-1.amazoncognito.com" -> "tenantid-abc123")
        local domain_prefix=""
        if [[ -n "$oauth_domain" && "$oauth_domain" != "null" ]]; then
            domain_prefix=$(echo "$oauth_domain" | sed 's/\.auth\..*//')
        fi
        
        # If no oauth_domain in DDB, try to describe the pool to get it
        if [[ -z "$domain_prefix" ]]; then
            domain_prefix=$(aws cognito-idp describe-user-pool \
                --user-pool-id "$user_pool_id" \
                --region "$CDK_DEPLOY_REGION" \
            --query 'UserPool.Domain' --output text 2>/dev/null || echo "")
        fi
        
        if [[ -n "$domain_prefix" && "$domain_prefix" != "None" && "$domain_prefix" != "null" ]]; then
            log_info "  Deleting UserPool domain: $domain_prefix"
            aws cognito-idp delete-user-pool-domain \
            --domain "$domain_prefix" \
            --user-pool-id "$user_pool_id" \
            --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1 || true
            # Wait for domain deletion to propagate
            sleep 2
        fi
        
        # Step 5b: Delete UserPool (cascades to all clients, providers, etc.)
        if aws cognito-idp delete-user-pool \
        --user-pool-id "$user_pool_id" \
        --region "$CDK_DEPLOY_REGION" 2>/dev/null; then
            record_success "Cognito UserPool '$user_pool_id' deleted for tenant '$tenant_id'"
        else
            record_failure "Failed to delete Cognito UserPool '$user_pool_id' for tenant '$tenant_id'"
        fi
    done
}

# ============================================================================
# Phase 6: Delete Per-Tenant DynamoDB Tables
# ============================================================================

cleanup_tenant_dynamodb_tables() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 6: Deleting per-tenant DynamoDB tables"
    log_info "═══════════════════════════════════════════════════════"
    
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    
    if [[ $tenant_count -eq 0 ]]; then
        record_skip "No tenants found for DynamoDB table cleanup"
        return 0
    fi
    
    for row in $(echo "$TENANT_DATA" | jq -c '.Items[]'); do
        local tenant_id
        tenant_id=$(echo "$row" | jq -r '.id.S // ""' | sed 's/^TENANT#//')
        
        if [[ -z "$tenant_id" ]]; then
            continue
        fi
        
        log_info "Deleting DynamoDB tables for tenant: $tenant_id"
        
        # 6 per-tenant tables
        local table_types=("authcode" "sessionid" "totptoken" "pwdhash" "spinfo" "importjobid")
        for table_type in "${table_types[@]}"; do
            delete_dynamodb_table "amfa-${table_type}-${tenant_id}"
        done
    done
}

# ============================================================================
# Phase 7: Delete Per-Tenant and Global Secrets
# ============================================================================

cleanup_secrets() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 7: Deleting Secrets Manager secrets"
    log_info "═══════════════════════════════════════════════════════"
    
    # Per-tenant secrets
    local tenant_count
    tenant_count=$(echo "$TENANT_DATA" | jq '.Items | length')
    
    for row in $(echo "$TENANT_DATA" | jq -c '.Items[]'); do
        local tenant_id
        tenant_id=$(echo "$row" | jq -r '.id.S // ""' | sed 's/^TENANT#//')
        
        if [[ -z "$tenant_id" ]]; then
            continue
        fi
        
        log_info "Deleting secrets for tenant: $tenant_id"
        delete_secret "apersona/${tenant_id}/smtp"
        delete_secret "apersona/${tenant_id}/secret"
        delete_secret "apersona/${tenant_id}/asm"
        delete_secret "apersona/asm/tenant/${tenant_id}"
    done
    
    # Per-org secrets
    for org_id in "${ORG_IDS[@]+"${ORG_IDS[@]}"}"; do
        log_info "Deleting secrets for org: $org_id"
        delete_secret "apersona/asm/org/$org_id"
    done
    
    # Global secrets
    log_info "Deleting global secrets..."
    delete_secret "apersona/asm/installkey"
    delete_secret "apersona/asm/credentials"
}

# ============================================================================
# Phase 8: Clean S3 Buckets
# ============================================================================

cleanup_s3_buckets() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 8: Cleaning S3 buckets"
    log_info "═══════════════════════════════════════════════════════"
    
    # Shared AMFA service bucket
    empty_s3_bucket "amfa-service-shared-${CDK_DEPLOY_ACCOUNT}-${CDK_DEPLOY_REGION}"
    
    # Shared SP portal bucket
    empty_s3_bucket "sp-portal-shared-${CDK_DEPLOY_ACCOUNT}-${CDK_DEPLOY_REGION}"
    
    # Admin portal bucket
    empty_s3_bucket "${CDK_DEPLOY_ACCOUNT}-${CDK_DEPLOY_REGION}-adminportal-amfa-web"
    
    # Admin portal import users jobs bucket (if exists)
    empty_s3_bucket "${CDK_DEPLOY_ACCOUNT}-${CDK_DEPLOY_REGION}-adminportal-importusersjobs"
    
    # CloudFront log buckets, CDK auto-generated buckets, and access log buckets
    # These are created by CDK with auto-generated names (e.g., amfastack-sharedamfaservice...-xxx)
    log_info "Looking for additional S3 buckets to clean..."
    local buckets
    buckets=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || echo "")
    for bucket in $buckets; do
        case "$bucket" in
            amfa-service-shared-*|sp-portal-shared-*|*-adminportal-amfa-*|*-adminportal-importusersjobs)
                # Already handled above
            ;;
            amfastack-*)
                # CloudFront log buckets auto-created by CDK (e.g., amfastack-sharedamfaservice...-xxx)
                log_info "Found AmfaStack CDK bucket: $bucket"
                empty_s3_bucket "$bucket"
            ;;
            access-log-${CDK_DEPLOY_ACCOUNT}*)
                # S3 server access log bucket
                log_info "Found access log bucket: $bucket"
                empty_s3_bucket "$bucket"
            ;;
            *amfa*log*|*amfa*access*)
                log_info "Found additional AMFA-related bucket: $bucket"
                empty_s3_bucket "$bucket"
            ;;
        esac
    done
}

# ============================================================================
# Phase 9: Delete CloudFormation Stacks
# ============================================================================

cleanup_cloudformation_stacks() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 9: Deleting CloudFormation stacks"
    log_info "═══════════════════════════════════════════════════════"
    
    # Admin portal stacks first (depend on AMFA stack SSM params)
    log_info "--- Admin Portal Stacks ---"
    delete_stack "SSO-CUPStack" "$CDK_DEPLOY_REGION"
    delete_stack "APICertificateStack" "$CDK_DEPLOY_REGION"
    delete_stack "CertStack222" "us-east-1"
    
    # AMFA main stack (depends on certificate stacks)
    log_info "--- AMFA Service Stacks ---"
    delete_stack "AmfaStack" "$CDK_DEPLOY_REGION"
    
    # Certificate stacks (us-east-1) - delete after main stacks that reference them
    log_info "--- Certificate Stacks (us-east-1) ---"
    delete_stack "SharedApiCertificateStack" "us-east-1"
    delete_stack "RootWildcardCertificateStack" "us-east-1"
    delete_stack "LoginWildcardCertificateStack" "us-east-1"
    delete_stack "IdaPersonaWildcardCertificateStack" "us-east-1"
}

# ============================================================================
# Phase 10: Delete Shared DynamoDB Tables
# ============================================================================

cleanup_shared_dynamodb() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 10: Deleting shared DynamoDB tables"
    log_info "═══════════════════════════════════════════════════════"
    
    delete_dynamodb_table "amfa-configtable"
    delete_dynamodb_table "amfa-tenanttable"
}

# ============================================================================
# Phase 11: Route53 Cleanup
# ============================================================================

cleanup_route53() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 11: Cleaning up Route53 DNS records"
    log_info "═══════════════════════════════════════════════════════"
    
    local ADMINPORTAL_DOMAIN_NAME="adminportal.${ROOT_DOMAIN_NAME}"
    
    # Helper: delete all non-NS/SOA records from a hosted zone, then delete the zone
    delete_hosted_zone() {
        local zone_domain=$1
        local zone_ids
        
        zone_ids=$(aws route53 list-hosted-zones --output json 2>/dev/null | \
            jq -r --arg domain "${zone_domain}." \
        '.HostedZones[] | select(.Name == $domain) | .Id | sub("/hostedzone/"; "")' 2>/dev/null || echo "")
        
        if [[ -z "$zone_ids" ]]; then
            record_skip "No hosted zone found for '$zone_domain'"
            return 0
        fi
        
        for zone_id in $zone_ids; do
            log_info "Cleaning hosted zone '$zone_domain' (ID: $zone_id)"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would delete all records and hosted zone '$zone_id'"
                continue
            fi
            
            # Delete A, CNAME, and other non-essential records
            local record_types=("A" "CNAME" "AAAA")
            for rtype in "${record_types[@]}"; do
                local batches
                batches=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null | \
                    jq --compact-output --arg rtype "$rtype" \
                    '[.ResourceRecordSets[] | select(.Type == $rtype) |
                    {Action: "DELETE", ResourceRecordSet: (
                        if .AliasTarget then
                            {Name: .Name, Type: .Type, AliasTarget: .AliasTarget}
                        else
                            {Name: .Name, Type: .Type, TTL: .TTL, ResourceRecords: .ResourceRecords}
                        end
                )}] | if length > 0 then {Changes: .} else empty end' 2>/dev/null || echo "")
                
                if [[ -n "$batches" ]]; then
                    aws route53 change-resource-record-sets \
                    --hosted-zone-id "$zone_id" \
                    --change-batch "$batches" >/dev/null 2>&1 || true
                fi
            done
            
            # Delete the hosted zone
            if aws route53 delete-hosted-zone --id "$zone_id" >/dev/null 2>&1; then
                record_success "Hosted zone '$zone_domain' ($zone_id) deleted"
            else
                record_failure "Failed to delete hosted zone '$zone_domain' ($zone_id)"
            fi
        done
    }
    
    # Delete admin portal subdomain hosted zone
    log_info "Removing adminportal subdomain from DNS..."
    delete_hosted_zone "$ADMINPORTAL_DOMAIN_NAME"
    
    # Delete NS delegation records from root hosted zone
    log_info "Removing NS delegation records from root hosted zone..."
    if [[ -n "${ROOT_HOSTED_ZONE_ID:-}" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            # Remove adminportal NS delegation
            local ns_batch
            ns_batch=$(aws route53 list-resource-record-sets --hosted-zone-id "$ROOT_HOSTED_ZONE_ID" --output json 2>/dev/null | \
                jq --compact-output --arg name "${ADMINPORTAL_DOMAIN_NAME}." \
                '[.ResourceRecordSets[] | select(.Type == "NS" and .Name == $name) |
                {Action: "DELETE", ResourceRecordSet: {Name: .Name, Type: .Type, TTL: .TTL, ResourceRecords: .ResourceRecords}}] |
            if length > 0 then {Changes: .} else empty end' 2>/dev/null || echo "")
            
            if [[ -n "$ns_batch" ]]; then
                aws route53 change-resource-record-sets \
                --hosted-zone-id "$ROOT_HOSTED_ZONE_ID" \
                --change-batch "$ns_batch" >/dev/null 2>&1 && \
                record_success "Removed adminportal NS delegation from root zone" || \
                record_failure "Failed to remove adminportal NS delegation"
            else
                record_skip "No adminportal NS delegation found in root zone"
            fi
        else
            log_info "[DRY-RUN] Would remove NS delegation records from root hosted zone"
        fi
    else
        record_skip "ROOT_HOSTED_ZONE_ID not set, skipping NS delegation cleanup"
    fi
}

# ============================================================================
# Phase 12: SSM Parameter Cleanup
# ============================================================================

cleanup_ssm_parameters() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 12: Cleaning up SSM Parameters"
    log_info "═══════════════════════════════════════════════════════"
    
    # Helper to delete SSM parameters matching a filter
    delete_ssm_params_by_filter() {
        local filter_value=$1
        local region=$2
        local description=$3
        
        local params
        params=$(aws ssm describe-parameters \
            --parameter-filters "Key=Name,Option=Contains,Values=$filter_value" \
            --region "$region" \
        --query 'Parameters[].Name' --output text 2>/dev/null || echo "")
        
        if [[ -z "$params" ]]; then
            record_skip "No SSM parameters found matching '$filter_value' in $region"
            return 0
        fi
        
        log_info "Deleting SSM parameters matching '$filter_value' in $region ($description)..."
        
        for param_name in $params; do
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would delete SSM param: $param_name"
                continue
            fi
            if aws ssm delete-parameter --name "$param_name" --region "$region" >/dev/null 2>&1; then
                record_success "SSM parameter '$param_name' deleted"
            else
                record_failure "Failed to delete SSM parameter '$param_name'"
            fi
        done
    }
    
    # AMFA Lambda ARNs and infrastructure params
    delete_ssm_params_by_filter "/amfa/" "$CDK_DEPLOY_REGION" "AMFA shared infrastructure"
    
    # Tenant configurations in SSM
    delete_ssm_params_by_filter "/apersona/" "$CDK_DEPLOY_REGION" "aPersona tenant configs"
    
    # Cross-region exporter parameters created by CloudFormation
    delete_ssm_params_by_filter "/AmfaStack/" "$CDK_DEPLOY_REGION" "AmfaStack cross-region exports"
    delete_ssm_params_by_filter "/SSO-CUPStack/" "$CDK_DEPLOY_REGION" "SSO-CUPStack cross-region exports"
    delete_ssm_params_by_filter "/SharedApiCertificateStack/" "$CDK_DEPLOY_REGION" "SharedApiCert cross-region exports"
    delete_ssm_params_by_filter "/RootWildcardCertificateStack/" "$CDK_DEPLOY_REGION" "RootWildcardCert cross-region exports"
    delete_ssm_params_by_filter "/LoginWildcardCertificateStack/" "$CDK_DEPLOY_REGION" "LoginWildcardCert cross-region exports"
    delete_ssm_params_by_filter "/IdaPersonaWildcardCertificateStack/" "$CDK_DEPLOY_REGION" "IdaPersonaWildcardCert cross-region exports"
    delete_ssm_params_by_filter "/CertStack222/" "$CDK_DEPLOY_REGION" "CertStack222 cross-region exports"
    delete_ssm_params_by_filter "/APICertificateStack/" "$CDK_DEPLOY_REGION" "APICertificateStack cross-region exports"
    
    # Also clean us-east-1 if different from deployment region
    if [[ "$CDK_DEPLOY_REGION" != "us-east-1" ]]; then
        log_info "Also cleaning cross-region parameters in us-east-1..."
        delete_ssm_params_by_filter "/AmfaStack/" "us-east-1" "AmfaStack cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/SSO-CUPStack/" "us-east-1" "SSO-CUPStack cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/SharedApiCertificateStack/" "us-east-1" "SharedApiCert cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/RootWildcardCertificateStack/" "us-east-1" "RootWildcardCert cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/LoginWildcardCertificateStack/" "us-east-1" "LoginWildcardCert cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/IdaPersonaWildcardCertificateStack/" "us-east-1" "IdaPersonaWildcardCert cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/CertStack222/" "us-east-1" "CertStack222 cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/APICertificateStack/" "us-east-1" "APICertificateStack cross-region exports (us-east-1)"
        delete_ssm_params_by_filter "/amfa/" "us-east-1" "AMFA params (us-east-1)"
    fi
}

# ============================================================================
# Phase 13: IAM Cleanup
# ============================================================================

cleanup_iam() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Phase 13: Cleaning up IAM resources"
    log_info "═══════════════════════════════════════════════════════"
    
    local role_name="CrossAccountDnsDelegationRole-DO-NOT-DELETE"
    local policy_name="dns-delegation-policy"
    local policy_arn="arn:aws:iam::${CDK_DEPLOY_ACCOUNT}:policy/${policy_name}"
    
    # Check if role exists
    if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        record_skip "IAM role '$role_name' not found"
        return 0
    fi
    
    log_info "Cleaning up DNS delegation IAM resources..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would detach and delete policy '$policy_name' from role '$role_name'"
        log_info "[DRY-RUN] Would delete role '$role_name'"
        return 0
    fi
    
    # Detach policy from role
    aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true
    
    # Delete policy
    if aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null; then
        log_info "  Deleted policy: $policy_name"
    else
        log_warning "  Policy '$policy_name' not found or already deleted"
    fi
    
    # Delete role
    if aws iam delete-role --role-name "$role_name" 2>/dev/null; then
        record_success "IAM role '$role_name' deleted"
    else
        record_failure "Failed to delete IAM role '$role_name'"
    fi
}

# ============================================================================
# Show Summary
# ============================================================================

show_summary() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         UNINSTALL SUMMARY                            ║"
    echo "╠═══════════════════════════════════════════════════════╣"
    echo "║  Account:  $CDK_DEPLOY_ACCOUNT"
    echo "║  Region:   $CDK_DEPLOY_REGION"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "║  Mode:     DRY-RUN (no changes made)"
    fi
    echo "╠═══════════════════════════════════════════════════════╣"
    printf "║  ✓ Successful: %-5d                                 ║\n" "$TOTAL_SUCCESS"
    printf "║  ✗ Failed:     %-5d                                 ║\n" "$TOTAL_FAILED"
    printf "║  ⊘ Skipped:    %-5d                                 ║\n" "$TOTAL_SKIPPED"
    echo "╚═══════════════════════════════════════════════════════╝"
    
    if [[ $TOTAL_FAILED -gt 0 ]]; then
        echo ""
        log_error "The following items failed:"
        for item in "${FAILED_ITEMS[@]}"; do
            echo "  ✗ $item"
        done
        echo ""
        log_warning "Some resources may need manual cleanup."
        log_warning "Check the AWS Console for remaining resources."
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        log_info "This was a DRY RUN. No changes were made."
        log_info "Run without --dry-run to perform the actual uninstall."
    fi
    
    echo ""
}

# ============================================================================
# Error Handling and Cleanup
# ============================================================================

cleanup() {
    log_info "Performing cleanup..."
    unset NODE_OPTIONS 2>/dev/null || true
}

handle_error() {
    local exit_code=$1
    local line_number=$2
    log_error "Script encountered an error at line $line_number (exit code: $exit_code)"
    log_error "Continuing with cleanup..."
    # Don't exit - let the script continue to clean up what it can
}

# Use trap to continue on errors rather than exit
trap 'handle_error $? $LINENO' ERR
trap cleanup EXIT

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Change to project directory
    cd "$PROJECT_DIR" || {
        log_error "Project directory not found: $PROJECT_DIR"
        exit 1
    }
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║    aPersona Identity Manager Multi-Tenant Uninstaller ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY-RUN MODE: No changes will be made"
        echo ""
    fi
    
    # Load configuration (lightweight - no Secrets Manager side effects)
    # We don't use load_config_from_json because it creates/updates the
    # apersona/asm/installkey secret as a side effect, which we don't want
    # during uninstall.
    load_config_for_uninstall
    
    # Validate AWS credentials and detect environment
    validate_aws_credentials
    detect_aws_environment
    
    # Resolve hosted zone ID (non-fatal if it fails)
    resolve_hosted_zone_id 2>/dev/null || {
        log_warning "Could not resolve hosted zone ID. Route53 cleanup may be limited."
        export ROOT_HOSTED_ZONE_ID=""
    }
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Uninstall Target:"
    echo "  Account:      $CDK_DEPLOY_ACCOUNT"
    echo "  Region:       $CDK_DEPLOY_REGION"
    echo "  Domain:       $ROOT_DOMAIN_NAME"
    echo "  ASM Portal:   $ASM_PORTAL_URL"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    if ! confirm_action "This will PERMANENTLY DELETE all aPersona resources. Continue?"; then
        log_info "Uninstall cancelled by user"
        exit 0
    fi
    
    local start_time
    start_time=$(date +%s)
    
    # Phase 1: Read tenant data (must be first - feeds all subsequent phases)
    read_tenant_data
    
    # Phase 2: SAML Proxy cleanup (external service - do before deleting Cognito)
    cleanup_saml_proxy
    
    # Phase 3: ASM tenant deregistration (external service - do before deleting tenants)
    cleanup_asm_tenants
    
    # Phase 4: ASM Service Provider deletion (after all tenants deregistered)
    cleanup_asm_service_providers
    
    # Phase 5: Delete Cognito UserPools (per-tenant runtime resources)
    cleanup_cognito_userpools
    
    # Phase 6: Delete per-tenant DynamoDB tables (runtime-created)
    cleanup_tenant_dynamodb_tables
    
    # Phase 7: Delete Secrets Manager secrets (per-tenant + per-org + global)
    cleanup_secrets
    
    # Phase 8: Clean S3 buckets (must empty before CloudFormation can delete them)
    cleanup_s3_buckets
    
    # Phase 9: Delete CloudFormation stacks (the bulk of shared infrastructure)
    cleanup_cloudformation_stacks
    
    # Phase 10: Delete shared DynamoDB tables (might survive stack deletion due to RETAIN policy)
    cleanup_shared_dynamodb
    
    # Phase 11: Route53 cleanup (subdomains and NS delegations)
    cleanup_route53
    
    # Phase 12: SSM Parameter cleanup (cross-region exporter params)
    cleanup_ssm_parameters
    
    # Phase 13: IAM cleanup (DNS delegation role)
    cleanup_iam
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    log_info "Uninstall completed in ${duration} seconds"
    
    # Show summary
    show_summary
    
    if [[ $TOTAL_FAILED -eq 0 ]]; then
        log_success "aPersona Identity Manager has been completely uninstalled!"
    else
        log_warning "Uninstall completed with $TOTAL_FAILED failure(s). Review the summary above."
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
