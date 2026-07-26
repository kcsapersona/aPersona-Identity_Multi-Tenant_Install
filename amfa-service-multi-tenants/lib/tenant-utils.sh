#!/bin/bash

# Tenant utilities for aPersona Multi-Tenant Installer
# This file contains tenant registration and configuration functions

# Repository names (defined in main script)
# APERSONAIDP_REPO_NAME is set in the main script

# Exit codes (if not already defined)
if [[ -z "${EXIT_SUCCESS:-}" ]]; then
    readonly EXIT_SUCCESS=0
    readonly EXIT_ERROR=1
    readonly EXIT_USER_CANCEL=2
    readonly EXIT_CONFIG_ERROR=3
    readonly EXIT_AWS_ERROR=4
fi
# Update mobile token details globally - ONE-TIME for entire deployment
update_mobile_token_global() {
    log_info "Updating mobile token details with ASM portal..."
    
    # Get mobile token details from CDK outputs (global, non-tenant-specific)
    local mobile_token_api_client_id mobile_token_api_client_secret mobile_token_auth_endpoint_uri mobile_token_api_endpoint_uri
    mobile_token_api_client_id=$(jq -rc ".AmfaStack.AmfamobileTokenApiClientId" ../apersona_idp_deploy_outputs.json)
    mobile_token_api_client_secret=$(jq -rc ".AmfaStack.AmfamobileTokenApiClientSecret" ../apersona_idp_deploy_outputs.json)
    mobile_token_auth_endpoint_uri=$(jq -rc ".AmfaStack.AmfamobileTokenAuthEndpointUri" ../apersona_idp_deploy_outputs.json)
    mobile_token_api_endpoint_uri=$(jq -rc ".AmfaStack.AmfamobileTokenApiEndpointUri" ../apersona_idp_deploy_outputs.json)

    if [[ -z "$mobile_token_api_client_id" || "$mobile_token_api_client_id" = "null" ]]; then
        log_error "Mobile token API client ID not found in CDK outputs"
        return 1
    fi

    # URL encode the endpoints
    mobile_token_auth_endpoint_uri=$(jq -rn --arg x "$mobile_token_auth_endpoint_uri" '$x|@uri')
    mobile_token_api_endpoint_uri=$(jq -rn --arg x "$mobile_token_api_endpoint_uri" '$x|@uri')

    # Get ASM client details from secrets manager (global credentials)
    local install_param asm_client_secret_key asm_client_id
    install_param=$(aws secretsmanager get-secret-value --region "$CDK_DEPLOY_REGION" --secret-id "apersona/asm/credentials" 2>/dev/null)
    
    if [[ -z "$install_param" ]]; then
        log_error "ASM credentials not found in Secrets Manager"
        return 1
    fi

    install_param=$(echo "$install_param" | jq -r .SecretString | jq -r -c .registRes)
    asm_client_secret_key=$(echo "$install_param" | jq -r .asmClientSecretKey)
    asm_client_id=$(echo "$install_param" | jq -r .asmClientId)

    if [[ -z "$asm_client_secret_key" || "$asm_client_secret_key" = "null" || -z "$asm_client_id" || "$asm_client_id" = "null" ]]; then
        log_error "Invalid ASM credentials in Secrets Manager"
        return 1
    fi

    # Update ASM with mobile token details
    log_info "Mobile Token Update Request:"
    log_info "  URL: $ASM_PORTAL_URL/updateAsmClientMobileTokenDetails.ap"
    log_info "  ASM Client ID: $asm_client_id"
    log_info "  Mobile Token Auth Endpoint: $mobile_token_auth_endpoint_uri"
    log_info "  Mobile Token API Endpoint: $mobile_token_api_endpoint_uri"
    
    local pass_secret_res update_mob_sec_stats_code
    pass_secret_res=$(timeout 30 curl -s -X POST "$ASM_PORTAL_URL/updateAsmClientMobileTokenDetails.ap" \
        -H "Content-Type:application/json" \
        -d "{\"mobileTokenApiClientId\":\"$mobile_token_api_client_id\",\"mobileTokenApiClientSecret\":\"$mobile_token_api_client_secret\",\"mobileTokenAuthEndpointUri\":\"$mobile_token_auth_endpoint_uri\",\"asmClientSecretKey\":\"$asm_client_secret_key\",\"mobileTokenApiEndpointUri\":\"$mobile_token_api_endpoint_uri\",\"asmClientId\":$asm_client_id}" 2>&1)
    
    log_info "Mobile Token Update Response:"
    log_info "$pass_secret_res"
    
    update_mob_sec_stats_code=$(echo "$pass_secret_res" | jq -r .code 2>/dev/null || echo "error")
    
    if [[ "$update_mob_sec_stats_code" != "200" ]]; then
        log_error "Failed to update mobile token details with ASM portal"
        log_error "Response code: $update_mob_sec_stats_code"
        return 1
    fi

    log_success "Mobile token details updated successfully with ASM portal"
    return 0
}

# Update ASM URLs for all existing tenants in DynamoDB
# Called during redeployment to propagate new ASM_SERVICE_URL/ASM_PORTAL_URL to existing tenants
update_existing_tenants_asm_urls() {
    local asm_service_url="${ASM_SERVICE_URL:-}"
    local asm_portal_url="${ASM_PORTAL_URL:-}"

    if [[ -z "$asm_service_url" || -z "$asm_portal_url" ]]; then
        log_warning "ASM_SERVICE_URL or ASM_PORTAL_URL not set, skipping DDB update"
        return 0
    fi

    log_info "Updating ASM URLs for existing tenants in amfa-configtable..."

    # Check if config table exists
    if ! aws dynamodb describe-table --table-name "amfa-configtable" --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
        log_info "amfa-configtable not found — no existing tenants to update"
        return 0
    fi

    # Scan all amfaConfigs records
    local items
    if ! items=$(aws dynamodb scan \
        --table-name "amfa-configtable" \
        --filter-expression "configtype = :ct" \
        --expression-attribute-values '{":ct":{"S":"amfaConfigs"}}' \
        --region "$CDK_DEPLOY_REGION" \
        --output json 2>/dev/null); then
        log_warning "Failed to scan amfa-configtable — existing tenants were NOT updated with new ASM URLs"
        return 0
    fi

    local count
    count=$(echo "$items" | jq '.Items | length')

    if [[ "$count" -eq 0 ]]; then
        log_info "No existing tenant configs found — nothing to update"
        return 0
    fi

    local updated=0
    for i in $(seq 0 $((count - 1))); do
        local tenant_id current_value updated_value
        tenant_id=$(echo "$items" | jq -r ".Items[$i].id.S")
        current_value=$(echo "$items" | jq -r ".Items[$i].value.S")

        # Update asmurl and asm_portal_url in the JSON value
        updated_value=$(echo "$current_value" | jq \
            --arg asmurl "$asm_service_url" \
            --arg portal "$asm_portal_url" \
            '.asmurl = $asmurl | .asm_portal_url = $portal')

        # Write back to DynamoDB
        local escaped_value
        escaped_value=$(echo "$updated_value" | jq -c . | jq -Rs .)

        if aws dynamodb update-item \
            --table-name "amfa-configtable" \
            --key "{\"id\":{\"S\":\"$tenant_id\"},\"configtype\":{\"S\":\"amfaConfigs\"}}" \
            --update-expression "SET #v = :v" \
            --expression-attribute-names '{"#v":"value"}' \
            --expression-attribute-values "{\":v\":{\"S\":$escaped_value}}" \
            --region "$CDK_DEPLOY_REGION" >/dev/null 2>&1; then
            updated=$((updated + 1))
            log_info "  ✓ Updated tenant: $tenant_id"
        else
            log_warning "  ✗ Failed to update tenant: $tenant_id"
        fi
    done

    log_success "Updated ASM URLs for $updated/$count tenant(s)"
    return 0
}
