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
    # Writer gate, step 1 (rounds 18–19 P1): close the SIGNUP# gate item BEFORE
    # the deploy and drain in-flight requests, so no SIGNUP# write can land
    # while CloudFormation may be replacing the D10 stream consumer's mapping.
    # Re-opened by signup_gate_writers after the deploy, once the consumer is
    # verified and has acked a canary.
    signup_close_writers || return 1

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
        signup_gate_writers "../apersona_idp_mgt_deploy_outputs.json" || return 1
    else
        log_error "✗ Outputs file NOT created! Cannot verify the signup-events consumer; aborting."
        return 1
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

# ---------------------------------------------------------------------------
# Tenant self-signup writer gate (TENANT_SELF_SIGNUP_IMPLEMENTATION.md D10,
# round 19).
#
# The D10 stream consumer must be reading before any SIGNUP# item is
# written, and a CloudFormation update may replace the consumer's mapping
# (LATEST: records written during the replacement would be missed). The
# gate is a DynamoDB item, `SIGNUP#__gate__` / `GATE`, that EVERY SIGNUP#
# write in lambda/shared/signup/state.mjs condition-checks in the same
# transaction (closed -> 503 maintenance). It covers registration, setup,
# retry and the orchestrator alike, which the earlier key-secret gate did
# not (round 19 P1).
#
#   signup_close_writers  — before `cdk deploy`: write the gate item closed,
#                           empty the registration key list (the only gate
#                           Lambdas from a pre-gate release know), then wait
#                           out the API Gateway timeout so every request
#                           already in flight has either committed or been
#                           refused.
#   signup_gate_writers   — after `cdk deploy`: verify the consumer (mapping
#                           Enabled, no PROBLEM processing result, function
#                           Active), prove it is LIVE by writing a canary
#                           item through the stream and waiting for its ack,
#                           store the configured registration keys, and only
#                           then reopen the gate. Any failure aborts the
#                           install with the gate still closed.
#
# The key material is read from the config file here, in this function's
# scope, and passed straight to Secrets Manager; it is never exported.
# ---------------------------------------------------------------------------
SIGNUP_SECRET_ID="apersona/signup/apikey"
SIGNUP_EMPTY_KEYS='{"keys":[]}'
SIGNUP_TENANT_TABLE="amfa-tenanttable"
SIGNUP_GATE_ID="SIGNUP#__gate__"
SIGNUP_GATE_SK="GATE"
SIGNUP_CANARY_ID="SIGNUP#__canary__"
SIGNUP_CANARY_SK="SIGNUP#PROFILE"   # the stream filter only delivers this sk
SIGNUP_DRAIN_SECONDS=35             # > the 30 s API Gateway integration timeout
SIGNUP_CANARY_POLLS=45              # x 2 s = ~90 s for the consumer to ack

# Every regional call names its region: detect_aws_environment exports only
# CDK_DEPLOY_REGION, and AWS_REGION is set only when config has aws.region, so
# a bare `aws` call on an EC2 host can have no region at all (round 20 P1).
signup_aws() { aws "$@" --region "${CDK_DEPLOY_REGION:-$AWS_REGION}"; }

signup_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
signup_nonce() {
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$RANDOM$RANDOM"
}

# Configured keys as the secret JSON. The config file is mandatory and the
# read must succeed: a missing file or a jq failure aborts instead of
# silently storing an empty key list (round 19 P2). Only a config whose
# `signup.keys` is really empty (or absent) yields {"keys":[]}.
signup_configured_keys() {
    local config_file="${TENANTS_CONFIG_FILE:-}"
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_error "TENANTS_CONFIG_FILE is not set or does not exist ('${config_file}'); cannot read the registration keys."
        return 1
    fi
    local keys
    if ! keys=$(jq -c '{keys: [(.signup.keys // [])[] | select(.key != null and .key != "")]}' "$config_file" 2>&1); then
        log_error "Failed to read signup.keys from $config_file: $keys"
        return 1
    fi
    [[ "$keys" == \{* ]] || { log_error "Unexpected jq output for signup.keys: $keys"; return 1; }
    echo "$keys"
}

# Write the gate item: closed=true|false.
signup_write_gate() {
    local closed="$1" reason="$2"
    signup_aws dynamodb put-item --table-name "$SIGNUP_TENANT_TABLE" --item \
        "{\"id\":{\"S\":\"$SIGNUP_GATE_ID\"},\"sk\":{\"S\":\"$SIGNUP_GATE_SK\"},\"closed\":{\"BOOL\":$closed},\"reason\":{\"S\":\"$reason\"},\"at\":{\"S\":\"$(signup_now)\"}}" \
        >/dev/null
}

signup_close_writers() {
    log_info "Closing self-signup writes (gate item $SIGNUP_GATE_ID closed) for the duration of the deploy..."
    if ! signup_write_gate true deploy; then
        log_error "Could not write the signup gate item to $SIGNUP_TENANT_TABLE; the deploy must not start."
        return 1
    fi
    # Lambdas from a release before the gate item do not read it; for them
    # the empty registration key list is still the only closure, so keep
    # writing it until the deploy has replaced them (round 20 P1). The keys
    # are restored by signup_gate_writers before the gate reopens.
    log_info "Emptying the registration key list for writers that predate the gate item..."
    store_secret_or_die "$SIGNUP_SECRET_ID" "$SIGNUP_EMPTY_KEYS" \
        "Tenant self-signup registration API keys with per-key IP allowlist and org"
    log_info "Draining in-flight signup requests (${SIGNUP_DRAIN_SECONDS}s)..."
    sleep "$SIGNUP_DRAIN_SECONDS"
    return 0
}

# Verify the stream consumer is really processing: mapping Enabled AND its
# last processing result is not a problem AND the function is Active. Every
# lookup failure is a failure (round 19 P2: an unknown function is not ready).
signup_consumer_ready() {
    local uuid="$1" state="" result="" fn="" fstate=""
    local i
    for i in $(seq 1 45); do
        state=$(signup_aws lambda get-event-source-mapping --uuid "$uuid" --query State --output text 2>/dev/null) || state="(lookup failed)"
        [[ "$state" == "Enabled" ]] && break
        sleep 2
    done
    if [[ "$state" != "Enabled" ]]; then
        log_error "signup-events stream consumer is '$state', not Enabled."
        return 1
    fi
    result=$(signup_aws lambda get-event-source-mapping --uuid "$uuid" --query LastProcessingResult --output text 2>/dev/null) || result="(lookup failed)"
    case "$result" in
        OK|"No records processed"|None|null|"") ;;  # healthy, or nothing to process yet (liveness is proven by the canary)
        *) log_error "signup-events stream consumer reports LastProcessingResult='$result'."; return 1 ;;
    esac
    fn=$(signup_aws lambda get-event-source-mapping --uuid "$uuid" --query FunctionArn --output text 2>/dev/null) || fn=""
    if [[ -z "$fn" || "$fn" == "None" ]]; then
        log_error "Could not resolve the signup-events function from mapping $uuid; not treating it as ready."
        return 1
    fi
    fstate=$(signup_aws lambda get-function-configuration --function-name "$fn" --query State --output text 2>/dev/null) || fstate="(lookup failed)"
    if [[ "$fstate" != "Active" ]]; then
        log_error "signup-events function is '$fstate', not Active."
        return 1
    fi
    return 0
}

# Liveness: write the canary item (its sk passes the stream filter) and
# wait for the consumer to ack the nonce on the same item.
signup_consumer_live() {
    local nonce acked="" i
    nonce=$(signup_nonce)
    if ! signup_aws dynamodb put-item --table-name "$SIGNUP_TENANT_TABLE" --item \
        "{\"id\":{\"S\":\"$SIGNUP_CANARY_ID\"},\"sk\":{\"S\":\"$SIGNUP_CANARY_SK\"},\"status\":{\"S\":\"canary\"},\"nonce\":{\"S\":\"$nonce\"},\"at\":{\"S\":\"$(signup_now)\"}}" \
        >/dev/null; then
        log_error "Could not write the signup canary item to $SIGNUP_TENANT_TABLE."
        return 1
    fi
    for i in $(seq 1 "$SIGNUP_CANARY_POLLS"); do
        acked=$(signup_aws dynamodb get-item --table-name "$SIGNUP_TENANT_TABLE" --consistent-read \
            --key "{\"id\":{\"S\":\"$SIGNUP_CANARY_ID\"},\"sk\":{\"S\":\"$SIGNUP_CANARY_SK\"}}" \
            --query 'Item.ackedNonce.S' --output text 2>/dev/null) || acked=""
        [[ "$acked" == "$nonce" ]] && return 0
        sleep 2
    done
    log_error "signup-events consumer did not ack the canary (nonce $nonce) within $((SIGNUP_CANARY_POLLS * 2))s: the stream is not being read."
    return 1
}

signup_gate_writers() {
    local outputs_file="$1"
    local uuid
    uuid=$(jq -r '.["SSO-CUPStack"].SignupEventsMappingUuid // empty' "$outputs_file" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        log_error "Deploy outputs carry no SignupEventsMappingUuid: the D10 stream consumer is not in this stack. Signup writes stay closed; aborting."
        return 1
    fi
    log_info "Verifying the signup-events stream consumer ($uuid)..."
    if ! signup_consumer_ready "$uuid"; then
        log_error "Signup writes stay closed (gate item not reopened); aborting."
        return 1
    fi
    log_info "Proving the consumer is live (canary through the stream)..."
    if ! signup_consumer_live; then
        log_error "Signup writes stay closed (gate item not reopened); aborting."
        return 1
    fi
    log_info "signup-events stream consumer is ready and live"
    local keys
    if ! keys=$(signup_configured_keys); then
        log_error "Signup writes stay closed (gate item not reopened); aborting."
        return 1
    fi
    store_secret_or_die "$SIGNUP_SECRET_ID" "$keys" \
        "Tenant self-signup registration API keys with per-key IP allowlist and org"
    if [[ "$keys" == "$SIGNUP_EMPTY_KEYS" ]]; then
        log_info "No registration keys in config: POST /signup is unusable (empty key list stored)"
    else
        log_info "Registration keys stored"
    fi
    if ! signup_write_gate false deployed; then
        log_error "Could not reopen the signup gate item in $SIGNUP_TENANT_TABLE; signup writes stay closed. Aborting."
        return 1
    fi
    log_info "Self-signup writes reopened (gate item $SIGNUP_GATE_ID open)"
    return 0
}
