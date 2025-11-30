#!/bin/bash

# ==============================================================================
# AUTOMATED CI/CD SETUP V15
# ORIGINAL SCRIPT VERSION  
# AUTHOR: Badr Eddine Moufid
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Backup Config
BACKUP_ROOT="/var/backups/server-setup"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CURRENT_BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

# Flags
DRY_RUN=false
RESTORE_MODE=false

# ==============================================================================
# 1. ARGUMENT HANDLING & RESTORE LOGIC
# ==============================================================================

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true; echo -e "${YELLOW}[DRY-RUN] No changes will be applied.${NC}" ;;
        --restore) RESTORE_MODE=true ;;
    esac
done

if [ "$RESTORE_MODE" = true ]; then
    echo -e "${BLUE}=== RESTORE MODE (Server Config) ===${NC}"
    if [ ! -d "$BACKUP_ROOT" ]; then echo -e "${RED}No backups found.${NC}"; exit 1; fi
    echo "Available Backups:"
    ls -1 "$BACKUP_ROOT"
    read -p "Enter timestamp to restore: " RESTORE_TS
    RESTORE_SOURCE="$BACKUP_ROOT/$RESTORE_TS"
    if [ ! -d "$RESTORE_SOURCE" ]; then echo "Backup not found."; exit 1; fi
    
    echo "Restoring from $RESTORE_SOURCE..."
    [ -f "$RESTORE_SOURCE/default" ] && cp "$RESTORE_SOURCE/default" "/etc/nginx/sites-available/default"
    for f in "$RESTORE_SOURCE"/*.service; do
        [ -f "$f" ] && cp "$f" "/etc/systemd/system/$(basename "$f")"
    done

    systemctl daemon-reload
    systemctl reload nginx
    echo -e "${GREEN}Restore Complete.${NC}"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root.${NC}"; exit 1; fi

# ==============================================================================
# 2. USER INTERVIEW
# ==============================================================================

DEFAULT_USER=$(logname 2>/dev/null || echo $SUDO_USER)
read -p "1. VPS Username (runner user) [no spaces] [$DEFAULT_USER]: " TARGET_USER
TARGET_USER=${TARGET_USER:-$DEFAULT_USER}

if ! id "$TARGET_USER" &>/dev/null; then
    echo -e "${RED}User $TARGET_USER does not exist. Please create it first.${NC}"
    exit 1
fi

# --- Backend Config ---
echo -e "\n${YELLOW}--- Backend (Spring Boot) ---${NC}"
read -p "2. Backend Folder Name [no spaces] [spring-api]: " API_NAME
API_NAME=${API_NAME:-spring-api}
API_PATH="/var/www/$API_NAME"

read -p "3. Service Name [no spaces] [spring-api-svc]: " SERVICE_NAME
SERVICE_NAME=${SERVICE_NAME:-spring-api-svc}

read -p "4. Backend Port [8080]: " API_PORT
API_PORT=${API_PORT:-8080}

read -p "5. Spring Profile [no spaces] (e.g. staging) [staging]: " SPRING_PROFILE
SPRING_PROFILE=${SPRING_PROFILE:-staging}

read -p "6. API Prefix [no spaces] (e.g. /api) [/api]: " API_PREFIX
API_PREFIX=${API_PREFIX:-/api}

echo -e "\n${BLUE}Backend Config Strategy:${NC}"
echo "  [y] External: Create secure config file on server (Prod)"
echo "  [n] Internal: Use config inside JAR (Repo .properties)"
read -p "7. Use secure external config file? [y/N]: " USE_EXTERNAL_CONFIG

echo -e "\n${BLUE}Backend Testing Strategy:${NC}"
echo "  [y] Run Tests: mvn package (Requires DB connection in Runner)"
echo "  [n] Skip Tests: mvn package -DskipTests (Safer for simple setups)"
read -p "8. Run Unit Tests during build? [y/N]: " RUN_TESTS

# Validate Integer for Health Check
while true; do
    read -p "9. Max wait time for Health Check (seconds) [30]: " HEALTH_CHECK_DELAY
    HEALTH_CHECK_DELAY=${HEALTH_CHECK_DELAY:-30}
    if [[ "$HEALTH_CHECK_DELAY" =~ ^[0-9]+$ ]]; then
        break
    else
        echo -e "${RED}Please enter a valid number.${NC}"
    fi
done

# --- Frontend Config ---
echo -e "\n${YELLOW}--- Frontend (React/Vite) ---${NC}"
read -p "10. Frontend Folder Name [no spaces] [react-ui]: " UI_NAME
UI_NAME=${UI_NAME:-react-ui}
UI_PATH="/var/www/$UI_NAME"

read -p "11. Build output directory [dist]: " BUILD_DIR
BUILD_DIR=${BUILD_DIR:-dist}

echo -e "\n${BLUE}Frontend Environment Strategy:${NC}"
echo "  [1] Repo Files: Use .env files from Git (e.g. .env.staging)"
echo "  [2] GitHub Secrets: Inject secrets via GitHub Action"
read -p "12. Choose Strategy [1/2]: " FRONTEND_ENV_STRATEGY

VITE_VAR_NAME=""
if [ "$FRONTEND_ENV_STRATEGY" == "2" ]; then
    read -p "    Enter Variable Name to inject (e.g. VITE_API_URL): " VITE_VAR_NAME
fi

# --- Java Memory Settings ---
echo -e "\n${YELLOW}--- Backend JVM Memory ---${NC}"
read -p "13. Choose JVM memory profile [1-Small, 2-Medium(Def), 3-Large]: " MEMORY_PROFILE
case $MEMORY_PROFILE in
    1) JAVA_XMS="256m"; JAVA_XMX="512m" ;;
    3) JAVA_XMS="1024m"; JAVA_XMX="2048m" ;;
    *) JAVA_XMS="512m"; JAVA_XMX="1024m" ;;
esac

# ==============================================================================
# 3. DATABASE & SERVICES INTERVIEW
# ==============================================================================

echo -e "\n${YELLOW}--- Database & Services ---${NC}"

SYSTEMD_AFTER="network.target"

# PostgreSQL
read -p "14. Install PostgreSQL? [y/N]: " INSTALL_PG
if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
    echo "    Available Versions: 14, 15, 16, 17"
    read -p "    Choose Postgres Version [16]: " PG_VER
    PG_VER=${PG_VER:-16}
    
    echo "    --- Database Setup ---"
    read -p "    DB Name to create [stock_db]: " DB_NAME
    DB_NAME=${DB_NAME:-stock_db}
    read -p "    DB User to create [stock_user]: " DB_USER
    DB_USER=${DB_USER:-stock_user}
    
    # Password Confirmation Loop
    while true; do
        echo -n "    DB Password: "
        read -s DB_PASS
        echo ""
        echo -n "    Confirm Password: "
        read -s DB_PASS_CONFIRM
        echo ""
        if [ "$DB_PASS" == "$DB_PASS_CONFIRM" ] && [ -n "$DB_PASS" ]; then
            break
        else
            echo -e "${RED}Passwords do not match or are empty. Try again.${NC}"
        fi
    done
    SYSTEMD_AFTER="$SYSTEMD_AFTER postgresql.service"
fi

# Redis
read -p "15. Install Redis (Caching)? [y/N]: " INSTALL_REDIS
if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
    SYSTEMD_AFTER="$SYSTEMD_AFTER redis-server.service"
fi

# RabbitMQ
echo -e "\n${BLUE}Message Brokers:${NC}"
read -p "16. Install RabbitMQ? [y/N]: " INSTALL_RABBITMQ
if [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]]; then
    SYSTEMD_AFTER="$SYSTEMD_AFTER rabbitmq-server.service"
fi

# ==============================================================================
# 4. SYSTEM PREP & INSTALLATION
# ==============================================================================

echo -e "\n${BLUE}>>> Preparing system...${NC}"
if [ "$DRY_RUN" = false ]; then 
    mkdir -p "$CURRENT_BACKUP_DIR"
    [ -f "/etc/nginx/sites-available/default" ] && cp "/etc/nginx/sites-available/default" "$CURRENT_BACKUP_DIR/"
    [ -f "/etc/systemd/system/$SERVICE_NAME.service" ] && cp "/etc/systemd/system/$SERVICE_NAME.service" "$CURRENT_BACKUP_DIR/"
    
    # Dependencies
    apt update -y
    apt install -y openjdk-17-jre-headless nginx ufw acl curl gnupg2 lsb-release ca-certificates
    
    mkdir -p "$API_PATH" "$UI_PATH"
    chown -R "$TARGET_USER":"$TARGET_USER" "$API_PATH" "$UI_PATH"
fi

# --- Install Services ---

if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}>>> Installing PostgreSQL $PG_VER (Secure Keyring Method)...${NC}"
    if [ "$DRY_RUN" = false ]; then
        # Modern Keyring Method
        install -d /usr/share/postgresql-common/pgdg
        curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
        sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        
        apt update -y
        apt install -y "postgresql-$PG_VER"
        
        # Configure DB
        echo "Creating Database & User..."
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
            sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
        else
            echo "User $DB_USER exists. Updating password."
            sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
        fi
        
        if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
        else
            echo "Database $DB_NAME already exists."
        fi
        
        # Configure pg_hba.conf using portable sed regex
        PG_CONF_PATH="/etc/postgresql/$PG_VER/main/pg_hba.conf"
        echo "Configuring $PG_CONF_PATH..."
        if [ -f "$PG_CONF_PATH" ]; then
            backup_file="$PG_CONF_PATH.bak.$(date +%s)"
            cp "$PG_CONF_PATH" "$backup_file"
            
            # Replaces 'local all all peer' with 'scram-sha-256' using portable regex
            sed -i 's/^local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+peer/local all all scram-sha-256/' "$PG_CONF_PATH"
            
            # Ensure host connections allowed for localhost
            if ! grep -q "host    all             all             127.0.0.1/32            scram-sha-256" "$PG_CONF_PATH"; then
                 echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_CONF_PATH"
            fi
            
            systemctl restart postgresql
        fi

        # Verify Connection (With visibility)
        echo "Testing DB Connection..."
        if PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c '\q' 2>&1; then
             echo -e "${GREEN}✅ Database connection successful!${NC}"
        else
             echo -e "${RED}❌ Database connection failed!${NC}"
             echo "Debug Info: Check pg_hba.conf or logs: sudo journalctl -u postgresql -n 50"
             # Warn but do not crash script here, allow user to fix manually
        fi
    fi
fi

if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}>>> Installing Redis...${NC}"
    [ "$DRY_RUN" = false ] && apt install -y redis-server
fi

if [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}>>> Installing RabbitMQ...${NC}"
    if [ "$DRY_RUN" = false ]; then
        apt install -y rabbitmq-server
        echo "Enabling RabbitMQ Management Plugin..."
        rabbitmq-plugins enable rabbitmq_management
    fi
fi

# --- NVM Setup ---
echo -e "\n${BLUE}>>> Node.js/NVM for Manual Testing...${NC}"
read -p "Install NVM for user '$TARGET_USER' (useful for manual debugging)? [y/N]: " INSTALL_NVM
if [[ "$INSTALL_NVM" =~ ^[Yy]$ ]]; then
    if [ "$DRY_RUN" = false ]; then
        if ! sudo -u "$TARGET_USER" bash -c '[ -s "$HOME/.nvm/nvm.sh" ]'; then
            sudo -u "$TARGET_USER" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
            # Using --lts for future-proofing
            sudo -u "$TARGET_USER" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; nvm install --lts'
        fi
    fi
fi

# ==============================================================================
# 5. BACKEND CONFIGURATION (With DB Injection)
# ==============================================================================

EXEC_START_CMD="/usr/bin/java -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar app.jar --spring.profiles.active=$SPRING_PROFILE"

if [[ "$USE_EXTERNAL_CONFIG" =~ ^[Yy]$ ]]; then
    CONFIG_DIR="$API_PATH/config"
    CONFIG_FILE="$CONFIG_DIR/application-$SPRING_PROFILE.properties"
    
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$CONFIG_DIR"
        
        # DB Configuration Logic
        if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
            DB_CONFIG="
# PostgreSQL Configuration (Auto-Generated)
spring.datasource.url=jdbc:postgresql://localhost:5432/$DB_NAME
spring.datasource.username=$DB_USER
spring.datasource.password=$DB_PASS
spring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect
spring.jpa.hibernate.ddl-auto=update"
        else
            DB_CONFIG="
# Database Configuration (Placeholder)
# spring.datasource.url=jdbc:postgresql://localhost:5432/mydb
# spring.datasource.username=dbuser
# spring.datasource.password=secure_password
# spring.jpa.hibernate.ddl-auto=update"
        fi
        
        # Write File
        if [ ! -f "$CONFIG_FILE" ]; then
            cat <<EOF > "$CONFIG_FILE"
# SECURE CONFIGURATION ($SPRING_PROFILE)
$DB_CONFIG

# API Documentation
springdoc.api-docs.path=$API_PREFIX/v3/api-docs
springdoc.swagger-ui.path=$API_PREFIX/swagger-ui.html
management.endpoints.web.base-path=$API_PREFIX/actuator
EOF
            chown "$TARGET_USER":"$TARGET_USER" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
        fi
    fi
    EXEC_START_CMD="$EXEC_START_CMD --spring.config.location=file:$CONFIG_DIR/"
fi

# ==============================================================================
# 6. SERVICE & SUDOERS
# ==============================================================================

if [ "$DRY_RUN" = false ]; then
cat <<EOF > "/etc/systemd/system/$SERVICE_NAME.service"
[Unit]
Description=Spring Boot API ($API_NAME)
After=$SYSTEMD_AFTER

[Service]
User=$TARGET_USER
WorkingDirectory=$API_PATH
ExecStart=$EXEC_START_CMD
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
    
    SUDO_FILE="/etc/sudoers.d/${SERVICE_NAME//-/_}_runner"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: $(which systemctl) restart $SERVICE_NAME" > "$SUDO_FILE"
    chmod 0440 "$SUDO_FILE"
fi

# ==============================================================================
# 7. NGINX CONFIGURATION
# ==============================================================================

if [ "$DRY_RUN" = false ]; then
cat <<EOF > "/etc/nginx/sites-available/default"
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root $UI_PATH;
    index index.html;

    location / {
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
    
    nginx -t && systemctl reload nginx
fi

# ==============================================================================
# 8. FIREWALL (Interactive)
# ==============================================================================

if [ "$DRY_RUN" = false ]; then
    echo -e "\n${BLUE}>>> Configuring Firewall...${NC}"
    
    # ALWAYS allow SSH first
    ufw limit ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    read -p "Enable UFW Firewall now? [y/N]: " ENABLE_FW
    if [[ "$ENABLE_FW" =~ ^[Yy]$ ]]; then
        echo "y" | ufw enable
    else
        echo "Rules added. Run 'ufw enable' manually."
    fi
fi

# ==============================================================================
# 9. GENERATE GITHUB WORKFLOWS (Robust Retry Loop)
# ==============================================================================

WORKFLOW_DIR="/home/$TARGET_USER/generated-workflows"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$WORKFLOW_DIR"

    # --- MAVEN CMD ---
    if [[ "$RUN_TESTS" =~ ^[Yy]$ ]]; then
        MAVEN_CMD="mvn -B package --file pom.xml"
    else
        MAVEN_CMD="mvn -B package -DskipTests --file pom.xml"
    fi

    # --- Backend YAML ---
    cat <<EOF > "$WORKFLOW_DIR/backend-deploy.yml"
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
        run: $MAVEN_CMD

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
          # Robust Retry Loop
          for i in {1..${HEALTH_CHECK_DELAY}}; do
             if curl -s -f http://localhost:${API_PORT}${API_PREFIX}/actuator/health > /dev/null 2>&1; then
                echo "✅ Service Health Check Passed (Attempt \$i)"
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

    # --- Frontend YAML ---
    FRONTEND_BUILD_STEP=""
    if [ "$FRONTEND_ENV_STRATEGY" == "2" ] && [ -n "$VITE_VAR_NAME" ]; then
        FRONTEND_BUILD_STEP="
      - name: Build project
        run: npm run build
        env:
          $VITE_VAR_NAME: \${{ secrets.$VITE_VAR_NAME }}"
    else
        FRONTEND_BUILD_STEP="
      - name: Build project
        run: npm run build"
    fi

    cat <<EOF > "$WORKFLOW_DIR/frontend-deploy.yml"
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
$FRONTEND_BUILD_STEP

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

    chown -R "$TARGET_USER":"$TARGET_USER" "$WORKFLOW_DIR"
fi

# ==============================================================================
# 10. ATTEMPT START
# ==============================================================================

if [ "$DRY_RUN" = false ] && [ -f "$API_PATH/app.jar" ]; then
    echo -e "\n${BLUE}>>> Existing JAR found. Attempting to start service...${NC}"
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    systemctl status "${SERVICE_NAME}" --no-pager
fi

# ==============================================================================
# 11. FINAL MANIFESTO
# ==============================================================================

echo -e "\n${GREEN}====================================================================${NC}"
echo -e "${GREEN}                  SETUP COMPLETE (V15: Final Edition)            ${NC}"
echo -e "${GREEN}====================================================================${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No changes were made.${NC}"
else
    echo -e "${CYAN}📂 DIRECTORY & USER MAP${NC}"
    echo "--------------------------------------------------------------------"
    echo "Runner User:       $TARGET_USER"
    echo "Backend Path:      $API_PATH"
    echo "Frontend Path:     $UI_PATH"
    echo "Generated YAMLs:   $WORKFLOW_DIR/"
    echo ""

    echo -e "${CYAN}⚙️  CONFIGURATION DETAILS${NC}"
    echo "--------------------------------------------------------------------"
    echo "Service:           $SERVICE_NAME (Port $API_PORT)"
    echo "Dependencies:      $SYSTEMD_AFTER"
    echo "Java Memory:       Xms=${JAVA_XMS}, Xmx=${JAVA_XMX}"
    
    if [[ "$USE_EXTERNAL_CONFIG" =~ ^[Yy]$ ]]; then
        echo "Config Strategy:   EXTERNAL ($CONFIG_FILE)"
        if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
            echo "DB Connection:     ✅ Auto-configured to Postgres ($DB_NAME)"
        else
            echo "DB Connection:     ⚠️  Placeholder (You must edit the file!)"
        fi
    else
        echo "Config Strategy:   INTERNAL (Repo)"
    fi
    echo ""

    echo -e "${CYAN}📦 INSTALLED SERVICES${NC}"
    echo "--------------------------------------------------------------------"
    [[ "$INSTALL_PG" =~ ^[Yy]$ ]] && echo "✅ PostgreSQL $PG_VER (DB: $DB_NAME, Port: 5432)" || echo "⭕ PostgreSQL skipped"
    [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]] && echo "✅ Redis (Port: 6379)" || echo "⭕ Redis skipped"
    [[ "$INSTALL_RABBITMQ" =~ ^[Yy]$ ]] && echo "✅ RabbitMQ (UI: http://localhost:15672 - guest/guest)" || echo "⭕ RabbitMQ skipped"
    echo ""

    echo -e "${CYAN}🚨 CRITICAL REMINDERS${NC}"
    echo "--------------------------------------------------------------------"
    echo "1. ACTUATOR: Ensure 'spring-boot-starter-actuator' is in your pom.xml!"
    echo "2. SWAGGER:  Ensure 'springdoc-openapi-ui' is in your pom.xml."
    echo "3. FIREWALL: UFW is configured. Run 'ufw status' to verify."
    echo "4. ROLLBACK: To restore server config, run: sudo ./script.sh --restore"
    echo ""

    echo -e "${GREEN}System Ready. Good luck!${NC}"
fi