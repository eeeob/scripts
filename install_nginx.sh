#!/bin/bash

# ==============================================================================
# Nginx Install Script (Ubuntu 20.04 / 22.04 / 24.04)
# التثبيت من المصادر الرسمية فقط: nginx.org أو صورة nginx الرسمية عبر Docker Compose
# الاعتماد على Cloudflare (Full strict) اختياري، مع locations في ملفات منفصلة
# قابل لإعادة التشغيل أكثر من مرة بدون مشاكل، وآمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_nginx.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# تمرير -d example.com يحدد الدومين بدون سؤال تفاعلي
# تمرير native أو docker يحدد طريقة التثبيت
# تمرير cloudflare يفعّل وضع Cloudflare، و no-cloudflare يعطّله (وبدونهما يُسأل المستخدم)
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)


# ==============================================================================
# Variables - المتغيرات والمسارات
# ==============================================================================

#shared
CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"

TEMP_CONFIG_DIR="/root/.temp_configs/nginx"
CONFIG_DIR="/root/.configs/nginx"

CONFIG_FILE="$CONFIG_DIR/nginx_install.conf"

LOCATIONS_DIR="$CONFIG_DIR/locations"
CERTS_DIR="$CONFIG_DIR/certs"

CLIENT_MAX_BODY_SIZE="20M"

#غير قابل للتعديل
NGINX_CONFIG_DIR="/etc/nginx/conf.d"

# تُضبط أثناء التشغيل حسب اختيارات المستخدم (وسيط ممرَّر أو سؤال تفاعلي)
SERVER_NAME=""        # الدومين
INSTALL_METHOD=""     # native | docker
CLOUDFLARE=""         # yes | no

#docker
DOCKER_COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
DOCKER_CONTAINER_NAME="nginx"
DOCKER_NETWORK_NAME="main_network"


# ==============================================================================
# Arguments - قراءة الأعلام والوسائط
# ==============================================================================

# الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

# الوسائط الخاصة بهذا السكربت: -d للدومين، وطريقة التثبيت، والاعتماد على Cloudflare
_parse_flag_value "d" SERVER_NAME "$@"
_parse_choice_value "native docker" INSTALL_METHOD "$@"
_parse_choice_value "cloudflare=yes no-cloudflare=no" CLOUDFLARE "$@"


# ==============================================================================
# Pre-flight checks - تحققات ما قبل التثبيت
# ==============================================================================

# كشف تثبيت nginx سابق (native أو docker) وتصفيته بالكامل بالطرق الرسمية عند موافقة المستخدم
detect_previous_installation() {
    local found_native="no"
    local found_docker="no"
    local found=""

    if _package_installed nginx || _service_exists nginx; then
        found_native="yes"
        found="native package 'nginx'"
    fi

    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        found_docker="yes"
        found="${found:+$found + }Docker container '$DOCKER_CONTAINER_NAME'"
    fi

    [ -z "$found" ] && return 0

    print_warning "Existing Nginx installation detected on this server: $found."

    if ! _confirm "Remove the existing installation completely (official cleanup) and reinstall from scratch? (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi

    print_step "Removing the existing Nginx installation (official cleanup)"

    # تصفية التثبيت المباشر بالطرق الرسمية (إيقاف الخدمة، إزالة الحزم والمصادر والاعدادات)
    # ملاحظة: يتم الإبقاء على مجلد الشهادات لتجنب فقدان الشهادة (Cloudflare Origin أو الموقّعة ذاتياً)
    if [ "$found_native" = "yes" ]; then
        print_info "Cleaning up the native Nginx installation..."
        _destroy_service "nginx"
        sudo apt-get purge -y nginx 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/nginx.list
        sudo rm -f /usr/share/keyrings/nginx-archive-keyring.gpg
    fi

    # تصفية تثبيت Docker (حذف الحاوية مع صورتها وشبكاتها الخاصة)
    if [ "$found_docker" = "yes" ]; then
        print_info "Cleaning up the Docker Nginx installation..."
        _remove_container "$DOCKER_CONTAINER_NAME"
        rm -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/cloudflare.conf
    fi

    rm -rf "${CONFIG_DIR}" "${NGINX_CONFIG_DIR}" "${LOCATIONS_DIR}" "${CERTS_DIR}"

    print_info "Existing Nginx installation removed. Continuing with a fresh setup..."
}

# التأكد أن البورتين 80 و 443 خاليان تماماً من أي خدمة (حتى nginx نفسها)
# وجود أي خدمة تستمع على أيٍّ منهما يوقف السكربت مباشرة دون سؤال
check_ports() {
    print_step "Checking ports 80 and 443"

    local port holder blocked=""

    for port in 80 443; do
        holder=$(sudo ss -tlnpH "( sport = :$port )" 2>/dev/null || true)
        if [ -n "$holder" ]; then
            print_warning "Port $port is already in use:"
            echo "$holder"
            blocked="yes"
        fi
    done

    if [ -n "$blocked" ]; then
        print_error "Ports 80 and 443 must be completely free before installing. Stop the service(s) above and re-run. Aborting."
        exit 1
    fi

    print_info "Ports 80 and 443 are free."
}


prompt_missing_inputs() {
    print_step "Collecting setup inputs"

    # الدومين
    if [ -n "$SERVER_NAME" ]; then
        _check_variable_required "SERVER_NAME" "$SERVER_NAME" '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    else
        _prompt_required "Enter your domain (e.g. example.com): " SERVER_NAME '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    fi
    print_info "Domain: $SERVER_NAME"


    # الاعتماد على Cloudflare
    if [ -z "$CLOUDFLARE" ]; then
        if _confirm "Run Nginx behind Cloudflare (verify Cloudflare IPs + restore real client IP)? (y/n): "; then
            CLOUDFLARE="yes"
        else
            CLOUDFLARE="no"
        fi
    fi

    if [ "$CLOUDFLARE" = "yes" ]; then
        print_info "Cloudflare mode: enabled (IP ranges fetched fresh on every run)."
    else
        print_info "Cloudflare mode: disabled (all source IPs allowed)."
    fi

    # طريقة التثبيت
    if [ -z "$INSTALL_METHOD" ]; then
        print_info "Native = official apt repo (nginx.org). Docker = official 'nginx' image via compose."

        if _confirm "Install Nginx inside Docker instead of the native installation? (y/n): "; then
            INSTALL_METHOD="docker"
        else
            INSTALL_METHOD="native"
        fi
    fi
    print_info "Install method: $INSTALL_METHOD"

    
}


_ensure_cloudflare_certificate() {
    print_info "Cloudflare mode: a Cloudflare Origin certificate and key are required for HTTPS on port 443."

    local cert_file="$CERTS_DIR/origin.pem"
    local key_file="$CERTS_DIR/origin.key"

    _prompt_paste_file "Paste the Cloudflare Origin CERTIFICATE (PEM) then save and exit" "$cert_file" true
    _prompt_paste_file "Paste the Cloudflare Origin PRIVATE KEY then save and exit" "$key_file" true

    if ! sudo test -s "$cert_file" || ! sudo test -s "$key_file"; then
        print_error "Certificate or key is empty. A valid Cloudflare Origin certificate is mandatory. Aborting."
        exit 1
    fi

    sudo chmod 600 "$key_file"

    print_info "Cloudflare Origin certificate saved to $CERTS_DIR."
}
_generate_self_signed_certificate() {
    print_info "No Cloudflare: generating a self-signed certificate automatically..."

    local cert_file="$CERTS_DIR/origin.pem"
    local key_file="$CERTS_DIR/origin.key"

    _ensure_packages openssl

    sudo rm -rf "$CERTS_DIR"
    sudo mkdir -p "$CERTS_DIR"

    sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$key_file" -out "$cert_file" -subj "/CN=${SERVER_NAME}" >/dev/null 2>&1
    sudo chmod 600 "$key_file"

    print_info "Self-signed certificate generated at $CERTS_DIR."
}

_generate_cloudflare_config() {
    print_info "Fetching Cloudflare IP ranges..."

    local cf_ipv4 cf_ipv6

    cf_ipv4=$(curl -fsSL https://www.cloudflare.com/ips-v4 || echo "")
    cf_ipv6=$(curl -fsSL https://www.cloudflare.com/ips-v6 || echo "")

    if [ -z "$cf_ipv4" ] || [ -z "$cf_ipv6" ]; then
        print_error "Failed to fetch Cloudflare IP ranges. Aborting to avoid a misconfigured origin."
        exit 1
    fi

    local ip set_real_ip_from="" geo_entries=""

    for ip in $cf_ipv4 $cf_ipv6; do
        set_real_ip_from+="set_real_ip_from ${ip};"$'\n'
        geo_entries+="    ${ip} 1;"$'\n'
    done

    set_real_ip_from="${set_real_ip_from%$'\n'}"
    geo_entries="${geo_entries%$'\n'}"

    print_info "Updating Cloudflare IP ranges in $NGINX_CONFIG_DIR/cloudflare.conf"

    _render_template_file "$TEMP_CONFIG_DIR/conf/cloudflare.conf.template" "$NGINX_CONFIG_DIR/cloudflare.conf" \
        SET_REAL_IP_FROM="$set_real_ip_from" \
        GEO_ENTRIES="$geo_entries"
}
_deploy_nginx_config() {
    print_step "Deploying Nginx configuration"

    local conf_file

    if [ "$CLOUDFLARE" = "yes" ]; then
        _ensure_cloudflare_certificate
        _generate_cloudflare_config

        conf_file="$TEMP_CONFIG_DIR/conf/default_cloudflare.conf.template"
    else
        _generate_self_signed_certificate

        conf_file="$TEMP_CONFIG_DIR/conf/default.conf.template"

    fi

    _render_template_file "$conf_file" "$NGINX_CONFIG_DIR/default.conf" \
        LOCATIONS_DIR CERTS_DIR SERVER_NAME CLIENT_MAX_BODY_SIZE

    print_info "Base config deployed to $NGINX_CONFIG_DIR/default.conf"
}


# ==============================================================================
# Installation: Native - التثبيت المباشر من مستودع nginx.org
# ==============================================================================

install_native() {
    if _package_installed nginx || _service_exists nginx; then
        print_error "A native Nginx installation still exists. Aborting to avoid a broken setup."
        exit 1
    fi

    print_step "Installing Nginx (native, official nginx.org repo)"

    _deploy_nginx_config
    _install_dependencies nginx

    if _package_installed ufw; then
        sudo ufw allow 'Nginx Full'
    fi

    
    print_info "Testing Nginx configuration..."
    sudo nginx -t

    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl restart nginx

    _wait_for_service "nginx" 20

    print_info "Nginx is running (native) on ports 80 and 443."
}


# ==============================================================================
# Installation: Docker - التثبيت عبر Docker Compose من الصورة الرسمية
# ==============================================================================

install_in_docker() {
    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        print_error "A Docker container named '$DOCKER_CONTAINER_NAME' still exists. Aborting to avoid a conflict."
        exit 1
    fi

    print_step "Installing Nginx (Docker Compose, official image)"

    _install_docker
    _create_docker_network
    _deploy_nginx_config

    _render_template_file "$TEMP_CONFIG_DIR/docker-compose.yml.template" "$DOCKER_COMPOSE_FILE" \
        NGINX_CONFIG_DIR LOCATIONS_DIR CERTS_DIR \
        CONTAINER_NAME="$DOCKER_CONTAINER_NAME" \
        NETWORK_NAME="$DOCKER_NETWORK_NAME" \

    print_info "Compose file saved to $DOCKER_COMPOSE_FILE"

    sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    _wait_for_container "$DOCKER_CONTAINER_NAME" 30

    print_info "Nginx container started on ports 80 and 443."
}

run_installation() {
    if [ "$INSTALL_METHOD" = "docker" ]; then
        install_in_docker
    else
        install_native
    fi
}


# ==============================================================================
# Post-install - التوثيق (ملف config + معلومات MOTD)
# ==============================================================================

# كتابة ملف config يوثق تفاصيل التثبيت مع توليد سكربت التصفية
write_config() {
    print_step "Writing config file"

    local cleanup_script="$CONFIG_DIR/cleanup.sh"

    local docker_container_name=""
    local docker_network_name=""

    # توليد سكربت التصفية الحقيقي المطابق لطريقة التثبيت الحالية
    if [ "$INSTALL_METHOD" = "native" ]; then
        
        _render_template_file "$TEMP_CONFIG_DIR/cleanup_native.sh.template" "$cleanup_script" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    else
        docker_container_name="$DOCKER_CONTAINER_NAME"
        docker_network_name="$DOCKER_NETWORK_NAME"
        

        _render_template_file "$TEMP_CONFIG_DIR/cleanup_docker.sh.template" "$cleanup_script" \
            COMPOSE_FILE="$DOCKER_COMPOSE_FILE" \
            CONTAINER_NAME="$DOCKER_CONTAINER_NAME" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    fi
    sudo chmod +x "$cleanup_script"

    _render_template_file "$TEMP_CONFIG_DIR/nginx_install.conf.template" "$CONFIG_FILE" \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        INSTALL_METHOD="$INSTALL_METHOD" \
        SERVER_NAME="$SERVER_NAME" \
        CLOUDFLARE="$CLOUDFLARE" \
        RESTART_COMMAND="$RESTART_COMMAND" \
        CLEANUP_COMMAND="bash $cleanup_script" \
        DOCKER_CONTAINER_NAME="$docker_container_name" \
        DOCKER_NETWORK_NAME="$docker_network_name"

    print_info "Config saved to $CONFIG_FILE"
}

# إضافة معلومات استخدام سريعة لشاشة الدخول عبر SSH (من template في configs)
add_ssh_quick_info() {
    print_step "Adding quick usage info to the SSH login screen"

    local test_command="sudo nginx -t"
    [ "$INSTALL_METHOD" = "docker" ] && test_command="sudo docker exec $DOCKER_CONTAINER_NAME nginx -t"

    _add_motd_info "nginx" "$TEMP_CONFIG_DIR/motd-info.sh.tmpl" \
        SERVER_NAME="$SERVER_NAME" \
        TEST_COMMAND="$test_command" \
        LOCATIONS_DIR="$LOCATIONS_DIR" \
        CONFIG_FILE="$CONFIG_FILE"

    print_info "Quick usage info will appear on the next SSH login."
}




trap 'rm -rf "$TEMP_CONFIG_DIR"' EXIT

_handle_existing_config_file "$CONFIG_FILE"
detect_previous_installation
check_ports
prompt_missing_inputs

_download_github_path "$CONFIGS_REPO_URL" "nginx" "$TEMP_CONFIG_DIR"

run_installation

write_config
add_ssh_quick_info

print_step "Nginx setup completed successfully"