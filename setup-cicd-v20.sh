#!/bin/bash

# ==============================================================================
# AUTOMATED CI/CD SETUP V20: The Robust Edition
# ==============================================================================
# A comprehensive, production-ready automation script with modular operation modes
# Includes Docker integration, safe configs, and smart detection.
# ==============================================================================

set -e

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================

readonly SCRIPT_VERSION="20"
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# NEW: Configuration file path
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="$SCRIPT_DIR/.cicd.conf"

# NEW: Default subdirectories (relative to CICD_DIR)
readonly TEMPLATES_SUBDIR="templates"
readonly LOGS_SUBDIR="logs"
readonly BACKUPS_SUBDIR="backups"
readonly CREDENTIALS_SUBDIR="credentials"
readonly STATE_SUBDIR="state"
readonly WHITELIST_SUBDIR="whitelist"
readonly WORKFLOWS_SUBDIR="generated-workflows"

# NEW: Backup retention
readonly BACKUP_RETENTION_DAYS=7

# Colors (existing)
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# Global Flags (existing + new)
DRY_RUN=false
OPERATION_MODE=""
HEADLESS_MODE=false
ALLOW_SUDOERS=false
INSTALL_DOCKER="N"
REDIS_MODE="system"

# NEW: Global paths (will be set after CICD_DIR is determined)
CICD_DIR=""
TEMPLATES_DIR=""
LOGS_DIR=""
BACKUPS_DIR=""
CREDENTIALS_DIR=""
STATE_DIR=""
WHITELIST_DIR=""
WORKFLOWS_DIR=""

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

log_info() {
	echo -e "${BLUE}>>> $1${NC}"
}

log_success() {
	echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
	echo -e "${RED}❌ $1${NC}"
}

log_warning() {
	echo -e "${YELLOW}⚠️  $1${NC}"
}

log_section() {
	echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
	echo -e "${CYAN}  $1${NC}"
	echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}

prompt_user() {
		local prompt="$1"
		local default="$2"
		local result
		
		if [ -n "$default" ]; then
				read -p "$prompt [$default]: " result
		else
				read -p "$prompt: " result
		fi
		
		result="${result:-$default}"
		echo "$result"
}

prompt_password() {
	local prompt="$1"
	local pass1 pass2
	
	while true; do
		read -p "$prompt: " pass1
		read -p "Confirm Password: " pass2
		
		if [ "$pass1" == "$pass2" ] && [ -n "$pass1" ]; then
			echo "$pass1"
			return 0
		else
			log_error "Passwords do not match or are empty. Try again."
		fi
	done
}


validate_integer() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]]
}

validate_user_exists() {
	local username="$1"
	id "$username" &>/dev/null
}

create_backup() {
    local file_path="$1"
    local backup_dir="${2:-$BACKUPS_DIR/$TIMESTAMP}"
    
    if [ -f "$file_path" ]; then
        # FIX: Use the local 'backup_dir' variable, not the global 'BACKUPS_DIR'
        mkdir -p "$backup_dir"
        cp "$file_path" "$backup_dir/"
        log_success "Backed up: $file_path"
    fi
}

cleanup_old_backups() {
    if [ ! -d "$BACKUPS_DIR" ]; then
        return 0
    fi
    log_info "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
    local count=0
    while IFS= read -r backup_dir; do
        rm -rf "$backup_dir"
        ((count++))
    done < <(find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS")
    if [ $count -gt 0 ]; then
        log_success "Removed $count old backup(s)"
    else
        log_info "No old backups to remove"
    fi
}


detect_ssh_port() {
    local port="22"
    
    # Try to detect from running process first
    if command -v ss &>/dev/null; then
        local detected=$(ss -tlnp | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -n 1)
        if [ -n "$detected" ]; then
            echo "$detected"
            return
        fi
    fi
    
    # Fallback to config file
    if [ -f /etc/ssh/sshd_config ]; then
        local detected=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1 || true)
        if [ -n "$detected" ] && [[ "$detected" =~ ^[0-9]+$ ]]; then
            port="$detected"
        fi
    fi
    
    echo "$port"
}

check_docker_status() {
	if command -v docker &>/dev/null; then
		return 0 # Installed
	else
		return 1 # Not installed
	fi
}

check_and_install_tool() {
	local cmd="$1"
	local pkg="$2"
	
	if ! command -v "$cmd" &>/dev/null; then
		local choice=$(prompt_user "Command '$cmd' is missing. Install package '$pkg'? [y/N]" "N")
		if [[ "$choice" =~ ^[Yy]$ ]]; then
			if [ "$DRY_RUN" = false ]; then
				log_info "Installing $pkg..."
				apt update -y
				apt_install_retry "$pkg"
				log_success "$pkg installed"
			fi
			return 0
		else
			log_warning "Skipping $cmd check."
			return 1
		fi
	fi
	return 0
}

validate_script_location() {
	local script_dir="$SCRIPT_DIR"
	
	# Refuse to run from root or home directory
	if [ "$script_dir" == "/" ] || [ "$script_dir" == "$HOME" ]; then
		log_error "Cannot run script from root (/) or home (~) directory!"
		echo ""
		echo "This script generates multiple files and directories."
		echo "Please move it to a dedicated folder first."
		echo ""
		echo "Example:"
		echo "  mkdir -p ~/cicd-setup"
		echo "  mv $0 ~/cicd-setup/"
		echo "  cd ~/cicd-setup"
		echo "  sudo bash $(basename $0)"
		exit 1
	fi
}

check_or_create_config() {
	if [ -f "$CONFIG_FILE" ]; then
		# Load existing config
		source "$CONFIG_FILE"
		
		if [ -z "$CICD_DIR" ]; then
			log_error "Config file exists but CICD_DIR is not set"
			rm -f "$CONFIG_FILE"
			configure_cicd_directory
		else
			log_info "Using existing CICD directory: $CICD_DIR"
		fi
	else
		# First run - ask user
		configure_cicd_directory
	fi
	
	# Set all subdirectory paths
	TEMPLATES_DIR="$CICD_DIR/$TEMPLATES_SUBDIR"
	LOGS_DIR="$CICD_DIR/$LOGS_SUBDIR"
	BACKUPS_DIR="$CICD_DIR/$BACKUPS_SUBDIR"
	CREDENTIALS_DIR="$CICD_DIR/$CREDENTIALS_SUBDIR"
	STATE_DIR="$CICD_DIR/$STATE_SUBDIR"
	WHITELIST_DIR="$CICD_DIR/$WHITELIST_SUBDIR"
	WORKFLOWS_DIR="$CICD_DIR/$WORKFLOWS_SUBDIR"
	
	# Create directory structure
	create_cicd_structure
}

configure_cicd_directory() {
	log_section "First Time Setup - CICD Directory Configuration"
	
	echo "This script needs a directory to store:"
	echo "  • Configuration templates"
	echo "  • Logs and backups"
	echo "  • Generated workflows"
	echo "  • Credentials (secure storage)"
	echo ""
	
	local default_dir="/opt/cicd-artifacts"
	
	if [ "$HEADLESS_MODE" = true ]; then
		CICD_DIR="$default_dir"
		log_info "Headless mode: Using default directory: $CICD_DIR"
	else
		CICD_DIR=$(prompt_user "Choose CICD artifacts directory" "$default_dir")
	fi
	
	# Validate path
	if [[ "$CICD_DIR" == "/" ]] || [[ "$CICD_DIR" == "$HOME" ]]; then
		log_error "Cannot use root or home directory. Please choose a subdirectory."
		configure_cicd_directory
		return
	fi
	
	# Save to config file
	cat > "$CONFIG_FILE" <<EOF
# CICD Setup Script Configuration
# Generated: $(date)
CICD_DIR="$CICD_DIR"
EOF
	
	chmod 600 "$CONFIG_FILE"
	log_success "Configuration saved to $CONFIG_FILE"
}

create_cicd_structure() {
    log_info "Creating CICD directory structure..."
    
    # 1. Create Directories
    # We use -p to avoid errors if they exist
    mkdir -p "$CICD_DIR"
    mkdir -p "$TEMPLATES_DIR"
    mkdir -p "$LOGS_DIR"
    mkdir -p "$BACKUPS_DIR"
    mkdir -p "$CREDENTIALS_DIR"
    mkdir -p "$STATE_DIR"
    mkdir -p "$WHITELIST_DIR"
    mkdir -p "$WORKFLOWS_DIR"

    # 2. Assign Ownership to TARGET_USER (Recursively)
    # This ensures the Runner/User can read/write their own config/creds
    chown -R "$TARGET_USER":"$TARGET_USER" "$CICD_DIR"

    # 3. Lock down permissions (Security)
    # 700 = Only Owner (TARGET_USER) and Root can read/write/execute
    chmod 700 "$CICD_DIR"
    #chmod 700 "$LOGS_DIR"
    chmod 700 "$BACKUPS_DIR"
    chmod 700 "$CREDENTIALS_DIR" # Very important for secrets
    chmod 700 "$STATE_DIR"
    chmod 700 "$WHITELIST_DIR"
    
    # Templates and Workflows might need to be readable by others (optional), 
    # but 755 is standard for shared, 700 is safer. Let's stick to 755 for workflows 
    # so they can be viewed if necessary, or 700 if strictly private.
    chmod 755 "$TEMPLATES_DIR"
    chmod 755 "$WORKFLOWS_DIR"
    chmod 755 "$LOGS_DIR"

    log_success "CICD structure created at: $CICD_DIR (Owned by: $TARGET_USER)"
}

apt_install_retry() {
    local pkg="$1"
    local max_attempts=3
    local attempt=1
    local success=false

    while [ $attempt -le $max_attempts ]; do
		if apt install -y $pkg ; then 
			success=true
			break
		else
			log_warning "APT install failed (Attempt $attempt/$max_attempts)."
			if [ $attempt -lt $max_attempts ]; then
				log_info "Updating package cache and retrying in 5s..."
				apt update -y
				sleep 5
			fi
			((attempt++))
		fi
	done

    if [ "$success" = false ]; then
        log_error "Failed to install packages after $max_attempts attempts."
        return 1
    fi
}

perform_preflight_checks() {
    log_section "Pre-flight Checks"

    # 1. OS Check
    if [ ! -f /etc/debian_version ]; then
        log_error "This script currently only supports Debian/Ubuntu systems."
        exit 1
    fi

    # 2. Root Check
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (sudo)."
        exit 1
    fi

    # 3. RAM Check (Warn if < 1GB)
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [ "$total_mem_kb" -lt 1000000 ]; then
        log_warning "System has less than 1GB RAM. Java/Postgres might be unstable."
        local proceed=$(prompt_user "Continue anyway? [y/N]" "N")
        if [[ ! "$proceed" =~ ^[Yy]$ ]]; then exit 1; fi
    fi

    log_success "System checks passed."
}

# ==============================================================================
# PORT CONFLICT DETECTION
# ==============================================================================

check_port_available() {
    local port="$1"
    local service_name="$2"
    
    # Check using ss (Socket Statistics)
    if command -v ss &>/dev/null; then
        # If grep finds the port, it returns 0 (Success), meaning Port IS in use.
        if ss -tuln | grep -q ":$port "; then
			return 1  # Port in use
		fi
		
    # Fallback to netstat
    elif command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            return 1 # Port in use
        fi
    else
        log_warning "Cannot check port availability (ss/netstat not found)"
        return 0 # Assume available to avoid blocking
    fi
    
    return 0 # Port available
}

resolve_port_conflict() {
	local port="$1"
	local service_name="$2"
	local var_name="$3"  # Variable name to update (e.g., "API_PORT")
	
	log_warning "Port $port is already in use!"
	
	if command -v lsof &>/dev/null; then
		echo ""
		echo "Port usage details:"
		lsof -i ":$port" | head -5
		echo ""
	fi
	
	echo "Options:"
	echo "  1) Choose a different port"
	echo "  2) Continue anyway (may cause issues)"
	echo "  3) Cancel operation"
	
	local choice=$(prompt_user "Choose option [1-3]" "1")
	
	case $choice in
		1)
			while true; do
				local new_port=$(prompt_user "Enter alternative port for $service_name" "$((port + 1))")
				
				if ! validate_integer "$new_port"; then
					log_error "Invalid port number"
					continue
				fi
				
				if check_port_available "$new_port" "$service_name"; then
					eval "$var_name=$new_port"
					log_success "Using port $new_port for $service_name"
					return 0
				else
					log_error "Port $new_port is also in use. Try another."
				fi
			done
			;;
		2)
			log_warning "Continuing with port $port (this may cause conflicts)"
			return 0
			;;
		3)
			log_error "Operation cancelled"
			return 1
			;;
	esac
}

validate_backend_port() {
	if ! check_port_available "$API_PORT" "Backend API"; then
		resolve_port_conflict "$API_PORT" "Backend API" "API_PORT" || return 1
	fi
}



# ==============================================================================
# VERSION FETCHING FUNCTIONS
# ==============================================================================

fetch_postgresql_versions() {
    # Primary method: scrape PostgreSQL official source archive
    versions=$(
        curl -s https://www.postgresql.org/ftp/source/ \
        | grep -oE 'v[0-9]+\.[0-9]+' \
        | sed 's/^v//' \
        | cut -d. -f1 \
        | sort -Vru \
        | uniq \
        | head -10
    )

    # If primary fails, try apt-cache
    if [ -z "$versions" ]; then
        echo "Primary source failed. Falling back to apt-cache..." >&2

        versions=$(apt-cache search postgresql \
            | grep -oE 'postgresql-[0-9]+' \
            | grep -oE '[0-9]+' \
            | sort -Vru \
            | uniq \
            | head -10
        )
    fi

    # If both fail → use hardcoded safe defaults
    if [ -z "$versions" ]; then
        echo "Both primary and fallback failed. Using hardcoded versions." >&2
        echo "13 14 15 16 17"
        return
    fi

    # Print versions (space-separated)
    echo "$versions" | tr '\n' ' '
}

fetch_java_versions() {
	local versions
	versions=$(apt-cache search openjdk | grep -oE 'openjdk-[0-9]+-jre-headless' | grep -oE '[0-9]+' | sort -Vu | tr '\n' ' ')
	
	if [ -z "$versions" ]; then
		echo "8 11 17 21"
	else
		echo "$versions"
	fi
}

fetch_node_versions() {
	local versions
	versions=$(curl -s https://nodejs.org/dist/ | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tr -d 'v' | sort -Vr | head -20)
	
	if [ -z "$versions" ]; then
		echo "18.19.0 20.11.0 21.6.0"
	else
		echo "$versions" | tr '\n' ' '
	fi
}

validate_version_exists() {
	local version="$1"
	local available_versions="$2"
	echo "$available_versions" | grep -qw "$version"
}



# ==============================================================================
# MAIN MENU & MODE SELECTION
# ==============================================================================

show_main_menu() {
	clear
	log_section "CI/CD Automation Script V${SCRIPT_VERSION}"
	
	echo "CICD Directory: $CICD_DIR"
	echo ""
	echo "Select Operation Mode:"
	echo ""
	echo "  1) 🚀 Full Setup         - Complete CI/CD pipeline installation"
	echo "  2) 🔧 Update Config      - Update existing configurations"
	echo "  3) 📦 Install Services   - Install individual services"
	echo "  4) 📝 Regenerate Files   - Regenerate config/workflow files"
	echo "  5) 🔄 Restore Backup     - Restore from backup"
	echo "  6) 🗑️ Uninstall Services - Remove installed components"
	echo "  7) 📊 System Diagnostics - View ports, services, and resources"
	echo "  8) 🔐 Secrets Management - Manage stored credentials"
	echo "  9) 💾 Database Backups   - Configure PostgreSQL backups"
	echo " 10) ❌ Exit"
	echo ""
	
	local choice
	choice=$(prompt_user "Enter your choice [1-10]" "1")

	case $choice in
		1) OPERATION_MODE="full" ;;
		2) OPERATION_MODE="update" ;;
		3) OPERATION_MODE="install" ;;
		4) OPERATION_MODE="regenerate" ;;
		5) OPERATION_MODE="restore" ;;
		6) OPERATION_MODE="uninstall" ;;
		7) OPERATION_MODE="diagnostics" ;;
		8) OPERATION_MODE="secrets" ;;
		9) OPERATION_MODE="db_backups" ;;
		10) exit 0 ;;
		*) log_error "Invalid choice"; show_main_menu ;;
	esac
}

# ==============================================================================
# SECRETS MANAGEMENT
# ==============================================================================

show_secrets_menu() {
	log_section "Secrets Management"
	
	echo "Manage stored credentials and secrets"
	echo ""
	echo "  1) List all secrets"
	echo "  2) Show secret value"
	echo "  3) Rotate secret"
	echo "  4) Back to main menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-4]" "4")
	
	case $choice in
		1) list_secrets ;;
		2) show_secret ;;
		3) rotate_secret ;;
		4) return 0 ;;
		*) log_error "Invalid choice"; show_secrets_menu ;;
	esac
}

list_secrets() {
	log_info "Stored Secrets:"
	echo ""
	
	if [ ! -d "$CREDENTIALS_DIR" ] || [ -z "$(ls -A "$CREDENTIALS_DIR" 2>/dev/null)" ]; then
		echo "  No secrets stored yet"
	else
		for secret_file in "$CREDENTIALS_DIR"/*; do
			if [ -f "$secret_file" ]; then
				local name=$(basename "$secret_file")
				local size=$(stat -c%s "$secret_file" 2>/dev/null || stat -f%z "$secret_file" 2>/dev/null)
				echo "  • $name ($size bytes)"
			fi
		done
	fi
	
	echo ""
	read -p "Press Enter to continue..."
	show_secrets_menu
}

show_secret() {
	if [ ! -d "$CREDENTIALS_DIR" ] || [ -z "$(ls -A "$CREDENTIALS_DIR" 2>/dev/null)" ]; then
		log_warning "No secrets stored"
		read -p "Press Enter to continue..."
		show_secrets_menu
		return
	fi
	
	echo "Available secrets:"
	local secrets=()
	local i=1
	
	for secret_file in "$CREDENTIALS_DIR"/*; do
		if [ -f "$secret_file" ]; then
			local name=$(basename "$secret_file")
			echo "  $i) $name"
			secrets+=("$secret_file")
			((i++))
		fi
	done
	
	echo "  b) Back"
	echo ""
	
	local choice=$(prompt_user "Select secret to view [1-${#secrets[@]}]" "b")
	
	if [[ "$choice" =~ ^[Bb]$ ]]; then
		show_secrets_menu
		return
	fi
	
	if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#secrets[@]}" ]; then
		local secret_file="${secrets[$((choice-1))]}"
		local name=$(basename "$secret_file")
		
		echo ""
		echo -e "${CYAN}Secret: $name${NC}"
		echo -e "${MAGENTA}$(cat "$secret_file")${NC}"
		echo ""
	else
		log_error "Invalid selection"
	fi
	
	read -p "Press Enter to continue..."
	show_secrets_menu
}

rotate_secret() {
	log_warning "Secret rotation is service-specific"
	echo ""
	echo "Available options:"
	echo "  1) Rotate Redis password"
	echo "  2) Rotate database password"
	echo "  b) Back"
	echo ""
	
	local choice=$(prompt_user "Choose option" "b")
	
	case $choice in
		1) rotate_redis_password ;;
		2) rotate_database_password ;;
		*) show_secrets_menu; return ;;
	esac
}

rotate_redis_password() {
	if [ ! -f "$CREDENTIALS_DIR/redis_auth" ]; then
		log_warning "Redis authentication not configured"
		read -p "Press Enter to continue..."
		show_secrets_menu
		return
	fi
	
	log_section "Rotate Redis Password"
	
	local new_pass=$(generate_redis_password)
	
	echo ""
	echo -e "${CYAN}New Password: ${MAGENTA}$new_pass${NC}"
	echo ""
	
	local confirm=$(prompt_user "Apply this new password? [y/N]" "N")
	
	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
		log_info "Rotation cancelled"
		read -p "Press Enter to continue..."
		show_secrets_menu
		return
	fi
	
	# Update stored password
	echo "$new_pass" > "$CREDENTIALS_DIR/redis_auth"
	
	# Apply to Redis
	if [ "$REDIS_MODE" == "docker" ]; then
		apply_redis_auth_docker "$new_pass"
	else
		apply_redis_auth_system "$new_pass"
	fi
	
	log_success "Redis password rotated successfully"
	echo ""
	echo -e "${YELLOW}⚠️  Update your application configuration with the new password!${NC}"
	echo ""
	
	read -p "Press Enter to continue..."
	show_secrets_menu
}

rotate_database_password() {
	log_section "Rotate Database Password"
	
	local db_user=$(prompt_user "Database username" "")
	
	if [ -z "$db_user" ]; then
		log_error "Username required"
		read -p "Press Enter to continue..."
		show_secrets_menu
		return
	fi
	
	local new_pass=$(prompt_password "New password for $db_user")
	
	# Update in PostgreSQL
	if sudo -u postgres psql -c "ALTER USER $db_user WITH PASSWORD '$new_pass';" 2>/dev/null; then
		log_success "Database password updated for $db_user"
		
		# Save to credentials
		echo "$new_pass" > "$CREDENTIALS_DIR/db_${db_user}_password"
		chmod 600 "$CREDENTIALS_DIR/db_${db_user}_password"
		
		echo ""
		echo -e "${YELLOW}⚠️  Update your application configuration with the new password!${NC}"
	else
		log_error "Failed to update database password"
	fi
	
	echo ""
	read -p "Press Enter to continue..."
	show_secrets_menu
}

# ==============================================================================
# CONFIGURATION COLLECTION
# ==============================================================================

collect_user_config() {
	log_section "User Configuration"
	
	DEFAULT_USER=$(logname 2>/dev/null || echo $SUDO_USER)
	TARGET_USER=$(prompt_user "VPS Username (runner user)" "$DEFAULT_USER")
	
	if ! validate_user_exists "$TARGET_USER"; then
		log_error "User $TARGET_USER does not exist."
		exit 1
	fi
}

collect_backend_config() {
	log_section "Backend Configuration (Spring Boot)"
	
	API_NAME=$(prompt_user "Backend Folder Name" "spring-api")
	API_PATH="/var/www/$API_NAME"
	
	while true; do
		SERVICE_NAME=$(prompt_user "Service Name" "spring-api-svc")
		if validate_service_name "$SERVICE_NAME"; then break; fi
	done

	
	# Port with validation
	while true; do
		API_PORT=$(prompt_user "Backend Port" "8080")
		
		if ! validate_integer "$API_PORT"; then
			log_error "Invalid port number"
			continue
		fi
		
		if ! check_port_available "$API_PORT" "Backend API"; then
			if ! resolve_port_conflict "$API_PORT" "Backend API" "API_PORT"; then
				continue
			fi
		fi
		break
	done
	
	SPRING_PROFILE=$(prompt_user "Spring Profile (e.g. staging)" "staging")
	DEPLOY_BRANCH=$(prompt_user "Git Branch to trigger deploy" "staging")
	API_PREFIX=$(prompt_user "API Prefix (e.g. /api)" "/api")
	
	echo ""
	echo "Backend Config Strategy:"
	echo "  [y] External: Create secure config file on server"
	echo "  [n] Internal: Use config inside JAR"
	USE_EXTERNAL_CONFIG=$(prompt_user "Use external config?" "N")
	
	echo ""
	echo "Backend Testing Strategy:"
	echo "  [y] Run Tests: mvn package"
	echo "  [n] Skip Tests: mvn package -DskipTests"
	RUN_TESTS=$(prompt_user "Run tests during build?" "N")
	
	while true; do
		HEALTH_CHECK_DELAY=$(prompt_user "Max wait time for Health Check (seconds)" "30")
		if validate_integer "$HEALTH_CHECK_DELAY"; then
			break
		else
			log_error "Please enter a valid number."
		fi
	done
	
	echo ""
	echo "JVM Memory Profile:"
	echo "  1) Small  (256m-512m)"
	echo "  2) Medium (512m-1024m)"
	echo "  3) Large  (1024m-2048m)"
	local mem_choice=$(prompt_user "Choose profile" "2")
	
	case $mem_choice in
		1) JAVA_XMS="256m"; JAVA_XMX="512m" ;;
		3) JAVA_XMS="1024m"; JAVA_XMX="2048m" ;;
		*) JAVA_XMS="512m"; JAVA_XMX="1024m" ;;
	esac
}

collect_frontend_config() {
	log_section "Frontend Configuration (React/Vite)"
	
	UI_NAME=$(prompt_user "Frontend Folder Name" "react-ui")
	UI_PATH="/var/www/$UI_NAME"
	
	BUILD_DIR=$(prompt_user "Build output directory" "dist")
	
	echo ""
	echo "Frontend Environment Strategy:"
	echo "  1) Repo Files: Use .env files from Git"
	echo "  2) GitHub Secrets: Inject secrets via GitHub Action"
	FRONTEND_ENV_STRATEGY=$(prompt_user "Choose strategy [1/2]" "1")
	
	VITE_VAR_NAME=""
	if [ "$FRONTEND_ENV_STRATEGY" == "2" ]; then
		VITE_VAR_NAME=$(prompt_user "Variable name to inject (e.g. VITE_API_URL)" "")
	fi
}

collect_database_config() {
	log_section "Database Configuration"
	
	INSTALL_PG=$(prompt_user "Install PostgreSQL? [y/N]" "N")
	
	if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
		echo ""
		log_info "Fetching available PostgreSQL versions..."
		local available_versions=$(fetch_postgresql_versions)
		echo "Available versions: $available_versions"
		
		while true; do
			PG_VER=$(prompt_user "Choose Postgres Version" "16")
			if validate_version_exists "$PG_VER" "$available_versions"; then
				break
			else
				log_error "Version $PG_VER not found. Please choose from available versions."
			fi
		done
		
		DB_NAME=$(prompt_user "Database name to create" "stock_db")
		while ! validate_db_identifier "$DB_NAME" "database name"; do
			DB_NAME=$(prompt_user "Database name to create" "stock_db")
		done
		DB_USER=$(prompt_user "Database user to create" "stock_user")
		while ! validate_db_identifier "$DB_USER" "username"; do
			DB_USER=$(prompt_user "Database user to create" "stock_user")
		done
		DB_PASS=$(prompt_password "Database password")
	fi
}

collect_java_config() {
	log_section "Java Configuration"
	
	INSTALL_JAVA=$(prompt_user "Install Java? [Y/n]" "Y")
	
	if [[ ! "$INSTALL_JAVA" =~ ^[Nn]$ ]]; then
		echo ""
		log_info "Available Java versions..."
		local available_versions=$(fetch_java_versions)
		echo "Available versions: $available_versions"
		
		while true; do
			JAVA_VER=$(prompt_user "Choose Java version" "17")
			if validate_version_exists "$JAVA_VER" "$available_versions"; then
				break
			else
				log_error "Version $JAVA_VER not available. Choose from: $available_versions"
			fi
		done
	fi
}

collect_node_config() {
	INSTALL_NODE=$(prompt_user "Install Node.js/NVM for manual testing? [y/N]" "N")
	
	if [[ "$INSTALL_NODE" =~ ^[Yy]$ ]]; then
		echo ""
		log_info "Fetching available Node.js versions..."
		local available_versions=$(fetch_node_versions)
		echo "Available versions: $available_versions"
		echo "Or enter 'lts' for latest LTS"
		
		NODE_VER=$(prompt_user "Choose Node version" "lts")
		
		if [ "$NODE_VER" != "lts" ]; then
			if ! validate_version_exists "$NODE_VER" "$available_versions"; then
				log_warning "Version $NODE_VER not found. Using LTS instead."
				NODE_VER="lts"
			fi
		fi
	fi
}

collect_services_config() {
	log_section "Additional Services & Redis Options"
	
	INSTALL_REDIS=$(prompt_user "Install Redis? [y/N]" "N")
	REDIS_MODE="none"

	if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
		while true; do
			echo ""
			echo "How should Redis be installed?"
			echo "  1) System (APT Package) - Recommended for stability"
			echo "  2) Docker Container - Recommended for isolation"
			local redis_choice=$(prompt_user "Choose option [1/2]" "1")
			
			if [ "$redis_choice" == "1" ]; then
				REDIS_MODE="system"
				configure_redis_auth
				break
			elif [ "$redis_choice" == "2" ]; then
				if check_docker_status; then
					REDIS_MODE="docker"
					configure_redis_auth
					break
				else
					log_warning "Docker is NOT installed."
					local auto_install=$(prompt_user "Do you want to install Docker automatically? [Y/n]" "Y")
					
					if [[ ! "$auto_install" =~ ^[Nn]$ ]]; then
						INSTALL_DOCKER="Y"
						REDIS_MODE="docker"
						configure_redis_auth
						break
					else
						log_error "Cannot use Docker mode without Docker. Please choose System mode or install Docker first."
					fi
				fi
			else
				log_error "Invalid choice."
			fi
		done
	fi

	INSTALL_RABBITMQ=$(prompt_user "Install RabbitMQ? [y/N]" "N")
}

# ==============================================================================
# UPDATE MODE FUNCTIONS
# ==============================================================================

show_update_menu() {
	log_section "Update Configuration Menu"
	
	echo "What would you like to update?"
	echo ""
	echo "  1) Backend Service Configuration"
	echo "  2) Frontend Configuration"
	echo "  3) Nginx Configuration"
	echo "  4) Database Configuration"
	echo "  5) Systemd Service File"
	echo "  6) GitHub Workflows"
	echo "  7) All Configurations"
	echo "  8) Back to Main Menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-8]" "1")
	
	case $choice in
		1) update_backend_config ;;
		2) update_frontend_config ;;
		3) update_nginx_config ;;
		4) update_database_config ;;
		5) update_systemd_service ;;
		6) regenerate_workflows ;;
		7) update_all_configs ;;
		8) show_main_menu ;;
		*) log_error "Invalid choice"; show_update_menu ;;
	esac
}

update_backend_config() {
	log_section "Updating Backend Configuration"
	
	collect_user_config
	collect_backend_config
	
	if [ "$DRY_RUN" = false ]; then
		generate_backend_config
		log_success "Backend configuration updated"
	fi
	
	show_update_menu
}

update_frontend_config() {
	log_section "Updating Frontend Configuration"
	
	collect_user_config
	collect_frontend_config
	
	log_success "Frontend configuration updated"
	show_update_menu
}

update_nginx_config() {
	log_section "Updating Nginx Configuration"
	
	collect_user_config
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUPS_DIR/$TIMESTAMP"
		generate_nginx_config
		nginx -t && systemctl reload nginx
		log_success "Nginx configuration updated"
	fi
	
	show_update_menu
}

update_database_config() {
	log_section "Updating Database Configuration"
	
	echo "Database update options:"
	echo "  1) Update PostgreSQL configuration"
	echo "  2) Create new database"
	echo "  3) Create new user"
	echo "  4) Update user password"
	
	local choice=$(prompt_user "Choose option" "1")
	
	case $choice in
		1) reconfigure_postgresql ;;
		2) create_new_database ;;
		3) create_new_db_user ;;
		4) update_db_password ;;
	esac
	
	show_update_menu
}

update_systemd_service() {
	log_section "Updating Systemd Service"
	
	collect_user_config
	collect_backend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUPS_DIR/$TIMESTAMP"
		generate_systemd_service
		systemctl daemon-reload
		log_success "Systemd service updated"
	fi
	
	show_update_menu
}

update_all_configs() {
	log_info "Updating all configurations..."
	
	collect_user_config
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUPS_DIR/$TIMESTAMP"
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUPS_DIR/$TIMESTAMP"
		
		generate_backend_config
		generate_nginx_config
		generate_systemd_service
		regenerate_workflows
		
		systemctl daemon-reload
		nginx -t && systemctl reload nginx
		
		log_success "All configurations updated"
	fi
	
	show_update_menu
}

# ==============================================================================
# INSTALL MODE FUNCTIONS
# ==============================================================================

show_install_menu() {
	log_section "Install Services Menu"
	
	echo "What would you like to install?"
	echo ""
	echo "  1) Java (OpenJDK)"
	echo "  2) PostgreSQL"
	echo "  3) Redis"
	echo "  4) RabbitMQ"
	echo "  5) Node.js/NVM"
	echo "  6) Nginx"
	echo "  7) Docker (Engine & Compose)"
	echo "  8) All Services (Excluding Docker)"
	echo "  9) Back to Main Menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-9]" "9")
	
	case $choice in
			1) install_java_interactive ;;
			2) install_postgresql_interactive ;;
			3) install_redis_interactive ;;
			4) install_rabbitmq_interactive ;;
			5) install_node_interactive ;;
			6) install_nginx_interactive ;;
			7) install_docker_interactive ;;
			8) install_all_services ;;
			9) show_main_menu ;;
			*) log_error "Invalid choice"; show_install_menu ;;
	esac
}

install_java_logic() {
    local version="$1"
    if [ -z "$version" ]; then version="17"; fi
    
    log_info "Installing Java $version..."
    apt_install_retry "openjdk-${version}-jre-headless"
    log_success "Java $version installed"
}

install_rabbitmq_logic() {
    log_info "Installing RabbitMQ..."
    apt_install_retry "rabbitmq-server"
    
    log_info "Enabling Management Plugin..."
    rabbitmq-plugins enable rabbitmq_management
    
    systemctl enable rabbitmq-server
    systemctl start rabbitmq-server
    
    log_success "RabbitMQ installed (UI: http://localhost:15672 - guest/guest)"
}

install_redis_logic() {
    local mode="$1" # system or docker
    
    if [ "$mode" == "docker" ]; then
        log_info "Installing Redis (Docker)..."
        
        # Check for password file
        local redis_pass="none"
        if [ -f "$CREDENTIALS_DIR/redis_auth" ]; then
            redis_pass=$(cat "$CREDENTIALS_DIR/redis_auth")
        elif [ -f "$CREDENTIALS_DIR/redis_docker_password" ]; then
             redis_pass=$(cat "$CREDENTIALS_DIR/redis_docker_password")
        fi

        if [ "$redis_pass" != "none" ] && [ -n "$redis_pass" ]; then
            apply_redis_auth_docker "$redis_pass"
        else
            # Fallback for no-auth (though your config usually forces auth)
            docker run -d --name redis-server --restart always -p 6379:6379 -v redis_data:/data redis:alpine
            log_success "Redis Container Started (No Auth)"
        fi
        
    elif [ "$mode" == "system" ]; then
        log_info "Installing Redis (System)..."
        apt_install_retry "redis-server"
        
        # Check for password file
        local redis_pass="none"
        if [ -f "$CREDENTIALS_DIR/redis_auth" ]; then
            redis_pass=$(cat "$CREDENTIALS_DIR/redis_auth")
        fi

        if [ "$redis_pass" != "none" ] && [ -n "$redis_pass" ]; then
            apply_redis_auth_system "$redis_pass"
        else
            log_info "Redis running without authentication (as configured)"
        fi
        log_success "Redis installed (Port: 6379)"
    fi
}


install_java_interactive() {
	log_section "Installing Java"
	
	log_info "Fetching available Java versions..."
	local available_versions=$(fetch_java_versions)
	
	# Convert space-separated string to array
	read -ra ver_array <<< "$available_versions"
	
	while true; do
			echo -e "${CYAN}Available OpenJDK Versions:${NC}"
			local i=1
			for ver in "${ver_array[@]}"; do
					echo "  $i) OpenJDK $ver (LTS)"
					((i++))
			done
			echo "  c) Custom Version"
			echo "  b) Back"
			echo ""
			
			local selection=$(prompt_user "Select Version" "1")
			
			# Handle Back
			if [[ "$selection" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
			
			# Handle Selection
			local java_ver=""
			if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ver_array[@]}" ]; then
					java_ver="${ver_array[$((selection-1))]}"
			elif [[ "$selection" =~ ^[Cc]$ ]]; then
					java_ver=$(prompt_user "Enter version number (e.g. 19)" "")
			else
					log_error "Invalid selection."
					continue
			fi
			
			# Validate existence
			local pkg_name="openjdk-${java_ver}-jre-headless"
			if apt-cache show "$pkg_name" >/dev/null 2>&1; then
					if [ "$DRY_RUN" = false ]; then
							# log_info "Installing $pkg_name..."
							# apt update -y
							# apt install -y "$pkg_name"
							# log_success "Java $java_ver installed"

							install_java_logic "$java_ver"
					fi
					break
			else
					log_error "Package '$pkg_name' not found in repositories. Try 'apt update' or choose another version."
			fi
	done
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_postgresql_interactive() {
	log_section "Installing PostgreSQL"
	
	log_info "Fetching available PostgreSQL versions..."
	local available_versions=$(fetch_postgresql_versions)
	read -ra ver_array <<< "$available_versions"
	
	while true; do
			echo -e "${CYAN}Available PostgreSQL Versions:${NC}"
			local i=1
			for ver in "${ver_array[@]}"; do
					echo "  $i) PostgreSQL $ver"
					((i++))
			done
			echo "  b) Back"
			echo ""
			
			local selection=$(prompt_user "Select Version" "1")
			if [[ "$selection" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
			
			local pg_ver=""
			if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ver_array[@]}" ]; then
					pg_ver="${ver_array[$((selection-1))]}"
					
					# DB Config
					local db_name=$(prompt_user "Database name to create" "stock_db")
					while ! validate_db_identifier "$DB_NAME" "database name"; do
						DB_NAME=$(prompt_user "Database name to create" "stock_db")
					done
					local db_user=$(prompt_user "Database user to create" "stock_user")
					while ! validate_db_identifier "$DB_USER" "username"; do
						DB_USER=$(prompt_user "Database user to create" "stock_user")
					done
					local db_pass=$(prompt_password "Database password")
					
					if [ "$DRY_RUN" = false ]; then
							install_postgresql "$pg_ver" "$db_name" "$db_user" "$db_pass"
							log_success "PostgreSQL $pg_ver installed"
					fi
					break
			else
					log_error "Invalid selection."
			fi
	done
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_redis_interactive() {
	log_section "Installing Redis"
	
	echo "How would you like to install Redis?"
	echo "  1) System (APT)"
	echo "  2) Docker"
	echo "  b) Back"
	
	local method=$(prompt_user "Choice" "1")
	if [[ "$method" =~ ^[Bb]$ ]]; then show_install_menu; return; fi

	if [ "$method" == "2" ]; then
			if ! check_docker_status; then
					log_warning "Docker is required."
					local i=$(prompt_user "Install Docker now? [y/N]" "N")
					if [[ "$i" =~ ^[Yy]$ ]]; then
							install_docker_engine_logic
					else
							log_error "Cannot continue without Docker."
							return
					fi
			fi
			
			if [ "$DRY_RUN" = false ]; then
						log_info "Starting Redis Container..."
						docker run -d --name redis-server --restart always -p 6379:6379 -v redis_data:/data redis:alpine
						log_success "Redis (Docker) installed"
			fi
			return
	fi
	
	# 1. Install Redis Server (System)
	log_info "Checking available Redis version..."
	local candidate_ver=$(apt-cache policy redis-server | grep Candidate | awk '{print $2}')
	
	if [ -z "$candidate_ver" ]; then
			[ "$DRY_RUN" = false ] && apt update -y
			candidate_ver=$(apt-cache policy redis-server | grep Candidate | awk '{print $2}')
	fi

	echo ""
	echo "  Package: redis-server"
	echo "  Version: ${candidate_ver:-Unknown}"
	echo ""
	
	local confirm=$(prompt_user "Install Redis Server? [Y/n]" "Y")
	
	if [[ ! "$confirm" =~ ^[Nn]$ ]] && [ "$DRY_RUN" = false ]; then
			apt update -y
			apt install -y redis-server
			systemctl enable redis-server
			systemctl start redis-server
			log_success "Redis installed (Port: 6379)"
	fi
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_rabbitmq_interactive() {
	log_section "Installing RabbitMQ"
	
	log_info "Checking available RabbitMQ version..."
	local candidate_ver=$(apt-cache policy rabbitmq-server | grep Candidate | awk '{print $2}')
	
	echo ""
	echo "  Package: rabbitmq-server"
	echo "  Version: ${candidate_ver:-Unknown}"
	echo ""
	
	echo "Options:"
	echo "  y) Install"
	echo "  n) Cancel"
	echo "  b) Back"
	local confirm=$(prompt_user "Proceed?" "y")
	
	if [[ "$confirm" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
	
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
			if [ "$DRY_RUN" = false ]; then
					# apt update -y
					# apt install -y rabbitmq-server
					
					# log_info "Enabling Management Plugin..."
					# rabbitmq-plugins enable rabbitmq_management
					
					# systemctl enable rabbitmq-server
					# systemctl start rabbitmq-server

					install_rabbitmq_logic
					
					# log_success "RabbitMQ installed (UI: http://localhost:15672 - guest/guest)"
			fi
	else
			log_warning "Installation cancelled."
	fi
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_node_interactive() {
	log_section "Installing Node.js/NVM"
	
	collect_user_config
	
	log_info "Fetching available Node versions..."
	local available_versions=$(fetch_node_versions)
	read -ra ver_array <<< "$available_versions"
	
	while true; do
			echo -e "${CYAN}Available Node Versions:${NC}"
			local i=1
			for ver in "${ver_array[@]}"; do
					echo "  $i) Node $ver"
					((i++))
			done
			echo "  l) Latest LTS (Recommended)"
			echo "  b) Back"
			echo ""
			
			local selection=$(prompt_user "Select Version" "l")
			if [[ "$selection" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
			
			local node_ver=""
			if [[ "$selection" =~ ^[Ll]$ ]]; then
					node_ver="lts"
			elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ver_array[@]}" ]; then
					node_ver="${ver_array[$((selection-1))]}"
			else
					log_error "Invalid selection."
					continue
			fi
			
			if [ "$DRY_RUN" = false ]; then
					install_nvm_for_user "$TARGET_USER" "$node_ver"
					log_success "Node.js installed for $TARGET_USER"
			fi
			break
	done
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_nginx_interactive() {
	log_section "Installing Nginx"
	
	echo "Options:"
	echo "  y) Install Nginx"
	echo "  b) Back"
	local confirm=$(prompt_user "Proceed?" "y")
	
	if [[ "$confirm" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
	
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
			if [ "$DRY_RUN" = false ]; then
					apt update -y
					apt install -y nginx
					log_success "Nginx installed"
			fi
	fi
	
	read -p "Press Enter to continue..."
	show_install_menu
}

install_docker_interactive() {
	log_section "Installing Docker"
	
	if check_docker_status; then
			log_warning "Docker is already installed."
			docker --version
	else
			echo "This will install Docker Engine (Community) from the official repository."
			echo "Options:"
			echo "  y) Proceed"
			echo "  b) Back"
			local confirm=$(prompt_user "Proceed?" "Y")
			
			if [[ "$confirm" =~ ^[Bb]$ ]]; then show_install_menu; return; fi
			
			if [[ "$confirm" =~ ^[Yy]$ ]]; then
					if [ "$DRY_RUN" = false ]; then
							install_docker_engine_logic
							log_success "Docker installed."
					fi
			fi
	fi
	read -p "Press Enter to continue..."
	show_install_menu
}

install_all_services() {
    log_info "Installing all services..."
    
    # FIX: Collect ALL necessary configs
    collect_user_config
    collect_java_config      # ← Added
    collect_backend_config   # ← Added (needed for directory creation)
    collect_database_config
    collect_services_config
    
    if [ "$DRY_RUN" = false ]; then
        apt update -y
        local base_pkgs="nginx ufw acl curl gnupg2 lsb-release ca-certificates git"
        
        # Install Java with selected version
        if [[ ! "$INSTALL_JAVA" =~ ^[Nn]$ ]]; then
            # Ensure JAVA_VER defaults to something if empty (safety net)
            local j_ver="${JAVA_VER:-17}" 
            base_pkgs="$base_pkgs openjdk-${j_ver}-jre-headless"
        fi
        
        apt_install_retry "$base_pkgs"
        
        # Create directories (needs backend config)
        mkdir -p "$API_PATH" "$UI_PATH"
        chown -R "$TARGET_USER":"$TARGET_USER" "$API_PATH" "$UI_PATH"
        
        [[ "$INSTALL_PG" =~ ^[Yy]$ ]] && install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
        [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && apt install -y redis-server
        [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && apt install -y rabbitmq-server && rabbitmq-plugins enable rabbitmq_management
        
        log_success "All services installed"
    fi
    
    read -p "Press Enter to continue..."
    show_install_menu
}


# ==============================================================================
# REDIS AUTHENTICATION CONFIGURATION
# ==============================================================================

generate_redis_password() {
	# Generate simple 8-character alphanumeric password
	tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8
}

configure_redis_auth() {
	local redis_pass=""
	
	if [ "$HEADLESS_MODE" = true ]; then
		log_info "Headless mode: Redis authentication disabled by default"
		echo "none" > "$CREDENTIALS_DIR/redis_auth"
		chmod 600 "$CREDENTIALS_DIR/redis_auth"
		return 0
	fi
	
	echo ""
	log_info "Redis Authentication Configuration"
	echo ""
	echo "Redis can run with or without password authentication."
	echo "For production, authentication is recommended."
	echo ""
	
	local enable_auth=$(prompt_user "Enable Redis authentication? [Y/n]" "Y")
	
	if [[ "$enable_auth" =~ ^[Nn]$ ]]; then
		log_warning "Redis will run WITHOUT authentication"
		echo "none" > "$CREDENTIALS_DIR/redis_auth"
		chmod 600 "$CREDENTIALS_DIR/redis_auth"
		return 0
	fi
	
	# Generate initial password
	redis_pass=$(generate_redis_password)
	
	while true; do
		echo ""
		echo -e "${CYAN}Generated Password: ${MAGENTA}$redis_pass${NC}"
		echo ""
		echo "Options:"
		echo "  1) Accept this password"
		echo "  2) Regenerate password"
		echo "  3) Enter custom password"
		echo "  4) Cancel (disable auth)"
		
		local choice=$(prompt_user "Choose option [1-4]" "1")
		
		case $choice in
			1)
				break
				;;
			2)
				redis_pass=$(generate_redis_password)
				;;
			3)
				redis_pass=$(prompt_password "Enter custom Redis password")
				break
				;;
			4)
				log_warning "Redis authentication cancelled"
				echo "none" > "$CREDENTIALS_DIR/redis_auth"
				chmod 600 "$CREDENTIALS_DIR/redis_auth"
				return 0
				;;
		esac
	done
	
	# Save password
	echo "$redis_pass" > "$CREDENTIALS_DIR/redis_auth"
	chmod 600 "$CREDENTIALS_DIR/redis_auth"
	
	log_success "Redis password configured and saved to: $CREDENTIALS_DIR/redis_auth"
	echo ""
	echo -e "${YELLOW}⚠️  IMPORTANT: Save this password securely!${NC}"
	echo -e "   Password: ${MAGENTA}$redis_pass${NC}"
	echo ""
	
	read -p "Press Enter after saving the password..."
	
	export REDIS_PASSWORD="$redis_pass"
}

apply_redis_auth_system() {
    local redis_pass="$1"
    local redis_conf="/etc/redis/redis.conf"
    
    if [ ! -f "$redis_conf" ]; then
        log_warning "Redis config not found at $redis_conf"
        return 1
    fi
    
    # 1. Backup original config (Idempotency check: don't backup if we just did it)
    # We check if a backup from "today" exists to avoid filling disk on repeated runs
    local today=$(date +%Y%m%d)
    if ! ls "$redis_conf.bak.$today"* 1> /dev/null 2>&1; then
        cp "$redis_conf" "$redis_conf.bak.$(date +%s)"
        log_info "Original config backed up."
    fi
    
    # 2. Set password (FIX: Use '|' delimiter to handle '/' in passwords)
    if grep -q "^requirepass" "$redis_conf"; then
        sed -i "s|^requirepass.*|requirepass $redis_pass|" "$redis_conf"
    else
        # Appending is safe, but let's add a newline first to ensure we aren't on a comment line
        echo "" >> "$redis_conf"
        echo "# Security: Password added by CI/CD Script" >> "$redis_conf"
        echo "requirepass $redis_pass" >> "$redis_conf"
    fi
    
    # 3. Configure bind address (localhost only)
    if grep -q "^bind" "$redis_conf"; then
        sed -i "s|^bind.*|bind 127.0.0.1 ::1|" "$redis_conf"
    else
        echo "bind 127.0.0.1 ::1" >> "$redis_conf"
    fi
    
    # 4. Enable protected mode
    if grep -q "^protected-mode" "$redis_conf"; then
        sed -i "s|^protected-mode.*|protected-mode yes|" "$redis_conf"
    else
        echo "protected-mode yes" >> "$redis_conf"
    fi
    
    # 5. Disable dangerous commands
    # Note: We removed SHUTDOWN to ensure admins can still manage the service easily.
    # We use FLUSHDB/ALL/CONFIG/DEBUG to prevent app-level destruction.
    local dangerous_commands=("FLUSHDB" "FLUSHALL" "CONFIG" "DEBUG")
    
    for cmd in "${dangerous_commands[@]}"; do
        # Only append if not already renamed/disabled
        if ! grep -q "rename-command $cmd" "$redis_conf"; then
            echo "rename-command $cmd \"\"" >> "$redis_conf"
        fi
    done
    
    # 6. Save password to credentials directory
    echo "$redis_pass" > "$CREDENTIALS_DIR/redis_system_password"
    chmod 600 "$CREDENTIALS_DIR/redis_system_password"
    chown "$TARGET_USER":"$TARGET_USER" "$CREDENTIALS_DIR/redis_system_password"
    
    # 7. Restart Redis
    log_info "Restarting Redis service..."
    # Reload daemon in case unit file changed (rare but safe)
    systemctl daemon-reload 
    systemctl restart redis-server
    
    # 8. Verify service started
    sleep 2
    if ! systemctl is-active --quiet redis-server; then
        log_error "Redis service failed to start!"
        echo "Last 20 lines of log:"
        journalctl -u redis-server -n 20 --no-pager
        return 1
    fi
    
    # 9. Verify authentication works
    log_info "Testing Redis connection..."
    if redis-cli -a "$redis_pass" PING 2>/dev/null | grep -q PONG; then
        log_success "Redis (System) authentication enabled and verified"
        echo ""
        echo "Configuration:"
        echo "  - Bind: 127.0.0.1 (Localhost)"
        echo "  - Config File: $redis_conf"
        echo "  - Credential File: $CREDENTIALS_DIR/redis_system_password"
    else
        log_error "Redis started but password rejected!"
        log_warning "This usually happens if special characters broke the config file syntax."
        return 1
    fi
}

apply_redis_auth_docker() {
    local redis_pass="$1"
    
    # 1. Prepare the config file location
    local redis_conf_dir="$STATE_DIR/redis"
    local redis_conf_file="$redis_conf_dir/redis.conf"
    
    mkdir -p "$redis_conf_dir"
    
    # 2. Determine Host Bind Address (Controls external access via Docker)
    local docker_publish_flag="-p 6379:6379" # Default: Open to 0.0.0.0
    
    if [ "$HEADLESS_MODE" != true ]; then
        echo ""
        log_warning "Redis Network Configuration"
        echo "  1) Localhost only (127.0.0.1) - Recommended, most secure"
        echo "  2) All Interfaces (0.0.0.0)   - Riskier, requires firewall"
        echo ""
        local net_choice=$(prompt_user "Choose binding [1/2]" "1")
        
        if [ "$net_choice" == "1" ]; then
            # This restricts access to the VPS localhost only
            docker_publish_flag="-p 127.0.0.1:6379:6379"
        fi
    else
        # Headless default: Localhost only for safety
        docker_publish_flag="-p 127.0.0.1:6379:6379"
    fi
    
    # 3. Write the config file with hardening
    # NOTE: We bind 0.0.0.0 INSIDE the container so Docker can bridge to it.
    # Security is handled by the docker_publish_flag above.
    cat > "$redis_conf_file" <<EOF
# Network Configuration (Internal)
bind 0.0.0.0
port 6379
protected-mode yes

# Authentication
requirepass $redis_pass

# Security - Disable dangerous commands
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
# Generate a random suffix for SHUTDOWN so it can't be guessed
rename-command SHUTDOWN SHUTDOWN_$(openssl rand -hex 8 2>/dev/null || echo "SECURE")

# Persistence (RDB)
save 900 1
save 300 10
save 60 10000

# Logging
loglevel notice
EOF
    
    # 4. Lock down permissions (Host side)
    chmod 600 "$redis_conf_file"
    
    # 5. Save password to credentials directory
    echo "$redis_pass" > "$CREDENTIALS_DIR/redis_docker_password"
    chmod 600 "$CREDENTIALS_DIR/redis_docker_password"
    chown "$TARGET_USER":"$TARGET_USER" "$CREDENTIALS_DIR/redis_docker_password"
    
    # 6. Stop existing container
    if docker ps -a --format '{{.Names}}' | grep -q "^redis-server$"; then
        log_info "Stopping existing Redis container..."
        docker stop redis-server >/dev/null 2>&1 || true
        docker rm redis-server >/dev/null 2>&1 || true
    fi
    
    # 7. Run with mounted config
    log_info "Starting Redis container with secure configuration..."
    
    # Using :ro (Read Only) for the config mount adds extra security
    docker run -d \
        --name redis-server \
        --restart always \
        $docker_publish_flag \
        -v redis_data:/data \
        -v "$redis_conf_file":/usr/local/etc/redis/redis.conf:ro \
        redis:alpine \
        redis-server /usr/local/etc/redis/redis.conf
    
    # 8. Verify container started
    sleep 3
    if ! docker ps --format '{{.Names}}' | grep -q "^redis-server$"; then
        log_error "Redis container failed to start!"
        echo ""
        echo "Container logs:"
        docker logs redis-server 2>&1 | tail -20
        return 1
    fi
    
    # 9. Verify authentication works
    log_info "Testing Redis connection..."
    if docker exec redis-server redis-cli -a "$redis_pass" PING 2>/dev/null | grep -q PONG; then
        log_success "Redis container started with secure configuration"
        log_success "Authentication verified (Password protected)"
        echo ""
        echo "Configuration:"
        echo "  - Access: $docker_publish_flag"
        echo "  - Config: $redis_conf_file"
        echo "  - Password stored in: $CREDENTIALS_DIR/redis_docker_password"
        
        # Save the docker command for reference/debugging
        echo "docker run -d --name redis-server --restart always $docker_publish_flag -v redis_data:/data -v \"$redis_conf_file\":/usr/local/etc/redis/redis.conf:ro redis:alpine redis-server /usr/local/etc/redis/redis.conf" > "$STATE_DIR/redis/run_command.sh"
        chmod 600 "$STATE_DIR/redis/run_command.sh"
    else
        log_error "Redis started but authentication test failed!"
        echo "Check container logs: docker logs redis-server"
        return 1
    fi
}
# ==============================================================================
# SUDOERS WHITELIST CONFIGURATION
# ==============================================================================

configure_sudoers_whitelist() {
	if [ "$HEADLESS_MODE" = true ] && [ "$ALLOW_SUDOERS" != true ]; then
		log_warning "Headless mode: Skipping sudoers configuration (use --allow-sudoers to enable)"
		return 0
	fi
	
	log_section "Sudoers Whitelist Configuration"
	
	echo "GitHub Actions runners need sudo permissions to restart services."
	echo "You can whitelist specific services for passwordless restart."
	echo ""
	echo "Suggested services:"
	echo "  • $SERVICE_NAME (Backend)"
	echo "  • nginx"
	echo "  • redis-server"
	echo "  • postgresql"
	echo "  • rabbitmq-server"
	echo ""
	
	local configure=$(prompt_user "Configure sudoers whitelist? [Y/n]" "Y")
	
	if [[ "$configure" =~ ^[Nn]$ ]]; then
		log_info "Skipping sudoers configuration"
		return 0
	fi
	
	# Collect services to whitelist
	local services=()
	
	# Backend service
	if [ -n "$SERVICE_NAME" ]; then
		local add=$(prompt_user "Allow restart of $SERVICE_NAME? [Y/n]" "Y")
		[[ ! "$add" =~ ^[Nn]$ ]] && services+=("$SERVICE_NAME")
	fi
	
	# Nginx
	local add=$(prompt_user "Allow restart of nginx? [Y/n]" "Y")
	[[ ! "$add" =~ ^[Nn]$ ]] && services+=("nginx")
	
	# Redis
	if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && [ "$REDIS_MODE" == "system" ]; then
		local add=$(prompt_user "Allow restart of redis-server? [y/N]" "N")
		[[ "$add" =~ ^[Yy]$ ]] && services+=("redis-server")
	fi
	
	# PostgreSQL
	if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
		local add=$(prompt_user "Allow restart of postgresql? [y/N]" "N")
		[[ "$add" =~ ^[Yy]$ ]] && services+=("postgresql")
	fi
	
	# RabbitMQ
	if [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]]; then
		local add=$(prompt_user "Allow restart of rabbitmq-server? [y/N]" "N")
		[[ "$add" =~ ^[Yy]$ ]] && services+=("rabbitmq-server")
	fi
	
	if [ ${#services[@]} -eq 0 ]; then
		log_warning "No services selected. Sudoers will not be configured."
		return 0
	fi
	
	# Create whitelist
	create_sudoers_whitelist "${services[@]}"
}

create_sudoers_whitelist() {
    local services=("$@")

    if [ ${#services[@]} -eq 0 ]; then
        return 0
    fi

    log_info "Creating sudoers whitelist for ${#services[@]} service(s)..."
    # Validate service names (prevent injection)
    for svc in "${services[@]}"; do
        if [[ ! "$svc" =~ ^[a-zA-Z0-9._@-]+$ ]]; then
            log_error "Invalid service name: $svc"
            return 1
        fi
    done

    # Create wrapper script
    local wrapper_script="$WHITELIST_DIR/service-restart-wrapper.sh"

    cat > "$wrapper_script" <<'EOF'
#!/bin/bash
set -e
ALLOWED_SERVICES=(
EOF
    # Insert the whitelist entries
    for svc in "${services[@]}"; do
        echo "    \"$svc\"" >> "$wrapper_script"
    done
    cat >> "$wrapper_script" <<'EOF'
)
SERVICE="$1"
is_allowed() {
    local svc="$1"
    for allowed in "${ALLOWED_SERVICES[@]}"; do
        if [[ "$svc" == "$allowed" ]]; then
            return 0
        fi
    done
    return 1
}
if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service-name>"
    echo "Allowed: ${ALLOWED_SERVICES[*]}"
    exit 1
fi
if ! is_allowed "$SERVICE"; then
    echo "Service '$SERVICE' is NOT allowed"
    echo "Allowed: ${ALLOWED_SERVICES[*]}"
    exit 2
fi
echo "Restarting $SERVICE..."
systemctl restart "$SERVICE"
if systemctl is-active --quiet "$SERVICE"; then
    echo "✅ $SERVICE restarted successfully"
else
    echo "❌ $SERVICE failed to start"
    systemctl status "$SERVICE" --no-pager
    exit 3
fi
EOF

    # Permissions: private script
    chmod 700 "$wrapper_script"
    chown root:root "$wrapper_script"

    # Create sudoers file
    local sudoers_file="/etc/sudoers.d/cicd_service_restart"

    cat > "$sudoers_file" <<EOF
# CICD Service Restart Permissions
# Generated on $(date)
# User: $TARGET_USER
#
# Only allow restarting whitelisted services through the wrapper.
EOF

    # EXACT MATCH rule — hardened
    for svc in "${services[@]}"; do
        echo "$TARGET_USER ALL=(root) NOPASSWD: $wrapper_script $svc" >> "$sudoers_file"
    done

    chmod 0440 "$sudoers_file"

    # Validate sudoers syntax
    if ! visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
        log_error "Sudoers syntax validation failed!"
        rm -f "$sudoers_file"
        return 1
    fi

    log_success "Sudoers whitelist configured"
    echo "Wrapper: $wrapper_script"
    echo "Sudoers: $sudoers_file"
}

# ==============================================================================
# UNINSTALL MODE FUNCTIONS
# ==============================================================================

show_uninstall_menu() {
	log_section "Uninstall & Cleanup Menu"
	
	echo -e "${YELLOW}⚠️  WARNING: This will remove selected components${NC}"
	echo ""
	echo "Services:"
	echo "  1) Redis"
	echo "  2) RabbitMQ"
	echo "  3) Nginx"
	echo "  4) Java (OpenJDK)"
	echo "  5) PostgreSQL"
	echo "  6) Node.js/NVM"
	echo ""
	echo "Generated Files:"
	echo "  7) Configuration Files"
	echo "  8) Backups"
	echo "  9) Secrets/Credentials"
	echo " 10) Generated Workflows"
	echo " 11) Entire CICD Directory"
	echo ""
	echo " 12) Back to Main Menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-12]" "12")
	
	case $choice in
		1) uninstall_redis_interactive ;;
		2) uninstall_named_service "rabbitmq-server" "RabbitMQ" ;;
		3) uninstall_named_service "nginx" "Nginx" ;;
		4) uninstall_java_interactive ;;
		5) uninstall_postgresql_interactive ;;
		6) uninstall_node_interactive ;;
		7) cleanup_config_files ;;
		8) cleanup_backups ;;
		9) cleanup_secrets ;;
		10) cleanup_workflows ;;
		11) cleanup_cicd_directory ;;
		12) show_main_menu ;;
		*) log_error "Invalid choice"; show_uninstall_menu ;;
	esac
}

uninstall_postgresql_interactive() {
    log_section "Uninstalling PostgreSQL"

    echo -e "${RED}⚠️  DANGER: This will remove PostgreSQL and ALL DATABASES${NC}"
    echo ""
    echo "This action is IRREVERSIBLE unless you have backups."
    echo ""

    local confirm
    confirm=$(prompt_user "Type 'DELETE' to confirm" "")

    if [ "$confirm" != "DELETE" ]; then
        log_info "Cancelled"
        show_uninstall_menu
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would stop PostgreSQL"
        log_info "[DRY RUN] Would purge PostgreSQL packages"
        log_info "[DRY RUN] Would ask about data directory removal"
        log_info "[DRY RUN] Would remove /var/lib/postgresql/ if confirmed"
    else
        log_info "Stopping PostgreSQL..."
        systemctl stop postgresql || log_warning "PostgreSQL was not running"

        log_info "Removing PostgreSQL packages..."
        apt remove --purge -y postgresql 'postgresql-*'
        apt autoremove -y

        log_warning "Database data remains in /var/lib/postgresql/"
        local remove_data
        remove_data=$(prompt_user "Remove database data directory? [y/N]" "N")

        if [[ "$remove_data" =~ ^[Yy]$ ]]; then
            rm -rf /var/lib/postgresql/
            log_success "Database data removed"
        fi

        log_success "PostgreSQL uninstalled"
    fi
    
    read -p "Press Enter to continue..."
    show_uninstall_menu
}


uninstall_named_service() {
    local pkg_name="$1"
    local human_name="$2"

    log_section "Uninstalling $human_name"

    local confirm
    confirm=$(prompt_user "Are you sure you want to uninstall $human_name? [y/N]" "N")

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warning "Cancelled."
        show_uninstall_menu
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would stop service: $pkg_name"
        log_info "[DRY RUN] Would remove package: $pkg_name"
        log_info "[DRY RUN] Would autoremove unused dependencies"
    else
        log_info "Stopping service $pkg_name..."
        systemctl stop "$pkg_name" >/dev/null 2>&1 || log_warning "$pkg_name was not running"

        log_info "Removing package $pkg_name..."
        if ! apt remove --purge -y "$pkg_name" "${pkg_name}*"; then
            log_error "Failed to remove $pkg_name"
            show_uninstall_menu
            return
        fi

        apt autoremove -y
        log_success "$human_name uninstalled."
    fi

    show_uninstall_menu
}


uninstall_redis_interactive() {
    log_section "Uninstalling Redis"

    local confirm
    confirm=$(prompt_user "Are you sure you want to uninstall Redis? [y/N]" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        show_uninstall_menu
        return
    fi

    local redis_dump="/var/lib/redis/dump.rdb"
    local backup_file="$BACKUPS_DIR/redis_dump_${TIMESTAMP:-$(date +%s)}.rdb"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would stop redis-server"
        log_info "[DRY RUN] Would backup dump file (if exists)"
        log_info "[DRY RUN] Would uninstall redis-server"
        log_info "[DRY RUN] Would autoremove unused dependencies"
        log_info "[DRY RUN] Would remove Redis Commander if installed"
    else
        log_info "Stopping Redis service..."
        systemctl stop redis-server >/dev/null 2>&1 || log_warning "Redis was not running"

        # ---------- BACKUP ----------
        if [ -f "$redis_dump" ]; then
            log_info "Found Redis data dump. Creating backup..."
            mkdir -p "$BACKUPS_DIR"
            if cp "$redis_dump" "$backup_file"; then
                log_success "Redis data backed up to: $backup_file"
            else
                log_error "Failed to create Redis backup!"
            fi
        else
            log_warning "No dump.rdb found. Skipping backup."
        fi

        # ---------- UNINSTALL ----------
        log_info "Removing Redis packages..."
        if ! apt remove --purge -y redis-server; then
            log_error "apt remove redis-server failed!"
            show_uninstall_menu
            return
        fi

        apt autoremove -y

        # ---------- Redis Commander ----------
        if [ -f "/etc/systemd/system/redis-commander.service" ]; then
            log_info "Removing Redis Commander UI..."
            systemctl stop redis-commander >/dev/null 2>&1 || true
            systemctl disable redis-commander >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/redis-commander.service"
            systemctl daemon-reload
        fi

        log_success "Redis uninstalled successfully."
        if [ -f "$backup_file" ]; then
            echo -e "${YELLOW}📝 REMINDER: Backup saved at: $backup_file${NC}"
        fi
    fi

    echo ""
    read -p "Press Enter to continue..."
    show_uninstall_menu
}


uninstall_java_interactive() {
    log_section "Uninstalling Java"
    echo "This will remove all OpenJDK JRE/JDK packages from the system."
    echo ""
    
    # Early scan to show what exists
    log_info "Scanning for installed Java packages..."
    local packages=$(dpkg -l | grep -E '^ii\s+openjdk-[0-9]+-j(re|dk)(-headless)?' | awk '{print $2}' || true)
    
    if [ -z "$packages" ]; then
        log_warning "No OpenJDK packages found installed."
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return 0
    fi
    
    # Show what will be removed
    local pkg_count=$(echo "$packages" | wc -w)
    echo -e "${YELLOW}Found $pkg_count package(s) to remove:${NC}"
    echo "$packages" | tr ' ' '\n' | sed 's/^/  - /'
    echo ""
    
    # Strong confirmation
    log_warning "This will remove ALL Java versions."
    log_warning "Applications depending on Java may break."
    echo ""
    
    local confirm=$(prompt_user "Proceed with removal? [y/N]" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        show_uninstall_menu
        return 0
    fi
    
    # DRY RUN MODE
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would remove: $packages"
        log_info "[DRY RUN] Would run: apt remove --purge -y <packages>"
        log_info "[DRY RUN] Would run: apt autoremove -y"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return 0
    fi
    
    # Actual removal
    log_info "Removing Java packages..."
    
    # Intentionally unquoted - needs word splitting for multiple packages
    if apt remove --purge -y $packages; then
        log_success "$pkg_count Java package(s) removed successfully."
    else
        log_error "Failed to remove some packages."
        log_info "Attempting to fix broken dependencies..."
        apt --fix-broken install -y
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return 1
    fi
    
    # Cleanup
    log_info "Cleaning up unused dependencies..."
    apt autoremove -y
    
    # Verify removal
    local remaining=$(dpkg -l | grep -E '^ii\s+openjdk-[0-9]+-j(re|dk)(-headless)?' | awk '{print $2}' || true)
    if [ -n "$remaining" ]; then
        log_warning "Some packages could not be removed: $remaining"
        log_warning "They may be held or have unresolved dependencies."
    else
        log_success "All Java packages removed. System cleaned."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
    show_uninstall_menu
}


uninstall_node_interactive() {
    log_section "Uninstalling Node.js/NVM"

    # Make sure TARGET_USER is always valid
    collect_user_config
    if [ -z "$TARGET_USER" ]; then
        log_error "TARGET_USER is empty — cannot continue."
        show_uninstall_menu
        return 1
    fi

    echo "This will remove NVM and all Node versions for user: $TARGET_USER"

    # Safe prompt handling (no empty variable issues)
    local confirm
    confirm="$(prompt_user "Are you sure? [y/N]" "N")"

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ "$DRY_RUN" = false ]; then

            log_info "Removing .nvm directory for $TARGET_USER..."

            local nvm_dir="/home/$TARGET_USER/.nvm"

            # Check directory safely
            if [ -d "$nvm_dir" ]; then
                rm -rf "$nvm_dir"
                log_success "NVM removed for $TARGET_USER."
            else
                log_warning "NVM directory not found for $TARGET_USER."
            fi
        else
            log_info "[DRY RUN] Would remove /home/$TARGET_USER/.nvm"
        fi
    else
        log_warning "Cancelled."
    fi

    show_uninstall_menu
}


cleanup_config_files() {
    log_section "Cleanup Configuration Files"
    
    echo "This will remove:"
    echo "  • Nginx configurations in $TEMPLATES_DIR"
    echo "  • Systemd service files (system-wide)"
    echo "  • Sudoers files"
    echo ""
    
    local confirm=$(prompt_user "Proceed? [y/N]" "N")
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        show_uninstall_menu
        return
    fi
    
    # DRY RUN CHECK
    if [ "$DRY_RUN" = true ]; then
        log_warning "[DRY RUN] Would perform the following:"
        [ -d "$TEMPLATES_DIR" ] && log_warning "  - Remove all files in $TEMPLATES_DIR"
        log_warning "  - Remove /etc/sudoers.d/cicd_*"
        log_warning "  - Prompt to remove systemd services and nginx configs from /etc"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    # Remove templates
    if [ -d "$TEMPLATES_DIR" ]; then
        rm -rf "$TEMPLATES_DIR"/*
        log_success "Template files removed"
    fi
    
    # Remove sudoers
    rm -f /etc/sudoers.d/cicd_*
    log_success "Sudoers files removed"
    
    # Prompt for systemd/nginx removal
    local remove_system=$(prompt_user "Remove systemd services and nginx configs from /etc? [y/N]" "N")
    
    if [[ "$remove_system" =~ ^[Yy]$ ]]; then
        # Collect service name if not set
        if [ -z "$SERVICE_NAME" ]; then
            SERVICE_NAME=$(prompt_user "Enter service name to remove" "spring-api-svc")
        fi
        
        if [ -n "$SERVICE_NAME" ]; then
            rm -f "/etc/systemd/system/$SERVICE_NAME.service"
            rm -f "/etc/nginx/sites-available/$SERVICE_NAME"
            rm -f "/etc/nginx/sites-enabled/$SERVICE_NAME"
            systemctl daemon-reload
            log_success "System configurations removed"
        fi
    fi
    
    read -p "Press Enter to continue..."
    show_uninstall_menu
}


cleanup_backups() {
    log_section "Cleanup Backups"
    
    if [ ! -d "$BACKUPS_DIR" ] || [ -z "$(ls -A "$BACKUPS_DIR" 2>/dev/null)" ]; then
        log_warning "No backups found"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    local backup_count=$(find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    
    echo "Found $backup_count backup(s) in $BACKUPS_DIR"
    echo ""
    echo "Options:"
    echo "  1) Remove all backups"
    echo "  2) Keep last 3 backups"
    echo "  3) Cancel"
    
    local choice=$(prompt_user "Choose option [1-3]" "3")
    
    # DRY RUN CHECK
    if [ "$DRY_RUN" = true ]; then
        case $choice in
            1)
                log_warning "[DRY RUN] Would remove all $backup_count backup(s) from $BACKUPS_DIR"
                ;;
            2)
                local remove_count=$((backup_count - 3))
                if [ $remove_count -gt 0 ]; then
                    log_warning "[DRY RUN] Would remove $remove_count old backup(s), keeping last 3"
                else
                    log_info "[DRY RUN] Only $backup_count backup(s) exist, none would be removed"
                fi
                ;;
            3)
                log_info "Cancelled"
                ;;
        esac
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    case $choice in
        1)
            rm -rf "$BACKUPS_DIR"/*
            log_success "All backups removed"
            ;;
        2)
            find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +4 | xargs -r rm -rf
            log_success "Old backups removed, kept last 3"
            ;;
        3)
            log_info "Cancelled"
            ;;
    esac
    
    read -p "Press Enter to continue..."
    show_uninstall_menu
}

cleanup_secrets() {
    log_section "Cleanup Secrets/Credentials"
    
    echo -e "${YELLOW}⚠️  WARNING: This will permanently delete stored passwords${NC}"
    echo ""
    
    if [ ! -d "$CREDENTIALS_DIR" ] || [ -z "$(ls -A "$CREDENTIALS_DIR" 2>/dev/null)" ]; then
        log_warning "No secrets found"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    echo "Stored secrets:"
    for secret_file in "$CREDENTIALS_DIR"/*; do
        [ -f "$secret_file" ] && echo "  • $(basename "$secret_file")"
    done
    
    echo ""
    local confirm=$(prompt_user "Type 'DELETE' to confirm removal" "")
    
    if [ "$confirm" != "DELETE" ]; then
        log_info "Cancelled"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    # DRY RUN CHECK
    if [ "$DRY_RUN" = true ]; then
        log_warning "[DRY RUN] Would remove all secrets from $CREDENTIALS_DIR:"
        for secret_file in "$CREDENTIALS_DIR"/*; do
            [ -f "$secret_file" ] && log_warning "  - $(basename "$secret_file")"
        done
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    rm -rf "$CREDENTIALS_DIR"/*
    log_success "All secrets removed"
    
    read -p "Press Enter to continue..."
    show_uninstall_menu
}

cleanup_workflows() {
    log_section "Cleanup Generated Workflows"
    
    if [ ! -d "$WORKFLOWS_DIR" ] || [ -z "$(ls -A "$WORKFLOWS_DIR" 2>/dev/null)" ]; then
        log_warning "No workflows found"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    echo "This will remove all generated GitHub workflow files from:"
    echo "  $WORKFLOWS_DIR"
    echo ""
    
    # Show what would be deleted
    echo "Files to be removed:"
    for workflow in "$WORKFLOWS_DIR"/*; do
        [ -f "$workflow" ] && echo "  • $(basename "$workflow")"
    done
    echo ""
    
    local confirm=$(prompt_user "Proceed? [y/N]" "N")
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    # DRY RUN CHECK
    if [ "$DRY_RUN" = true ]; then
        log_warning "[DRY RUN] Would remove workflows:"
        for workflow in "$WORKFLOWS_DIR"/*; do
            [ -f "$workflow" ] && log_warning "  - $(basename "$workflow")"
        done
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    rm -rf "$WORKFLOWS_DIR"/*
    log_success "Workflows removed"
    
    read -p "Press Enter to continue..."
    show_uninstall_menu
}

cleanup_cicd_directory() {
    log_section "Remove Entire CICD Directory"
    
    echo -e "${RED}⚠️  DANGER: This will remove EVERYTHING${NC}"
    echo ""
    echo "This includes:"
    echo "  • All templates"
    echo "  • All logs"
    echo "  • All backups"
    echo "  • All secrets"
    echo "  • All generated files"
    echo "  • The configuration file (.cicd.conf)"
    echo ""
    echo "Directory: $CICD_DIR"
    
    # Show current size
    if [ -d "$CICD_DIR" ]; then
        local dir_size=$(du -sh "$CICD_DIR" 2>/dev/null | cut -f1)
        echo "Total size: $dir_size"
    fi
    
    echo ""
    local confirm=$(prompt_user "Type 'DELETE EVERYTHING' to confirm" "")
    
    if [ "$confirm" != "DELETE EVERYTHING" ]; then
        log_info "Cancelled"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    # DRY RUN CHECK
    if [ "$DRY_RUN" = true ]; then
        log_warning "[DRY RUN] Would perform the following:"
        log_warning "  - Remove entire directory: $CICD_DIR"
        log_warning "  - Remove config file: $CONFIG_FILE"
        log_warning "  - Script would require first-time setup on next run"
        read -p "Press Enter to continue..."
        show_uninstall_menu
        return
    fi
    
    rm -rf "$CICD_DIR"
    rm -f "$CONFIG_FILE"
    log_success "CICD directory completely removed"
    
    echo ""
    echo "The script configuration has been reset."
    echo "Next run will require first-time setup again."
    
    read -p "Press Enter to exit..."
    exit 0
}

# ==============================================================================
# REGENERATE MODE FUNCTIONS
# ==============================================================================

show_regenerate_menu() {
	log_section "Regenerate Files Menu"
	
	echo "What would you like to regenerate?"
	echo ""
	echo "  1) GitHub Workflows (Backend + Frontend)"
	echo "  2) Nginx Configuration"
	echo "  3) Systemd Service File"
	echo "  4) Backend Config File"
	echo "  5) All Files"
	echo "  6) Back to Main Menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-6]" "1")
	
	case $choice in
		1) regenerate_workflows ;;
		2) regenerate_nginx ;;
		3) regenerate_systemd ;;
		4) regenerate_backend_config ;;
		5) regenerate_all ;;
		6) show_main_menu ;;
		*) log_error "Invalid choice"; show_regenerate_menu ;;
	esac
}

regenerate_workflows() {
	log_section "Regenerating GitHub Workflows"

	collect_user_config
	collect_java_config
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		generate_github_workflows
		log_success "Workflows regenerated in $WORKFLOWS_DIR"
	fi
	
	show_regenerate_menu
}

regenerate_nginx() {
	log_section "Regenerating Nginx Configuration"
	
	collect_user_config
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUPS_DIR/$TIMESTAMP"
		generate_nginx_config
		nginx -t && systemctl reload nginx
		log_success "Nginx configuration regenerated"
	fi
	
	show_regenerate_menu
}

regenerate_systemd() {
	log_section "Regenerating Systemd Service"
	
	collect_user_config
	collect_backend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUPS_DIR/$TIMESTAMP"
		generate_systemd_service
		systemctl daemon-reload
		log_success "Systemd service regenerated"
	fi
	
	show_regenerate_menu
}

regenerate_backend_config() {
	log_section "Regenerating Backend Config"
	
	collect_user_config
	collect_backend_config
	collect_database_config
	
	if [ "$DRY_RUN" = false ]; then
		generate_backend_config
		log_success "Backend configuration regenerated"
	fi
	
	show_regenerate_menu
}

regenerate_all() {
	log_info "Regenerating all files..."
	
	regenerate_workflows
	regenerate_nginx
	regenerate_systemd
	regenerate_backend_config
	
	log_success "All files regenerated"
	show_regenerate_menu
}

# ==============================================================================
# INSTALLATION FUNCTIONS (Core Logic)
# ==============================================================================

install_docker_engine_logic() {
		log_info "Setting up Docker repository..."
		apt remove -y docker docker-engine docker.io containerd runc || true
		apt update -y
		apt install -y ca-certificates curl gnupg
		
		install -m 0755 -d /etc/apt/keyrings
		if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
				curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
				chmod a+r /etc/apt/keyrings/docker.gpg
		fi
		
		echo \
			"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
			$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
			tee /etc/apt/sources.list.d/docker.list > /dev/null
		
		apt update -y
		apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		
		 # "Smart" Group Logic
		if [ -n "$TARGET_USER" ]; then
			# Check if user is already in group to avoid unnecessary output
			if ! groups "$TARGET_USER" | grep -q "\bdocker\b"; then
				log_info "Adding $TARGET_USER to 'docker' group..."
				log_warning "⚠️  SECURITY: Docker group grants root-equivalent privileges!"
				log_warning "User can run containers with --privileged flag or mount /"
				local confirm=$(prompt_user "Continue? [y/N]" "N")
				[[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
				
				# This ensures that if we (Root) need to run a command AS the user later in this script,
				# we can use 'sg' (execute as group) to make it work immediately without logout.
				# But since this script runs commands as ROOT, we don't strictly need it.
				
				echo ""
				log_warning "User '$TARGET_USER' added to docker group."
				log_warning "⚠️  The user must LOGOUT and LOGIN again to use 'docker' commands without sudo."
				echo ""
			else
				log_info "$TARGET_USER is already in the docker group."
			fi
		fi
		
		# Verify Docker is running (Self-Healing)
		if ! systemctl is-active --quiet docker; then
			log_info "Starting Docker service..."
			systemctl start docker
			systemctl enable docker
		fi
}

install_postgresql() {
    local pg_ver="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    log_info "Installing PostgreSQL $pg_ver..."
    
    # 1. Setup Repo (Standard logic)
    if [ ! -d /usr/share/postgresql-common/pgdg ]; then
        mkdir -p /usr/share/postgresql-common/pgdg
    fi
    
    if [ ! -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ]; then
        if ! curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail -L https://www.postgresql.org/media/keys/ACCC4CF8.asc; then
            log_error "Failed to download PostgreSQL keys."
            return 1
        fi
    fi
    
    sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    
    # 2. Install
    apt update -y
    apt_install_retry "postgresql-$pg_ver"
    
    log_info "Configuring Database..."
    
	# 3. Create/Update DB User & Database (SAFE PIPE VERSION)
    # Check/Create User
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -q 1; then
        # Create new user (Use pipe + variable for password safety)
        echo "CREATE USER \"$db_user\" WITH PASSWORD :'pass';" | sudo -u postgres psql -v pass="$db_pass"
    else
        # Update existing user password
        echo "ALTER USER \"$db_user\" WITH PASSWORD :'pass';" | sudo -u postgres psql -v pass="$db_pass"
    fi
    
    # Check/Create Database
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" | grep -q 1; then
        echo "CREATE DATABASE \"$db_name\" OWNER \"$db_user\";" | sudo -u postgres psql
    fi
    
    # 4. Configure Authentication (TIGHTER SCOPE)
    local pg_conf="/etc/postgresql/$pg_ver/main/pg_hba.conf"
    if [ -f "$pg_conf" ]; then
        if [ ! -f "$pg_conf.bak.original" ]; then
            cp "$pg_conf" "$pg_conf.bak.original"
        fi
        
        # Check if this specific user/db combo is already allowed
        if ! grep -qE "^host\s+$db_name\s+$db_user\s+127\.0\.0\.1\/32\s+scram-sha-256" "$pg_conf"; then
            log_info "Enabling SCRAM-SHA-256 auth for $db_user on $db_name..."
            
            # FIX: Use sed '1i' to insert at the very TOP of the file.
            # This ensures this specific rule is hit before any generic "host all all" rules.
            sed -i "1i host\t$db_name\t$db_user\t127.0.0.1/32\tscram-sha-256" "$pg_conf"
            
            # Add a comment above it (Line 1 again pushes previous line down)
            sed -i "1i # CICD Script Rule: Specific access for $db_name" "$pg_conf"
            
            systemctl restart postgresql
        fi
    fi
    
    # 5. Verify Connection
    log_info "Verifying connection for user '$db_user'..."
    if PGPASSWORD=$db_pass psql -h 127.0.0.1 -U "$db_user" -d "$db_name" -c '\q' 2>/dev/null; then
        log_success "Database connection verified (TCP/Password)."
        
        # Save credentials
        echo "$db_pass" > "$CREDENTIALS_DIR/db_${db_user}_password"
        chmod 600 "$CREDENTIALS_DIR/db_${db_user}_password"
        chown "$TARGET_USER":"$TARGET_USER" "$CREDENTIALS_DIR/db_${db_user}_password"

		log_success "PostgreSQL $pg_ver installed and configured"

		# Prompt for backup configuration
		echo ""
		local setup_backups=$(prompt_user "Configure automatic database backups now? [y/N]" "N")
		if [[ "$setup_backups" =~ ^[Yy]$ ]]; then
			configure_postgresql_backups
		fi

    else
		log_error "Database connection failed!"
		echo "Debug: Try manually: PGPASSWORD='...' psql -h 127.0.0.1 -U $db_user -d $db_name"
		echo "Check: /var/log/postgresql/postgresql-$pg_ver-main.log"
	fi
}



install_nvm_for_user() {
	local username="$1"
	local node_version="$2"
	
	if ! sudo -u "$username" bash -c '[ -s "$HOME/.nvm/nvm.sh" ]'; then
		sudo -u "$username" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
		
		if [ "$node_version" == "lts" ]; then
			sudo -u "$username" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; nvm install --lts'
		else
			sudo -u "$username" bash -c "export NVM_DIR=\"\$HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\"; nvm install $node_version"
		fi
	fi
}

# ==============================================================================
# GENERATION FUNCTIONS
# ==============================================================================

generate_backend_config() {
	if [[ ! "$USE_EXTERNAL_CONFIG" =~ ^[Yy]$ ]]; then
		return
	fi
	
	local config_dir="$API_PATH/config"
	local config_file="$config_dir/application-$SPRING_PROFILE.properties"
	
	mkdir -p "$config_dir"

	# --- Check for missing DB Credentials ---
	if [[ "$INSTALL_PG" =~ ^[Yy]$ ]] || [ -z "$DB_PASS" ]; then
		log_warning "Database credentials required for configuration generation."
		[ -z "$DB_NAME" ] && DB_NAME=$(prompt_user "Database Name" "stock_db")
		[ -z "$DB_USER" ] && DB_USER=$(prompt_user "Database User" "stock_user")
		[ -z "$DB_PASS" ] && DB_PASS=$(prompt_password "Enter Database Password")
		INSTALL_PG="y" 
	fi
	
	local db_config=""
	if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
		db_config="
# PostgreSQL Configuration (Auto-Generated)
spring.datasource.url=jdbc:postgresql://localhost:5432/$DB_NAME
spring.datasource.username=$DB_USER
spring.datasource.password=$DB_PASS
spring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect
spring.jpa.hibernate.ddl-auto=update"
	else
		db_config="
# Database Configuration (Placeholder)
# spring.datasource.url=jdbc:postgresql://localhost:5432/mydb
# spring.datasource.username=dbuser
# spring.datasource.password=secure_password
# spring.jpa.hibernate.ddl-auto=update"
	fi
	
	cat > "$config_file" <<EOF
# SECURE CONFIGURATION ($SPRING_PROFILE)
$db_config

# API Documentation
springdoc.api-docs.path=$API_PREFIX/v3/api-docs
springdoc.swagger-ui.path=$API_PREFIX/swagger-ui.html
management.endpoints.web.base-path=$API_PREFIX/actuator
EOF
	
	chown "$TARGET_USER":"$TARGET_USER" "$config_file"
	chmod 600 "$config_file"
}

generate_systemd_service() {
    local systemd_after="network.target"
    [[ "$INSTALL_PG" =~ ^[Yy]$ ]] && systemd_after="$systemd_after postgresql.service"
    [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && systemd_after="$systemd_after redis-server.service"
    [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && systemd_after="$systemd_after rabbitmq-server.service"
    
    local exec_cmd="/usr/bin/java -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar app.jar --spring.profiles.active=$SPRING_PROFILE"
    [[ "$USE_EXTERNAL_CONFIG" =~ ^[Yy]$ ]] && exec_cmd="$exec_cmd --spring.config.location=file:$API_PATH/config/"
    
    # 1. Create the Service File
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Spring Boot API ($API_NAME)
After=$systemd_after

[Service]
User=$TARGET_USER
WorkingDirectory=$API_PATH
ExecStart=$exec_cmd
SuccessExitStatus=143
Restart=always
RestartSec=10
# Direct stdout/stderr to files. Logrotate will manage these.
StandardOutput=append:/var/log/$SERVICE_NAME.log
StandardError=append:/var/log/$SERVICE_NAME-error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # 2. Create Initial Log Files & Set Permissions
    touch "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME-error.log"
    chown "$TARGET_USER":"$TARGET_USER" "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME-error.log"
    
    # 3. Configure Logrotate (The Fix)
    # This tells the OS to rotate these specific files daily, keep 7 days, and compress them.
    local logrotate_conf="/etc/logrotate.d/${SERVICE_NAME//-/_}"
    cat > "$logrotate_conf" <<EOF
/var/log/$SERVICE_NAME.log /var/log/$SERVICE_NAME-error.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 $TARGET_USER $TARGET_USER
    copytruncate
}
EOF
    chmod 644 "$logrotate_conf"

    # 4. Reload & Enable
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    # 5. Sudoers for Restart
    local sudo_file="/etc/sudoers.d/${SERVICE_NAME//-/_}_runner"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: $(which systemctl) restart $SERVICE_NAME" > "$sudo_file"
    chmod 0440 "$sudo_file"
    
    log_success "Systemd service and Logrotate configured."
}


generate_nginx_config() {
	# FIX #3: Use specific filename to avoid overwriting default site
	local nginx_conf="/etc/nginx/sites-available/$SERVICE_NAME"
	
	cat > "$nginx_conf" <<EOF
server {
	listen 80;
	listen [::]:80;

	server_name _;
	root $UI_PATH;
	index index.html;

	location / {
		# FIX: Use single slash escape so it prints '$uri' in the file
		try_files \$uri \$uri/ /index.html;
	}

	location $API_PREFIX {
		proxy_pass http://localhost:$API_PORT;
		proxy_http_version 1.1;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_cache_bypass \$http_upgrade;
	}
}
EOF
		# Symlink and remove default if conflicting
		rm -f "/etc/nginx/sites-enabled/$SERVICE_NAME"
		ln -s "$nginx_conf" "/etc/nginx/sites-enabled/$SERVICE_NAME"
		log_info "Generated Nginx config at $nginx_conf"
}

generate_github_workflows() {

	log_section "Generating Workflows"
    
    echo "The generated workflows use 'runs-on: self-hosted'."
    echo "This assumes you have installed the GitHub Actions Runner AGENT on THIS server."
    echo "If you use GitHub Cloud Runners, these workflows will fail (they can't access localhost)."
    
    local confirm=$(prompt_user "Are you using a Self-Hosted runner on this server? [Y/n]" "Y")
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_warning "Workflows generated will require modification for SSH/SCP access."
    fi

	mkdir -p "$WORKFLOWS_DIR"
	
	local maven_cmd="mvn -B package --file pom.xml"
	[[ ! "$RUN_TESTS" =~ ^[Yy]$ ]] && maven_cmd="mvn -B package -DskipTests --file pom.xml"
	
	# Backend Workflow
	cat > "$WORKFLOWS_DIR/backend-deploy.yml" <<EOF
name: Deploy Backend

on:
	push:
	branches: [ "$DEPLOY_BRANCH" ]

jobs:
	build:
	runs-on: self-hosted
	env:
		MAVEN_OPTS: "-Xmx1024m"

	steps:
		- name: Checkout code
		uses: actions/checkout@v3
		
		- name: Set up JDK 17
		uses: actions/setup-java@v3
		with:
			java-version: '$JAVA_VER'
			distribution: 'temurin'
			cache: maven

		- name: Build with Maven
		run: $maven_cmd

		- name: Backup Current Deployment
		run: |
			if [ -f "${API_PATH}/app.jar" ]; then
			cp "${API_PATH}/app.jar" "${API_PATH}/app.jar.bak"
			fi

		- name: Deploy to Server
		run: |
			cp target/*.jar "${API_PATH}/app.jar"
			sudo systemctl restart "${SERVICE_NAME}"

		- name: Verify Health (Actuator)
		run: |
			echo "Waiting for service to start (Max ${HEALTH_CHECK_DELAY}s)..."
			for i in {1..${HEALTH_CHECK_DELAY}}; do
			 if curl -s -f http://localhost:${API_PORT}${API_PREFIX}/actuator/health > /dev/null 2>&1; then
				echo "✅ Service Health Check Passed (Attempt \\\$i)"
				exit 0
			 fi
			 sleep 1
			done
			
			echo "❌ Health Check Failed after ${HEALTH_CHECK_DELAY} attempts"
			echo "ℹ️  Ensure 'spring-boot-starter-actuator' is in your pom.xml!"
			exit 1

		- name: Rollback on Failure
		if: failure()
		run: |
			echo "⚠️ DEPLOYMENT FAILED. Initiating Rollback..."
			if [ -f "${API_PATH}/app.jar.bak" ]; then
			mv "${API_PATH}/app.jar" "${API_PATH}/app.jar.failed"
			mv "${API_PATH}/app.jar.bak" "${API_PATH}/app.jar"
			sudo systemctl restart "${SERVICE_NAME}"
			echo "✅ Rollback successful."
			else
			echo "❌ No backup found to restore."
			fi
			
		- name: Cleanup Backup
		if: success()
		run: rm -f "${API_PATH}/app.jar.bak"
EOF

	# Frontend Workflow
	local frontend_build=""
	if [ "$FRONTEND_ENV_STRATEGY" == "2" ] && [ -n "$VITE_VAR_NAME" ]; then
		frontend_build="
		- name: Build project
		run: npm run build
		env:
			$VITE_VAR_NAME: \\\${{ secrets.$VITE_VAR_NAME }}"
	else
		frontend_build="
		- name: Build project
		run: npm run build"
	fi

	cat > "$WORKFLOWS_DIR/frontend-deploy.yml" <<EOF
name: Deploy Frontend

on:
	push:
	branches: [ "$SPRING_PROFILE" ]

jobs:
	build:
	runs-on: self-hosted

	steps:
		- name: Checkout code
		uses: actions/checkout@v3

		- name: Use Node.js
		uses: actions/setup-node@v3
		with:
			node-version: lts/*
			cache: 'npm'

		- name: Install dependencies
		run: npm ci
$frontend_build

		- name: Backup Current Deployment
		run: |
			if [ -d "${UI_PATH}" ]; then
			 rm -rf "${UI_PATH}.bak"
			 mkdir -p "${UI_PATH}.bak"
			 cp -a "${UI_PATH}/." "${UI_PATH}.bak/"
			fi

		- name: Deploy to Nginx
		run: |
			find "${UI_PATH}" -mindepth 1 -delete
			cp -r "${BUILD_DIR}"/* "${UI_PATH}/"

		- name: Verify Deployment
		run: |
			if [ -f "${UI_PATH}/index.html" ]; then
			echo "✅ Frontend deployed successfully"
			else
			echo "❌ Deployment verification failed"
			exit 1
			fi

		- name: Rollback on Failure
		if: failure()
		run: |
			echo "⚠️ DEPLOYMENT FAILED. Initiating Rollback..."
			if [ -d "${UI_PATH}.bak" ]; then
			 find "${UI_PATH}" -mindepth 1 -delete
			 cp -a "${UI_PATH}.bak/." "${UI_PATH}/"
			 echo "✅ Rollback successful."
			fi
			
		- name: Cleanup Backup
		if: success()
		run: rm -rf "${UI_PATH}.bak"
EOF

	chown -R "$TARGET_USER":"$TARGET_USER" "$WORKFLOWS_DIR"
	
	log_success "Workflows generated in: $WORKFLOWS_DIR"
}

# ==============================================================================
# DATABASE HELPER FUNCTIONS
# ==============================================================================

# Add after validate_user_exists() around line 150
validate_db_identifier() {
    local value="$1"
    local name="$2"  # For better error messages
    
    # PostgreSQL rules: start with letter/underscore, contain letters/digits/underscores, max 63 chars
    if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]]; then
        log_error "Invalid $name: '$value'"
        echo "Must start with letter/underscore, contain only alphanumeric + underscore, max 63 chars"
        return 1
    fi
    return 0
}

validate_service_name() {
    local value="$1"
    # Service names: alphanumeric, hyphens, underscores
    if [[ ! "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid service name: '$value'"
        echo "Must contain only letters, numbers, hyphens, and underscores"
        return 1
    fi
    return 0
}

validate_path() {
    local value="$1"
    # Must be absolute path, no spaces or special chars except /-_
    if [[ ! "$value" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "Invalid path: '$value'"
        echo "Must be absolute path with no spaces or special characters"
        return 1
    fi
    return 0
}

reconfigure_postgresql() {
	log_info "Reconfiguring PostgreSQL..."
	
	local pg_versions=$(ls /etc/postgresql/ 2>/dev/null)
	if [ -z "$pg_versions" ]; then
		log_error "No PostgreSQL installation found"
		return
	fi
	
	echo "Installed PostgreSQL versions: $pg_versions"
	local pg_ver=$(prompt_user "Choose version to reconfigure" "$(echo $pg_versions | awk '{print $1}')")
    
    # Get details for stricter security
    local db_name=$(prompt_user "Database Name to allow" "stock_db")
	if ! validate_db_identifier "$db_name"; then
		log_error "Invalid database name format"
		return 1
	fi
    local db_user=$(prompt_user "Database User to allow" "stock_user")
	
	local pg_conf="/etc/postgresql/$pg_ver/main/pg_hba.conf"
	if [ -f "$pg_conf" ]; then
		cp "$pg_conf" "$pg_conf.bak.$(date +%s)"
		
        # FIX: Prepend instead of Append
        sed -i "1i host\t$db_name\t$db_user\t127.0.0.1/32\tscram-sha-256" "$pg_conf"
        sed -i "1i # CICD Script Rule: Specific access for $db_name" "$pg_conf"
		
        systemctl restart postgresql
		log_success "PostgreSQL reconfigured (Allowed $db_user to access $db_name on localhost)"
	fi
}

create_new_database() {
    local db_name
    local db_owner
    db_name=$(prompt_user "Database name" "new_db")
    db_owner=$(prompt_user "Owner (existing user)" "postgres")
    # Validate identifiers: only allow letters, numbers, _, no spaces
    if [[ ! "$db_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid database name: $db_name"
        return 1
    fi
    if [[ ! "$db_owner" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid owner name: $db_owner"
        return 1
    fi
	
    # Safe check: use SQL, not grep
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$db_name'" | grep -q 1; then
        log_warning "Database $db_name already exists"
        return 0
    fi

    # Create database with error reporting
    if sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -v db="$db_name" \
        -v owner="$db_owner" \
        -c 'CREATE DATABASE :"db" OWNER :"owner";'; then
        
        log_success "Database $db_name created successfully"
    else
        log_error "Failed to create database $db_name (psql returned an error)"
        return 1
    fi
}

create_new_db_user() {
    local db_user
    local db_pass
    db_user=$(prompt_user "Username" "new_user")
    db_pass=$(prompt_password "Password for $db_user")
    # Validate username: PostgreSQL identifiers
    if [[ ! "$db_user" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid username: $db_user"
        return 1
    fi
    # Check if user exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$db_user'" | grep -q 1; then
        log_warning "User $db_user already exists"
        return 0
    fi
    # Safely create user (password always single-quoted correctly)
    if sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -v user="$db_user" \
        -v pass="$db_pass" \
        -c "CREATE USER :\"user\" WITH PASSWORD :'pass';"
    then
        log_success "User $db_user created"
        return 0
    else
        log_error "Failed to create user $db_user"
        return 1
    fi
}

update_db_password() {
    local db_user
    local db_pass
    db_user=$(prompt_user "Username" "")

    # Validate input
    if [[ -z "$db_user" ]]; then
        log_error "Username cannot be empty"
        return 1
    fi
    # Validate username syntax
    if [[ ! "$db_user" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid username: $db_user"
        return 1
    fi
    
    # Validate user exists
    # Note: We use -v user=... here too just to be safe with the query, 
    # though strict regex check above makes it less critical.
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$db_user'" | grep -q 1; then
        log_error "User $db_user does not exist"
        return 1
    fi

    # Ask for password
    db_pass=$(prompt_password "New password for $db_user")
    if [[ -z "$db_pass" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi

    # --- THE FIX ---
    # 1. No sed/printf escaping needed.
    # 2. Pass password via -v pass="$db_pass"
    # 3. Use :'pass' in SQL to handle quoting/escaping safely.
    if sudo -u postgres psql -v ON_ERROR_STOP=1 \
        -v user="$db_user" \
        -v pass="$db_pass" \
        -c "ALTER USER :\"user\" WITH PASSWORD :'pass';"
    then
        log_success "Password updated for $db_user"
        return 0
    else
        log_error "Failed to update password for $db_user"
        return 1
    fi
}

configure_postgresql_backups() {
    log_section "PostgreSQL Backup Configuration"
    
    if [ ! -d "$BACKUPS_DIR" ]; then
        log_error "CICD directory not initialized"
        read -p "Press Enter to continue..."
        show_main_menu
        return 1
    fi
    
    # Check if PostgreSQL is installed
    if ! command -v pg_dump &>/dev/null; then
        log_error "PostgreSQL is not installed"
        read -p "Press Enter to continue..."
        show_main_menu
        return 1
    fi
    
    # Check for existing cron job
    local existing_cron=$(crontab -l 2>/dev/null | grep "pg_dump.*$BACKUPS_DIR" || true)
    
    if [ -n "$existing_cron" ]; then
        log_warning "Existing backup cron job found:"
        echo "  $existing_cron"
        echo ""
        local action=$(prompt_user "Action: [R]emove / [U]pdate / [C]ancel" "C")
        
        case $action in
            [Rr])
                crontab -l 2>/dev/null | grep -v "pg_dump.*$BACKUPS_DIR" | crontab -
                log_success "Backup cron job removed"
                read -p "Press Enter to continue..."
                show_main_menu
                return 0
                ;;
            [Cc])
                show_main_menu
                return 0
                ;;
        esac
    fi
    
    echo "Configure automatic PostgreSQL backups"
    echo ""
    
    # Collect database name
    local db_name=$(prompt_user "Database name to backup" "${DB_NAME:-stock_db}")
    
    # Backup frequency
    echo ""
    echo "Backup Schedule:"
    echo "  1) Daily at 2:00 AM"
    echo "  2) Daily at custom time"
    echo "  3) Weekly (Sunday 2:00 AM)"
    echo "  4) Custom cron expression"
    local freq_choice=$(prompt_user "Choose schedule [1-4]" "1")
    
    local cron_time=""
    case $freq_choice in
        1) cron_time="0 2 * * *" ;;
        2)
            local hour=$(prompt_user "Hour (0-23)" "2")
            local minute=$(prompt_user "Minute (0-59)" "0")
            cron_time="$minute $hour * * *"
            ;;
        3) cron_time="0 2 * * 0" ;;
        4) cron_time=$(prompt_user "Cron expression (e.g. '0 2 * * *')" "0 2 * * *") ;;
    esac
    
    # Retention policy
    echo ""
    local retention=$(prompt_user "Keep backups for how many days?" "7")
    if ! [[ "$retention" =~ ^[0-9]+$ ]]; then
        log_error "Invalid number"
        show_main_menu
        return 1
    fi
    
    # Create backup directory
    local pg_backup_dir="$BACKUPS_DIR/postgresql"
    mkdir -p "$pg_backup_dir"
    chmod 700 "$pg_backup_dir"
    
    # Compression option
    local compress=$(prompt_user "Compress backups with gzip? [Y/n]" "Y")
    local backup_ext="sql"
    local backup_cmd="pg_dump $db_name > $pg_backup_dir/\${db_name}_\$(date +\\%F_\\%H\\%M).sql"
    
    if [[ "$compress" =~ ^[Yy]$ ]]; then
        backup_ext="sql.gz"
        backup_cmd="pg_dump $db_name | gzip > $pg_backup_dir/\${db_name}_\$(date +\\%F_\\%H\\%M).sql.gz"
    fi
    
    # Cleanup command
    local cleanup_cmd="find $pg_backup_dir -name '*.${backup_ext}' -mtime +${retention} -delete"
    
    # Create cron job
    local cron_job="$cron_time cd /tmp && sudo -u postgres $backup_cmd && $cleanup_cmd"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would add cron job:"
        echo "  $cron_job"
    else
        (crontab -l 2>/dev/null; echo "# PostgreSQL Backup - $db_name"; echo "$cron_job") | crontab -
        log_success "Backup cron job configured"
        echo ""
        echo "Schedule: $cron_time"
        echo "Database: $db_name"
        echo "Location: $pg_backup_dir"
        echo "Retention: $retention days"
        echo "Compression: $([ "$compress" = "Y" ] && echo "Enabled" || echo "Disabled")"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
    show_main_menu
}

# ==============================================================================
# RESTORE MODE
# ==============================================================================

restore_from_backup() {
		log_section "Restore Mode"
		
		# 1. Check if backup root exists
		if [ ! -d "$BACKUPS_DIR" ]; then
				log_warning "No backup directory found at $BACKUPS_DIR"
				echo "Run a Full Setup or Update Config first to generate backups."
				read -p "Press Enter to return to menu..."
				return 0
		fi
		
		# 2. Get list of backups into an array
		# Uses mapfile to handle filenames with spaces safely, sorted by newest first
		mapfile -t backups < <(ls -1t "$BACKUPS_DIR" 2>/dev/null || true)

		# 3. Check if directory is empty
		if [ ${#backups[@]} -eq 0 ]; then
				log_warning "Backup directory exists but is empty."
				read -p "Press Enter to return to menu..."
				return 0
		fi
		
		# 4. Selection Menu Loop
		while true; do
				echo "Available backups (Newest first):"
				echo ""
				
				# Loop through array to display numbered list
				for i in "${!backups[@]}"; do
						# Format timestamp for readability if it matches standard format
						local ts="${backups[$i]}"
						echo "  $((i+1))) $ts"
				done
				echo ""
				echo "  b) 🔙 Back to Main Menu"
				echo ""
				
				local selection
				read -p "Select backup to restore [1-${#backups[@]}]: " selection
				
				# Handle Back
				if [[ "$selection" =~ ^[Bb]$ ]]; then
						return 0
				fi
				
				# Handle Empty (Loop again)
				if [ -z "$selection" ]; then
						continue
				fi
				
				# Validate Number
				if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#backups[@]}" ]; then
						# Map selection index (1-based) to array index (0-based)
						local index=$((selection-1))
						local restore_ts="${backups[$index]}"
						local restore_source="$BACKUPS_DIR/$restore_ts"
						
						log_info "Selected Backup: $restore_ts"
						local confirm=$(prompt_user "Are you sure you want to restore this configuration? [y/N]" "N")
						
						if [[ "$confirm" =~ ^[Yy]$ ]]; then
								# === RESTORE LOGIC ===
								log_info "Restoring from $restore_source..."
								local restore_count=0
								
								# Restore Nginx (Handle specific filenames now)
								if [ -f "$restore_source/$SERVICE_NAME" ]; then
										 cp "$restore_source/$SERVICE_NAME" "/etc/nginx/sites-available/$SERVICE_NAME"
										 ((restore_count++))
								elif [ -f "$restore_source/default" ]; then
										cp "$restore_source/default" "/etc/nginx/sites-available/default"
										((restore_count++))
								fi
								
								# Restore Services
								for f in "$restore_source"/*.service; do
										if [ -f "$f" ]; then
												cp "$f" "/etc/systemd/system/$(basename "$f")"
												echo -e "   - Restored Service: $(basename "$f")"
												((restore_count++))
										fi
								done
								
								if [ "$restore_count" -eq 0 ]; then
										log_warning "Backup folder was empty or contained no recognizable config files."
								else
										# Reload
										systemctl daemon-reload
										if command -v nginx &> /dev/null; then
												nginx -t && systemctl reload nginx
										fi
										log_success "Restore complete ($restore_count files)."
								fi
								
								read -p "Press Enter to continue..."
								return 0
						else
								echo "Restore cancelled."
						fi
				else
						log_error "Invalid selection. Please enter a number between 1 and ${#backups[@]}."
				fi
				echo ""
		done
}

# ==============================================================================
# FULL SETUP MODE
# ==============================================================================


run_full_setup() {
    log_section "Full Setup Mode"
    
    # 1. Configuration Phase
    collect_user_config
    collect_java_config
    collect_backend_config
    collect_frontend_config
    collect_database_config
    collect_services_config
    collect_node_config
    
    if [ "$DRY_RUN" = true ]; then
        log_warning "Dry run mode - no changes will be made"
        return
    fi
    
    # 2. Preparation Phase
    mkdir -p "$BACKUPS_DIR/$TIMESTAMP"
    
    log_info "Installing base dependencies..."
    apt update -y
    # Use the retry function for base packages
    apt_install_retry "nginx ufw acl curl gnupg2 lsb-release ca-certificates git"
    
    # 3. Installation Phase
    
    # Docker
    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
        install_docker_engine_logic
    fi
    
    # Java
    if [[ ! "$INSTALL_JAVA" =~ ^[Nn]$ ]]; then
        install_java_logic "$JAVA_VER"
    fi
    
    # Directories
    mkdir -p "$API_PATH" "$UI_PATH"
    chown -R "$TARGET_USER":"$TARGET_USER" "$API_PATH" "$UI_PATH"
    
    # PostgreSQL
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
    fi
    
    # Redis (Cleaned up!)
    if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
        install_redis_logic "$REDIS_MODE"
    fi
    
    # RabbitMQ (Cleaned up!)
    if [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]]; then
        install_rabbitmq_logic
    fi
    
    # Node.js
    if [[ "$INSTALL_NODE" =~ ^[Yy]$ ]]; then
        install_nvm_for_user "$TARGET_USER" "$NODE_VER"
        log_success "Node.js installed for $TARGET_USER"
    fi
    
    # 4. Generation Phase
    generate_backend_config
    generate_systemd_service
    generate_nginx_config
    generate_github_workflows
    
    # 5. Security Phase
    configure_sudoers_whitelist

    log_info "Configuring firewall..."
    local ssh_port=$(detect_ssh_port)
    log_info "Detected SSH port: $ssh_port"
    ufw allow "$ssh_port/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Database Backups (New Feature integration)
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        echo ""
        local setup_backups=$(prompt_user "Configure automatic database backups? [y/N]" "N")
        if [[ "$setup_backups" =~ ^[Yy]$ ]]; then
            configure_postgresql_backups
        fi
    fi
    
    # Enable Firewall
    local enable_fw=$(prompt_user "Enable UFW firewall now? [y/N]" "N")
    [[ "$enable_fw" =~ ^[Yy]$ ]] && echo "y" | ufw enable
    
    # 6. Summary
    show_setup_summary
}

show_setup_summary() {
	log_section "Setup Complete - Summary"
	
	echo -e "${CYAN}📂 Directories:${NC}"
	echo "   Backend:  $API_PATH"
	echo "   Frontend: $UI_PATH"
	echo "   Workflows: $WORKFLOWS_DIR"
	echo ""
	
	echo -e "${CYAN}⚙️  Configuration:${NC}"
	echo "   Service:   $SERVICE_NAME (Port: $API_PORT)"
	echo "   Profile:   $SPRING_PROFILE"
	echo "   Memory:    Xms=$JAVA_XMS, Xmx=$JAVA_XMX"
	[[ ! "$INSTALL_JAVA" =~ ^[Nn]$ ]] && echo "   Java:      OpenJDK $JAVA_VER"
	echo ""
	
	echo -e "${CYAN}📦 Services:${NC}"
	[[ "$INSTALL_PG" =~ ^[Yy]$ ]] && echo "   ✅ PostgreSQL $PG_VER (DB: $DB_NAME, Port: 5432)"
	
	if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
		echo "   ✅ Redis ($REDIS_MODE)"
	fi
	
	[[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && echo "   ✅ RabbitMQ (UI: http://localhost:15672)"
	[[ "$INSTALL_NODE" =~ ^[Yy]$ ]] && echo "   ✅ Node.js $NODE_VER (via NVM for $TARGET_USER)"
	
	echo ""
	echo -e "${CYAN}🚀 Next Steps:${NC}"
	echo "   1. Copy workflows to your .github/workflows/ folders"
	echo "   2. Install GitHub self-hosted runners"
	echo "   3. Push to branch '$SPRING_PROFILE' to deploy"
	echo ""
	
	log_success "System ready!"
}

# ==============================================================================
# DIAGNOSTICS MODE FUNCTIONS
# ==============================================================================

run_diagnostics() {
	log_section "System Diagnostics Report"
	
	# 1. Service Status
	echo -e "${CYAN}1. Critical Services Status:${NC}"
	for svc in nginx postgresql redis-server rabbitmq-server docker; do
		if systemctl list-unit-files 2>/dev/null | grep -q "$svc.service"; then
			if systemctl is-active --quiet "$svc"; then
				echo -e "   - $svc: ${GREEN}Active (Running)${NC}"
			else
				echo -e "   - $svc: ${RED}Inactive (Stopped/Failed)${NC}"
			fi
		else
			echo -e "   - $svc: ${YELLOW}Not Installed${NC}"
		fi
	done
	
	# Check User's Custom Service (wildcard search)
	# FIX: Use -print -quit so 'find' stops immediately. No pipe needed.
	local svc_path=$(find /etc/systemd/system -name "*api*.service" -print -quit)
	local spring_svc=""

	if [ -n "$svc_path" ]; then
		spring_svc=$(basename "$svc_path" .service)
	fi

	if [ -n "$spring_svc" ]; then
		if systemctl is-active --quiet "$spring_svc"; then
			echo -e "   - $spring_svc (App): ${GREEN}Active${NC}"
		else
			echo -e "   - $spring_svc (App): ${RED}Inactive${NC}"
		fi
	fi

	# 2. Listening Ports (Explicit Check)
	echo -e "\n${CYAN}2. Listening Ports:${NC}"
	if check_and_install_tool "ss" "iproute2"; then
		# Capture output first
		local ports_output=$(ss -tuln | grep -E ':(80|443|8080|5432|6379|5672|15672)\b' | awk '{print "   - "$5}')
		
		if [ -n "$ports_output" ]; then
			echo "$ports_output"
		else
			echo -e "   - ${YELLOW}No standard infrastructure ports active.${NC}"
			echo "     (Checking: 80, 443, 8080, 5432, 6379, 5672, 15672)"
		fi
	fi

	# 3. Resource Usage
	echo -e "\n${CYAN}3. Resource Usage:${NC}"
	df -h / | awk 'NR==2 {print "   - Disk (Root): "$4" free / "$2" total ("$5" used)"}'
	free -h | awk 'NR==2 {print "   - RAM:        "$4" free / "$2" total"}'

	# 4. Versions (Explicit "Not Installed")
	echo -e "\n${CYAN}4. Installed Versions:${NC}"
	
	# Java
	if command -v java &>/dev/null; then 
		echo "   - Java:   $(java -version 2>&1 | head -n 1)"
	else 
		echo -e "   - Java:   ${YELLOW}Not Installed${NC}"
	fi

	# Node
	# Node Check (Global or NVM via User)
	local node_ver=""
	local check_user="${TARGET_USER:-$SUDO_USER}" # Fallback to sudo user if TARGET_USER isn't set yet

	# 1. Check Global System Node
	if command -v node &>/dev/null; then 
		node_ver=$(node -v)
	
	# 2. Check NVM for the specific user (if nvm.sh exists)
	elif [ -n "$check_user" ] && [ -f "/home/$check_user/.nvm/nvm.sh" ]; then
		# Run as the user, source nvm, and check version
		node_ver=$(sudo -u "$check_user" bash -c '. "$HOME/.nvm/nvm.sh" 2>/dev/null && node -v' 2>/dev/null)
	fi

	if [ -n "$node_ver" ]; then
		echo "   - Node:   $node_ver"
	else 
		echo -e "   - Node:   ${YELLOW}Not Installed${NC}"
	fi

	# Postgres Client
	if command -v psql &>/dev/null; then 
		echo "   - PGSQL:  $(psql --version | awk '{print $3}')"
	else 
		echo -e "   - PGSQL:  ${YELLOW}Not Installed${NC}"
	fi

	# Docker
	if command -v docker &>/dev/null; then 
		echo "   - Docker: $(docker --version | sed 's/Docker version //')"
	else 
		echo -e "   - Docker: ${YELLOW}Not Installed${NC}"
	fi
	
	# Nginx
	if command -v nginx &>/dev/null; then
		echo "   - Nginx:  $(nginx -v 2>&1 | cut -d '/' -f 2)"
	else
		echo -e "   - Nginx:  ${YELLOW}Not Installed${NC}"
	fi

	echo ""
	log_success "Diagnostics complete."
	read -p "Press Enter to return to menu..."
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
	# Check root
	if [ "$EUID" -ne 0 ]; then
		log_error "Please run as root (sudo)"
		exit 1
	fi
	
	# Parse arguments
	for arg in "$@"; do
		case $arg in
			--dry-run) DRY_RUN=true ;;
			--allow-sudoers) ALLOW_SUDOERS=true ;;
			--help)
				show_help
				exit 0
				;;
		esac
	done

	# Initial checks for server specs, root, ...
	perform_preflight_checks
	
	# Validate script location
	validate_script_location
	
	# Check/create CICD directory structure
	check_or_create_config
	
	# Run backup cleanup
	cleanup_old_backups
	
	# Loop the menu
	while true; do
		OPERATION_MODE=""
		
		show_main_menu
		
		case $OPERATION_MODE in
			full) run_full_setup ;;
			update) show_update_menu ;;
			install) show_install_menu ;;
			regenerate) show_regenerate_menu ;;
			restore) restore_from_backup ;;
			uninstall) show_uninstall_menu ;;
			diagnostics) run_diagnostics ;;
			secrets) show_secrets_menu ;;
			db_backups) configure_postgresql_backups ;;  # ADD THIS LINE
		esac
		
		echo ""
		read -p "Press Enter to continue..."
	done
}

show_help() {
	cat <<EOF
CI/CD Automation Script V${SCRIPT_VERSION}

Prerequisites
- Ubuntu 20.04+ / Debian 11+
- Root access via sudo
- 1GB+ RAM, 10GB+ disk

Quick Start
sudo bash script.sh

Modes
1. Full Setup - First-time installation
2. Update Config - Modify existing setup
...

Security Considerations
- Docker group = root access
- Store secrets in $CICD_DIR/credentials

Usage: sudo bash $0 [OPTIONS]

Options:
  --dry-run          Show what would be done without making changes
  --headless         Non-interactive mode (uses defaults)
  --allow-sudoers    Allow sudoers configuration in headless mode
  --help             Show this help message

Examples:
  sudo bash $0                    # Interactive mode
  sudo bash $0 --dry-run          # Test without changes
  sudo bash $0 --headless --allow-sudoers  # Automated setup

Configuration:
  Config file: $CONFIG_FILE
  CICD directory will be configured on first run

For more information, see the script documentation.
EOF
}

# Run main
main "$@"