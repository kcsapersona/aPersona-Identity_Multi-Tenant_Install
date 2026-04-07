#!/bin/bash

# SSM Tenant Manager
# Manages tenant configurations in AWS Systems Manager Parameter Store

# SSM parameter path prefix
readonly SSM_TENANT_PREFIX="/apersona/tenants"

# Load tenant configuration from SSM Parameter Store
load_tenant_from_ssm() {
    local tenant_id=$1
    local param_name="${SSM_TENANT_PREFIX}/${tenant_id}/config"
    
    local param_value
    if param_value=$(aws ssm get-parameter \
        --region "$CDK_DEPLOY_REGION" \
        --name "$param_name" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null); then
        echo "$param_value"
        return 0
    else
        return 1
    fi
}

# Get all tenant IDs from SSM Parameter Store
get_ssm_tenant_ids() {
    local tenant_ids=()
    local params
    
    if params=$(aws ssm get-parameters-by-path \
        --region "$CDK_DEPLOY_REGION" \
        --path "$SSM_TENANT_PREFIX" \
        --recursive \
        --query 'Parameters[*].Name' \
        --output text 2>/dev/null); then
        
        # Extract tenant IDs from parameter names
        for param in $params; do
            # Extract tenant_id from /apersona/tenants/{tenant_id}/config
            if [[ $param =~ ${SSM_TENANT_PREFIX}/([^/]+)/config ]]; then
                tenant_ids+=("${BASH_REMATCH[1]}")
            fi
        done
    fi
    
    # Only output if we have tenant IDs
    if [[ ${#tenant_ids[@]} -gt 0 ]]; then
        printf '%s\n' "${tenant_ids[@]}" | sort -u
    fi
}

# Save tenant configuration to SSM Parameter Store
save_tenant_to_ssm() {
    local tenant_id=$1
    local tenant_name=$2
    local contact_email=$3
    local url=$4
    local sp_portal_url=$5
    local extra_app_url=$6
    local saml_proxy=${7:-true}
    local recaptcha_key=${8:-}
    local recaptcha_secret=${9:-}
    local smtp_host=${10:-}
    local smtp_user=${11:-}
    local smtp_pass=${12:-}
    local smtp_secure=${13:-}
    local smtp_port=${14:-}
    
    local param_name="${SSM_TENANT_PREFIX}/${tenant_id}/config"
    
    # Create JSON configuration from local file values
    # Always use values from conf file (new values override existing SSM values)
    local config_json
    config_json=$(jq -n \
        --arg name "$tenant_name" \
        --arg contact "$contact_email" \
        --arg url "$url" \
        --arg sp_portal_url "$sp_portal_url" \
        --arg extra_app_url "$extra_app_url" \
        --argjson saml_proxy "$saml_proxy" \
        --arg recaptcha_key "$recaptcha_key" \
        --arg recaptcha_secret "$recaptcha_secret" \
        --arg smtp_host "$smtp_host" \
        --arg smtp_user "$smtp_user" \
        --arg smtp_pass "$smtp_pass" \
        --arg smtp_secure "$smtp_secure" \
        --arg smtp_port "$smtp_port" \
        '{
            name: $name,
            contact: $contact,
            url: $url,
            sp_portal_url: $sp_portal_url,
            extra_app_url: $extra_app_url,
            saml_proxy: $saml_proxy,
            recaptcha_key: $recaptcha_key,
            recaptcha_secret: $recaptcha_secret,
            smtp_host: $smtp_host,
            smtp_user: $smtp_user,
            smtp_pass: $smtp_pass,
            smtp_secure: $smtp_secure,
            smtp_port: $smtp_port
    }')
    
    # Check if parameter exists
    if aws ssm get-parameter \
    --region "$CDK_DEPLOY_REGION" \
    --name "$param_name" \
    >/dev/null 2>&1; then
        # Update existing parameter
        aws ssm put-parameter \
        --region "$CDK_DEPLOY_REGION" \
        --name "$param_name" \
        --value "$config_json" \
        --type "String" \
        --overwrite \
        --description "Tenant configuration for $tenant_id" \
        >/dev/null
    else
        # Create new parameter
        aws ssm put-parameter \
        --region "$CDK_DEPLOY_REGION" \
        --name "$param_name" \
        --value "$config_json" \
        --type "String" \
        --description "Tenant configuration for $tenant_id" \
        >/dev/null
    fi
    
    return $?
}

# Delete tenant configuration from SSM Parameter Store
delete_tenant_from_ssm() {
    local tenant_id=$1
    local param_name="${SSM_TENANT_PREFIX}/${tenant_id}/config"
    
    aws ssm delete-parameter \
    --region "$CDK_DEPLOY_REGION" \
    --name "$param_name" \
    >/dev/null 2>&1
    
    return $?
}

# Load tenant configuration from .conf file
load_tenant_from_conf() {
    local conf_file=$1
    
    # Source the conf file in a subshell to avoid variable pollution
    (
        # shellcheck source=/dev/null
        source "$conf_file"
        
        # Output as JSON for easy parsing
        jq -n \
        --arg tenant_id "${TENANT_ID:-}" \
        --arg tenant_name "${TENANT_NAME:-}" \
        --arg contact_email "${CONTACT_EMAIL:-}" \
        --arg extra_app_url "${EXTRA_APP_URL:-}" \
        --arg recaptcha_key "${RECAPTCHA_KEY:-}" \
        --arg recaptcha_secret "${RECAPTCHA_SECRET:-}" \
        --arg smtp_host "${SMTP_HOST:-}" \
        --arg smtp_user "${SMTP_USER:-}" \
        --arg smtp_pass "${SMTP_PASS:-}" \
        --arg smtp_secure "${SMTP_SECURE:-}" \
        --arg smtp_port "${SMTP_PORT:-}" \
        '{
                tenant_id: $tenant_id,
                tenant_name: $tenant_name,
                contact_email: $contact_email,
                extra_app_url: $extra_app_url,
                recaptcha_key: $recaptcha_key,
                recaptcha_secret: $recaptcha_secret,
                smtp_host: $smtp_host,
                smtp_user: $smtp_user,
                smtp_pass: $smtp_pass,
                smtp_secure: $smtp_secure,
                smtp_port: $smtp_port
        }'
    )
}

# Compare and sync tenants between conf files and SSM
sync_tenants_to_ssm() {
    local tenants_dir=$1
    
    log_info "Synchronizing tenant configurations with SSM Parameter Store..."
    
    # Get tenant IDs from conf files
    local -a conf_tenant_ids=()
    for conf_file in "$tenants_dir"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        [[ "$(basename "$conf_file")" == "example-"* ]] && continue
        
        local tenant_config
        tenant_config=$(load_tenant_from_conf "$conf_file")
        local tenant_id
        tenant_id=$(echo "$tenant_config" | jq -r '.tenant_id')
        
        if [[ -n "$tenant_id" && "$tenant_id" != "null" ]]; then
            conf_tenant_ids+=("$tenant_id")
        fi
    done
    
    # Get tenant IDs from SSM
    local -a ssm_tenant_ids=()
    while IFS= read -r tenant_id; do
        ssm_tenant_ids+=("$tenant_id")
    done < <(get_ssm_tenant_ids)
    
    # Find new tenants (in conf but not in SSM)
    local -a new_tenants=()
    if [[ ${#conf_tenant_ids[@]} -gt 0 ]]; then
        for tenant_id in "${conf_tenant_ids[@]}"; do
            local ssm_tenant_list="${ssm_tenant_ids[*]:-}"
            if [[ ! " $ssm_tenant_list " =~ " ${tenant_id} " ]]; then
                new_tenants+=("$tenant_id")
            fi
        done
    fi
    
    # Find deleted tenants (in SSM but not in conf)
    local -a deleted_tenants=()
    if [[ ${#ssm_tenant_ids[@]} -gt 0 ]]; then
        for tenant_id in "${ssm_tenant_ids[@]}"; do
            local conf_tenant_list="${conf_tenant_ids[*]:-}"
            if [[ ! " $conf_tenant_list " =~ " ${tenant_id} " ]]; then
                deleted_tenants+=("$tenant_id")
            fi
        done
    fi
    
    # Find changed tenants (in both conf and SSM but with different values)
    local -a changed_tenants=()
    if [[ ${#conf_tenant_ids[@]} -gt 0 && ${#ssm_tenant_ids[@]} -gt 0 ]]; then
        for tenant_id in "${conf_tenant_ids[@]}"; do
            local ssm_tenant_list="${ssm_tenant_ids[*]:-}"
            # Only check tenants that exist in both places
            if [[ " $ssm_tenant_list " =~ " ${tenant_id} " ]]; then
                # Load both configs and compare
                for conf_file in "$tenants_dir"/*.conf; do
                    [[ -f "$conf_file" ]] || continue
                    local tenant_config
                    tenant_config=$(load_tenant_from_conf "$conf_file")
                    local conf_tenant_id
                    conf_tenant_id=$(echo "$tenant_config" | jq -r '.tenant_id')
                    
                    if [[ "$conf_tenant_id" == "$tenant_id" ]]; then
                        local ssm_config
                        if ssm_config=$(load_tenant_from_ssm "$tenant_id" 2>/dev/null); then
                            # Extract key values from both configs for comparison
                            local tenant_recaptcha_key tenant_recaptcha_secret
                            local tenant_smtp_host tenant_smtp_user tenant_smtp_pass tenant_smtp_secure tenant_smtp_port
                            local contact_email extra_app_url
                            
                            # Load from conf file
                            contact_email=$(echo "$tenant_config" | jq -r '.contact_email')
                            extra_app_url=$(echo "$tenant_config" | jq -r '.extra_app_url')
                            tenant_recaptcha_key=$(echo "$tenant_config" | jq -r '.recaptcha_key')
                            tenant_recaptcha_secret=$(echo "$tenant_config" | jq -r '.recaptcha_secret')
                            tenant_smtp_host=$(echo "$tenant_config" | jq -r '.smtp_host')
                            tenant_smtp_user=$(echo "$tenant_config" | jq -r '.smtp_user')
                            tenant_smtp_pass=$(echo "$tenant_config" | jq -r '.smtp_pass')
                            tenant_smtp_secure=$(echo "$tenant_config" | jq -r '.smtp_secure')
                            tenant_smtp_port=$(echo "$tenant_config" | jq -r '.smtp_port')
                            
                            # Use tenant-specific values if provided, otherwise fall back to global values
                            local final_recaptcha_key="${tenant_recaptcha_key:-${RECAPTCHA_KEY:-}}"
                            local final_recaptcha_secret="${tenant_recaptcha_secret:-${RECAPTCHA_SECRET:-}}"
                            local final_smtp_host="${tenant_smtp_host:-${SMTP_HOST:-}}"
                            local final_smtp_user="${tenant_smtp_user:-${SMTP_USER:-}}"
                            local final_smtp_pass="${tenant_smtp_pass:-${SMTP_PASS:-}}"
                            local final_smtp_secure="${tenant_smtp_secure:-${SMTP_SECURE:-}}"
                            local final_smtp_port="${tenant_smtp_port:-${SMTP_PORT:-}}"
                            
                            # Load from SSM
                            local ssm_contact_email ssm_extra_app_url
                            local ssm_recaptcha_key ssm_recaptcha_secret
                            local ssm_smtp_host ssm_smtp_user ssm_smtp_pass ssm_smtp_secure ssm_smtp_port
                            
                            ssm_contact_email=$(echo "$ssm_config" | jq -r '.contact // empty')
                            ssm_extra_app_url=$(echo "$ssm_config" | jq -r '.extra_app_url // empty')
                            ssm_recaptcha_key=$(echo "$ssm_config" | jq -r '.recaptcha_key // empty')
                            ssm_recaptcha_secret=$(echo "$ssm_config" | jq -r '.recaptcha_secret // empty')
                            ssm_smtp_host=$(echo "$ssm_config" | jq -r '.smtp_host // empty')
                            ssm_smtp_user=$(echo "$ssm_config" | jq -r '.smtp_user // empty')
                            ssm_smtp_pass=$(echo "$ssm_config" | jq -r '.smtp_pass // empty')
                            ssm_smtp_secure=$(echo "$ssm_config" | jq -r '.smtp_secure // empty')
                            ssm_smtp_port=$(echo "$ssm_config" | jq -r '.smtp_port // empty')
                            
                            # Compare values - if any differ, mark as changed
                            if [[ "$contact_email" != "$ssm_contact_email" ]] || \
                               [[ "$extra_app_url" != "$ssm_extra_app_url" ]] || \
                               [[ "$final_recaptcha_key" != "$ssm_recaptcha_key" ]] || \
                               [[ "$final_recaptcha_secret" != "$ssm_recaptcha_secret" ]] || \
                               [[ "$final_smtp_host" != "$ssm_smtp_host" ]] || \
                               [[ "$final_smtp_user" != "$ssm_smtp_user" ]] || \
                               [[ "$final_smtp_pass" != "$ssm_smtp_pass" ]] || \
                               [[ "$final_smtp_secure" != "$ssm_smtp_secure" ]] || \
                               [[ "$final_smtp_port" != "$ssm_smtp_port" ]]; then
                                changed_tenants+=("$tenant_id")
                            fi
                        fi
                        break
                    fi
                done
            fi
        done
    fi
    
    # Display summary
    echo ""
    echo "=============================================="
    echo "Tenant Synchronization Summary"
    echo "=============================================="
    echo "Tenants in conf files: ${#conf_tenant_ids[@]}"
    echo "Tenants in SSM: ${#ssm_tenant_ids[@]}"
    echo "New tenants to add: ${#new_tenants[@]}"
    echo "Changed tenants to update: ${#changed_tenants[@]}"
    echo "Tenants not in conf : ${#deleted_tenants[@]}"
    echo ""
    
    # Show new tenants
    if [[ ${#new_tenants[@]} -gt 0 ]]; then
        echo "New tenants to be added:"
        echo "----------------------------------------"
        for tenant_id in "${new_tenants[@]}"; do
            # Find and load the conf file
            for conf_file in "$tenants_dir"/*.conf; do
                [[ -f "$conf_file" ]] || continue
                local tenant_config
                tenant_config=$(load_tenant_from_conf "$conf_file")
                local conf_tenant_id
                conf_tenant_id=$(echo "$tenant_config" | jq -r '.tenant_id')
                
                if [[ "$conf_tenant_id" == "$tenant_id" ]]; then
                    local tenant_name contact_email extra_app_url
                    local tenant_recaptcha_key tenant_recaptcha_secret
                    local tenant_smtp_host tenant_smtp_user tenant_smtp_pass tenant_smtp_secure tenant_smtp_port
                    
                    tenant_name=$(echo "$tenant_config" | jq -r '.tenant_name')
                    contact_email=$(echo "$tenant_config" | jq -r '.contact_email')
                    extra_app_url=$(echo "$tenant_config" | jq -r '.extra_app_url')
                    tenant_recaptcha_key=$(echo "$tenant_config" | jq -r '.recaptcha_key')
                    tenant_recaptcha_secret=$(echo "$tenant_config" | jq -r '.recaptcha_secret')
                    tenant_smtp_host=$(echo "$tenant_config" | jq -r '.smtp_host')
                    tenant_smtp_user=$(echo "$tenant_config" | jq -r '.smtp_user')
                    tenant_smtp_pass=$(echo "$tenant_config" | jq -r '.smtp_pass')
                    tenant_smtp_secure=$(echo "$tenant_config" | jq -r '.smtp_secure')
                    tenant_smtp_port=$(echo "$tenant_config" | jq -r '.smtp_port')
                    
                    # Use tenant-specific values if provided, otherwise fall back to global values
                    local final_recaptcha_key="${tenant_recaptcha_key:-${RECAPTCHA_KEY:-}}"
                    local final_recaptcha_secret="${tenant_recaptcha_secret:-${RECAPTCHA_SECRET:-}}"
                    local final_smtp_host="${tenant_smtp_host:-${SMTP_HOST:-}}"
                    local final_smtp_user="${tenant_smtp_user:-${SMTP_USER:-}}"
                    local final_smtp_pass="${tenant_smtp_pass:-${SMTP_PASS:-}}"
                    local final_smtp_secure="${tenant_smtp_secure:-${SMTP_SECURE:-}}"
                    local final_smtp_port="${tenant_smtp_port:-${SMTP_PORT:-}}"
                    
                    # Generate URLs
                    local url="https://${tenant_id}.${ROOT_DOMAIN_NAME}"
                    local sp_portal_url="https://login.${tenant_id}.${ROOT_DOMAIN_NAME}"
                    
                    echo "  Tenant ID: $tenant_id"
                    echo "  Name: $tenant_name"
                    echo "  Contact: $contact_email"
                    echo "  URL: $url"
                    echo "  SP Portal URL: $sp_portal_url"
                    echo "  Extra App URL: ${extra_app_url:-<none>}"
                    echo "  SAML Proxy: true"
                    echo "  reCAPTCHA Key: ${final_recaptcha_key:-<none>}"
                    echo "  reCAPTCHA Secret: ${final_recaptcha_secret:+***hidden***}"
                    echo "  SMTP Host: ${final_smtp_host:-<none>}"
                    echo "  SMTP User: ${final_smtp_user:-<none>}"
                    echo "  SMTP Pass: ${final_smtp_pass:+***hidden***}"
                    echo "  SMTP Secure: ${final_smtp_secure:-<none>}"
                    echo "  SMTP Port: ${final_smtp_port:-<none>}"
                    echo ""
                    break
                fi
            done
        done
    fi
    
    # Show changed tenants with differences
    if [[ ${#changed_tenants[@]} -gt 0 ]]; then
        echo "Changed tenants to be updated:"
        echo "----------------------------------------"
        for tenant_id in "${changed_tenants[@]}"; do
            echo "  Tenant ID: $tenant_id"
            echo "  Changes detected in configuration values"
            echo ""
        done
    fi
    
    # Show tenants in SSM but not in conf files (will be kept, not deleted)
    if [[ ${#deleted_tenants[@]} -gt 0 ]]; then
        echo "Tenants in SSM but not in conf files:"
        echo "----------------------------------------"
        for tenant_id in "${deleted_tenants[@]}"; do
            local tenant_config
            if tenant_config=$(load_tenant_from_ssm "$tenant_id"); then
                local tenant_name
                tenant_name=$(echo "$tenant_config" | jq -r '.name')
                echo "  Tenant ID: $tenant_id"
                echo "  Name: $tenant_name"
                echo ""
            else
                echo "  Tenant ID: $tenant_id (unable to load details)"
                echo ""
            fi
        done
        echo "Note: These tenants will NOT be deleted from SSM."
        echo ""
    fi
    
    # Confirm with user
    if [[ ${#new_tenants[@]} -eq 0 && ${#changed_tenants[@]} -eq 0 ]]; then
        log_success "All tenants are in sync. No changes needed."
        return 0
    fi
    
    echo "=============================================="
    local action_msg="Proceed with"
    [[ ${#new_tenants[@]} -gt 0 ]] && action_msg="$action_msg adding ${#new_tenants[@]} new tenant(s)"
    [[ ${#new_tenants[@]} -gt 0 && ${#changed_tenants[@]} -gt 0 ]] && action_msg="$action_msg and"
    [[ ${#changed_tenants[@]} -gt 0 ]] && action_msg="$action_msg updating ${#changed_tenants[@]} changed tenant(s)"
    action_msg="$action_msg?"
    
    if ! confirm_with_timeout "$action_msg" 60 "n"; then
        log_info "Tenant synchronization cancelled by user"
        return 1
    fi
    
    # Add new tenants
    for tenant_id in "${new_tenants[@]+"${new_tenants[@]}"}"; do
        log_info "Adding tenant $tenant_id to SSM..."
        
        # Find and load the conf file
        for conf_file in "$tenants_dir"/*.conf; do
            [[ -f "$conf_file" ]] || continue
            local tenant_config
            tenant_config=$(load_tenant_from_conf "$conf_file")
            local conf_tenant_id
            conf_tenant_id=$(echo "$tenant_config" | jq -r '.tenant_id')
            
            if [[ "$conf_tenant_id" == "$tenant_id" ]]; then
                local tenant_name contact_email extra_app_url
                local tenant_recaptcha_key tenant_recaptcha_secret
                local tenant_smtp_host tenant_smtp_user tenant_smtp_pass tenant_smtp_secure tenant_smtp_port
                
                tenant_name=$(echo "$tenant_config" | jq -r '.tenant_name')
                contact_email=$(echo "$tenant_config" | jq -r '.contact_email')
                extra_app_url=$(echo "$tenant_config" | jq -r '.extra_app_url')
                tenant_recaptcha_key=$(echo "$tenant_config" | jq -r '.recaptcha_key')
                tenant_recaptcha_secret=$(echo "$tenant_config" | jq -r '.recaptcha_secret')
                tenant_smtp_host=$(echo "$tenant_config" | jq -r '.smtp_host')
                tenant_smtp_user=$(echo "$tenant_config" | jq -r '.smtp_user')
                tenant_smtp_pass=$(echo "$tenant_config" | jq -r '.smtp_pass')
                tenant_smtp_secure=$(echo "$tenant_config" | jq -r '.smtp_secure')
                tenant_smtp_port=$(echo "$tenant_config" | jq -r '.smtp_port')
                
                # Use tenant-specific values if provided, otherwise fall back to global values
                local final_recaptcha_key="${tenant_recaptcha_key:-${RECAPTCHA_KEY:-}}"
                local final_recaptcha_secret="${tenant_recaptcha_secret:-${RECAPTCHA_SECRET:-}}"
                local final_smtp_host="${tenant_smtp_host:-${SMTP_HOST:-}}"
                local final_smtp_user="${tenant_smtp_user:-${SMTP_USER:-}}"
                local final_smtp_pass="${tenant_smtp_pass:-${SMTP_PASS:-}}"
                local final_smtp_secure="${tenant_smtp_secure:-${SMTP_SECURE:-}}"
                local final_smtp_port="${tenant_smtp_port:-${SMTP_PORT:-}}"
                
                # Generate URLs
                local url="https://${tenant_id}.${ROOT_DOMAIN_NAME}"
                local sp_portal_url="https://login.${tenant_id}.${ROOT_DOMAIN_NAME}"
                
                if save_tenant_to_ssm "$tenant_id" "$tenant_name" "$contact_email" \
                "$url" "$sp_portal_url" "$extra_app_url" "true" \
                "$final_recaptcha_key" "$final_recaptcha_secret" \
                "$final_smtp_host" "$final_smtp_user" "$final_smtp_pass" "$final_smtp_secure" "$final_smtp_port"; then
                    log_success "Tenant $tenant_id added to SSM"
                else
                    log_error "Failed to add tenant $tenant_id to SSM"
                    return 1
                fi
                break
            fi
        done
    done
    
    # Update changed tenants
    for tenant_id in "${changed_tenants[@]+"${changed_tenants[@]}"}"; do
        log_info "Updating tenant $tenant_id in SSM..."
        
        # Find and load the conf file
        for conf_file in "$tenants_dir"/*.conf; do
            [[ -f "$conf_file" ]] || continue
            local tenant_config
            tenant_config=$(load_tenant_from_conf "$conf_file")
            local conf_tenant_id
            conf_tenant_id=$(echo "$tenant_config" | jq -r '.tenant_id')
            
            if [[ "$conf_tenant_id" == "$tenant_id" ]]; then
                local tenant_name contact_email extra_app_url
                local tenant_recaptcha_key tenant_recaptcha_secret
                local tenant_smtp_host tenant_smtp_user tenant_smtp_pass tenant_smtp_secure tenant_smtp_port
                
                tenant_name=$(echo "$tenant_config" | jq -r '.tenant_name')
                contact_email=$(echo "$tenant_config" | jq -r '.contact_email')
                extra_app_url=$(echo "$tenant_config" | jq -r '.extra_app_url')
                tenant_recaptcha_key=$(echo "$tenant_config" | jq -r '.recaptcha_key')
                tenant_recaptcha_secret=$(echo "$tenant_config" | jq -r '.recaptcha_secret')
                tenant_smtp_host=$(echo "$tenant_config" | jq -r '.smtp_host')
                tenant_smtp_user=$(echo "$tenant_config" | jq -r '.smtp_user')
                tenant_smtp_pass=$(echo "$tenant_config" | jq -r '.smtp_pass')
                tenant_smtp_secure=$(echo "$tenant_config" | jq -r '.smtp_secure')
                tenant_smtp_port=$(echo "$tenant_config" | jq -r '.smtp_port')
                
                # Use tenant-specific values if provided, otherwise fall back to global values
                local final_recaptcha_key="${tenant_recaptcha_key:-${RECAPTCHA_KEY:-}}"
                local final_recaptcha_secret="${tenant_recaptcha_secret:-${RECAPTCHA_SECRET:-}}"
                local final_smtp_host="${tenant_smtp_host:-${SMTP_HOST:-}}"
                local final_smtp_user="${tenant_smtp_user:-${SMTP_USER:-}}"
                local final_smtp_pass="${tenant_smtp_pass:-${SMTP_PASS:-}}"
                local final_smtp_secure="${tenant_smtp_secure:-${SMTP_SECURE:-}}"
                local final_smtp_port="${tenant_smtp_port:-${SMTP_PORT:-}}"
                
                # Generate URLs
                local url="https://${tenant_id}.${ROOT_DOMAIN_NAME}"
                local sp_portal_url="https://login.${tenant_id}.${ROOT_DOMAIN_NAME}"
                
                if save_tenant_to_ssm "$tenant_id" "$tenant_name" "$contact_email" \
                "$url" "$sp_portal_url" "$extra_app_url" "true" \
                "$final_recaptcha_key" "$final_recaptcha_secret" \
                "$final_smtp_host" "$final_smtp_user" "$final_smtp_pass" "$final_smtp_secure" "$final_smtp_port"; then
                    log_success "Tenant $tenant_id updated in SSM"
                else
                    log_error "Failed to update tenant $tenant_id in SSM"
                    return 1
                fi
                break
            fi
        done
    done
    
    log_success "Tenant synchronization completed"
    return 0
}

# Load all tenants from SSM as a JSON array
load_all_tenants_from_ssm() {
    local -a tenant_ids=()
    while IFS= read -r tenant_id; do
        tenant_ids+=("$tenant_id")
    done < <(get_ssm_tenant_ids)
    
    local tenants_json="[]"
    
    if [[ ${#tenant_ids[@]} -gt 0 ]]; then
        for tenant_id in "${tenant_ids[@]}"; do
            local tenant_config
            if tenant_config=$(load_tenant_from_ssm "$tenant_id"); then
                # Add tenant_id to the config
                tenant_config=$(echo "$tenant_config" | jq --arg id "$tenant_id" '. + {tenant_id: $id}')
                tenants_json=$(echo "$tenants_json" | jq --argjson tenant "$tenant_config" '. + [$tenant]')
            fi
        done
    fi
    
    echo "$tenants_json"
}
