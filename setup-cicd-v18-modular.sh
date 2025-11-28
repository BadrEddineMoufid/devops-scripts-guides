#!/bin/bash

# ==============================================================================
# AUTOMATED CI/CD SETUP V18: The Modular Edition
# ==============================================================================
# A comprehensive, production-ready automation script with modular operation modes
# ==============================================================================

set -e

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================

readonly SCRIPT_VERSION="18.0"
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
        echo "${result:-$default}"
    else
        read -p "$prompt: " result
        echo "$result"
    fi
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

# ==============================================================================
# VERSION FETCHING FUNCTIONS
# ==============================================================================

fetch_postgresql_versions() {
    local versions
    # Fix: Used grep -oE (Standard) instead of -P (Perl)
    # 1. grep -oE extracts 'v16.1'
    # 2. tr -d 'v' removes the 'v'
    # 3. awk -F. '{print $1}' keeps only the Major version (e.g. 16) for apt compatibility
    # 4. sort -Vu sorts unique versions
    versions=$(curl -s https://www.postgresql.org/ftp/source/ | grep -oE 'v[0-9]+\.[0-9]+' | tr -d 'v' | awk -F. '{print $1}' | sort -Vru | head -10)
    
    if [ -z "$versions" ]; then
        echo "13 14 15 16 17"
    else
        echo "$versions" | tr '\n' ' '
    fi
}

fetch_java_versions() {
    local versions
    # 1. Check apt-cache for packages matching 'openjdk-[number]-jre-headless'
    # 2. Extract the pattern (grep -oE)
    # 3. Extract just the number
    # 4. Sort Unique (Version sort)
    # 5. Format as single line
    versions=$(apt-cache search openjdk | grep -oE 'openjdk-[0-9]+-jre-headless' | grep -oE '[0-9]+' | sort -Vu | tr '\n' ' ')
    
    if [ -z "$versions" ]; then
        # Fallback if apt cache is empty or network is down
        echo "8 11 17 21"
    else
        echo "$versions"
    fi
}

fetch_node_versions() {
    local versions
    # Fix: Used grep -oE instead of -P
    # Extracts v20.11.0, removes 'v', sorts by Version Reverse
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
    echo "  6) ❌ Exit"
    echo ""
    
    local choice
    choice=$(prompt_user "Enter your choice [1-6]" "1")
    
    case $choice in
        1) OPERATION_MODE="full" ;;
        2) OPERATION_MODE="update" ;;
        3) OPERATION_MODE="install" ;;
        4) OPERATION_MODE="regenerate" ;;
        5) OPERATION_MODE="restore" ;;
        6) exit 0 ;;
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
    log_section "Additional Services"
    
    INSTALL_REDIS=$(prompt_user "Install Redis? [y/N]" "N")
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
        create_backup "/etc/nginx/sites-available/default" "$BACKUP_ROOT/$TIMESTAMP"
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
        create_backup "/etc/nginx/sites-available/default" "$BACKUP_ROOT/$TIMESTAMP"
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
    echo "  7) All Services"
    echo "  8) Back to Main Menu"
    echo ""
    
    local choice=$(prompt_user "Enter your choice [1-8]" "1")
    
    case $choice in
        1) install_java_interactive ;;
        2) install_postgresql_interactive ;;
        3) install_redis_interactive ;;
        4) install_rabbitmq_interactive ;;
        5) install_node_interactive ;;
        6) install_nginx_interactive ;;
        7) install_all_services ;;
        8) show_main_menu ;;
        *) log_error "Invalid choice"; show_install_menu ;;
    esac
}

install_java_interactive() {
    log_section "Installing Java"
    
    log_info "Fetching available Java versions..."
    local available_versions=$(fetch_java_versions)
    echo "Available versions: $available_versions"
    
    while true; do
        local java_ver=$(prompt_user "Choose Java version" "17")
        if validate_version_exists "$java_ver" "$available_versions"; then
            if [ "$DRY_RUN" = false ]; then
                apt update -y
                apt install -y "openjdk-${java_ver}-jre-headless"
                log_success "Java $java_ver installed"
            fi
            break
        else
            log_error "Version $java_ver not available. Choose from: $available_versions"
        fi
    done
    
    show_install_menu
}

install_postgresql_interactive() {
    log_section "Installing PostgreSQL"
    
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
    
    if [ "$DRY_RUN" = false ]; then
        install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
        log_success "PostgreSQL $PG_VER installed"
    fi
    
    show_install_menu
}

install_redis_interactive() {
    log_section "Installing Redis"
    
    if [ "$DRY_RUN" = false ]; then
        apt update -y
        apt install -y redis-server
        log_success "Redis installed (Port: 6379)"
    fi
    
    show_install_menu
}

install_rabbitmq_interactive() {
    log_section "Installing RabbitMQ"
    
    if [ "$DRY_RUN" = false ]; then
        apt update -y
        apt install -y rabbitmq-server
        rabbitmq-plugins enable rabbitmq_management
        log_success "RabbitMQ installed (UI: http://localhost:15672 - guest/guest)"
    fi
    
    show_install_menu
}

install_node_interactive() {
    log_section "Installing Node.js/NVM"
    
    collect_user_config
    
    log_info "Fetching available Node versions..."
    local available_versions=$(fetch_node_versions)
    echo "Available versions: $available_versions"
    echo "Or enter 'lts' for latest LTS"
    
    local node_ver=$(prompt_user "Choose Node version" "lts")
    
    if [ "$node_ver" != "lts" ]; then
        if ! validate_version_exists "$node_ver" "$available_versions"; then
            log_error "Version $node_ver not found. Using LTS instead."
            node_ver="lts"
        fi
    fi
    
    if [ "$DRY_RUN" = false ]; then
        install_nvm_for_user "$TARGET_USER" "$node_ver"
        log_success "Node.js installed for $TARGET_USER"
    fi
    
    show_install_menu
}

install_nginx_interactive() {
    log_section "Installing Nginx"
    
    if [ "$DRY_RUN" = false ]; then
        apt update -y
        apt install -y nginx
        log_success "Nginx installed"
    fi
    
    show_install_menu
}

install_all_services() {
    log_info "Installing all services..."
    
    collect_user_config
    collect_database_config
    collect_services_config
    
    if [ "$DRY_RUN" = false ]; then
        apt update -y
        apt install -y openjdk-17-jre-headless nginx ufw acl curl gnupg2 lsb-release ca-certificates
        
        [[ "$INSTALL_PG" =~ ^[Yy]$ ]] && install_postgresql "$PG_VER" "$DB_NAME" "$DB_USER" "$DB_PASS"
        [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && apt install -y redis-server
        [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && apt install -y rabbitmq-server && rabbitmq-plugins enable rabbitmq_management
        
        log_success "All services installed"
    fi
    
    show_install_menu
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
        create_backup "/etc/nginx/sites-available/default" "$BACKUP_ROOT/$TIMESTAMP"
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

install_postgresql() {
    local pg_ver="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    log_info "Installing PostgreSQL $pg_ver..."
    
    # Modern Keyring Method
    install -d /usr/share/postgresql-common/pgdg
    curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
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
    
    # Configure authentication
    local pg_conf="/etc/postgresql/$pg_ver/main/pg_hba.conf"
    if [ -f "$pg_conf" ]; then
        cp "$pg_conf" "$pg_conf.bak.$(date +%s)"
        sed -i 's/^local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+peer/local all all scram-sha-256/' "$pg_conf"
        if ! grep -q "host    all             all             127.0.0.1/32            scram-sha-256" "$pg_conf"; then
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

    # --- FIX START: Check for missing DB Credentials ---
    # If we are regenerating config, we might not have collected DB info yet.
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]] || [ -z "$DB_PASS" ]; then
        log_warning "Database credentials required for configuration generation."
        
        # Only prompt if they weren't set previously
        [ -z "$DB_NAME" ] && DB_NAME=$(prompt_user "Database Name" "stock_db")
        [ -z "$DB_USER" ] && DB_USER=$(prompt_user "Database User" "stock_user")
        [ -z "$DB_PASS" ] && DB_PASS=$(prompt_password "Enter Database Password")
        
        # Ensure Install Flag is set so the if-block below generates PG config
        INSTALL_PG="y" 
    fi
    # --- FIX END ---
    
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
    cat > "/etc/nginx/sites-available/default" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

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
        sed -i 's/^local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+peer/local all all scram-sha-256/' "$pg_conf"
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
    
    if [ ! -d "$BACKUP_ROOT" ]; then
        log_error "No backups found in $BACKUP_ROOT"
        exit 1
    fi
    
    echo "Available backups:"
    ls -1 "$BACKUP_ROOT"
    echo ""
    
    local restore_ts=$(prompt_user "Enter timestamp to restore" "")
    local restore_source="$BACKUP_ROOT/$restore_ts"
    
    if [ ! -d "$restore_source" ]; then
        log_error "Backup not found: $restore_source"
        exit 1
    fi
    
    log_info "Restoring from $restore_source..."
    
    [ -f "$restore_source/default" ] && cp "$restore_source/default" "/etc/nginx/sites-available/default"
    
    for f in "$restore_source"/*.service; do
        [ -f "$f" ] && cp "$f" "/etc/systemd/system/$(basename "$f")"
    done
    
    systemctl daemon-reload
    if command -v nginx &> /dev/null; then
        nginx -t && systemctl reload nginx
    fi
    
    log_success "Restore complete"
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
    collect_services_config
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
    apt install -y nginx ufw acl curl gnupg2 lsb-release ca-certificates
    
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
        log_info "Installing Redis..."
        apt install -y redis-server
        log_success "Redis installed (Port: 6379)"
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
    ufw limit ssh
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
    [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && echo "   ✅ Redis (Port: 6379)"
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
    
    # Show menu and execute
    if [ -z "$OPERATION_MODE" ]; then
        show_main_menu
    fi
    
    case $OPERATION_MODE in
        full) run_full_setup ;;
        update) show_update_menu ;;
        install) show_install_menu ;;
        regenerate) show_regenerate_menu ;;
        restore) restore_from_backup ;;
    esac
}

# Run main
main "$@"