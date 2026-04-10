#!/bin/bash

# Build utilities for aPersona Multi-Tenant Installer
# This file contains build and dependency management functions

# Repository names (defined in main script)
# APERSONAIDP_REPO_NAME and APERSONAADM_REPO_NAME are set in the main script

# Exit codes (if not already defined)
if [[ -z "${EXIT_SUCCESS:-}" ]]; then
    readonly EXIT_SUCCESS=0
    readonly EXIT_ERROR=1
    readonly EXIT_USER_CANCEL=2
    readonly EXIT_CONFIG_ERROR=3
    readonly EXIT_AWS_ERROR=4
fi

# Package info extraction with better error handling
get_package_info() {
    local repo_name=$1
    local field=$2
    
    # Look for the repository relative to REPO_ROOT (works for both mono-repo and release layout)
    local repo_path="${REPO_ROOT:-$SCRIPT_DIR}/$repo_name"
    
    if [[ ! -f "$repo_path/package.json" ]]; then
        log_error "package.json not found in $repo_path directory"
        log_error "Please ensure the repository is properly cloned and built"
        log_error "Expected repository location: $repo_path"
        log_error "Current script directory: $SCRIPT_DIR"
        exit $EXIT_ERROR
    fi
    
    local result
    if ! result=$(jq -rc ".$field" "$repo_path/package.json" 2>/dev/null); then
        log_error "Failed to extract $field from $repo_path/package.json"
        exit $EXIT_ERROR
    fi
    
    echo "$result"
}

# Detect if running from a pre-built release repo (no source code, only compiled artifacts).
# Release repos have build/ or dist/ (compiled frontend) and cdk/lib/*.js but no src/ directory.
# Service uses build/, admin-portal uses dist/.
is_release_repo() {
    [[ ! -d "src" ]] && { [[ -d "build" ]] || [[ -d "dist" ]]; }
}

# Optimized dependency installation with better error handling and parallel builds
install_dependencies() {
    log_info "Installing application dependencies..."
    
    # Navigate to the repo root to find the repository
    cd "${REPO_ROOT:-$SCRIPT_DIR}" || exit $EXIT_ERROR
    
    # Ensure the repository exists
    if [[ ! -d "$APERSONAIDP_REPO_NAME" ]]; then
        log_error "Repository directory not found: $APERSONAIDP_REPO_NAME"
        log_error "Current directory: $(pwd)"
        log_error "Expected to find: $APERSONAIDP_REPO_NAME"
        log_error "Please ensure the repository is cloned in the same directory as the install script"
        exit $EXIT_ERROR
    fi
    
    cd "$APERSONAIDP_REPO_NAME" || exit $EXIT_ERROR
    
    # Check Node.js version and set appropriate options
    local node_version
    node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ "$node_version" -ge 18 ]] && [[ "$node_version" -lt 21 ]]; then
        export NODE_OPTIONS="--max-old-space-size=8192 --no-experimental-fetch"
    else
        export NODE_OPTIONS="--max-old-space-size=8192"
    fi
    
    # Use npm ci for faster, reliable installs when package-lock.json exists
    if [[ -f "package-lock.json" ]]; then
        log_info "Using npm ci for faster installation..."
        if ! timeout 600 npm ci --silent --no-progress --no-audit --no-fund; then
            log_warning "npm ci failed or timed out, falling back to npm install..."
            if ! timeout 600 npm install --silent --no-progress --no-audit --no-fund; then
                log_error "Failed to install dependencies with both npm ci and npm install"
                exit $EXIT_ERROR
            fi
        fi
    else
        log_info "Using npm install..."
        if ! timeout 600 npm install --silent --no-progress --no-audit --no-fund; then
            log_error "Failed to install dependencies with npm install"
            exit $EXIT_ERROR
        fi
    fi
    
    # Verify node_modules exists
    if [[ ! -d "node_modules" ]]; then
        log_error "node_modules directory not found after installation"
        exit $EXIT_ERROR
    fi
    
    log_success "Dependencies installed successfully"
    
    # In release repo, all artifacts are pre-built — skip build steps
    if is_release_repo; then
        log_info "Release repo detected (pre-built artifacts). Skipping build steps."
        log_success "Pre-built artifacts verified"
        return 0
    fi
    
    # Build main application with error handling
    log_info "Building main application..."
    if ! timeout 600 npm run build --silent >/dev/null 2>&1; then
        log_error "Failed to build main application"
        exit $EXIT_ERROR
    fi
    
    # Build lambda functions with error handling
    log_info "Building lambda functions..."
    if ! timeout 300 npm run lambda-build --silent >/dev/null 2>&1; then
        log_error "Failed to build lambda functions"
        exit $EXIT_ERROR
    fi
    
    # Build portal with optimized installation
    log_info "Building end user portal..."
    cd spportal || exit $EXIT_ERROR
    
    if [[ -f "package-lock.json" ]]; then
        log_info "Installing spportal dependencies with npm ci..."
        if ! timeout 600 npm ci --silent --no-progress --no-audit --no-fund --legacy-peer-deps; then
            log_warning "npm ci failed for spportal, falling back to npm install..."
            if ! timeout 600 npm install --silent --no-progress --no-audit --no-fund --legacy-peer-deps; then
                log_error "Failed to install spportal dependencies"
                exit $EXIT_ERROR
            fi
        fi
    else
        log_info "Installing spportal dependencies with npm install..."
        if ! timeout 600 npm install --silent --no-progress --no-audit --no-fund --legacy-peer-deps; then
            log_error "Failed to install spportal dependencies"
            exit $EXIT_ERROR
        fi
    fi
    
    # Verify spportal node_modules exists
    if [[ ! -d "node_modules" ]]; then
        log_error "spportal node_modules directory not found after installation"
        exit $EXIT_ERROR
    fi
    
    log_info "Building spportal..."
    if ! timeout 600 npm run build --silent >/dev/null 2>&1; then
        log_error "Failed to build end user portal"
        exit $EXIT_ERROR
    fi
    
    cd .. || exit $EXIT_ERROR
    
    log_success "Dependencies installed and built successfully"
}

# Build CDK stack
build_cdk_stack() {
    # In release repo, CDK JS is already compiled — skip TypeScript compilation
    if is_release_repo; then
        log_info "Release repo detected. CDK already compiled — skipping cdk-build."
        log_success "CDK stack ready (pre-compiled)"
        return 0
    fi

    log_info "Building CDK stack..."
    if ! npm run cdk-build --silent >/dev/null 2>&1; then
        log_error "Failed to build CDK stack"
        exit $EXIT_ERROR
    fi
    log_success "CDK stack built successfully"
}
