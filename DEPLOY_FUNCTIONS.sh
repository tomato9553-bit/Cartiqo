#!/bin/bash
# SwiftCart Custom OTP - Enhanced Cloud Functions Deployment Script
# This script automates the Cloud Functions setup and deployment with
# comprehensive error handling, validation, and logging

set -euo pipefail  # Exit on error, undefined variables, pipe failures

# Script variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FUNCTIONS_DIR="${SCRIPT_DIR}/functions"
readonly ENV_FILE="${FUNCTIONS_DIR}/.env"
readonly LOG_FILE="${SCRIPT_DIR}/deployment_$(date +%Y%m%d_%H%M%S).log"
readonly MIN_NODE_VERSION="18.0.0"
readonly MIN_NPM_VERSION="8.0.0"

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly GRAY='\033[0;37m'
readonly NC='\033[0m' # No Color

# State tracking
FIREBASE_CLI_INSTALLED=false
DEPLOYMENT_FAILED=false

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

log_warning() {
    log "WARNING" "$@"
}

log_error() {
    log "ERROR" "$@"
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}⚠  $1${NC}" | tee -a "$LOG_FILE"
}

# Cleanup function for graceful shutdown
cleanup() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo ""
        print_error "Deployment failed with exit code $exit_code"
        echo -e "${GRAY}Check ${LOG_FILE} for details${NC}"
    fi
    
    return $exit_code
}

trap cleanup EXIT

# ============================================================================
# Validation Functions
# ============================================================================

compare_versions() {
    # Compare two version strings (e.g., "18.0.0" vs "18.5.0")
    # Returns 0 if first >= second, 1 otherwise
    local ver1="$1"
    local ver2="$2"
    
    printf '%s\n%s' "$ver2" "$ver1" | sort -V -C
}

check_command() {
    local cmd="$1"
    local display_name="${2:-$cmd}"
    
    if ! command -v "$cmd" &>/dev/null; then
        print_error "$display_name not found"
        return 1
    fi
    return 0
}

check_node_version() {
    local node_version=$(node --version | sed 's/v//')
    
    if ! compare_versions "$node_version" "$MIN_NODE_VERSION"; then
        print_error "Node.js version $node_version is below required $MIN_NODE_VERSION"
        return 1
    fi
    
    print_success "Node.js $node_version"
    return 0
}

check_npm_version() {
    local npm_version=$(npm --version)
    
    if ! compare_versions "$npm_version" "$MIN_NPM_VERSION"; then
        print_error "npm version $npm_version is below required $MIN_NPM_VERSION"
        return 1
    fi
    
    print_success "npm $npm_version"
    return 0
}

check_firebase_cli() {
    if ! check_command "firebase" "Firebase CLI"; then
        print_warning "Firebase CLI not found. Installing..."
        
        if npm install -g firebase-tools >> "$LOG_FILE" 2>&1; then
            FIREBASE_CLI_INSTALLED=true
            print_success "Firebase CLI installed successfully"
            return 0
        else
            print_error "Failed to install Firebase CLI"
            return 1
        fi
    fi
    
    print_success "Firebase CLI found"
    return 0
}

check_functions_directory() {
    if [ ! -d "$FUNCTIONS_DIR" ]; then
        print_error "functions directory not found at $FUNCTIONS_DIR"
        return 1
    fi
    
    if [ ! -f "$FUNCTIONS_DIR/package.json" ]; then
        print_error "functions/package.json not found"
        return 1
    fi
    
    print_success "functions directory structure valid"
    return 0
}

# ============================================================================
# Environment Configuration Functions
# ============================================================================

prompt_for_env() {
    local prompt_text="$1"
    local is_secret="${2:-false}"
    local default_value="${3:-}"
    
    if [ -n "$default_value" ]; then
        prompt_text="${prompt_text} [default: $default_value]"
    fi
    
    while true; do
        if [ "$is_secret" = "true" ]; then
            read -s -p "$(echo -e "${BLUE}${prompt_text}: ${NC}")" value
            echo "" >&2
        else
            read -p "$(echo -e "${BLUE}${prompt_text}: ${NC}")" value
        fi
        
        if [ -z "$value" ] && [ -n "$default_value" ]; then
            value="$default_value"
        fi
        
        if [ -z "$value" ]; then
            print_warning "This field is required. Please enter a value."
            continue
        fi
        
        echo "$value"
        break
    done
}

prompt_for_optional_env() {
    local prompt_text="$1"
    local is_secret="${2:-false}"
    local default_value="${3:-}"
    
    if [ "$is_secret" = "true" ]; then
        read -s -p "$(echo -e "${BLUE}${prompt_text} (optional): ${NC}")" value
        echo "" >&2
    else
        read -p "$(echo -e "${BLUE}${prompt_text} (optional): ${NC}")" value
    fi
    
    if [ -z "$value" ] && [ -n "$default_value" ]; then
        value="$default_value"
    fi
    
    echo "$value"
}

validate_twilio_credentials() {
    local account_sid="$1"
    local auth_token="$2"
    local phone_number="$3"
    
    if [ -z "$account_sid" ]; then
        print_error "Twilio Account SID is required"
        return 1
    fi
    
    if [ -z "$auth_token" ]; then
        print_error "Twilio Auth Token is required"
        return 1
    fi
    
    if [ -z "$phone_number" ]; then
        print_error "Twilio Phone Number is required"
        return 1
    fi
    
    # Basic phone number validation (starts with +, contains digits)
    if ! [[ "$phone_number" =~ ^\+[0-9]{10,}$ ]]; then
        print_error "Phone number must start with + and contain at least 10 digits (e.g., +1234567890)"
        return 1
    fi
    
    return 0
}

validate_email() {
    local email="$1"
    
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    
    return 1
}

configure_environment() {
    print_section "4. Configuring Environment Variables"
    
    echo ""
    echo -e "${GRAY}Get your Twilio credentials from: https://www.twilio.com/console${NC}"
    echo ""
    
    # Collect Twilio credentials (required)
    local twilio_account_sid
    local twilio_auth_token
    local twilio_phone_number
    
    while true; do
        twilio_account_sid=$(prompt_for_env "Twilio Account SID" "true")
        twilio_auth_token=$(prompt_for_env "Twilio Auth Token" "true")
        twilio_phone_number=$(prompt_for_env "Twilio Phone Number (e.g., +1234567890)")
        
        if validate_twilio_credentials "$twilio_account_sid" "$twilio_auth_token" "$twilio_phone_number"; then
            break
        fi
        
        echo ""
        print_warning "Please check your input and try again"
        echo ""
    done
    
    # Collect optional email credentials
    echo ""
    echo -e "${GRAY}Optional: Set up email OTP (via Resend)${NC}"
    local resend_api_key=$(prompt_for_optional_env "Resend API Key" "true")
    
    local from_email="otp@swiftcart.com"
    if [ -n "$resend_api_key" ]; then
        from_email=$(prompt_for_optional_env "From Email" false "otp@swiftcart.com")
        
        while [ -n "$from_email" ] && ! validate_email "$from_email"; do
            print_warning "Invalid email format"
            from_email=$(prompt_for_optional_env "From Email" false "otp@swiftcart.com")
        done
    fi
    
    # Backup existing .env file if it exists
    if [ -f "$ENV_FILE" ]; then
        local backup_file="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$ENV_FILE" "$backup_file"
        log_info "Backed up existing .env to $backup_file"
    fi
    
    # Write .env file with validation
    {
        echo "# SwiftCart OTP Configuration"
        echo "# Generated: $(date)"
        echo ""
        echo "# Twilio SMS Configuration (Required)"
        echo "TWILIO_ACCOUNT_SID=${twilio_account_sid}"
        echo "TWILIO_AUTH_TOKEN=${twilio_auth_token}"
        echo "TWILIO_PHONE_NUMBER=${twilio_phone_number}"
        echo ""
        
        if [ -n "$resend_api_key" ]; then
            echo "# Resend Email Configuration (Optional)"
            echo "RESEND_API_KEY=${resend_api_key}"
            echo "FROM_EMAIL=${from_email}"
            echo ""
        fi
        
        echo "# Environment"
        echo "NODE_ENV=production"
    } > "$ENV_FILE"
    
    # Secure .env file permissions
    chmod 600 "$ENV_FILE"
    
    print_success "Environment configuration saved"
    log_info "Configuration written to $ENV_FILE"
}

# ============================================================================
# Build and Deployment Functions
# ============================================================================

install_dependencies() {
    print_section "2. Installing Dependencies"
    
    if ! cd "$FUNCTIONS_DIR"; then
        print_error "Failed to enter functions directory"
        return 1
    fi
    
    if ! npm install >> "$LOG_FILE" 2>&1; then
        print_error "Failed to install dependencies"
        return 1
    fi
    
    print_success "Dependencies installed successfully"
    cd - > /dev/null
    return 0
}

build_typescript() {
    print_section "3. Building TypeScript"
    
    if ! cd "$FUNCTIONS_DIR"; then
        print_error "Failed to enter functions directory"
        return 1
    fi
    
    if ! npm run build >> "$LOG_FILE" 2>&1; then
        print_error "Failed to build TypeScript"
        return 1
    fi
    
    print_success "TypeScript compiled successfully"
    cd - > /dev/null
    return 0
}

deploy_functions() {
    print_section "5. Deploying Cloud Functions"
    
    if ! firebase deploy --only functions; then
        print_error "Cloud Functions deployment failed"
        return 1
    fi
    
    print_success "Cloud Functions deployed successfully"
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_section "🚀 SwiftCart Custom OTP - Cloud Functions Deployment"
    
    log_info "Deployment started"
    log_info "Script directory: $SCRIPT_DIR"
    log_info "Log file: $LOG_FILE"
    
    # Step 1: Check Prerequisites
    print_section "1. Checking Prerequisites"
    
    check_command "bash" "Bash" || return 1
    check_node_version || return 1
    check_npm_version || return 1
    check_firebase_cli || return 1
    check_functions_directory || return 1
    
    print_success "All prerequisites met"
    
    # Step 2: Install Dependencies
    install_dependencies || return 1
    
    # Step 3: Build TypeScript
    build_typescript || return 1
    
    # Step 4: Configure Environment
    configure_environment || return 1
    
    # Step 5: Deploy Functions
    deploy_functions || return 1
    
    # Success
    echo ""
    print_section "✅ Deployment Complete"
    
    echo ""
    echo -e "${BLUE}📋 Next Steps:${NC}"
    echo "  1. Test SMS sending by opening your Flutter app"
    echo "  2. Open the custom Phone OTP screen"
    echo "  3. Enter a phone number and click 'Send OTP'"
    echo "  4. Check your phone for the SMS"
    echo "  5. View logs: ${GRAY}firebase functions:log${NC}"
    echo ""
    echo -e "${YELLOW}⚠  Important:${NC}"
    echo "  • Update Firestore security rules"
    echo "  • See FUNCTIONS_DEPLOYMENT_GUIDE.md for details"
    echo "  • Keep your .env file secure and never commit it"
    echo ""
    
    log_info "Deployment completed successfully"
}

# Run main function
main "$@"
