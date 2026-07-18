#!/bin/bash

# ==============================================================================
# UFW Firewall Setup Script
# يقوم بتفعيل UFW مع إبقاء SSH مفتوحاً، مع فحص الخدمات المتأثرة والقواعد القديمة
# آمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/setup_ufw.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)

CONFIG_DIR="/root/.configs"
CONFIG_FILE="$CONFIG_DIR/ufw_setup.conf"
CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"
SSH_PORT="22"
OLD_RULES_RESET="no"

# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

# --- التحقق من وجود ملف config قديم من تشغيل سابق ---
check_existing_config() {
    sudo test -f "$CONFIG_FILE" || return 0

    print_step "Existing configuration detected"
    print_warning "A previous UFW setup config was found at: $CONFIG_FILE"
    echo
    sudo cat "$CONFIG_FILE"
    echo

    if _confirm "Delete the old config and redo the setup from scratch? (y/n): "; then
        sudo rm -f "$CONFIG_FILE"
        print_info "Old config deleted. Continuing with a fresh setup..."
    else
        print_info "Keeping the existing setup. Exiting without changes."
        exit 0
    fi
}

# --- التحقق من وجود قواعد UFW قديمة وتخيير المستخدم بإلغائها ---
check_old_rules() {
    print_step "Checking existing UFW rules"

    local old_rules
    old_rules=$(sudo ufw status numbered | grep -E '^\[' || true)

    if [ -z "$old_rules" ]; then
        print_info "No existing UFW rules found."
        return 0
    fi

    print_warning "Existing UFW rules were found:"
    echo
    sudo ufw status numbered
    echo

    if _confirm "Reset (delete) these old rules and continue? (y/n): "; then
        print_info "Resetting UFW to defaults..."
        sudo ufw --force reset >/dev/null
        OLD_RULES_RESET="yes"
        print_info "Old rules removed."
    else
        print_info "Keeping existing rules and continuing."
    fi
}

# --- فحص الخدمات المستمعة التي ستتأثر بتفعيل الجدار الناري ---
check_affected_services() {
    print_step "Checking services that may be affected"

    local affected
    affected=$(sudo ss -tulnpH 2>/dev/null | awk -v ssh="$SSH_PORT" -f "$ASSETS_DIR/ufw/affected_services.awk")

    if [ -z "$affected" ]; then
        print_info "No public listening services found other than SSH. Safe to enable."
        return 0
    fi

    print_warning "The following listening services will be BLOCKED for incoming connections after enabling UFW:"
    echo
    echo "$affected"
    echo
    print_info "SSH (port $SSH_PORT) will remain allowed via the OpenSSH profile."

    if ! _confirm "Do you want to continue and enable UFW anyway? (y/n): "; then
        print_info "Aborted by user. No changes were made to the firewall."
        exit 0
    fi
}

# --- تفعيل UFW مع السماح لـ SSH ---
enable_ufw() {
    print_step "Enabling UFW"

    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    sudo ufw allow OpenSSH >/dev/null
    print_info "Allowed SSH via the OpenSSH application profile."

    sudo ufw --force enable
    print_info "UFW is now active."
    echo
    sudo ufw status verbose
}

# --- كتابة ملف config يوثق الإعدادات المطبقة ---
write_config() {
    print_step "Writing config file"

    sudo mkdir -p "$CONFIG_DIR"

    _render_template_file "$ASSETS_DIR/ufw/ufw_setup.conf.template" "$CONFIG_FILE" \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        SSH_PORT="$SSH_PORT" \
        OLD_RULES_RESET="$OLD_RULES_RESET"

    print_info "Config saved to $CONFIG_FILE"
}

check_existing_config
_install_dependencies ufw gettext-base

# اكتشاف بورت SSH الفعلي عبر الدالة العامة في utils.sh
SSH_PORT=$(_detect_ssh_port)
print_info "Detected SSH port: $SSH_PORT"

# جلب الملفات المساعدة من مشروع configs إلى مجلد مؤقت يُحذف عند الخروج
# لا يبقى على السيرفر إلا ملف الاعدادات النهائي الحقيقي في /root/.configs
ASSETS_DIR=$(mktemp -d)
trap 'rm -rf "$ASSETS_DIR"' EXIT
_download_github_path "$CONFIGS_REPO_URL" "ufw" "$ASSETS_DIR/ufw"

check_old_rules
check_affected_services
enable_ufw
write_config

sudo rm -rf $ASSETS_DIR

print_step "UFW setup completed successfully"



