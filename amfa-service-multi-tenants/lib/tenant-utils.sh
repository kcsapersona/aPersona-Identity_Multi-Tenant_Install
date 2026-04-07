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
