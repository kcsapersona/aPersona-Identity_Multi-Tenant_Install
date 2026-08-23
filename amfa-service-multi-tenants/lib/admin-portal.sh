#!/bin/bash

# Admin portal utilities for aPersona Multi-Tenant Installer
# This file contains admin portal deployment and configuration functions

# DEBUG MODE - controlled by DEBUG_MODE environment variable (shared with aws-utils.sh)

# Repository names (defined in main script)
# APERSONAADM_REPO_NAME is set in the main script

# Exit codes (if not already defined)
if [[ -z "${EXIT_SUCCESS:-}" ]]; then
    readonly EXIT_SUCCESS=0
    readonly EXIT_ERROR=1
    readonly EXIT_USER_CANCEL=2
    readonly EXIT_CONFIG_ERROR=3
    readonly EXIT_AWS_ERROR=4
fi

# Debug logging function - only logs when DEBUG_MODE=1
debug_log() {
    if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
        log_info "[DEBUG ADMIN] $*"
    fi
}

# Resolve the release version in both packaged and source repository layouts.
resolve_worker_version() {
    local repo_root=$1
    local version=""
    local package_json

    if [[ -s "$repo_root/VERSION" ]]; then
        version=$(tr -d '[:space:]' < "$repo_root/VERSION")
    fi

    if [[ -z "$version" ]]; then
        for package_json in \
            "$repo_root/package.json" \
            "$repo_root/${APERSONAADM_REPO_NAME:-packages/admin-portal}/package.json"; do
            if [[ -f "$package_json" ]]; then
                version=$(jq -er '.version // empty' "$package_json" 2>/dev/null || true)
                [[ -n "$version" ]] && break
            fi
        done
    fi

    printf '%s\n' "${version:-0.0.0}"
}

# Enhanced admin portal deployment
deploy_admin_portal() {
    debug_log "=========================================="
    debug_log "ADMIN PORTAL DEPLOYMENT START"
    debug_log "=========================================="
    debug_log "Current directory before navigation: $(pwd)"
    debug_log "SCRIPT_DIR: $SCRIPT_DIR"
    debug_log "APERSONAADM_REPO_NAME: $APERSONAADM_REPO_NAME"
    debug_log "ROOT_DOMAIN_NAME: $ROOT_DOMAIN_NAME"
    
    log_info "Deploying admin portal..."

    # Navigate to the repo root and then to the admin portal repo
    cd "${REPO_ROOT:-$SCRIPT_DIR}" || exit $EXIT_ERROR
    debug_log "Changed to REPO_ROOT: $(pwd)"
    
    if [[ ! -d "$APERSONAADM_REPO_NAME" ]]; then
        log_error "Admin portal directory not found: $APERSONAADM_REPO_NAME"
        log_error "Available directories: $(ls -d */ 2>/dev/null || echo 'none')"
        exit $EXIT_ERROR
    fi
    
    cd "$APERSONAADM_REPO_NAME" || exit $EXIT_ERROR
    debug_log "Changed to admin portal directory: $(pwd)"
    
    # Verify critical files exist
    debug_log "Checking for cdk.json..."
    if [[ ! -f "cdk.json" ]]; then
        log_error "cdk.json not found in $(pwd)"
        exit $EXIT_ERROR
    fi
    debug_log "✓ cdk.json found"
    
    debug_log "Checking for package.json..."
    if [[ ! -f "package.json" ]]; then
        log_error "package.json not found in $(pwd)"
        exit $EXIT_ERROR
    fi
    debug_log "✓ package.json found"

    export ADMINPORTAL_DOMAIN_NAME="adminportal.$ROOT_DOMAIN_NAME"
    debug_log "ADMINPORTAL_DOMAIN_NAME: $ADMINPORTAL_DOMAIN_NAME"

    # Check/create hosted zone for admin portal
    log_info "Looking for existing hosted zone for: $ADMINPORTAL_DOMAIN_NAME"
    
    local adminportal_hosted_zone_id
    # Try multiple approaches to find the hosted zone
    adminportal_hosted_zone_id=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$ADMINPORTAL_DOMAIN_NAME.'].Id" --output text 2>/dev/null)
    
    # If not found, try with jq
    if [[ -z "$adminportal_hosted_zone_id" || "$adminportal_hosted_zone_id" = "None" ]]; then
        adminportal_hosted_zone_id=$(aws route53 list-hosted-zones | jq -r ".HostedZones[] | select(.Name==\"$ADMINPORTAL_DOMAIN_NAME.\") | .Id" 2>/dev/null)
    fi
    
    # Remove the /hostedzone/ prefix if present
    adminportal_hosted_zone_id=${adminportal_hosted_zone_id#/hostedzone/}
    
    log_info "Found hosted zone ID: $adminportal_hosted_zone_id"

    if [[ -z "$adminportal_hosted_zone_id" || "$adminportal_hosted_zone_id" = "null" || "$adminportal_hosted_zone_id" = "None" ]]; then
        log_info "Creating hosted zone for $ADMINPORTAL_DOMAIN_NAME"

        adminportal_hosted_zone_id=$(aws route53 create-hosted-zone --name "$ADMINPORTAL_DOMAIN_NAME" --caller-reference "$RANDOM" | jq -r .HostedZone.Id)
        adminportal_hosted_zone_id=${adminportal_hosted_zone_id#*/}

        local name_servers
        name_servers=$(aws route53 get-hosted-zone --id "$adminportal_hosted_zone_id" | jq -r '.DelegationSet.NameServers[]')

        # Create NS record
        cat > ns_record.json <<EOF
{
    "Changes": [{
        "Action": "CREATE",
        "ResourceRecordSet": {
            "Name": "$ADMINPORTAL_DOMAIN_NAME",
            "Type": "NS",
            "TTL": 300,
            "ResourceRecords": [
EOF

        local first=true
        while IFS= read -r name_server; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo "," >> ns_record.json
            fi
            echo "                { \"Value\": \"$name_server\" }" >> ns_record.json
        done <<< "$name_servers"

        cat >> ns_record.json <<EOF
            ]
        }
    }]
}
EOF

        aws route53 change-resource-record-sets --hosted-zone-id "$ROOT_HOSTED_ZONE_ID" --change-batch file://ns_record.json >/dev/null
        log_success "Created hosted zone for $ADMINPORTAL_DOMAIN_NAME"
    else
        # Check for duplicate hosted zones
        local duplicate_count
        duplicate_count=$(aws route53 list-hosted-zones | jq ".HostedZones | map(select(.Name==\"$ADMINPORTAL_DOMAIN_NAME.\")) | length")

        if [[ "$duplicate_count" -gt 1 ]]; then
            log_error "Multiple hosted zones found for $ADMINPORTAL_DOMAIN_NAME. Please resolve this manually."
            exit $EXIT_ERROR
        fi

        log_info "Using existing hosted zone for $ADMINPORTAL_DOMAIN_NAME"
    fi

    export ADMINPORTAL_HOSTED_ZONE_ID=${adminportal_hosted_zone_id#*/}
    log_info "Admin Portal Hosted Zone ID: $ADMINPORTAL_HOSTED_ZONE_ID"
    debug_log "ADMINPORTAL_HOSTED_ZONE_ID exported: $ADMINPORTAL_HOSTED_ZONE_ID"

    # Install dependencies and build
    debug_log "Installing admin portal dependencies..."
    log_info "Installing admin portal dependencies..."
    if npm install --legacy-peer-deps --silent >/dev/null 2>&1; then
        debug_log "✓ npm install completed successfully"
    else
        log_error "npm install failed"
        return 1
    fi

    # In release repo, all artifacts are pre-built — skip build steps
    if is_release_repo; then
        log_info "Release repo detected (pre-built admin portal artifacts). Skipping build steps."
        debug_log "✓ Skipped build/lambda-build/cdk-build (pre-compiled)"
    else
        debug_log "Building admin portal..."
        log_info "Building admin portal..."
        
        if npm run build --silent >/dev/null 2>&1; then
            debug_log "✓ npm run build completed"
        else
            log_error "npm run build failed"
            return 1
        fi
        
        if npm run lambda-build --silent >/dev/null 2>&1; then
            debug_log "✓ npm run lambda-build completed"
        else
            log_error "npm run lambda-build failed"
            return 1
        fi
        
        if npm run cdk-build --silent >/dev/null 2>&1; then
            debug_log "✓ npm run cdk-build completed"
        else
            log_error "npm run cdk-build failed"
            return 1
        fi
    fi

    # Read Admin Portal distribution ID from SSM (shared across all tenants)
    export ADMINPORTAL_DISTRIBUTION_ID=$(aws ssm get-parameter --name "/amfa/shared/adminportal-distribution-id" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    debug_log "ADMINPORTAL_DISTRIBUTION_ID: ${ADMINPORTAL_DISTRIBUTION_ID:-not found}"

    # Ensure IGW SSM parameter exists (needed for dedicated IP provisioning)
    local vpc_id_for_igw
    vpc_id_for_igw=$(aws ssm get-parameter --name "/amfa/vpc/vpc-id" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    if [[ -n "$vpc_id_for_igw" && "$vpc_id_for_igw" != "None" ]]; then
        local existing_igw
        existing_igw=$(aws ssm get-parameter --name "/amfa/vpc/igw-id" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
        if [[ -z "$existing_igw" || "$existing_igw" == "None" ]]; then
            log_info "Auto-detecting Internet Gateway for VPC $vpc_id_for_igw..."
            local igw_id
            igw_id=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id_for_igw" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
            if [[ -n "$igw_id" && "$igw_id" != "None" ]]; then
                aws ssm put-parameter --name "/amfa/vpc/igw-id" --value "$igw_id" --type String --overwrite >/dev/null 2>&1
                log_info "✓ Set /amfa/vpc/igw-id = $igw_id"
            else
                debug_log "No IGW found for VPC $vpc_id_for_igw (dedicated IP provisioning will not work)"
            fi
        else
            debug_log "IGW SSM parameter already set: $existing_igw"
        fi
    fi

    # Deploy admin portal stack
    debug_log "=========================================="
    debug_log "CDK DEPLOYMENT START"
    debug_log "=========================================="
    debug_log "Current directory: $(pwd)"
    debug_log "CDK Deploy Region: $CDK_DEPLOY_REGION"
    debug_log "CDK Deploy Account: $CDK_DEPLOY_ACCOUNT"
    debug_log "Command: npx cdk deploy --require-approval never --all --outputs-file ../apersona_idp_mgt_deploy_outputs.json"
    
    log_info "Deploying admin portal stack..."

    # Clear cached CDK assets to ensure fresh Lambda bundles are deployed
    rm -rf cdk.out 2>/dev/null

    local cdk_log_file="/tmp/admin-portal-cdk-deploy.log"
    
    if [[ "$DEBUG_MODE" == "1" ]]; then
        # Show full output in debug mode
        if npx cdk deploy --require-approval never --all --verbose --outputs-file ../apersona_idp_mgt_deploy_outputs.json 2>&1 | tee "$cdk_log_file"; then
            debug_log "✓ CDK deployment completed successfully"
        else
            log_error "Admin portal CDK deployment failed"
            log_error "See deployment log: $cdk_log_file"
            debug_log "CDK deployment failed. Last 50 lines of log:"
            debug_log "$(tail -50 "$cdk_log_file" 2>/dev/null || echo 'Log file not found')"
            return 1
        fi
    else
        # Show compact progress in normal mode (aligned with amfa-services deploy style)
        if npx cdk deploy --require-approval never --all --outputs-file ../apersona_idp_mgt_deploy_outputs.json 2>&1 | \
           tee "$cdk_log_file" | \
           while IFS= read -r line; do
               # Show important lines
               if [[ "$line" =~ (CREATE_COMPLETE|UPDATE_COMPLETE|CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|Stack.*ARN|✨|✅) ]]; then
                   echo "$line"
               else
                   echo -n "."
               fi
           done; then
            echo ""
            log_info "CDK deployment completed successfully"
        else
            echo ""
            log_error "Admin portal CDK deployment failed"
            log_error "See deployment log: $cdk_log_file"
            return 1
        fi
    fi
    
    # Verify outputs file was created
    if [[ -f "../apersona_idp_mgt_deploy_outputs.json" ]]; then
        debug_log "✓ Outputs file created: ../apersona_idp_mgt_deploy_outputs.json"
        debug_log "Outputs file content:"
        debug_log "$(cat ../apersona_idp_mgt_deploy_outputs.json | jq . 2>/dev/null || cat ../apersona_idp_mgt_deploy_outputs.json)"
    else
        log_error "✗ Outputs file NOT created!"
    fi
    
    # Verify CloudFormation stacks were created
    debug_log "Checking CloudFormation stacks..."
    local stacks=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[?contains(StackName, `CertStack`) || contains(StackName, `SSO-CUP`)].StackName' --output text 2>/dev/null)
    if [[ -n "$stacks" ]]; then
        debug_log "✓ Admin portal stacks found: $stacks"
    else
        log_warning "⚠ Admin portal stacks not found in CloudFormation!"
    fi
    
    debug_log "CDK deployment section completed"

    # Note: amfaext.js is deployed alongside dist/ in a single CDK BucketDeployment.
    # Admin user + SA group creation is handled by the post-deployment Lambda.

    # ─── Upload AD Sync Worker code to S3 (post-deploy, bucket now exists) ────
    # Per-tenant dedicated IP Lambdas are created at runtime from this S3 artifact.
    # Must run AFTER CDK deploy (S3 bucket is created by CDK).
    local worker_dist="$(pwd)/cdk/lambda/ad-sync-worker/dist"
    if [[ -d "$worker_dist" ]]; then
        local s3_bucket="${CDK_DEPLOY_ACCOUNT}-${CDK_DEPLOY_REGION}-ad-sync-state"
        local worker_version
        worker_version=$(resolve_worker_version "$REPO_ROOT")
        local zip_file="/tmp/ad-sync-worker-code.zip"

        log_info "Uploading AD sync worker code to S3 (v${worker_version})..."
        (cd "$worker_dist" && zip -qr "$zip_file" .)

        if aws s3 cp "$zip_file" "s3://${s3_bucket}/worker-code/v${worker_version}.zip" --quiet 2>/dev/null; then
            aws s3 cp "$zip_file" "s3://${s3_bucket}/worker-code/latest.zip" --quiet 2>/dev/null
            log_success "Worker code uploaded to S3 (v${worker_version} + latest)"
        else
            log_warning "⚠ Failed to upload worker code to S3 (bucket may not exist yet on first deploy)"
        fi

        rm -f "$zip_file"
    fi

    log_success "Admin portal deployed successfully"
}
