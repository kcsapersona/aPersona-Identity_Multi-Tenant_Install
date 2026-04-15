#!/bin/bash

# AWS utilities for aPersona Multi-Tenant Installer
# This file contains AWS-related functions

# ============================================
# DEBUG MODE CONFIGURATION
# Set DEBUG_MODE=1 to enable verbose logging
# Set DEBUG_MODE=0 to disable (default)
# ============================================
: "${DEBUG_MODE:=0}"

debug_log() {
    if [[ "$DEBUG_MODE" == "1" ]]; then
        echo "[DEBUG $(date '+%H:%M:%S')] $*" >&2
    fi
}

# AWS validation functions with better error handling
validate_aws_credentials() {
    log_info "Validating AWS credentials..."
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        log_error "You must execute this script from an EC2 instance with an Admin Role attached"
        log_error "Or ensure AWS CLI is configured with proper credentials"
        exit $EXIT_AWS_ERROR
    fi
    
    log_success "AWS credentials validated"
}

validate_hosted_zone() {
    log_info "Validating hosted zone configuration..."
    
    local domain_name
    if ! domain_name=$(aws route53 get-hosted-zone --id "$ROOT_HOSTED_ZONE_ID" 2>/dev/null | jq -r .HostedZone.Name); then
        log_error "Failed to retrieve hosted zone information for ID: $ROOT_HOSTED_ZONE_ID"
        log_error "Please verify the hosted zone ID is correct and you have proper permissions"
        exit $EXIT_CONFIG_ERROR
    fi
    
    if [[ "$domain_name" != "$ROOT_DOMAIN_NAME." ]]; then
        log_error "ROOT_DOMAIN_NAME ($ROOT_DOMAIN_NAME) and ROOT_HOSTED_ZONE_ID ($ROOT_HOSTED_ZONE_ID) do not match"
        log_error "Expected domain: $domain_name, configured: $ROOT_DOMAIN_NAME"
        exit $EXIT_CONFIG_ERROR
    fi
    
    log_success "Hosted zone validated: $ROOT_DOMAIN_NAME"
}

# AWS environment detection with improved fallback
detect_aws_environment() {
    log_info "Detecting AWS environment..."
    
    local token
    local region_from_metadata=""
    
    # Try to get EC2 metadata token with timeout
    if token=$(timeout 5 curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null); then
        # Get region from EC2 metadata
        region_from_metadata=$(timeout 5 curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
    fi
    
    # Set region with fallback chain
    if [[ -n "$region_from_metadata" ]]; then
        CDK_DEPLOY_REGION="$region_from_metadata"
        log_info "Using region from EC2 metadata: $CDK_DEPLOY_REGION"
    elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
        CDK_DEPLOY_REGION="$AWS_DEFAULT_REGION"
        log_info "Using region from AWS_DEFAULT_REGION: $CDK_DEPLOY_REGION"
    elif region_from_cli=$(aws configure get region 2>/dev/null); then
        CDK_DEPLOY_REGION="$region_from_cli"
        log_info "Using region from AWS CLI config: $CDK_DEPLOY_REGION"
    else
        CDK_DEPLOY_REGION="us-east-1"
        log_warning "Could not detect region, defaulting to: $CDK_DEPLOY_REGION"
    fi
    
    # Get account ID
    if ! CDK_DEPLOY_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
        log_error "Failed to get AWS account ID"
        exit $EXIT_AWS_ERROR
    fi
    
    log_success "AWS Account: $CDK_DEPLOY_ACCOUNT"
    log_success "AWS Region: $CDK_DEPLOY_REGION"
    
    export CDK_DEPLOY_REGION
    export CDK_DEPLOY_ACCOUNT
}

# Resolve hosted zone ID from root domain name via Route53 API
resolve_hosted_zone_id() {
    log_info "Resolving hosted zone ID for root domain: $ROOT_DOMAIN_NAME ..."

    # Query Route53 for hosted zones matching the root domain name
    local zones_json
    if ! zones_json=$(aws route53 list-hosted-zones-by-name \
        --dns-name "$ROOT_DOMAIN_NAME" \
        --max-items 100 \
        --output json 2>&1); then
        log_error "Failed to query Route53 for hosted zones: $zones_json"
        log_error "Please ensure you have route53:ListHostedZonesByName permission"
        exit $EXIT_AWS_ERROR
    fi

    # Filter for exact match (Route53 returns zones starting from the given name)
    # The domain name in Route53 has a trailing dot
    local matching_zones
    matching_zones=$(echo "$zones_json" | jq -r \
        --arg domain "${ROOT_DOMAIN_NAME}." \
        '[.HostedZones[] | select(.Name == $domain and .Config.PrivateZone == false)] | length')

    if [[ "$matching_zones" -eq 0 ]]; then
        log_error "No public hosted zone found for domain: $ROOT_DOMAIN_NAME"
        log_error "Please create a Route53 hosted zone for '$ROOT_DOMAIN_NAME' before running the installer"
        exit $EXIT_CONFIG_ERROR
    fi

    if [[ "$matching_zones" -gt 1 ]]; then
        log_error "Multiple public hosted zones found for domain: $ROOT_DOMAIN_NAME ($matching_zones zones)"
        log_error "Please ensure there is exactly one public hosted zone for '$ROOT_DOMAIN_NAME'"
        log_error "Found zones:"
        echo "$zones_json" | jq -r \
            --arg domain "${ROOT_DOMAIN_NAME}." \
            '.HostedZones[] | select(.Name == $domain and .Config.PrivateZone == false) | "  ID: \(.Id) | Name: \(.Name)"'
        exit $EXIT_CONFIG_ERROR
    fi

    # Extract the hosted zone ID (strip /hostedzone/ prefix)
    local zone_id
    zone_id=$(echo "$zones_json" | jq -r \
        --arg domain "${ROOT_DOMAIN_NAME}." \
        '.HostedZones[] | select(.Name == $domain and .Config.PrivateZone == false) | .Id' | sed 's|/hostedzone/||')

    if [[ -z "$zone_id" ]]; then
        log_error "Failed to extract hosted zone ID for domain: $ROOT_DOMAIN_NAME"
        exit $EXIT_CONFIG_ERROR
    fi

    export ROOT_HOSTED_ZONE_ID="$zone_id"
    log_success "Resolved hosted zone ID: $ROOT_HOSTED_ZONE_ID"

    # Validate DNS resolution using dig (warning only)
    validate_dns_resolution
}

# Validate DNS resolution using dig (warning only, non-blocking)
validate_dns_resolution() {
    log_info "Validating DNS resolution for $ROOT_DOMAIN_NAME ..."

    # Check if dig is available
    if ! command -v dig &>/dev/null; then
        log_warning "dig command not found, skipping DNS resolution validation"
        return 0
    fi

    # Get NS records from Route53 (authoritative)
    local route53_ns
    route53_ns=$(aws route53 get-hosted-zone --id "$ROOT_HOSTED_ZONE_ID" \
        --query 'DelegationSet.NameServers' --output text 2>/dev/null | tr '\t' '\n' | sort)

    if [[ -z "$route53_ns" ]]; then
        log_warning "Could not retrieve Route53 name servers for zone $ROOT_HOSTED_ZONE_ID"
        return 0
    fi

    debug_log "Route53 NS records: $(echo "$route53_ns" | tr '\n' ', ')"

    # Get NS records from public DNS using dig
    local dig_ns
    dig_ns=$(dig +short NS "$ROOT_DOMAIN_NAME" 2>/dev/null | sed 's/\.$//' | sort)

    if [[ -z "$dig_ns" ]]; then
        log_warning "DNS resolution check: No NS records found for $ROOT_DOMAIN_NAME via public DNS"
        log_warning "This may indicate DNS delegation is not yet configured or has not propagated"
        log_warning "The installation will continue, but DNS-dependent features may not work until propagation completes"
        return 0
    fi

    debug_log "Public DNS NS records: $(echo "$dig_ns" | tr '\n' ', ')"

    # Compare NS records - check if at least one Route53 NS appears in dig results
    local match_found=false
    while IFS= read -r ns; do
        if echo "$dig_ns" | grep -qi "$ns"; then
            match_found=true
            break
        fi
    done <<< "$route53_ns"

    if [[ "$match_found" == "true" ]]; then
        log_success "DNS resolution validated: NS records match Route53 hosted zone"
    else
        log_warning "DNS resolution check: NS records from public DNS do not match Route53 hosted zone"
        log_warning "  Route53 NS: $(echo "$route53_ns" | tr '\n' ', ')"
        log_warning "  Public DNS NS: $(echo "$dig_ns" | tr '\n' ', ')"
        log_warning "This may indicate NS delegation is not yet configured or has not propagated"
        log_warning "The installation will continue, but DNS-dependent features may not work until propagation completes"
    fi
}

# DNS delegation role creation with better error handling
create_dns_delegation_role() {
    local role_name="CrossAccountDnsDelegationRole-DO-NOT-DELETE"

    log_info "Checking DNS delegation role..."

    if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        log_info "DNS delegation role already exists"
        return 0
    fi

    log_info "Creating DNS delegation role..."

    # Create role policy - Updated path for parent directory execution
    cat > delegationRole.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::$CDK_DEPLOY_ACCOUNT:root"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Create role and attach policy with error handling - Updated path for delegationPolicy.json
    if aws iam create-role --role-name "$role_name" --assume-role-policy-document file://delegationRole.json >/dev/null 2>&1 &&
       aws iam create-policy --policy-name dns-delegation-policy --policy-document file://delegationPolicy.json >/dev/null 2>&1 &&
       aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::$CDK_DEPLOY_ACCOUNT:policy/dns-delegation-policy" >/dev/null 2>&1; then
        log_success "DNS delegation role created successfully"
    else
        log_error "Failed to create DNS delegation role"
        return 1
    fi
}

# Enhanced CDK operations with debug support
bootstrap_cdk() {
    log_info "Bootstrapping CDK..."
    debug_log "CDK_DEPLOY_ACCOUNT: $CDK_DEPLOY_ACCOUNT"
    debug_log "CDK_DEPLOY_REGION: $CDK_DEPLOY_REGION"

    export CDK_NEW_BOOTSTRAP=1
    export IS_BOOTSTRAP=1

    # Determine verbosity flag based on DEBUG_MODE
    local verbose_flag="--quiet"
    if [[ "$DEBUG_MODE" == "1" ]]; then
        verbose_flag="--verbose"
        debug_log "Running in VERBOSE mode"
    fi

    local bootstrap_log="/tmp/cdk-bootstrap.log"

    # Bootstrap us-east-1 (required for CloudFront)
    log_info "Bootstrapping CDK in us-east-1..."
    debug_log "Running: npx cdk bootstrap aws://$CDK_DEPLOY_ACCOUNT/us-east-1 $verbose_flag"
    debug_log "This may take 2-5 minutes if creating new resources..."
    
    local start_time
    start_time=$(date +%s)
    
    if [[ "$DEBUG_MODE" == "1" ]]; then
        # Show full output in debug mode
        if ! npx cdk bootstrap "aws://$CDK_DEPLOY_ACCOUNT/us-east-1" $verbose_flag 2>&1 | tee "$bootstrap_log"; then
            log_error "Failed to bootstrap CDK in us-east-1"
            return 1
        fi
    else
        # Capture output to log file; show progress dots; display errors on failure
        if ! npx cdk bootstrap "aws://$CDK_DEPLOY_ACCOUNT/us-east-1" $verbose_flag 2>&1 | tee "$bootstrap_log" | \
             while IFS= read -r line; do echo -n "."; done; then
            echo ""
            log_error "Failed to bootstrap CDK in us-east-1"
            log_error "Bootstrap log output:"
            cat "$bootstrap_log" >&2
            return 1
        fi
        echo ""
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    debug_log "Bootstrap us-east-1 completed in ${duration}s"

    # Bootstrap target region if different
    if [[ "$CDK_DEPLOY_REGION" != "us-east-1" ]]; then
        log_info "Bootstrapping CDK in $CDK_DEPLOY_REGION..."
        debug_log "Running: npx cdk bootstrap aws://$CDK_DEPLOY_ACCOUNT/$CDK_DEPLOY_REGION $verbose_flag"
        debug_log "This may take 2-5 minutes if creating new resources..."
        
        start_time=$(date +%s)
        
        if [[ "$DEBUG_MODE" == "1" ]]; then
            if ! npx cdk bootstrap "aws://$CDK_DEPLOY_ACCOUNT/$CDK_DEPLOY_REGION" $verbose_flag 2>&1 | tee "$bootstrap_log"; then
                log_error "Failed to bootstrap CDK in $CDK_DEPLOY_REGION"
                return 1
            fi
        else
            if ! npx cdk bootstrap "aws://$CDK_DEPLOY_ACCOUNT/$CDK_DEPLOY_REGION" $verbose_flag 2>&1 | tee "$bootstrap_log" | \
                 while IFS= read -r line; do echo -n "."; done; then
                echo ""
                log_error "Failed to bootstrap CDK in $CDK_DEPLOY_REGION"
                log_error "Bootstrap log output:"
                cat "$bootstrap_log" >&2
                return 1
            fi
            echo ""
        fi
        
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        debug_log "Bootstrap $CDK_DEPLOY_REGION completed in ${duration}s"
    fi

    unset IS_BOOTSTRAP
    unset CDK_NEW_BOOTSTRAP

    log_success "CDK bootstrap completed"
}

# Enhanced deployment with progress tracking and debug support
deploy_multi_tenant_stack() {
    log_info "Starting multi-tenant CDK deployment..."
    debug_log "Output file: ../apersona_idp_deploy_outputs.json"
    debug_log "This may take 15-30 minutes for full deployment..."

    # Clear cached CDK assets to ensure fresh Lambda bundles are deployed
    rm -rf cdk.out 2>/dev/null
    
    local start_time
    start_time=$(date +%s)
    
    local deploy_cmd="npx cdk deploy --require-approval never --all --outputs-file ../apersona_idp_deploy_outputs.json"
    
    if [[ "$DEBUG_MODE" == "1" ]]; then
        deploy_cmd="$deploy_cmd --verbose"
        debug_log "Running: $deploy_cmd"
    fi
    
    if [[ "$DEBUG_MODE" == "1" ]]; then
        # Show full output in debug mode
        if eval "$deploy_cmd"; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            debug_log "Deployment completed in ${duration}s"
            log_success "Multi-tenant service deployment completed successfully!"
            return 0
        else
            log_error "CDK deployment failed"
            return 1
        fi
    else
        # Show progress indicators in normal mode
        if eval "$deploy_cmd" 2>&1 | \
           while IFS= read -r line; do
               # Show important lines
               if [[ "$line" =~ (CREATE_COMPLETE|UPDATE_COMPLETE|CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|Stack.*ARN|✨|✅) ]]; then
                   echo "$line"
               else
                   echo -n "."
               fi
           done; then
            echo ""
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            debug_log "Deployment completed in ${duration}s"
            log_success "Multi-tenant service deployment completed successfully!"
            return 0
        else
            echo ""
            log_error "CDK deployment failed"
            return 1
        fi
    fi
}
