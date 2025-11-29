#!/bin/bash
# CICD Setup Script - Chunk 1
# Purpose: Top-level safety, config dir initialization, logging, and traps.
# Script version: 0.1-chunk1
#
# Comments:
# - This file implements the first chunk of the single-file bootstrap script you asked for.
# - It enforces: "do not run from /", loads or creates a .cicd.conf next to the script,
#   prompts the user for CICD_DIR (default = current script directory),
#   creates the required directory layout, initializes logging, and installs error/exit traps.
# - All changes are heavily commented to explain what and why.

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Global constants & default values
# -----------------------------------------------------------------------------
SCRIPT_VERSION="0.1-chunk1"
# Determine the directory where the script resides. This is used to store .cicd.conf
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/.cicd.conf"
CICD_DIR=""   # to be loaded from conf or prompted
LOG_FILE=""   # will be set once CICD_DIR known
DRY_RUN=false
AUTO_MODE=false
ALLOW_SUDOERS=false

# Subdirectories under CICD_DIR (created at init time)
TEMPLATES_DIR="templates"
LOGS_DIR="logs"
BACKUPS_DIR="backups"
CREDENTIALS_DIR="credentials"
STATE_DIR="state"
WHITELIST_DIR="whitelist"
GENERATED_WORKFLOWS_DIR="generated-workflows"

# -----------------------------------------------------------------------------
# Utility: color helpers for friendly prompts
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}>>> $*${NC}"; }
log_success() { echo -e "${GREEN}✅ $*${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}"; }

# -----------------------------------------------------------------------------
# Error and exit handlers
# - on_error: called by trap on ERR to log where the script failed
# - on_exit: called on script exit to perform cleanup if needed
# -----------------------------------------------------------------------------
on_error() {
	local lineno="${1:-unknown}"
	log_error "Script failed at line: $lineno"
	echo "See log file for full details: $LOG_FILE" || true
}

on_exit() {
	# placeholder for cleanup actions in later chunks
	log_info "Exiting script (version ${SCRIPT_VERSION})."
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

# -----------------------------------------------------------------------------
# Safety check: refuse to run if script is located at root (/)
# Rationale: running from / risks creating files in the root namespace and
# polluting the filesystem. Ask user to move the script and exit.
# -----------------------------------------------------------------------------
check_script_not_root_dir() {
	if [ "$SCRIPT_DIR" = "/" ]; then
		log_error "This script must not be run from the root directory (/)."
		echo
		echo "Move the script into its own folder (e.g. /opt/cicd-setup or ~/cicd-setup) and run it from there."
		echo
		exit 1
	fi
}

# -----------------------------------------------------------------------------
# Load configuration file (.cicd.conf) next to the script (Option A)
# - This file stores a small set of persistent keys, e.g. CICD_DIR
# - Format: simple KEY=VALUE pairs, sourced in a controlled manner
# -----------------------------------------------------------------------------
load_conf() {
	if [ -f "$CONF_FILE" ]; then
		# shellcheck disable=SC1090
		# load safely: only key=value lines allowed
		while IFS='=' read -r key val || [ -n "$key" ]; do
			# skip comments and empty lines
			[[ "$key" =~ ^# ]] && continue
			[[ -z "$key" ]] && continue
			key_trimmed="$(echo "$key" | tr -d ' \t')"
			val_trimmed="$(echo "$val" | sed -e 's/^"//' -e 's/"$//' | sed -e "s/^'//" -e "s/'$//")"
			case "$key_trimmed" in
				CICD_DIR) CICD_DIR="$val_trimmed" ;;
				*) ;;
			esac
		done < "$CONF_FILE"
		log_info "Loaded configuration from $CONF_FILE"
	fi
}

# -----------------------------------------------------------------------------
# Save minimal config back to .cicd.conf
# - Only write the keys we control to avoid stomping other files
# -----------------------------------------------------------------------------
save_conf() {
	cat > "$CONF_FILE" <<EOF
# CICD Setup Configuration (auto-generated)
# Do not edit unless you know what you're doing.
CICD_DIR="$CICD_DIR"
EOF
	chmod 600 "$CONF_FILE"
	log_info "Saved configuration to $CONF_FILE"
}

# -----------------------------------------------------------------------------
# Prompt user to choose CICD_DIR (first-run behavior)
# - Default: script directory
# - This implements your requirement that artifacts be either under the
#   script directory or a user-specified location chosen once.
# -----------------------------------------------------------------------------
prompt_for_cicd_dir() {
	if [ -n "${CICD_DIR:-}" ]; then
		log_info "CICD_DIR is already set to: $CICD_DIR"
		return 0
	fi

	echo "Choose a directory to store generated artifacts (templates, logs, backups, credentials)."
	echo "Default: $SCRIPT_DIR"
	read -rp "Enter path or press Enter to accept default: " user_choice
	user_choice="${user_choice:-$SCRIPT_DIR}"

	# expand tilde
	eval user_choice="$user_choice"

	# if input is root, refuse
	if [ "$user_choice" = "/" ]; then
		log_error "Cannot use root (/) as CICD_DIR. Pick a specific folder."
		exit 1
	fi

	CICD_DIR="$user_choice"
	# ensure the directory exists and is owned by current user
	mkdir -p "$CICD_DIR"
	chmod 700 "$CICD_DIR" || true

	save_conf
}

# -----------------------------------------------------------------------------
# Initialize directory structure under CICD_DIR
# - This creates the templates, logs, backups, credentials, etc. directories
# - Permissions: credentials mode 600, others 700/755 as appropriate
# -----------------------------------------------------------------------------
init_cicd_dirs() {
	# create all required subdirectories
	mkdir -p "$CICD_DIR/$TEMPLATES_DIR"
	mkdir -p "$CICD_DIR/$LOGS_DIR"
	mkdir -p "$CICD_DIR/$BACKUPS_DIR"
	mkdir -p "$CICD_DIR/$CREDENTIALS_DIR"
	mkdir -p "$CICD_DIR/$STATE_DIR"
	mkdir -p "$CICD_DIR/$WHITELIST_DIR"
	mkdir -p "$CICD_DIR/$GENERATED_WORKFLOWS_DIR"

	# permissions
	chmod 755 "$CICD_DIR/$TEMPLATES_DIR" || true
	chmod 700 "$CICD_DIR/$LOGS_DIR" || true
	chmod 700 "$CICD_DIR/$BACKUPS_DIR" || true
	chmod 700 "$CICD_DIR/$CREDENTIALS_DIR" || true
	chmod 700 "$CICD_DIR/$STATE_DIR" || true
	chmod 700 "$CICD_DIR/$WHITELIST_DIR" || true
	chmod 755 "$CICD_DIR/$GENERATED_WORKFLOWS_DIR" || true

	log_success "Initialized CICD directory structure under $CICD_DIR"
}

# -----------------------------------------------------------------------------
# Initialize logging: set LOG_FILE and ensure append permissions
# -----------------------------------------------------------------------------
init_logging() {
	LOG_FILE="$CICD_DIR/$LOGS_DIR/cicd-setup.log"
	# ensure log exists and is appendable
	touch "$LOG_FILE"
	chmod 600 "$LOG_FILE" || true
	log_info "Logging initialized -> $LOG_FILE"
}

# -----------------------------------------------------------------------------
# CLI arg parsing for top-level flags (dry-run, auto, allow-sudoers)
# -----------------------------------------------------------------------------
parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--dry-run) DRY_RUN=true ; shift ;;
			--auto) AUTO_MODE=true ; shift ;;
			--allow-sudoers) ALLOW_SUDOERS=true ; shift ;;
			--help|-h) echo "Usage: $0 [--dry-run] [--auto] [--allow-sudoers]"; exit 0 ;;
			*) echo "Unknown arg: $1"; shift ;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Main entry: orchestrates the chunk 1 initialization
# -----------------------------------------------------------------------------
main_chunk1() {
	parse_args "$@"

	check_script_not_root_dir

	load_conf

	prompt_for_cicd_dir

	init_cicd_dirs

	init_logging

	log_success "Chunk 1 initialization complete."
	log_info "CICD_DIR: $CICD_DIR"

	# At this point we have safe traps, a persistent config, and directories.
	# Next chunks will implement version fetchers, templates, sudoers wrapper, redis handling, etc.
}

# Run main for chunk1 when the file is executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main_chunk1 "$@"
fi

# -----------------------------------------------------------------------------
# Chunk 2: Template renderer and default templates
# -----------------------------------------------------------------------------
# Comments:
# - This chunk introduces template rendering utilities and a set of built-in
#   default templates for Nginx, Systemd (Spring Boot), and GitHub workflows
#   (backend + frontend). The idea is that templates can live under
#   $CICD_DIR/templates/ but if missing we can write defaults.
# - The renderer uses envsubst for variable substitution (POSIX-friendly) and
#   falls back to a sed-based substitution if envsubst is unavailable.
# - The script will check on startup for templates and warn if they are missing.

# Render a template file (source) into destination with environment variable substitution
# Usage: render_template_file <src_template> <dest_path>
render_template_file() {
	local src="$1"
	local dest="$2"

	if [ ! -f "$src" ]; then
		log_warning "Template file not found: $src"
		return 1
	fi

	# Ensure destination directory exists
	mkdir -p "$(dirname "$dest")"

	if command -v envsubst &>/dev/null; then
		envsubst < "$src" > "$dest"
	else
		# Fallback: naive sed replacement for ${VAR} patterns
		# Note: This fallback is simple and not fully envsubst-compliant
		awk '{gsub(/\$\{([^}]+)\}/,"'"ENVIRON[substr($0,match($0,/\$\{([^}]+)\}/)+2,RLENGTH-3)"'")}1' "$src" > "$dest" 2>/dev/null || cp "$src" "$dest"
	fi

	chmod 644 "$dest" || true
	log_info "Rendered template: $src -> $dest"
}

# Render template from a shell variable (heredoc content) into a destination
# Usage: render_template_var VAR_NAME dest_path
render_template_var() {
	local var_name="$1"
	local dest="$2"
	local content
	# Use indirect expansion to get variable content
	content="${!var_name}"

	if [ -z "$content" ]; then
		log_warning "Template variable '$var_name' is empty"
		return 1
	fi

	mkdir -p "$(dirname "$dest")"

	if command -v envsubst &>/dev/null; then
		# Use a here-doc piped to envsubst
		envsubst <<< "$content" > "$dest"
	else
		# Naive fallback: write content as-is
		printf "%s" "$content" > "$dest"
	fi

	chmod 644 "$dest" || true
	log_info "Rendered template var: $var_name -> $dest"
}

# Check templates directory for required templates and warn if missing
ensure_templates_exist() {
	local missing_count=0
	local required=("nginx.conf.tpl" "systemd.service.tpl" "workflow-backend.yml.tpl" "workflow-frontend.yml.tpl")

	for f in "${required[@]}"; do
		if [ ! -f "$CICD_DIR/$TEMPLATES_DIR/$f" ]; then
			log_warning "Missing template: $CICD_DIR/$TEMPLATES_DIR/$f"
			missing_count=$((missing_count+1))
		fi
	done

	if [ "$missing_count" -gt 0 ]; then
		log_warning "Some templates are missing. Functionality will be limited. You can generate defaults with the script when prompted."
	else
		log_info "All required templates are present in $CICD_DIR/$TEMPLATES_DIR"
	fi
}

# Save default templates to the templates dir if user desires
save_default_templates() {
	log_info "Writing default templates into $CICD_DIR/$TEMPLATES_DIR (will not overwrite existing files)"

	mkdir -p "$CICD_DIR/$TEMPLATES_DIR"

	# Nginx template (basic single-site with proxy for API prefix)
	local nginx_tpl_path="$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl"
	if [ ! -f "$nginx_tpl_path" ]; then
		cat > "$nginx_tpl_path" <<'NGINX_TPL'
server {
	listen 80;
	listen [::]:80;

	server_name _;
	root ${UI_PATH};
	index index.html;

	location / {
		try_files $uri $uri/ /index.html;
	}

	location ${API_PREFIX} {
		proxy_pass http://localhost:${API_PORT};
		proxy_http_version 1.1;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_cache_bypass $http_upgrade;
	}
}
NGINX_TPL
		chmod 644 "$nginx_tpl_path" || true
		log_info "Default nginx template created: $nginx_tpl_path"
	fi

	# Systemd template for Spring Boot app
	local systemd_tpl_path="$CICD_DIR/$TEMPLATES_DIR/systemd.service.tpl"
	if [ ! -f "$systemd_tpl_path" ]; then
		cat > "$systemd_tpl_path" <<'SYSTEMD_TPL'
[Unit]
Description=Spring Boot API (${API_NAME})
After=network.target ${SYSTEMD_AFTER}

[Service]
User=${TARGET_USER}
WorkingDirectory=${API_PATH}
ExecStart=/usr/bin/java -Xms${JAVA_XMS} -Xmx${JAVA_XMX} -jar ${API_PATH}/app.jar --spring.profiles.active=${SPRING_PROFILE}
SuccessExitStatus=143
Restart=always
RestartSec=10
StandardOutput=append:${LOG_PATH}
StandardError=append:${ERROR_LOG_PATH}

[Install]
WantedBy=multi-user.target
SYSTEMD_TPL
		chmod 644 "$systemd_tpl_path" || true
		log_info "Default systemd template created: $systemd_tpl_path"
	fi

	# Backend GitHub workflow template
	local backend_tpl_path="$CICD_DIR/$TEMPLATES_DIR/workflow-backend.yml.tpl"
	if [ ! -f "$backend_tpl_path" ]; then
		cat > "$backend_tpl_path" <<'BACKEND_TPL'
name: Deploy Backend

on:
  push:
	branches: [ "${SPRING_PROFILE}" ]

jobs:
  build:
	runs-on: self-hosted

	steps:
	  - uses: actions/checkout@v3
	  - name: Set up JDK
		uses: actions/setup-java@v3
		with:
		  java-version: '${JAVA_VER}'
	  - name: Build with Maven
		run: ${MAVEN_CMD}
	  - name: Deploy to server
		run: |
		  cp target/*.jar ${API_PATH}/app.jar
		  sudo /usr/local/sbin/cicd_restart_service ${SERVICE_NAME}
BACKEND_TPL
		chmod 644 "$backend_tpl_path" || true
		log_info "Default backend workflow template created: $backend_tpl_path"
	fi

	# Frontend GitHub workflow template
	local frontend_tpl_path="$CICD_DIR/$TEMPLATES_DIR/workflow-frontend.yml.tpl"
	if [ ! -f "$frontend_tpl_path" ]; then
		cat > "$frontend_tpl_path" <<'FRONTEND_TPL'
name: Deploy Frontend

on:
  push:
	branches: [ "${SPRING_PROFILE}" ]

jobs:
  build:
	runs-on: self-hosted

	steps:
	  - uses: actions/checkout@v3
	  - name: Use Node.js
		uses: actions/setup-node@v3
		with:
		  node-version: 'lts/*'
	  - name: Build
		run: npm ci && npm run build
	  - name: Deploy to Nginx
		run: |
		  rm -rf ${UI_PATH}/
		  mkdir -p ${UI_PATH}
		  cp -r ${BUILD_DIR}/* ${UI_PATH}/
FRONTEND_TPL
		chmod 644 "$frontend_tpl_path" || true
		log_info "Default frontend workflow template created: $frontend_tpl_path"
	fi

	log_success "Default templates installed where missing."
}

# -----------------------------------------------------------------------------
# Helper: create rendered files from templates into final destination locations
# This allows generation of nginx conf, systemd service and workflows by rendering
# templates found under $CICD_DIR/$TEMPLATES_DIR or using builtin defaults.
# -----------------------------------------------------------------------------
render_all_templates() {
	log_info "Rendering all templates..."

	# Ensure some necessary env vars exist to prevent rendering with empty values
	: "${API_PATH:=/var/www/spring-api}"
	: "${UI_PATH:=/var/www/react-ui}"
	: "${API_PORT:=8080}"
	: "${API_NAME:=spring-api}"
	: "${SERVICE_NAME:=spring-api-svc}"
	: "${SPRING_PROFILE:=staging}"
	: "${JAVA_VER:=17}"
	: "${MAVEN_CMD:=mvn -B package -DskipTests --file pom.xml}"
	: "${BUILD_DIR:=dist}"

	# Nginx
	if [ -f "$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl" ]; then
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl" "/etc/nginx/sites-available/${SERVICE_NAME}"
	else
		# Use builtin default template var via render_template_var (we store defaults in variables)
		# If default variable not set, create it on the fly using save_default_templates
		if [ ! -f "$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl" ]; then
			save_default_templates
		fi
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl" "/etc/nginx/sites-available/${SERVICE_NAME}"
	fi

	# Systemd
	if [ -f "$CICD_DIR/$TEMPLATES_DIR/systemd.service.tpl" ]; then
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/systemd.service.tpl" "/etc/systemd/system/${SERVICE_NAME}.service"
	else
		save_default_templates
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/systemd.service.tpl" "/etc/systemd/system/${SERVICE_NAME}.service"
	fi

	# Workflows
	mkdir -p "$CICD_DIR/$GENERATED_WORKFLOWS_DIR"
	if [ -f "$CICD_DIR/$TEMPLATES_DIR/workflow-backend.yml.tpl" ]; then
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-backend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/backend-deploy.yml"
	else
		save_default_templates
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-backend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/backend-deploy.yml"
	fi

	if [ -f "$CICD_DIR/$TEMPLATES_DIR/workflow-frontend.yml.tpl" ]; then
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-frontend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/frontend-deploy.yml"
	else
		save_default_templates
		render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-frontend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/frontend-deploy.yml"
	fi

	log_success "All templates rendered (where possible)."
}

# End of chunk 2

# -----------------------------------------------------------------------------
# Chunk 3: Sudoers whitelist + secure restart wrapper
# -----------------------------------------------------------------------------
# Comments:
# - Implements a secure wrapper (/usr/local/sbin/cicd_restart_service) that can only
#   restart services listed in a whitelist file under $CICD_DIR/$WHITELIST_DIR/allowed_services
# - Adds functions to manage the whitelist (add/remove/list) and to install/remove
#   the sudoers entry granting the configured TARGET_USER the ability to run only
#   that wrapper without a password.
# - In headless/auto mode the script will refuse to install sudoers unless
#   ALLOW_SUDOERS=true is provided on the command line.

RESTART_WRAPPER="/usr/local/sbin/cicd_restart_service"
SUDOERS_FILE="/etc/sudoers.d/cicd_restart_service"
ALLOWED_SERVICES_FILE="$CICD_DIR/$WHITELIST_DIR/allowed_services"

# Ensure whitelist file exists
_init_whitelist_file() {
	mkdir -p "$(dirname "$ALLOWED_SERVICES_FILE")"
	if [ ! -f "$ALLOWED_SERVICES_FILE" ]; then
		touch "$ALLOWED_SERVICES_FILE"
		chmod 600 "$ALLOWED_SERVICES_FILE"
		log_info "Created empty whitelist at $ALLOWED_SERVICES_FILE"
	fi
}

# Add a service to whitelist (idempotent)
# Usage: add_service_to_whitelist <service_name>
add_service_to_whitelist() {
	local svc="$1"
	_init_whitelist_file
	# Validate service exists on systemd
	if ! systemctl list-unit-files | grep -qw "$svc"; then
		log_warning "Service '$svc' not found among systemd unit files. You can still add it, but restarts may fail."
	fi

	if grep -xq "$svc" "$ALLOWED_SERVICES_FILE"; then
		log_info "Service '$svc' already allowed"
		return 0
	fi

	echo "$svc" >> "$ALLOWED_SERVICES_FILE"
	chmod 600 "$ALLOWED_SERVICES_FILE"
	log_success "Added '$svc' to whitelist"
}

# Remove a service from whitelist
# Usage: remove_service_from_whitelist <service_name>
remove_service_from_whitelist() {
	local svc="$1"
	_init_whitelist_file
	if ! grep -xq "$svc" "$ALLOWED_SERVICES_FILE"; then
		log_warning "Service '$svc' not present in whitelist"
		return 1
	fi

	grep -vxF "$svc" "$ALLOWED_SERVICES_FILE" > "$ALLOWED_SERVICES_FILE.tmp" && mv "$ALLOWED_SERVICES_FILE.tmp" "$ALLOWED_SERVICES_FILE"
	chmod 600 "$ALLOWED_SERVICES_FILE"
	log_success "Removed '$svc' from whitelist"
}

# List whitelisted services
list_whitelisted_services() {
	_init_whitelist_file
	if [ ! -s "$ALLOWED_SERVICES_FILE" ]; then
		echo "(no whitelisted services)"
		return
	fi
	nl -ba -w2 -s") " "$ALLOWED_SERVICES_FILE"
}

# Install the secure restart wrapper script
install_restart_wrapper() {
	# Require root
	if [ "$EUID" -ne 0 ]; then
		log_error "install_restart_wrapper must be run as root"
		return 1
	fi

	# If in auto mode and ALLOW_SUDOERS is false, refuse to create
	if [ "$AUTO_MODE" = true ] && [ "$ALLOW_SUDOERS" = false ]; then
		log_error "Auto mode requires --allow-sudoers to create sudoers entries. Skipping wrapper installation."
		return 1
	fi

	# Create the wrapper
	cat > "$RESTART_WRAPPER" <<'WRAPPER'
#!/bin/bash
# cicd_restart_service: Secure wrapper to restart only whitelisted services.
ALLOWED_FILE="__ALLOWED_FILE__"
if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <service-name>" >&2
	exit 2
fi
SERVICE="$1"
# Verify allowed
if ! grep -xq "$SERVICE" "$ALLOWED_FILE"; then
	echo "Service '$SERVICE' is not allowed to be restarted by this helper." >&2
	exit 3
fi
# Verify systemd unit exists
if ! systemctl list-unit-files | grep -qw "$SERVICE"; then
	echo "Service unit '$SERVICE' not found on systemd." >&2
	exit 4
fi
# Perform restart
exec /bin/systemctl restart "$SERVICE"
WRAPPER

	# Replace placeholder with actual allowed file path
	sed -i "s|__ALLOWED_FILE__|$ALLOWED_SERVICES_FILE|g" "$RESTART_WRAPPER"
	chmod 750 "$RESTART_WRAPPER"
	chown root:root "$RESTART_WRAPPER"

	# Ensure whitelist exists
	_init_whitelist_file

	log_success "Installed secure restart wrapper at $RESTART_WRAPPER"

	# Create a sudoers entry for TARGET_USER to run only this wrapper (no password)
	create_sudoers_entry
}

# Create sudoers file allowing TARGET_USER to run the wrapper without a password
create_sudoers_entry() {
	if [ -z "${TARGET_USER:-}" ]; then
		log_error "TARGET_USER not set. Cannot create sudoers entry."
		return 1
	fi

	# If in auto mode and ALLOW_SUDOERS is false -> refuse
	if [ "$AUTO_MODE" = true ] && [ "$ALLOW_SUDOERS" = false ]; then
		log_error "Auto mode requires --allow-sudoers to create sudoers entries. Refusing to create sudoers file."
		return 1
	fi

	# Write sudoers file
	cat > "$SUDOERS_FILE" <<EOF
# Allow ${TARGET_USER} to restart whitelisted services via cicd_restart_service
${TARGET_USER} ALL=(root) NOPASSWD: $RESTART_WRAPPER
EOF
	chmod 0440 "$SUDOERS_FILE"
	log_success "Created sudoers entry at $SUDOERS_FILE for user $TARGET_USER"
}

# Remove sudoers entry and wrapper (cleanup)
remove_sudoers_and_wrapper() {
	if [ -f "$SUDOERS_FILE" ]; then
		rm -f "$SUDOERS_FILE"
		log_info "Removed sudoers file $SUDOERS_FILE"
	fi
	if [ -f "$RESTART_WRAPPER" ]; then
		rm -f "$RESTART_WRAPPER"
		log_info "Removed wrapper $RESTART_WRAPPER"
	fi
	log_success "Sudoers wrapper and entry removed"
}

# Interactive helper: ask user which services to whitelist
prompt_sudoers_whitelist_interactive() {
	# Build suggested list from common services + SERVICE_NAME if set
	local suggestions=("$SERVICE_NAME" "nginx" "postgresql" "redis-server" "rabbitmq-server")
	echo "Select services to allow restart without password (use numbers separated by spaces)."
	echo "Suggested services:"
	local i=1
	for s in "${suggestions[@]}"; do
		echo "  $i) $s"
		i=$((i+1))
	done
	echo "  0) Done / none"
	read -rp "Enter selection (e.g. 1 2) or 0 to skip: " sel
	if [ -z "$sel" ] || [ "$sel" = "0" ]; then
		log_info "No services selected for sudoers whitelist."
		return 0
	fi
	for token in $sel; do
		if [[ "$token" =~ ^[0-9]+$ ]]; then
			if [ "$token" -ge 1 ] && [ "$token" -le ${#suggestions[@]} ]; then
				svcname="${suggestions[$((token-1))]}"
				add_service_to_whitelist "$svcname"
			else
				log_warning "Invalid selection: $token"
			fi
		else
			# Allow user to type service names directly
			add_service_to_whitelist "$token"
		fi
	done

	# If whitelist is non-empty, ask to install wrapper and sudoers
	if [ -s "$ALLOWED_SERVICES_FILE" ]; then
		read -rp "Install secure restart wrapper and sudoers entry for $TARGET_USER? [y/N] " yn
		yn="${yn:-N}"
		if [[ "$yn" =~ ^[Yy]$ ]]; then
			install_restart_wrapper
		else
			log_info "Skipping wrapper installation as requested."
		fi
	fi
}

# End of chunk 3

# --------------------------------------------------------------------------
# Chunk 4: Redis credential flow (APT and Docker modes)
# --------------------------------------------------------------------------
# Comments:
# - Interactive credential handling for Redis for both apt and docker modes.
# - Stores final password in $CICD_DIR/$CREDENTIALS_DIR/redis (mode 600).
# - Applies auth by editing redis.conf (apt) or mounting redis.conf into Docker.
# - Respects DRY_RUN and AUTO_MODE flags.

_generate_simple_password() {
	tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || echo "Pass1234"
}

prompt_redis_password() {
	local confirmed="no"
	local pwd
	while [ "$confirmed" != "yes" ]; do
		local suggestion
		suggestion=$(_generate_simple_password)
		echo "Redis authentication is recommended."
		echo "Suggested 8-char password: $suggestion"
		echo "Options:"
		echo "  1) Accept suggested password"
		echo "  2) Regenerate suggestion"
		echo "  3) Enter custom password"
		echo "  4) Cancel (disable auth)"
		read -rp "Choose option [1/2/3/4]: " choice
		choice="${choice:-1}"
		case "$choice" in
			1) pwd="$suggestion" ;;
			2) continue ;;
			3)
				read -rp "Enter custom password (min 4 chars): " custom
				if [ ${#custom} -lt 4 ]; then
					log_warning "Password too short. Try again."
					continue
				fi
				pwd="$custom"
				;;
			4)
				echo "Auth disabled by user."
				return 1
				;;
			*)
				log_warning "Invalid choice"
				continue
				;;
		esac

		echo "Chosen password: $pwd"
		read -rp "Confirm and save this password? [y/N] " yn
		yn="${yn:-N}"
		if [[ "$yn" =~ ^[Yy]$ ]]; then
			confirmed="yes"
		else
			echo "Let's try again."
		fi
	done
	printf "%s" "$pwd"
	return 0
}

save_redis_password() {
	local pwd="$1"
	local out="$CICD_DIR/$CREDENTIALS_DIR/redis"
	mkdir -p "$(dirname "$out")"
	printf "%s" "$pwd" > "$out"
	chmod 600 "$out"
	log_success "Saved redis password to $out (mode 600)"
}

apply_redis_password_apt() {
	local pwd="$1"
	local redis_conf_path="/etc/redis/redis.conf"
	local backup_path="$CICD_DIR/$BACKUPS_DIR/redis.conf.$(date +%s)"

	if [ ! -f "$redis_conf_path" ]; then
		log_error "redis.conf not found at $redis_conf_path. Is redis installed?"
		return 1
	fi

	if [ "$DRY_RUN" = true ]; then
		log_info "DRY RUN: Would backup $redis_conf_path to $backup_path and set requirepass"
		return 0
	fi

	cp "$redis_conf_path" "$backup_path"
	chmod 600 "$backup_path" || true

	if grep -q "^\s*requirepass\s\+" "$redis_conf_path"; then
		sed -E "s|^\s*requirepass\s+.*|requirepass $pwd|" "$redis_conf_path" > "$redis_conf_path.tmp" && mv "$redis_conf_path.tmp" "$redis_conf_path"
	else
		echo "" >> "$redis_conf_path"
		echo "# Added by CICD setup: enable password auth" >> "$redis_conf_path"
		echo "requirepass $pwd" >> "$redis_conf_path"
	fi

	systemctl restart redis-server
	log_success "Redis (apt) configured with requirepass and restarted"
}

apply_redis_password_docker() {
	local pwd="$1"
	local redis_conf_local="$CICD_DIR/$TEMPLATES_DIR/redis.conf"
	local container_name="redis-server"

	cat > "$redis_conf_local" <<EOF
requirepass $pwd
EOF
	chmod 600 "$redis_conf_local"

	if [ "$DRY_RUN" = true ]; then
		log_info "DRY RUN: Would run docker container mounting $redis_conf_local"
		return 0
	fi

	if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
		docker rm -f "$container_name" || true
	fi

	docker run -d --name "$container_name" --restart always -p 6379:6379 -v "$redis_conf_local":/usr/local/etc/redis/redis.conf:ro redis:7-alpine redis-server /usr/local/etc/redis/redis.conf

	log_success "Redis Docker container started (name: $container_name)"
}

configure_redis() {
	local mode="$1"
	if [ -z "$mode" ]; then
		log_error "configure_redis requires a mode: apt or docker"
		return 1
	fi

	read -rp "Enable Redis password authentication? [Y/n] " yn
	yn="${yn:-Y}"
	if [[ ! "$yn" =~ ^[Yy]$ ]]; then
		log_info "Redis authentication will remain disabled as requested."
		return 0
	fi

	local pwd
	pwd=$(prompt_redis_password) || { log_info "User cancelled redis auth setup."; return 1; }

	save_redis_password "$pwd"

	if [ "$mode" = "apt" ]; then
		apply_redis_password_apt "$pwd"
	else
		if ! command -v docker &>/dev/null; then
			log_error "Docker not found. Install Docker first or select apt mode."
			return 1
		fi
		apply_redis_password_docker "$pwd"
	fi
}

rotate_redis_password() {
	local mode="$1"
	read -rp "Rotate Redis password? This will generate a new suggested password. Continue? [y/N] " yn
	yn="${yn:-N}"
	if [[ ! "$yn" =~ ^[Yy]$ ]]; then
		log_info "Rotation cancelled."
		return 0
	fi
	local newpwd
	newpwd=$(_generate_simple_password)
	echo "Suggested new password: $newpwd"
	read -rp "Accept new password? [Y/n] " accept
	accept="${accept:-Y}"
	if [[ ! "$accept" =~ ^[Yy]$ ]]; then
		log_info "Rotation cancelled by user."
		return 1
	fi

	save_redis_password "$newpwd"
	if [ "$mode" = "apt" ]; then
		apply_redis_password_apt "$newpwd"
	else
		apply_redis_password_docker "$newpwd"
	fi
	log_success "Redis password rotated and applied."
}

show_redis_password() {
	local file="$CICD_DIR/$CREDENTIALS_DIR/redis"
	if [ ! -f "$file" ]; then
		log_warning "No redis password stored at $file"
		return 1
	}
	read -rp "Show redis password (sensitive)? [y/N] " yn
	yn="${yn:-N}"
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		echo "Redis password: $(cat "$file")"
	else
		log_info "Aborted showing password."
	fi
}

# -------------------------------------------------------------------------
# Chunk 5: Version fetchers, port validation, regeneration flow, uninstall & diagnostics
# -------------------------------------------------------------------------
# Comments:
# - Implements version discovery for PostgreSQL, Node.js and Java (no caching).
# - Adds port conflict detection and helper to write port exports.
# - Regeneration flow: pure render functions; menu calls them.
# - Uninstall mode: user chooses what to remove.
# - Diagnostics: quick system / services / artifacts report.

fetch_postgresql_versions() {
	# Try upstream
	local upstream
	upstream=$(curl -s https://www.postgresql.org/ftp/source/ | grep -oE 'v[0-9]+\.[0-9]+' | tr -d 'v' | cut -d. -f1 | sort -Vru | uniq | head -n 10)
	if [ -n "$upstream" ]; then
		echo "$upstream"
		echo "source: upstream" >&2
		return 0
	fi

	# Fallback to apt-cache
	local aptv
	aptv=$(apt-cache search postgresql 2>/dev/null | grep -oE 'postgresql-[0-9]+' | grep -oE '[0-9]+' | sort -Vru | uniq | head -n 10)
	if [ -n "$aptv" ]; then
		echo "$aptv"
		echo "source: apt-cache" >&2
		return 0
	fi

	# Hardcoded fallback
	echo "17
16
15
14
13"
	echo "source: hardcoded" >&2
}

fetch_node_versions() {
	local upstream
	upstream=$(curl -s https://nodejs.org/dist/index.json | grep -oE '"version":\s*"v[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/"version":\s*"v([0-9]+)\..*/\1/' | sort -Vru | uniq | head -n 10)
	if [ -n "$upstream" ]; then
		echo "$upstream"
		echo "source: upstream" >&2
		return 0
	fi

	local aptv
	aptv=$(apt-cache search nodejs 2>/dev/null | grep -oE 'nodejs-[0-9]+' | grep -oE '[0-9]+' | sort -Vru | uniq | head -n 10)
	if [ -n "$aptv" ]; then
		echo "$aptv"
		echo "source: apt-cache" >&2
		return 0
	fi

	echo "18
16
14"
	echo "source: hardcoded" >&2
}

fetch_java_versions() {
	local upstream
	upstream=$(curl -s https://api.adoptopenjdk.net/v3/info/available_releases | tr -d '[],\"' | awk -F: '{print $2}' | tr ' ' '\n' | sort -Vru | uniq | head -n 10 2>/dev/null || true)
	if [ -n "$upstream" ]; then
		echo "$upstream"
		echo "source: adoptopenjdk api" >&2
		return 0
	fi

	local aptv
	aptv=$(apt-cache search openjdk 2>/dev/null | grep -oE 'openjdk-[0-9]+' | grep -oE '[0-9]+' | sort -Vru | uniq | head -n 10)
	if [ -n "$aptv" ]; then
		echo "$aptv"
		echo "source: apt-cache" >&2
		return 0
	fi

	echo "17
11
8"
	echo "source: hardcoded" >&2
}

# Port conflict helpers
detect_port_conflict() {
	local port="$1"
	if [ -z "$port" ]; then
		log_error "detect_port_conflict requires a port argument"
		return 2
	fi
	if ss -tuln | awk '{print $5}' | grep -E "[:.]$port$" >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

choose_port_interactive() {
	local suggested="$1"
	local port
	while true; do
		read -rp "Enter port to use [${suggested}]: " port
		port="${port:-$suggested}"
		if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
			log_warning "Invalid port: $port"
			continue
		fi
		if detect_port_conflict "$port"; then
			log_info "Port $port is free"
			break
		else
			log_warning "Port $port appears in use. Choose another or prefix with ! to force."
			read -rp "Type '!' to force using $port, or press Enter to choose another: " force
			if [ "$force" = "!" ]; then
				log_warning "Forcing use of $port despite conflict"
				break
			fi
		fi
	done
	echo "$port"
}

generate_port_exports() {
	local port="$1"
	cat <<EOF
API_PORT=$port
EOF
}

# Regeneration flow (pure functions)
render_nginx() {
	: "${SERVICE_NAME:=spring-api-svc}"
	render_template_file "$CICD_DIR/$TEMPLATES_DIR/nginx.conf.tpl" "/etc/nginx/sites-available/${SERVICE_NAME}"
}

render_systemd() {
	: "${SERVICE_NAME:=spring-api-svc}"
	render_template_file "$CICD_DIR/$TEMPLATES_DIR/systemd.service.tpl" "/etc/systemd/system/${SERVICE_NAME}.service"
}

render_workflows() {
	mkdir -p "$CICD_DIR/$GENERATED_WORKFLOWS_DIR"
	render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-backend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/backend-deploy.yml"
	render_template_file "$CICD_DIR/$TEMPLATES_DIR/workflow-frontend.yml.tpl" "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/frontend-deploy.yml"
}

regenerate_all() {
	render_nginx
	render_systemd
	render_workflows
}

# Uninstall menu
uninstall_menu() {
	echo "Uninstall options:"
	echo "  1) configs (nginx/systemd)"
	echo "  2) backups"
	echo "  3) credentials"
	echo "  4) generated workflows"
	echo "  5) sudoers & wrapper"
	echo "  6) packages (apt-installed packages managed by script)"
	echo "  0) Cancel"
	read -rp "Enter choices separated by space (e.g. 1 3 4): " choices
	[ -z "$choices" ] && { echo "Cancelled"; return; }

	for c in $choices; do
		case "$c" in
			1)
				echo "About to remove rendered configs: /etc/nginx/sites-available/$SERVICE_NAME and /etc/systemd/system/$SERVICE_NAME.service"
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					[ -f "/etc/nginx/sites-available/$SERVICE_NAME" ] && rm -f "/etc/nginx/sites-available/$SERVICE_NAME"
					[ -f "/etc/systemd/system/$SERVICE_NAME.service" ] && rm -f "/etc/systemd/system/$SERVICE_NAME.service"
					systemctl daemon-reload || true
					log_success "Configs removed"
				fi
				;;
			2)
				echo "About to remove backups under $CICD_DIR/$BACKUPS_DIR"
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					rm -rf "$CICD_DIR/$BACKUPS_DIR/*" || true
					log_success "Backups removed"
				fi
				;;
			3)
				echo "About to remove credentials under $CICD_DIR/$CREDENTIALS_DIR"
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					rm -rf "$CICD_DIR/$CREDENTIALS_DIR/*" || true
					log_success "Credentials removed"
				fi
				;;
			4)
				echo "About to remove generated workflows under $CICD_DIR/$GENERATED_WORKFLOWS_DIR"
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					rm -rf "$CICD_DIR/$GENERATED_WORKFLOWS_DIR/*" || true
					log_success "Generated workflows removed"
				fi
				;;
			5)
				echo "About to remove sudoers entry and wrapper"
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					remove_sudoers_and_wrapper
				fi
				;;
			6)
				echo "About to remove packages via apt (this will prompt)."
				read -rp "Confirm (y/N): " yn
				if [[ "$yn" =~ ^[Yy]$ ]]; then
					apt-get remove -y openjdk-* postgresql-* redis-server nginx docker-ce docker-ce-cli containerd.io || true
					log_success "Attempted to remove listed packages"
				fi
				;;
			0)
				echo "Cancelled"
				;;
			*)
				echo "Unknown option: $c"
				;;
		esac
	done
}

run_diagnostics() {
	echo "=== Diagnostics report ==="
	echo "Script version: $SCRIPT_VERSION"
	echo "CICD_DIR: $CICD_DIR"
	echo
	echo "-- System --"
	uname -a
	echo
	echo "-- Services --"
	for s in nginx redis-server postgresql docker; do
		if systemctl list-unit-files | grep -qw "$s"; then
			printf "%s: %s\n" "$s" "installed"
			systemctl is-active --quiet "$s" && printf "  status: active\n" || printf "  status: inactive/stopped\n"
		else
			printf "%s: not installed\n" "$s"
		fi
	done
	echo
	echo "-- Ports in use (selected) --"
	ss -tuln | head -n 20
	echo
	echo "-- Generated artifacts --"
	ls -la "$CICD_DIR" || true
	echo
	echo "=== End diagnostics ==="
}


# -----------------------------------------------------------------------------
# Chunk 6: Secrets management, backups + retention, uninstall improvements,
#           headless / dry-run enforcement and help utilities
# -----------------------------------------------------------------------------
# Comments:
# - Secrets management: list-secrets (masked), show-secret (explicit prompt), rotate-secret.
# - Backups: create timestamped backups for config files; rotate by retention policy.
# - Uninstall: improved confirmations and dry-run support.
# - Headless / dry-run enforcement: dangerous operations require --allow-sudoers or --force.
# - Help: generic help function for menus and dangerous ops.
#
# Notes about design decisions are commented inline.

# Default backup retention (can be overridden by editing .cicd.conf manually)
BACKUP_KEEP_DEFAULT=7
BACKUP_KEEP_FILE="$CICD_DIR/$STATE_DIR/backup_keep"

# Helper: read backup retention from state or return default
get_backup_keep() {
	if [ -f "$BACKUP_KEEP_FILE" ]; then
		cat "$BACKUP_KEEP_FILE"
	else
		echo "$BACKUP_KEEP_DEFAULT"
	fi
}

# Set backup retention (persist)
set_backup_keep() {
	local n="$1"
	mkdir -p "$(dirname "$BACKUP_KEEP_FILE")"
	printf "%s" "$n" > "$BACKUP_KEEP_FILE"
	chmod 600 "$BACKUP_KEEP_FILE" || true
	log_success "Backup retention set to keep last $n backups"
}

# Create a backup for a given file or directory
# Usage: create_backup <path>
create_backup() {
	local src="$1"
	if [ -z "$src" ]; then
		log_error "create_backup requires a source path"
		return 1
	fi
	if [ ! -e "$src" ]; then
		log_warning "Source for backup does not exist: $src"
		return 1
	fi

	local ts
	ts=$(date +%Y%m%d%H%M%S)
	local base
	base="$(basename "$src")"
	local dest="$CICD_DIR/$BACKUPS_DIR/${base}.$ts.tar.gz"

	if [ "$DRY_RUN" = true ]; then
		log_info "DRY RUN: Would create backup of $src -> $dest"
		return 0
	fi

	mkdir -p "$CICD_DIR/$BACKUPS_DIR"
	tar -czf "$dest" -C "$(dirname "$src")" "$base"
	chmod 600 "$dest" || true
	log_success "Backup created: $dest"

	rotate_backups "$base"
}

# Rotate backups for a base name using retention policy
# Usage: rotate_backups <base>
rotate_backups() {
	local base="$1"
	local keep
	keep=$(get_backup_keep)
	# list backups sorted by time (newest first), drop the first $keep, delete the rest
	local files
	IFS=$'\n' read -r -d '' -a files < <(ls -1t "$CICD_DIR/$BACKUPS_DIR/${base}."* 2>/dev/null && printf '\0')
	if [ "${#files[@]}" -le "$keep" ]; then
		return 0
	fi
	local i
	for ((i=keep; i<${#files[@]}; i++)); do
		rm -f "${files[$i]}" || true
		log_info "Rotated old backup: ${files[$i]}"
	done
}

# List secrets (masked). Shows file names under credentials dir.
list_secrets() {
	local creddir="$CICD_DIR/$CREDENTIALS_DIR"
	if [ ! -d "$creddir" ]; then
		echo "(no credentials stored)"
		return 0
	fi
	echo "Stored credentials (masked):"
	for f in "$creddir"/*; do
		[ -e "$f" ] || continue
		local name
		name="$(basename "$f")"
		local val
		val="$(head -c 1 "$f" 2>/dev/null || true)"
		if [ -z "$val" ]; then
			printf "  %s: (empty)\n" "$name"
		else
			printf "  %s: %s\n" "$name" "$(head -c 1 "$f")*** (masked)\n"
		fi
	done
}

# Show a specific secret (explicit confirmation)
show_secret() {
	local key="$1"
	if [ -z "$key" ]; then
		log_error "show_secret requires a key name (filename under credentials/)"
		return 1
	fi
	local file="$CICD_DIR/$CREDENTIALS_DIR/$key"
	if [ ! -f "$file" ]; then
		log_warning "Secret not found: $file"
		return 1
	fi
	read -rp "Show secret '$key' on screen (sensitive)? [y/N] " yn
	yn="${yn:-N}"
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		echo "Secret ($key):"
		sed -n '1p' "$file"
	else
		log_info "Aborted showing secret."
	fi
}

# Rotate a secret: generate new value or prompt custom and apply
rotate_secret() {
	local key="$1"
	local mode="$2"  # optional: if special handling needed (redis -> apply)
	if [ -z "$key" ]; then
		log_error "rotate_secret requires a key name"
		return 1
	fi
	local newval
	newval=$(_generate_simple_password)
	echo "Suggested new value for $key: $newval"
	read -rp "Accept new value? [Y/n] " yn
	yn="${yn:-Y}"
	if [[ ! "$yn" =~ ^[Yy]$ ]]; then
		read -rp "Enter custom value: " newval
	fi
	local file="$CICD_DIR/$CREDENTIALS_DIR/$key"
	mkdir -p "$(dirname "$file")"
	if [ "$DRY_RUN" = true ]; then
		log_info "DRY RUN: Would write rotated secret to $file"
		return 0
	fi
	printf "%s" "$newval" > "$file"
	chmod 600 "$file"
	log_success "Secret rotated: $file"
	# If special modes: e.g., redis, reapply config
	if [ "$key" = "redis" ]; then
		if [ "${mode:-}" = "apt" ]; then
			apply_redis_password_apt "$newval"
		else
			apply_redis_password_docker "$newval"
		fi
	fi
}

# Improved uninstall wrapper which respects dry-run and headless flags
uninstall_action() {
	local what="$1"
	case "$what" in
		configs)
			echo "Will remove nginx/systemd configs for $SERVICE_NAME"
			read -rp "Confirm (this will remove files). [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would remove configs"
				else
					rm -f "/etc/nginx/sites-available/$SERVICE_NAME" || true
					rm -f "/etc/systemd/system/$SERVICE_NAME.service" || true
					systemctl daemon-reload || true
					log_success "Configs removed"
				fi
			fi
			;;
		backups)
			echo "Will remove backups under $CICD_DIR/$BACKUPS_DIR"
			read -rp "Confirm (all backups will be deleted). [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would delete backups"
				else
					rm -rf "$CICD_DIR/$BACKUPS_DIR" || true
					log_success "Backups removed"
				fi
			fi
			;;
		credentials)
			echo "Will remove credentials under $CICD_DIR/$CREDENTIALS_DIR"
			read -rp "Confirm (this is destructive). [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would delete credentials"
				else
					rm -rf "$CICD_DIR/$CREDENTIALS_DIR" || true
					log_success "Credentials removed"
				fi
			fi
			;;
		workflows)
			echo "Will remove generated workflows under $CICD_DIR/$GENERATED_WORKFLOWS_DIR"
			read -rp "Confirm. [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would delete workflows"
				else
					rm -rf "$CICD_DIR/$GENERATED_WORKFLOWS_DIR" || true
					log_success "Workflows removed"
				fi
			fi
			;;
		sudoers)
			echo "Will remove sudoers entry and wrapper"
			read -rp "Confirm. [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would remove sudoers & wrapper"
				else
					remove_sudoers_and_wrapper
				fi
			fi
			;;
		packages)
			echo "Will attempt to remove packages installed by the script (example list)"
			read -rp "Confirm (this will call apt-get remove) [y/N] " yn
			yn="${yn:-N}"
			if [[ "$yn" =~ ^[Yy]$ ]]; then
				if [ "$DRY_RUN" = true ]; then
					log_info "DRY RUN: would apt-get remove packages"
				else
					apt-get remove -y openjdk-* postgresql-* redis-server nginx docker-ce docker-ce-cli containerd.io || true
					log_success "Attempted to remove packages"
				fi
			fi
			;;
		*)
			log_warning "Unknown uninstall target: $what"
			return 1
			;;
	esac
}

# Small help system to print descriptions for menu options and dangerous actions
help_for() {
	local topic="$1"
	case "$topic" in
		redis)
			cat <<'HELP'
Redis configuration:
 - configure_redis <mode> where mode is 'apt' or 'docker'
 - The script will prompt to enable password auth and store credentials under:
	 $CICD_DIR/credentials/redis
 - Use rotate_redis_password <mode> to rotate and immediately apply.
HELP
			;;
		sudoers)
			cat <<'HELP'
Sudoers & wrapper:
 - The script can create a secure wrapper at /usr/local/sbin/cicd_restart_service
 - A whitelist file controls which systemd units may be restarted.
 - In auto/headless mode, creating sudoers requires --allow-sudoers flag.
HELP
			;;
		backups)
			cat <<'HELP'
Backups:
 - Backups are stored under $CICD_DIR/backups/
 - Use set_backup_keep <N> to set retention (default: 7)
 - The script auto-rotates old backups when creating new ones.
HELP
			;;
		*)
			echo "No help available for topic: $topic"
			;;
	esac
}

# Ensure functions are available to top-level interactive menu later.
# End of chunk 6


# End of chunk 6

# -----------------------------------------------------------------------------
# Chunk 7: Software Installers, Config Collection, and Main Orchestration
# -----------------------------------------------------------------------------
# Comments:
# - Defines the actual installation commands (apt/docker).
# - Implements the user prompts to populate variables (API_PORT, SERVICE_NAME, etc.).
# - Implements run_full_setup which calls all previous chunks in order.
# - Implements the interactive Main Menu loop.

# --- Software Installers ---

install_base_deps() {
	log_info "Installing base system dependencies (git, acl, curl, ufw)..."
	if [ "$DRY_RUN" = true ]; then
		log_info "DRY RUN: would apt-get install dependencies"
		return
	fi
	apt-get update -y >/dev/null
	apt-get install -y nginx ufw acl curl git gnupg2 lsb-release ca-certificates
	log_success "Base dependencies installed."
}

install_docker_engine() {
	if command -v docker &>/dev/null; then
		log_info "Docker already installed."
		return
	fi
	log_info "Installing Docker Engine..."
	if [ "$DRY_RUN" = true ]; then return; fi

	mkdir -p /etc/apt/keyrings
	if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	fi
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
	
	apt-get update -y >/dev/null
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	
	# Add target user to docker group if set
	if [ -n "$TARGET_USER" ]; then
		usermod -aG docker "$TARGET_USER"
	fi
	log_success "Docker installed."
}

install_postgresql_software() {
	local ver="$1"
	local db="$2"
	local user="$3"
	local pass="$4"

	log_info "Installing PostgreSQL $ver..."
	if [ "$DRY_RUN" = true ]; then return; fi

	# Add repo
	install -d /usr/share/postgresql-common/pgdg
	[ ! -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ] && curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
	sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
	apt-get update -y >/dev/null
	apt-get install -y "postgresql-$ver"

	# Configure DB
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user'" | grep -q 1; then
		sudo -u postgres psql -c "CREATE USER $user WITH PASSWORD '$pass';"
	fi
	if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db"; then
		sudo -u postgres psql -c "CREATE DATABASE $db OWNER $user;"
	fi

	# Secure Auth (SCRAM-SHA-256)
	local pg_conf="/etc/postgresql/$ver/main/pg_hba.conf"
	if [ -f "$pg_conf" ]; then
		# Check if we already added the host line
		if ! grep -q "host    all             all             127.0.0.1/32            scram-sha-256" "$pg_conf"; then
			echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$pg_conf"
			systemctl restart postgresql
		fi
	fi
	log_success "PostgreSQL $ver configured."
}

install_java_software() {
	local ver="$1"
	log_info "Installing OpenJDK $ver..."
	if [ "$DRY_RUN" = true ]; then return; fi
	apt-get install -y "openjdk-${ver}-jre-headless"
	log_success "Java installed."
}

install_node_software() {
	local ver="$1" # e.g. "lts" or specific version
	local user="$2"
	log_info "Installing Node.js ($ver) for $user via NVM..."
	if [ "$DRY_RUN" = true ]; then return; fi

	# Install NVM for user if missing
	if ! sudo -u "$user" bash -c '[ -s "$HOME/.nvm/nvm.sh" ]'; then
		sudo -u "$user" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
	fi
	
	# Install Node
	local flag="$ver"
	[ "$ver" == "lts" ] && flag="--lts"
	sudo -u "$user" bash -c "export NVM_DIR=\"\$HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\"; nvm install $flag; nvm alias default $ver"
	log_success "Node.js installed."
}

install_redis_software_apt() {
	log_info "Installing Redis (APT)..."
	if [ "$DRY_RUN" = true ]; then return; fi
	apt-get install -y redis-server
	# Ensure supervised by systemd
	sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
	systemctl restart redis-server
	log_success "Redis (APT) installed."
}

# --- Configuration Collection ---

collect_user_config() {
	log_info "Configuring runner user..."
	local default_user
	default_user=$(logname 2>/dev/null || echo "$SUDO_USER")
	read -rp "VPS Username (runner user) [$default_user]: " u
	TARGET_USER="${u:-$default_user}"

	if ! id "$TARGET_USER" &>/dev/null; then
		log_error "User $TARGET_USER does not exist. Please create it first."
		exit 1
	fi
	log_info "Target user: $TARGET_USER"
}

collect_app_config() {
	log_info "Configuring Application details..."
	
	read -rp "Service Name [spring-api-svc]: " sn
	export SERVICE_NAME="${sn:-spring-api-svc}"

	read -rp "Backend Folder Name [spring-api]: " an
	export API_NAME="${an:-spring-api}"
	export API_PATH="/var/www/$API_NAME"

	# Port conflict check
	echo "Checking port availability..."
	local valid_port
	valid_port=$(choose_port_interactive "8080")
	export API_PORT="$valid_port"

	read -rp "Spring Profile [staging]: " sp
	export SPRING_PROFILE="${sp:-staging}"

	read -rp "API Prefix [/api]: " ap
	export API_PREFIX="${ap:-/api}"

	# Java Memory
	echo "JVM Memory: 1) Small (256m) 2) Medium (512m) 3) Large (1G)"
	read -rp "Select [2]: " mem
	mem="${mem:-2}"
	case "$mem" in
		1) export JAVA_XMS="256m"; export JAVA_XMX="512m" ;;
		3) export JAVA_XMS="1024m"; export JAVA_XMX="2048m" ;;
		*) export JAVA_XMS="512m"; export JAVA_XMX="1024m" ;;
	esac

	# Frontend
	read -rp "Frontend Folder Name [react-ui]: " fn
	export UI_NAME="${fn:-react-ui}"
	export UI_PATH="/var/www/$UI_NAME"
	read -rp "Build output dir [dist]: " bd
	export BUILD_DIR="${bd:-dist}"
}

# --- The Orchestrator ---

run_full_setup() {
	log_section "Full Setup Sequence"
	
	# 1. Collect Config
	collect_user_config
	collect_app_config

	# 2. Database Config
	local install_pg="N"
	read -rp "Install PostgreSQL? [y/N] " yn
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		install_pg="Y"
		echo "Fetching versions..."
		local avail_ver
		avail_ver=$(fetch_postgresql_versions)
		# pick first word
		local default_ver
		default_ver=$(echo "$avail_ver" | awk '{print $1}')
		read -rp "Postgres Version [$default_ver]: " pg_ver
		pg_ver="${pg_ver:-$default_ver}"

		read -rp "DB Name [stock_db]: " db_name
		db_name="${db_name:-stock_db}"
		read -rp "DB User [stock_user]: " db_user
		db_user="${db_user:-stock_user}"
		
		# In auto mode, gen password, else prompt
		local db_pass
		if [ "$AUTO_MODE" = true ]; then
			db_pass=$(_generate_simple_password)
			log_info "Auto-generated DB Pass: $db_pass"
			save_secret "postgres_db_pass" "$db_pass"
		else
			echo "Enter Database Password:"
			db_pass=$(prompt_redis_password) # reusing the password prompt logic
		fi
		export DB_NAME="$db_name"
		export DB_USER="$db_user"
		export DB_PASS="$db_pass"
	fi

	# 3. Redis Config
	local install_redis="N"
	local redis_mode="apt"
	read -rp "Install Redis? [y/N] " yn
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		install_redis="Y"
		read -rp "Install via (1) Apt or (2) Docker? [1]: " rm_choice
		if [ "$rm_choice" = "2" ]; then
			redis_mode="docker"
			# Mark docker for install
			INSTALL_DOCKER="Y"
		fi
	fi

	# 4. RabbitMQ
	local install_rabbit="N"
	read -rp "Install RabbitMQ? [y/N] " yn
	if [[ "$yn" =~ ^[Yy]$ ]]; then install_rabbit="Y"; fi

	# 5. Runtimes
	local install_java="Y"
	read -rp "Install Java? [Y/n] " yn
	if [[ "$yn" =~ ^[Nn]$ ]]; then install_java="N"; fi
	
	local install_node="N"
	read -rp "Install Node.js? [y/N] " yn
	if [[ "$yn" =~ ^[Yy]$ ]]; then install_node="Y"; fi

	# 6. Sudoers Whitelist prep
	local whitelist_candidates=("$SERVICE_NAME")
	if [ "$install_redis" = "Y" ] && [ "$redis_mode" = "apt" ]; then
		whitelist_candidates+=("redis-server")
	fi
	if [ "$install_rabbit" = "Y" ]; then
		whitelist_candidates+=("rabbitmq-server")
	fi

	# --- Start Installation ---
	log_section "Applying Configuration"
	
	install_base_deps
	
	if [ "$INSTALL_DOCKER" = "Y" ] || [ "$install_redis" = "Y" ] && [ "$redis_mode" = "docker" ]; then
		install_docker_engine
	fi

	if [ "$install_pg" = "Y" ]; then
		install_postgresql_software "$pg_ver" "$db_name" "$db_user" "$db_pass"
	fi

	if [ "$install_redis" = "Y" ]; then
		if [ "$redis_mode" = "apt" ]; then
			install_redis_software_apt
		fi
		# Configure auth (interactive or auto)
		configure_redis "$redis_mode"
	fi

	if [ "$install_rabbit" = "Y" ]; then
		log_info "Installing RabbitMQ..."
		if [ "$DRY_RUN" = false ]; then
			apt-get install -y rabbitmq-server
			rabbitmq-plugins enable rabbitmq_management
		fi
	fi

	if [ "$install_java" = "Y" ]; then
		local jv
		jv=$(fetch_java_versions | awk '{print $1}') # default first
		read -rp "Java Version [$jv]: " sel_jv
		export JAVA_VER="${sel_jv:-$jv}"
		install_java_software "$JAVA_VER"
	fi

	if [ "$install_node" = "Y" ]; then
		local nv
		nv=$(fetch_node_versions | awk '{print $1}')
		install_node_software "$nv" "$TARGET_USER"
	fi

	# Whitelist
	log_info "Configuring sudoers whitelist..."
	for svc in "${whitelist_candidates[@]}"; do
		add_service_to_whitelist "$svc"
	done
	
	if [ "$AUTO_MODE" = false ]; then
		# Interactive prompt to finalize whitelist
		prompt_sudoers_whitelist_interactive
	elif [ "$ALLOW_SUDOERS" = true ]; then
		install_restart_wrapper
	fi

	# Templates
	log_info "Generating configuration templates..."
	# Ensure dirs
	mkdir -p "$API_PATH" "$UI_PATH"
	chown -R "$TARGET_USER":"$TARGET_USER" "$API_PATH" "$UI_PATH"
	
	# We pass variables via export to the render function
	render_all_templates

	# Firewall
	log_info "Configuring Firewall..."
	if [ "$DRY_RUN" = false ]; then
		# Detect SSH port to avoid lockout
		local ssh_port
		ssh_port=$(ss -tlpn | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
		ssh_port=${ssh_port:-22}
		
		ufw allow "$ssh_port/tcp"
		ufw allow 80/tcp
		ufw allow 443/tcp
		echo "Firewall rules updated. Run 'ufw enable' manually."
	fi

	log_success "Full setup complete!"
	log_info "Artifacts stored in: $CICD_DIR"
}

# --- Main Menu Loop ---

show_menu() {
	echo "=========================================="
	echo " CICD Setup Manager v${SCRIPT_VERSION}"
	echo " Storage: $CICD_DIR"
	echo "=========================================="
	echo " 1) 🚀 Full Setup"
	echo " 2) 📝 Regenerate Templates (Configs/Workflows)"
	echo " 3) 🔐 Secrets Management"
	echo " 4) 📦 Uninstall / Cleanup"
	echo " 5) 📊 Diagnostics"
	echo " 6) ❓ Help"
	echo " 0) Exit"
	echo "=========================================="
	read -rp "Select option: " opt
	case "$opt" in
		1) run_full_setup ;;
		2) 
		   # Need basic config variables to render
		   if [ -z "$SERVICE_NAME" ]; then
			   log_warning "Service name not set. Running abbreviated config collection."
			   collect_user_config
			   collect_app_config
		   fi
		   render_all_templates 
		   ;;
		3) 
		   echo "Secrets: 1) List 2) Show 3) Rotate"
		   read -rp "Choice: " sc
		   case "$sc" in
			   1) list_secrets ;;
			   2) read -rp "Secret name: " sn; show_secret "$sn" ;;
			   3) read -rp "Secret name: " sn; rotate_secret "$sn" ;;
		   esac
		   ;;
		4) uninstall_menu ;;
		5) run_diagnostics ;;
		6) 
		   echo "Topics: redis, sudoers, backups"
		   read -rp "Topic: " t
		   help_for "$t" 
		   ;;
		0) exit 0 ;;
		*) log_error "Invalid option" ;;
	esac
}

# -----------------------------------------------------------------------------
# Script Entry Point
# -----------------------------------------------------------------------------

# If executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# Parse args (already done in chunk 1 main_chunk1, but re-run if this logic flows sequentially)
	# Since main_chunk1 handles init, we call it if we haven't already.
	# However, structure suggests we are appending. 
	# Let's ensure main_chunk1 was run.
	
	if [ -z "$CICD_DIR" ]; then
		main_chunk1 "$@"
	fi

	# If AUTO_MODE is true, run setup and exit
	if [ "$AUTO_MODE" = true ]; then
		run_full_setup
		exit 0
	fi

	# Interactive Loop
	while true; do
		show_menu
		echo
		read -rp "Press Enter to continue..."
	done
fi