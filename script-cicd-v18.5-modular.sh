#!/bin/bash

# ==============================================================================
# AUTOMATED CI/CD SETUP V18.5: The Robust Edition
# ==============================================================================
# A comprehensive, production-ready automation script with modular operation modes
# Includes Docker integration, safe configs, and smart detection.
# ==============================================================================

set -e

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================

readonly SCRIPT_VERSION="18.5"
readonly BACKUP_ROOT="/var/backups/server-setup"
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# Global Flags
DRY_RUN=false
OPERATION_MODE=""
# New Flags for Logic
INSTALL_DOCKER="N"
REDIS_MODE="system" # Default to system

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
		echo -n "$prompt: "
		read -s pass1
		echo ""
		echo -n "Confirm Password: "
		read -s pass2
		echo ""
		
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
	local backup_dir="$2"
	
	if [ -f "$file_path" ]; then
		mkdir -p "$backup_dir"
		cp "$file_path" "$backup_dir/"
		log_success "Backed up: $file_path"
	fi
}

detect_ssh_port() {
	# Safely detect SSH port, default to 22 if failed
	local port="22"
	if [ -f /etc/ssh/sshd_config ]; then
		local detected=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
		if [ -n "$detected" ]; then
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
				apt update -y && apt install -y "$pkg"
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
	
	echo "Select Operation Mode:"
	echo ""
	echo "  1) 🚀 Full Setup         - Complete CI/CD pipeline installation"
	echo "  2) 🔧 Update Config      - Update existing configurations"
	echo "  3) 📦 Install Services   - Install individual services"
	echo "  4) 📝 Regenerate Files   - Regenerate config/workflow files"
	echo "  5) 🔄 Restore Backup     - Restore from backup"
	echo "  6) 🗑️ Uninstall Services - Remove installed components"
	echo "  7) 📊 System Diagnostics - View ports, services, and resources"
	echo "  8) ❌ Exit"
	echo ""
	
	local choice
	choice=$(prompt_user "Enter your choice [1-8]" "1")
	
	case $choice in
		1) OPERATION_MODE="full" ;;
		2) OPERATION_MODE="update" ;;
		3) OPERATION_MODE="install" ;;
		4) OPERATION_MODE="regenerate" ;;
		5) OPERATION_MODE="restore" ;;
		6) OPERATION_MODE="uninstall" ;;
		7) OPERATION_MODE="diagnostics" ;;
		8) exit 0 ;;
		*) log_error "Invalid choice"; show_main_menu ;;
	esac
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
	
	SERVICE_NAME=$(prompt_user "Service Name" "spring-api-svc")
	API_PORT=$(prompt_user "Backend Port" "8080")
	SPRING_PROFILE=$(prompt_user "Spring Profile (e.g. staging)" "staging")
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
		DB_USER=$(prompt_user "Database user to create" "stock_user")
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
				break
			elif [ "$redis_choice" == "2" ]; then
				# IDIOT PROOFING START
				if check_docker_status; then
					REDIS_MODE="docker"
					break
				else
					log_warning "Docker is NOT installed."
					local auto_install=$(prompt_user "Do you want to install Docker automatically? [Y/n]" "Y")
					
					if [[ ! "$auto_install" =~ ^[Nn]$ ]]; then
						INSTALL_DOCKER="Y" # Flag to install docker in main loop
						REDIS_MODE="docker"
						break
					else
						log_error "Cannot use Docker mode without Docker. Please choose System mode or install Docker first."
					fi
				fi
				# IDIOT PROOFING END
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
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUP_ROOT/$TIMESTAMP"
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
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUP_ROOT/$TIMESTAMP"
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
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUP_ROOT/$TIMESTAMP"
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUP_ROOT/$TIMESTAMP"
		
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
								log_info "Installing $pkg_name..."
								apt update -y
								apt install -y "$pkg_name"
								log_success "Java $java_ver installed"
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
						local db_user=$(prompt_user "Database user to create" "stock_user")
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
						apt update -y
						apt install -y rabbitmq-server
						
						log_info "Enabling Management Plugin..."
						rabbitmq-plugins enable rabbitmq_management
						
						systemctl enable rabbitmq-server
						systemctl start rabbitmq-server
						
						log_success "RabbitMQ installed (UI: http://localhost:15672 - guest/guest)"
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
		log_info "Installing all services (Non-Interactive Mode)..."
		
		collect_user_config
		collect_database_config
		collect_services_config
		
		if [ "$DRY_RUN" = false ]; then
				apt update -y
				# ADDED GIT HERE (FIX #1)
				apt install -y openjdk-17-jre-headless nginx ufw acl curl gnupg2 lsb-release ca-certificates git
				
				[[ "$INSTALL_PG" =~ ^[Yy]$ ]] && install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
				[[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && apt install -y redis-server
				[[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && apt install -y rabbitmq-server && rabbitmq-plugins enable rabbitmq_management
				
				log_success "All services installed"
		fi
		
		read -p "Press Enter to continue..."
		show_install_menu
}

# ==============================================================================
# UNINSTALL MODE FUNCTIONS
# ==============================================================================

show_uninstall_menu() {
	log_section "Uninstall Services Menu"
	
	echo "⚠️  WARNING: Uninstalling services stops them immediately."
	echo "   Data backups will be attempted for Redis only."
	echo "   NOTE: Docker and PostgreSQL must be uninstalled manually to prevent accidental data loss."
	echo ""
	echo "  1) Redis (Auto-Backup & Remove)"
	echo "  2) RabbitMQ"
	echo "  3) Nginx"
	echo "  4) Java (OpenJDK)"
	echo "  5) Node.js/NVM (For Target User)"
	echo "  6) Back to Main Menu"
	echo ""
	
	local choice=$(prompt_user "Enter your choice [1-6]" "6")
	
	case $choice in
		1) uninstall_redis_interactive ;;
		2) uninstall_named_service "rabbitmq-server" "RabbitMQ" ;;
		3) uninstall_named_service "nginx" "Nginx" ;;
		4) uninstall_java_interactive ;;
		5) uninstall_node_interactive ;;
		6) show_main_menu ;;
		*) log_error "Invalid choice"; show_uninstall_menu ;;
	esac
}

uninstall_named_service() {
	local pkg_name=$1
	local human_name=$2
	
	log_section "Uninstalling $human_name"
	local confirm=$(prompt_user "Are you sure you want to uninstall $human_name? [y/N]" "N")
	
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
		if [ "$DRY_RUN" = false ]; then
			log_info "Stopping and removing $pkg_name..."
			systemctl stop "$pkg_name" || true
			apt remove --purge -y "$pkg_name"
			apt autoremove -y
			log_success "$human_name uninstalled."
		fi
	else
		log_warning "Cancelled."
	fi
	show_uninstall_menu
}

uninstall_redis_interactive() {
	log_section "Uninstalling Redis"
	
	local confirm=$(prompt_user "Are you sure you want to uninstall Redis? [y/N]" "N")
	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then show_uninstall_menu; return; fi

	if [ "$DRY_RUN" = false ]; then
		log_info "Stopping Redis service..."
		systemctl stop redis-server || true
		
		# --- BACKUP LOGIC ---
		local redis_dump="/var/lib/redis/dump.rdb"
		local backup_file="$BACKUP_ROOT/redis_dump_$TIMESTAMP.rdb"
		
		if [ -f "$redis_dump" ]; then
			log_info "Found Redis data dump. Creating backup..."
			mkdir -p "$BACKUP_ROOT"
			cp "$redis_dump" "$backup_file"
			log_success "Redis data backed up to: $backup_file"
		else
			log_warning "No Redis dump.rdb found. Skipping backup."
		fi
		
		# --- UNINSTALL ---
		log_info "Removing Redis packages..."
		apt remove --purge -y redis-server
		apt autoremove -y
		
		# Remove UI if exists
		if [ -f "/etc/systemd/system/redis-commander.service" ]; then
			log_info "Removing Redis Commander UI..."
			systemctl stop redis-commander
			systemctl disable redis-commander
			rm /etc/systemd/system/redis-commander.service
			systemctl daemon-reload
		fi
		
		log_success "Redis uninstalled successfully."
		if [ -f "$backup_file" ]; then
			echo -e "${YELLOW}📝 REMINDER: Your data backup is at: $backup_file${NC}"
		fi
	fi
	
	echo ""
	read -p "Press Enter to continue..."
	show_uninstall_menu
}


uninstall_java_interactive() {
	log_section "Uninstalling Java"
	echo "This will remove 'openjdk-*-jre-headless' packages."
	local confirm=$(prompt_user "Proceed? [y/N]" "N")
	
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
		if [ "$DRY_RUN" = false ]; then
			log_info "Removing OpenJDK packages..."
			apt remove --purge -y "openjdk-*-jre-headless"
			apt autoremove -y
			log_success "Java uninstalled."
		fi
	fi
	show_uninstall_menu
}

uninstall_node_interactive() {
	log_section "Uninstalling Node.js/NVM"
	collect_user_config
	
	echo "This will remove NVM and all Node versions for user: $TARGET_USER"
	local confirm=$(prompt_user "Are you sure? [y/N]" "N")
	
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
		if [ "$DRY_RUN" = false ]; then
			log_info "Removing .nvm directory for $TARGET_USER..."
			# Careful removal of specific directory
			if [ -d "/home/$TARGET_USER/.nvm" ]; then
				rm -rf "/home/$TARGET_USER/.nvm"
				log_success "NVM removed for $TARGET_USER."
			else
				log_warning "NVM directory not found for $TARGET_USER."
			fi
		fi
	fi
	show_uninstall_menu
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
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		generate_github_workflows
		log_success "Workflows regenerated in /home/$TARGET_USER/generated-workflows/"
	fi
	
	show_regenerate_menu
}

regenerate_nginx() {
	log_section "Regenerating Nginx Configuration"
	
	collect_user_config
	collect_backend_config
	collect_frontend_config
	
	if [ "$DRY_RUN" = false ]; then
		create_backup "/etc/nginx/sites-available/$SERVICE_NAME" "$BACKUP_ROOT/$TIMESTAMP"
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
		create_backup "/etc/systemd/system/$SERVICE_NAME.service" "$BACKUP_ROOT/$TIMESTAMP"
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
		
		# We might need TARGET_USER here, ensure it's set
		if [ -n "$TARGET_USER" ]; then
				log_info "Adding $TARGET_USER to 'docker' group..."
				usermod -aG docker "$TARGET_USER"
		fi
}

install_postgresql() {
	local pg_ver="$1"
	local db_name="$2"
	local db_user="$3"
	local db_pass="$4"
	
	log_info "Installing PostgreSQL $pg_ver..."
	
	# Modern Keyring Method
	install -d /usr/share/postgresql-common/pgdg
	if [ ! -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ]; then
		curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
	fi
	sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
	
	apt update -y
	apt install -y "postgresql-$pg_ver"
	
	# Create user and database
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -q 1; then
		sudo -u postgres psql -c "CREATE USER $db_user WITH PASSWORD '$db_pass';"
	else
		sudo -u postgres psql -c "ALTER USER $db_user WITH PASSWORD '$db_pass';"
	fi
	
	if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
		sudo -u postgres psql -c "CREATE DATABASE $db_name OWNER $db_user;"
	fi
	
	# Configure authentication (FIX #2: Safer than sed)
	local pg_conf="/etc/postgresql/$pg_ver/main/pg_hba.conf"
	if [ -f "$pg_conf" ]; then
		# Back up config
		cp "$pg_conf" "$pg_conf.bak.$(date +%s)"
		
		# Add TCP listener for localhost with scram-sha-256
		if ! grep -q "host    all             all             127.0.0.1/32            scram-sha-256" "$pg_conf"; then
			echo "# Added by CI/CD Setup Script" >> "$pg_conf"
			echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$pg_conf"
		fi
		
		systemctl restart postgresql
	fi
	
	# Test connection
	if PGPASSWORD=$db_pass psql -h localhost -U $db_user -d $db_name -c '\q' 2>&1; then
		log_success "PostgreSQL connection verified"
	else
		log_warning "PostgreSQL connection test failed. Check logs: sudo journalctl -u postgresql -n 50"
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
StandardOutput=append:/var/log/$SERVICE_NAME.log
StandardError=append:/var/log/$SERVICE_NAME-error.log

[Install]
WantedBy=multi-user.target
EOF
	
	touch "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME-error.log"
	chown "$TARGET_USER":"$TARGET_USER" "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME-error.log"
	
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
	
	local sudo_file="/etc/sudoers.d/${SERVICE_NAME//-/_}_runner"
	echo "$TARGET_USER ALL=(ALL) NOPASSWD: $(which systemctl) restart $SERVICE_NAME" > "$sudo_file"
	chmod 0440 "$sudo_file"
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
		try_files \\\$uri \\\$uri/ /index.html;
	}

	location $API_PREFIX {
		proxy_pass http://localhost:$API_PORT;
		proxy_http_version 1.1;
		proxy_set_header Host \\\$host;
		proxy_set_header X-Real-IP \\\$remote_addr;
		proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \\\$scheme;
		proxy_set_header Upgrade \\\$http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_cache_bypass \\\$http_upgrade;
	}
}
EOF
		# Symlink and remove default if conflicting
		ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/"
		log_info "Generated Nginx config at $nginx_conf"
}

generate_github_workflows() {
	local workflow_dir="/home/$TARGET_USER/generated-workflows"
	mkdir -p "$workflow_dir"
	
	local maven_cmd="mvn -B package --file pom.xml"
	[[ ! "$RUN_TESTS" =~ ^[Yy]$ ]] && maven_cmd="mvn -B package -DskipTests --file pom.xml"
	
	# Backend Workflow
	cat > "$workflow_dir/backend-deploy.yml" <<EOF
name: Deploy Backend

on:
	push:
	branches: [ "$SPRING_PROFILE" ]

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
			java-version: '17'
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

	cat > "$workflow_dir/frontend-deploy.yml" <<EOF
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

	chown -R "$TARGET_USER":"$TARGET_USER" "$workflow_dir"
}

# ==============================================================================
# DATABASE HELPER FUNCTIONS
# ==============================================================================

reconfigure_postgresql() {
	log_info "Reconfiguring PostgreSQL..."
	
	local pg_versions=$(ls /etc/postgresql/ 2>/dev/null)
	if [ -z "$pg_versions" ]; then
		log_error "No PostgreSQL installation found"
		return
	fi
	
	echo "Installed PostgreSQL versions: $pg_versions"
	local pg_ver=$(prompt_user "Choose version to reconfigure" "$(echo $pg_versions | awk '{print $1}')")
	
	local pg_conf="/etc/postgresql/$pg_ver/main/pg_hba.conf"
	if [ -f "$pg_conf" ]; then
		cp "$pg_conf" "$pg_conf.bak.$(date +%s)"
		# Safe Append instead of Sed
		echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$pg_conf"
		systemctl restart postgresql
		log_success "PostgreSQL reconfigured"
	fi
}

create_new_database() {
	local db_name=$(prompt_user "Database name" "new_db")
	local db_owner=$(prompt_user "Owner (existing user)" "postgres")
	
	if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
		log_warning "Database $db_name already exists"
	else
		sudo -u postgres psql -c "CREATE DATABASE $db_name OWNER $db_owner;"
		log_success "Database $db_name created"
	fi
}

create_new_db_user() {
	local db_user=$(prompt_user "Username" "new_user")
	local db_pass=$(prompt_password "Password for $db_user")
	
	if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -q 1; then
		log_warning "User $db_user already exists"
	else
		sudo -u postgres psql -c "CREATE USER $db_user WITH PASSWORD '$db_pass';"
		log_success "User $db_user created"
	fi
}

update_db_password() {
	local db_user=$(prompt_user "Username" "")
	local db_pass=$(prompt_password "New password for $db_user")
	
	sudo -u postgres psql -c "ALTER USER $db_user WITH PASSWORD '$db_pass';"
	log_success "Password updated for $db_user"
}

# ==============================================================================
# RESTORE MODE
# ==============================================================================

restore_from_backup() {
		log_section "Restore Mode"
		
		# 1. Check if backup root exists
		if [ ! -d "$BACKUP_ROOT" ]; then
				log_warning "No backup directory found at $BACKUP_ROOT"
				echo "Run a Full Setup or Update Config first to generate backups."
				read -p "Press Enter to return to menu..."
				return 0
		fi
		
		# 2. Get list of backups into an array
		# Uses mapfile to handle filenames with spaces safely, sorted by newest first
		mapfile -t backups < <(ls -1t "$BACKUP_ROOT" 2>/dev/null)

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
						local restore_source="$BACKUP_ROOT/$restore_ts"
						
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
	
	# Collect all configurations
	collect_user_config
	collect_java_config
	collect_backend_config
	collect_frontend_config
	collect_database_config
	collect_services_config # Now handles Redis Logic
	collect_node_config
	
	if [ "$DRY_RUN" = true ]; then
		log_warning "Dry run mode - no changes will be made"
		return
	fi
	
	# Create backup directory
	mkdir -p "$BACKUP_ROOT/$TIMESTAMP"
	
	# System preparation
	log_info "Installing base dependencies..."
	apt update -y
	# FIX #1: Added GIT
	apt install -y nginx ufw acl curl gnupg2 lsb-release ca-certificates git
	
	# Install Docker if marked by Redis Logic or other Services
	if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
		install_docker_engine_logic
	fi
	
	# Install Java with selected version
	if [[ ! "$INSTALL_JAVA" =~ ^[Nn]$ ]]; then
		log_info "Installing Java $JAVA_VER..."
		apt install -y "openjdk-${JAVA_VER}-jre-headless"
		log_success "Java $JAVA_VER installed"
	fi
	
	# Create directories
	mkdir -p "$API_PATH" "$UI_PATH"
	chown -R "$TARGET_USER":"$TARGET_USER" "$API_PATH" "$UI_PATH"
	
	# Install services with selected versions
	if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
		install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
	fi
	
	if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
		if [ "$REDIS_MODE" == "docker" ]; then
			log_info "Installing Redis (Docker)..."
			docker run -d --name redis-server --restart always -p 6379:6379 -v redis_data:/data redis:alpine
			log_success "Redis Container Started"
		else
			log_info "Installing Redis (System)..."
			apt install -y redis-server
			log_success "Redis installed (Port: 6379)"
		fi
	fi
	
	if [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]]; then
		log_info "Installing RabbitMQ..."
		apt install -y rabbitmq-server
		rabbitmq-plugins enable rabbitmq_management
		log_success "RabbitMQ installed (UI: http://localhost:15672 - guest/guest)"
	fi
	
	# Install Node/NVM if requested
	if [[ "$INSTALL_NODE" =~ ^[Yy]$ ]]; then
		install_nvm_for_user "$TARGET_USER" "$NODE_VER"
		log_success "Node.js installed for $TARGET_USER"
	fi
	
	# Generate configurations
	generate_backend_config
	generate_systemd_service
	generate_nginx_config
	generate_github_workflows
	
	# Configure firewall
	log_info "Configuring firewall..."
	# FIX #4: Detect Port dynamically
	local ssh_port=$(detect_ssh_port)
	log_info "Detected SSH port: $ssh_port"
	ufw allow "$ssh_port/tcp"
	ufw allow 80/tcp
	ufw allow 443/tcp
	
	local enable_fw=$(prompt_user "Enable UFW firewall now? [y/N]" "N")
	[[ "$enable_fw" =~ ^[Yy]$ ]] && echo "y" | ufw enable
	
	# Summary
	show_setup_summary
}

show_setup_summary() {
	log_section "Setup Complete - Summary"
	
	echo -e "${CYAN}📂 Directories:${NC}"
	echo "   Backend:  $API_PATH"
	echo "   Frontend: $UI_PATH"
	echo "   Workflows: /home/$TARGET_USER/generated-workflows/"
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
	local spring_svc=$(find /etc/systemd/system -name "*api*.service" -exec basename {} .service \; | head -n 1)
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
	if command -v node &>/dev/null; then 
		echo "   - Node:   $(node -v)"
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
		esac
	done
	
	# Loop the menu unless an operation mode was passed via args (future proofing)
	while true; do
		# Reset mode
		OPERATION_MODE=""
		
		show_main_menu
		
		case $OPERATION_MODE in
			full) run_full_setup ;;
			update) show_update_menu ;;
			install) show_install_menu ;;
			regenerate) show_regenerate_menu ;;
			restore) restore_from_backup ;;
			uninstall) show_uninstall_menu ;;
			diagnostics) run_diagnostics ;;  # <--- Add this line
		esac
		
		echo ""
		read -p "Press Enter to continue..."
	done
}

# Run main
main "$@"