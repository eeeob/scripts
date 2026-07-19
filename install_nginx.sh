#!/bin/bash

# ==============================================================================
# Nginx Install Script (Ubuntu 20.04 / 22.04 / 24.04)
# التثبيت من المصادر الرسمية فقط: nginx.org أو صورة nginx الرسمية عبر Docker Compose
# الاعدادات الأساسية تعمل خلف Cloudflare (Full strict) مع locations في ملفات منفصلة
# قابل لإعادة التشغيل أكثر من مرة بدون مشاكل، وآمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_nginx.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# تمرير -d example.com يحدد الدومين بدون سؤال تفاعلي
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)

CONFIG_DIR="/root/.configs/nginx"
CONFIG_FILE="$CONFIG_DIR/nginx_install.conf"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
CLEANUP_SCRIPT="$CONFIG_DIR/cleanup.sh"
CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"
CONTAINER_NAME="nginx"
INSTALL_METHOD="native"
SERVER_NAME=""
RESTART_COMMAND=""

NGINX_CONF_DIR="/etc/nginx/conf.d"
LOCATIONS_DIR="/etc/nginx/locations"
CERTS_DIR="/etc/nginx/certs"
CERT_FILE="$CERTS_DIR/cloudflare-origin.pem"
KEY_FILE="$CERTS_DIR/cloudflare-origin.key"

# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

# الأعلام الخاصة بالسكربت
while getopts "d:" opt; do
    case "${opt}" in
        d) SERVER_NAME="${OPTARG}" ;;
        *) echo "Usage: $0 [-y|-n] [-d domain]"; exit 1 ;;
    esac
done

# --- كشف تثبيت سابق موجود فعلياً لكن غير موثق في ملف config (حالة مخفية) ---
detect_previous_installation() {
    local found=""

    dpkg -s nginx >/dev/null 2>&1 && found="native package 'nginx'"

    if command -v docker >/dev/null 2>&1 && _container_exists "$CONTAINER_NAME"; then
        found="${found:+$found + }Docker container '$CONTAINER_NAME'"
    fi

    [ -z "$found" ] && return 0

    print_warning "Existing Nginx installation detected on this server: $found."

    if ! _confirm "Continue and reconfigure on top of the existing installation? (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi
}

# --- تخيير المستخدم بين التثبيت المباشر أو داخل Docker ---
choose_install_method() {
    print_step "Choose installation method"
    print_info "Native = official apt repo (nginx.org). Docker = official 'nginx' image via compose."

    if _confirm "Install Nginx inside Docker instead of the native installation? (y/n): "; then
        INSTALL_METHOD="docker"
    else
        INSTALL_METHOD="native"
    fi
}

# --- التحقق من أن البورتين 80 و 443 غير مستخدمين من خدمات أخرى ---
check_ports() {
    print_step "Checking ports 80 and 443"

    local port holder blocked=""
    for port in 80 443; do
        holder=$(sudo ss -tlnpH "( sport = :$port )" 2>/dev/null | grep -v nginx || true)
        if [ -n "$holder" ]; then
            print_warning "Port $port is already in use by another service:"
            echo "$holder"
            blocked="yes"
        fi
    done

    if [ -z "$blocked" ]; then
        print_info "Ports 80 and 443 are free (or already used by Nginx itself)."
        return 0
    fi

    echo
    if ! _confirm "Continue anyway? Nginx may fail to start. (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi
}

# --- التأكد من تحديد الدومين ---
ensure_domain() {
    if [ -n "$SERVER_NAME" ]; then
        _check_variable_required "SERVER_NAME" "$SERVER_NAME" '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    else
        _prompt_required "Enter your domain (e.g. example.com): " SERVER_NAME '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    fi
    print_info "Domain: $SERVER_NAME"
}

# --- التأكد من وجود شهادة Cloudflare Origin أو توفير بديل مؤقت ---
ensure_certificates() {
    print_step "Checking TLS certificates"

    if sudo test -f "$CERT_FILE" && sudo test -f "$KEY_FILE"; then
        print_info "Existing certificates found in $CERTS_DIR. Keeping them."
        return 0
    fi

    sudo mkdir -p "$CERTS_DIR"

    if _confirm "Paste your Cloudflare Origin certificate and key now? (y/n): "; then
        sudo touch "$CERT_FILE" "$KEY_FILE"
        sudo chmod 600 "$KEY_FILE"
        _prompt_paste_file "Paste the Cloudflare Origin CERTIFICATE (PEM) then save and exit" "$CERT_FILE"
        _prompt_paste_file "Paste the Cloudflare Origin PRIVATE KEY then save and exit" "$KEY_FILE"

        if ! sudo test -s "$CERT_FILE" || ! sudo test -s "$KEY_FILE"; then
            print_error "Certificate or key file is still empty. Nginx will fail to start on 443."
            exit 1
        fi
    else
        # شهادة self-signed مؤقتة حتى يعمل nginx، تُستبدل لاحقاً بشهادة Cloudflare الحقيقية
        print_warning "Generating a TEMPORARY self-signed certificate so Nginx can start..."
        sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SERVER_NAME}" >/dev/null 2>&1
        sudo chmod 600 "$KEY_FILE"
        print_warning "Replace it later with your real Cloudflare Origin certificate:"
        print_warning "  $CERT_FILE"
        print_warning "  $KEY_FILE"
    fi
}

# --- نشر ملفات الاعدادات (مشتركة بين الوضعين native و docker) ---
deploy_nginx_config() {
    print_step "Deploying Nginx configuration"

    sudo mkdir -p "$NGINX_CONF_DIR" "$LOCATIONS_DIR" "$CERTS_DIR"

    # الاعدادات الأساسية (خلف Cloudflare) مع استبدال الدومين
    _render_template_file "$ASSETS_DIR/nginx/conf/default.conf.template" "$NGINX_CONF_DIR/default.conf" \
        SERVER_NAME="$SERVER_NAME"

    # تعريف $is_cloudflare (يُحمّل قبل default.conf أبجدياً)
    sudo cp "$ASSETS_DIR/nginx/conf/cloudflare.conf" "$NGINX_CONF_DIR/cloudflare.conf"

    # مثال جاهز لملف location منفصل (لا يُحمّل لأن امتداده .example)
    sudo cp "$ASSETS_DIR/nginx/locations-examples/api_proxy.conf.example" "$LOCATIONS_DIR/"

    print_info "Base config deployed to $NGINX_CONF_DIR/default.conf"
    print_info "Put your per-service location blocks in $LOCATIONS_DIR/*.conf"
}

# --- التثبيت المباشر من المستودع الرسمي ---
install_native() {
    print_step "Installing Nginx (native, official nginx.org repo)"

    curl -fsSL https://nginx.org/keys/nginx_signing.key | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${UBUNTU_CODENAME} nginx" | \
        sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null

    sudo apt-get update -y
    sudo apt-get install -y nginx

    deploy_nginx_config

    print_info "Testing Nginx configuration..."
    sudo nginx -t

    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl restart nginx

    RESTART_COMMAND="sudo systemctl restart nginx"
}

# --- التثبيت داخل Docker عبر compose من الصورة الرسمية ---
install_in_docker() {
    print_step "Installing Nginx (Docker Compose, official image)"

    _install_docker

    deploy_nginx_config

    # ملف compose الحقيقي يُحفظ في /root/.configs/nginx ويبقى للاستخدام لاحقاً
    sudo mkdir -p "$CONFIG_DIR"
    sudo cp "$ASSETS_DIR/nginx/docker-compose.yml" "$COMPOSE_FILE"
    print_info "Compose file saved to $COMPOSE_FILE"

    print_info "Testing Nginx configuration inside a temporary container..."
    sudo docker run --rm \
        -v "$NGINX_CONF_DIR":/etc/nginx/conf.d:ro \
        -v "$LOCATIONS_DIR":/etc/nginx/locations:ro \
        -v "$CERTS_DIR":/etc/nginx/certs:ro \
        nginx:stable nginx -t

    if _handle_existing_container "$CONTAINER_NAME"; then
        sudo docker compose -f "$COMPOSE_FILE" up -d
        print_info "Nginx container started on ports 80 and 443."
    else
        sudo docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        print_info "Existing container kept and started."
    fi

    RESTART_COMMAND="sudo docker compose -f $COMPOSE_FILE restart"
}

# --- التحقق من نجاح التثبيت ---
verify_installation() {
    print_step "Verify installation"

    if [ "$INSTALL_METHOD" = "native" ]; then
        nginx -v 2>&1 | head -n 1
        NGINX_FULL_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")

        if sudo systemctl is-active --quiet nginx; then
            print_info "Nginx service is running."
        else
            print_error "Nginx service is NOT running. Check: sudo journalctl -u nginx -e"
            exit 1
        fi
    else
        sudo docker ps --filter "name=^${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
        NGINX_FULL_VERSION=$(sudo docker exec "$CONTAINER_NAME" nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")

        if ! sudo docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
            print_error "Nginx container is NOT running. Check: sudo docker logs $CONTAINER_NAME"
            exit 1
        fi
        print_info "Nginx container is running."
    fi

    # فحص استجابة HTTP فعلي (المتوقع 301 لأن البورت 80 يحول إلى HTTPS)
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/" -H "Host: $SERVER_NAME" || echo "000")
    print_info "HTTP check on 127.0.0.1:80 returned status: $http_code (301 is expected)"
}

# --- كتابة ملف config يوثق تفاصيل التثبيت مع توليد سكربت التصفية ---
write_config() {
    print_step "Writing config file"

    sudo mkdir -p "$CONFIG_DIR"

    # توليد سكربت التصفية الحقيقي المطابق لطريقة التثبيت الحالية
    if [ "$INSTALL_METHOD" = "native" ]; then
        _render_template_file "$ASSETS_DIR/nginx/cleanup_native.sh.template" "$CLEANUP_SCRIPT" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    else
        _render_template_file "$ASSETS_DIR/nginx/cleanup_docker.sh.template" "$CLEANUP_SCRIPT" \
            COMPOSE_FILE="$COMPOSE_FILE" \
            CONTAINER_NAME="$CONTAINER_NAME" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    fi
    sudo chmod +x "$CLEANUP_SCRIPT"

    _render_template_file "$ASSETS_DIR/nginx/nginx_install.conf.template" "$CONFIG_FILE" \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        INSTALL_METHOD="$INSTALL_METHOD" \
        NGINX_VERSION="$NGINX_FULL_VERSION" \
        SERVER_NAME="$SERVER_NAME" \
        RESTART_COMMAND="$RESTART_COMMAND" \
        CLEANUP_COMMAND="bash $CLEANUP_SCRIPT"

    print_info "Config saved to $CONFIG_FILE"
}

# --- إضافة معلومات استخدام سريعة لشاشة الدخول عبر SSH (من template في configs) ---
add_ssh_quick_info() {
    print_step "Adding quick usage info to the SSH login screen"

    local test_command="sudo nginx -t"
    [ "$INSTALL_METHOD" = "docker" ] && test_command="sudo docker exec $CONTAINER_NAME nginx -t"

    _add_motd_info "nginx" "$ASSETS_DIR/nginx/motd-info.sh.tmpl" \
        SERVER_NAME="$SERVER_NAME" \
        RESTART_COMMAND="$RESTART_COMMAND" \
        TEST_COMMAND="$test_command" \
        LOCATIONS_DIR="$LOCATIONS_DIR" \
        CERT_FILE="$CERT_FILE" \
        CONFIG_FILE="$CONFIG_FILE"

    print_info "Quick usage info will appear on the next SSH login."
}

UBUNTU_CODENAME=$(_get_ubuntu_codename "20.04 22.04 24.04")
print_info "Detected supported Ubuntu release: $UBUNTU_CODENAME"

_handle_existing_config_file "$CONFIG_FILE"
detect_previous_installation
choose_install_method
check_ports
ensure_domain

_install_dependencies gnupg ca-certificates openssl

# جلب الملفات المساعدة من مشروع configs إلى مجلد مؤقت يُحذف عند الخروج
ASSETS_DIR=$(mktemp -d)
trap 'rm -rf "$ASSETS_DIR"' EXIT
_download_github_path "$CONFIGS_REPO_URL" "nginx" "$ASSETS_DIR/nginx"

ensure_certificates

if [ "$INSTALL_METHOD" = "native" ]; then
    install_native
else
    install_in_docker
fi

verify_installation
write_config
add_ssh_quick_info

print_step "Nginx setup completed successfully"
print_info "Restart command: $RESTART_COMMAND"
