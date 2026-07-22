#!/usr/bin/env bash

# ==============================================================================
# utils.sh - دوال مشتركة لسكربتات مشروع scripts
# مقسّمة إلى أقسام حسب الخدمة/الوظيفة
# ==============================================================================

# لقطة بأسماء كل الدوال المعرّفة قبل تحميل هذا الملف (تُستخدم في نهاية الملف
# لاستخراج أسماء دوال utils.sh فقط عبر المقارنة، دون قائمة ثابتة يدوية)
_UTILS_PRELOAD_FUNCS=$(declare -F | awk '{print $3}')


# ==============================================================================
# Output helpers - دوال الطباعة
# ==============================================================================

print_step() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

print_info() {
    echo "[INFO] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo -e "\e[31m[ERROR] $1\e[0m"
}


# ==============================================================================
# Input, prompts & confirmation - المدخلات والتحققات والتخيير
# ==============================================================================

# تتعرف على الأعلام المشتركة: -y / --yes موافقة تلقائية، -n / --no رفض تلقائي
# الاستخدام العادي (بدون إعادة تعيين args، وتبقى كلها متاحة عبر "$@"):
#   _parse_common_flags "$@"
# أو مع إعادة تعيين args الخاصة بالسكربت (بدون الأعلام المشتركة):
#   eval "$(_parse_common_flags --reset "$@")"
_parse_common_flags() {
    local reset_mode="no"
    if [ "${1:-}" = "--reset" ]; then
        reset_mode="yes"
        shift
    fi

    ASSUME_YES="${ASSUME_YES:-no}"
    ASSUME_NO="${ASSUME_NO:-no}"
    
    local -a remaining=()
    local arg

    for arg in "$@"; do
        case "$arg" in
            -y|--yes) ASSUME_YES="yes" ;;
            -n|--no) ASSUME_NO="yes" ;;
            *) remaining+=("$arg") ;;
        esac
    done

    if [ "$reset_mode" = "yes" ]; then
        printf 'ASSUME_YES=%q\n' "$ASSUME_YES"
        printf 'ASSUME_NO=%q\n' "$ASSUME_NO"
        if [ ${#remaining[@]} -gt 0 ]; then
            printf 'set -- %s\n' "$(printf '%q ' "${remaining[@]}")"
        else
            printf 'set --\n'
        fi
    fi
}

# تستخرج قيمة علم بحرف واحد يأخذ قيمة (مثل: -d example.com) وتسندها لمتغير
# يمكن تمرير أكثر من علم لنفس المتغير مفصولة بفراغ (مثل "d h")، وأي علم يطابق يعيّن القيمة (الأخير يفوز)
# تتجاهل بقية الأعلام بدل الفشل، لتتعايش مع أعلام أخرى مررت للسكربت (مثل -y/-n)
# الاستخدام: _parse_flag_value "d" SERVER_NAME "$@"   أو   _parse_flag_value "d h" SERVER_NAME "$@"
_parse_flag_value() {
    local flags="$1"
    local out_var_name="$2"
    shift 2

    # نبني optstring بحيث كل علم يأخذ قيمة: مثلاً "d h" => ":d:h:"
    local optstring=":" flag
    for flag in $flags; do
        optstring+="${flag}:"
    done

    # OPTIND محلي حتى تعمل الدالة بأمان عند استدعائها أكثر من مرة
    # النقطتان في بداية optstring تجعل getopts صامتاً فلا يطبع أخطاء الأعلام المجهولة
    # opt يساوي أحد أعلامنا عند التطابق، أو ? لعلم مجهول، أو : لقيمة ناقصة
    local opt OPTIND=1
    while getopts "$optstring" opt; do
        if [[ "$opt" != "?" && "$opt" != ":" ]]; then
            printf -v "$out_var_name" '%s' "$OPTARG"
        fi
    done

    return 0
}

# تبحث في وسائط السكربت عن أي وسيط يطابق إحدى القيم المسموح بها وتسنده لمتغير
# القيم المسموح بها تمرّر كسلسلة مفصولة بفراغ (مثل "native docker")، وأي وسيط يطابق يعيّن القيمة (الأخير يفوز)
# المطابقة حساسة لحالة الأحرف (تماماً كما كتبها المستخدم)، وتقبل الوسيط بأي بادئة: docker أو -docker أو --docker
# لا تلمس المتغير إذا لم يُمرّر أي وسيط مطابق، فتبقى قيمته الافتراضية كما هي
# تتجاهل بقية الوسائط بدل الفشل، لتتعايش مع أعلام أخرى مررت للسكربت (مثل -y/-n)
# الاستخدام: _parse_choice_value "native docker" INSTALL_METHOD "$@"
_parse_choice_value() {
    local choices="$1"
    local out_var_name="$2"
    shift 2

    local arg normalized entry choice value

    for arg in "$@"; do
        normalized="${arg#--}"
        normalized="${normalized#-}"

        for entry in $choices; do
            if [[ "$entry" == *=* ]]; then
                choice="${entry%%=*}"
                value="${entry#*=}"
            else
                choice="$entry"
                value="$entry"
            fi

            if [ "$normalized" = "$choice" ]; then
                printf -v "$out_var_name" '%s' "$value"
            fi
        done
    done

    return 0
}

_confirm() {
    local prompt_text="$1"

    # عند تمرير -n يتم رفض كل التحققات تلقائياً (وله الأولوية على -y للأمان)
    if [ "${ASSUME_NO:-no}" = "yes" ]; then
        echo "${prompt_text}n (auto-declined by -n)"
        return 1
    fi

    # عند تمرير -y للسكربت يتم تفعيل ASSUME_YES فتتم الموافقة على كل التحققات تلقائياً
    if [ "${ASSUME_YES:-no}" = "yes" ]; then
        echo "${prompt_text}y (auto-approved by -y)"
        return 0
    fi

    local response=""

    read -p "$prompt_text" response </dev/tty
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
    [[ "$response" =~ ^(y|yes)$ ]]
}

_prompt_required() {
    local prompt_text="$1"
    local out_var_name="$2"
    local regex_pattern="${3:-}"
    local secret_flag="${4:-}"

    local input=""
    local -a read_opts=()
    [ "$secret_flag" = "--secret" ] && read_opts+=(-s)

    while true; do
        read "${read_opts[@]}" -p "$prompt_text" input </dev/tty
        [ "$secret_flag" = "--secret" ] && echo ""

        if [ -z "$input" ]; then
            print_error "This value cannot be empty!"
            continue
        fi

        if [ -n "$regex_pattern" ] && [[ ! "$input" =~ $regex_pattern ]]; then
            print_error "Invalid value!"
            continue
        fi

        break
    done

    printf -v "$out_var_name" '%s' "$input"
}

_prompt_paste_file() {
    local prompt_text="$1"
    local target_file="$2"
    local remove_existing="${3:-false}"

    echo
    echo "================================================================="
    echo " $prompt_text"
    echo "================================================================="
    echo "File to edit:"
    echo " $target_file"
    echo

    read -p "Press ENTER to open the file..." </dev/tty

    sudo mkdir -p "$(dirname "$target_file")"

    if [[ "$remove_existing" == "true" ]]; then
        sudo rm -f "$target_file"
    fi

    nano "$target_file" </dev/tty
}

_check_variable_required() {
    local var_name="$1"
    local var_value="$2"
    local regex_pattern="$3"

    if [ -z "$var_value" ]; then
        print_error "Validation Failed: Required variable '$var_name' is missing or empty!"
        exit 1
    fi

    if [ -n "$regex_pattern" ] && [[ ! "$var_value" =~ $regex_pattern ]]; then
        print_error "Validation Failed: Variable '$var_name' ('$var_value') does not match the required format!"
        exit 1
    fi
}

_ask_to_save_permanently() {
    local var_name="$1"
    local var_value="$2"

    if ! _confirm "$(echo -e "\e[33m[?]\e[0m Do you want to save $var_name permanently to the server? (y/n): ")"; then
        print_info "$var_name will be temporary for this script run only."
        return 0
    fi

    local shell_profile=""

    if [ -f "/root/.bashrc" ]; then
        shell_profile="/root/.bashrc"
    elif [ -f "/root/.profile" ]; then
        shell_profile="/root/.profile"
    fi

    if [ -z "$shell_profile" ]; then
        print_warning "Could not find .bashrc or .profile to save $var_name permanently."
        return 0
    fi

    sed -i "/export $var_name=/d" "$shell_profile"
    echo "export $var_name=\"$var_value\"" >> "$shell_profile"
    print_info "Saved $var_name permanently to $shell_profile"
}


# ==============================================================================
# Packages & dependencies - الحزم والتبعيات
# ==============================================================================

_package_installed() {
    dpkg -s "$1" >/dev/null 2>&1 || command -v "$1" >/dev/null 2>&1
}

_install_dependencies() {
    if [ "$#" -eq 0 ]; then
        print_error "No dependencies specified to install."
        return 1
    fi

    sudo apt-get update -y
    sudo apt-get install -y "$@"
}

# تثبت الحزم الممررة فقط إن لم تكن مثبتة مسبقاً (بدون apt update إذا كانت كلها موجودة)
# التحقق يتم بطريقتين: dpkg -s للحزمة، أو command -v إذا كان الاسم أمراً متاحاً
# (يغطي حالة أداة مثبتة من خارج apt مثل git من المصدر)
# الاستخدام: _ensure_packages <pkg1> [pkg2] ...
_ensure_packages() {
    if [ "$#" -eq 0 ]; then
        print_error "No packages specified to ensure."
        return 1
    fi

    local -a missing_packages=()
    local pkg

    for pkg in "$@"; do
        _package_installed "$pkg" || missing_packages+=("$pkg")
    done

    [ ${#missing_packages[@]} -eq 0 ] && return 0

    _install_dependencies "${missing_packages[@]}"
}


# ==============================================================================
# OS & system detection - كشف النظام والبيئة
# ==============================================================================

# تتحقق أن النظام Ubuntu وأن الإصدار مدعوم، وتطبع الـ codename (مثل jammy)
# الاستخدام: UBUNTU_CODENAME=$(_get_ubuntu_codename "20.04 22.04 24.04")
_get_ubuntu_codename() {
    local supported_versions="$1"

    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect OS: /etc/os-release not found." >&2
        return 1
    fi

    local os_id version_id codename
    os_id=$(. /etc/os-release && echo "$ID")
    version_id=$(. /etc/os-release && echo "$VERSION_ID")
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    if [ "$os_id" != "ubuntu" ]; then
        print_error "Unsupported OS '$os_id'. This script supports Ubuntu only." >&2
        return 1
    fi

    if [[ " $supported_versions " != *" $version_id "* ]]; then
        print_error "Unsupported Ubuntu version '$version_id'. Supported versions: $supported_versions" >&2
        return 1
    fi

    echo "$codename"
}

_detect_ssh_port() {
    local detected_port=""

    detected_port=$(sudo ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')

    if [ -z "$detected_port" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    fi

    echo "${detected_port:-22}"
}


# ==============================================================================
# Systemd services - خدمات systemd
# ==============================================================================

_service_exists() {
    local service="$1"
    local check_active="${2:-false}"

    if ! systemctl list-unit-files --type=service | grep -q "${service}.service"; then
        return 1
    fi

    if [[ "$check_active" == "true" ]]; then
        if ! systemctl is-active --quiet "$service"; then
            return 1
        fi
    fi

    return 0
}

_destroy_service() {
    local service_name="$1"
    local service_file="${2:-/etc/systemd/system/${service_name}.service}"

    sudo systemctl stop "${service_name}.service" >/dev/null 2>&1 || true
    sudo systemctl disable "${service_name}.service" >/dev/null 2>&1 || true

    sudo rm -f "$service_file"

    sudo systemctl reset-failed "${service_name}.service" >/dev/null 2>&1 || true
    sudo systemctl daemon-reload
}

_wait_for_service() {
    local service_name="$1"
    local timeout="${2:-30}"

    if ! _service_exists "$service_name"; then
        print_error "Service '${service_name}.service' does not exist."
        return 1
    fi

    local max_attempts=$((timeout * 5))
    local attempt=0

    while ! systemctl is-active --quiet "$service_name"; do
        if (( attempt >= max_attempts )); then
            print_error "Timed out waiting for '${service_name}.service' to become active."
            return 1
        fi

        sleep 0.20
        ((attempt++)) || true
    done
}

_create_systemd_service() {
    local service_name="$1"
    local template_file="$2"
    shift 2

    print_step "Creating Systemd Service: ${service_name}"

    local service_file="/etc/systemd/system/${service_name}.service"

    if _service_exists "$service_name" || [ -f "$service_file" ]; then
        print_info "Existing service '${service_name}' detected. Destroy it first..."
        _destroy_service "$service_name" "$service_file"
        print_info "Old service successfully cleaned up."
    fi

    print_info "Configuring systemd service file at ${service_file}..."

    _render_template_file "$template_file" "$service_file" "$@"

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service" >/dev/null 2>&1


    print_info "✅ Systemd service ${service_name}.service successfully created and enabled."
    print_info "for show logs run   sudo journalctl -u $service_name -e"
}


# ==============================================================================
# Templates, configs & MOTD - القوالب وملفات الاعدادات وشاشة الدخول
# ==============================================================================

_render_template_file() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    local -a template_vars=("$@")

    local vars_list=""
    local -a env_assignments=()
    local arg var_name

    for arg in "${template_vars[@]}"; do
        if [[ "$arg" == *=* ]]; then
            var_name="${arg%%=*}"
            env_assignments+=("$arg")
        else
            # اسم مجرّد: تُقرأ قيمته من نطاق المستدعي (متغير عام) وتُمرَّر لبيئة envsubst
            var_name="$arg"
            env_assignments+=("$var_name=${!var_name}")
        fi
        vars_list+="\${$var_name} "
    done

    sudo mkdir -p "$(dirname "$output_file")"

    # envsubst يأتي من حزمة gettext-base
    _ensure_packages gettext-base

    env "${env_assignments[@]}" envsubst "$vars_list" \
        < "$template_file" \
        | sudo tee "$output_file" > /dev/null
}

# تقرأ قيمة مفتاح من ملف config بصيغة KEY="value"
_read_config_value() {
    local config_file="$1"
    local key="$2"

    sudo grep -E "^${key}=" "$config_file" 2>/dev/null | head -n 1 | cut -d'"' -f2
}

# تتحقق من وجود ملف config قديم لخدمة وتخيّر المستخدم: إعادة الضبط من الصفر أو الخروج
# عند اختيار إعادة الضبط تنفذ أمر التصفية المسجل داخل الكونفج نفسه (CLEANUP_COMMAND)
# وهو المسؤول عن إيقاف وحذف كل ما يخص الخدمة، ثم تحذف الكونفج ومجلد الخدمة
_handle_existing_config_file() {
    local config_file="$1"

    sudo test -f "$config_file" || return 0

    print_step "Existing configuration detected"
    print_warning "A previous setup config was found at: $config_file"
    echo
    sudo cat "$config_file"
    echo

    if ! _confirm "Remove everything related to this service (including its data) and redo the setup from scratch? (y/n): "; then
        print_info "Keeping the existing setup. Exiting without changes."
        exit 0
    fi

    local cleanup_command
    cleanup_command=$(_read_config_value "$config_file" CLEANUP_COMMAND)

    if [ -n "$cleanup_command" ]; then
        sudo bash -c "$cleanup_command" || print_warning "Cleanup command finished with errors. Continuing anyway."
    else
        print_warning "No CLEANUP_COMMAND found in the config. Only the config file will be removed."
    fi

    print_info "Previous installation cleaned up. Continuing with a fresh setup..."
}

# تضيف/تحدث معلومات استخدام سريعة لخدمة تظهر في شاشة الدخول عبر SSH (MOTD)
# الـ template سكربت جاهز للتشغيل (مثل motd-info.sh.tmpl) ويتم فقط تمرير المتغيرات التي يحتاجها
# الاستخدام: _add_motd_info <service_name> <template_file> [VAR=value ...]
_add_motd_info() {
    local service_name="$1"
    local template_file="$2"
    shift 2

    local motd_file="/etc/update-motd.d/99-${service_name}-info"

    _render_template_file "$template_file" "$motd_file" "$@"
    sudo chmod +x "$motd_file"
}


# ==============================================================================
# Firewall (UFW) - الجدار الناري
# ==============================================================================

# ترفع حظر الجدار الناري (ufw) عن بورت، مع إمكانية تقييد السماح بمصدر محدد
# لا تفعل شيئاً إذا كان ufw غير مثبت أو غير مفعل
# الاستخدام: _allow_port_through_firewall <port> [source_subnet]
_allow_port_through_firewall() {
    local port="$1"
    local source_subnet="${2:-}"

    _package_installed ufw || return 0

    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        return 0
    fi

    if [ -n "$source_subnet" ]; then
        print_info "UFW is active. Allowing port $port from $source_subnet..."
        sudo ufw allow from "$source_subnet" to any port "$port" proto tcp >/dev/null
    else
        print_info "UFW is active. Allowing port $port..."
        sudo ufw allow "$port/tcp" >/dev/null
    fi
}


# ==============================================================================
# Git & GitHub - جيت والمستودعات
# ==============================================================================

_ensure_git_compatible() {
    local min_version="${1:-2.25.0}"
    local current_version

    _ensure_packages git

    current_version=$(git --version | grep -oP '\d+\.\d+\.\d+')

    if [ "$(printf '%s\n%s\n' "$min_version" "$current_version" | sort -V | head -n1)" != "$min_version" ]; then
        print_warning "Git $current_version is too old (requires >= $min_version). Updating..."
        _install_dependencies --only-upgrade git
        current_version=$(git --version | grep -oP '\d+\.\d+\.\d+')
    fi

    if [ "$(printf '%s\n%s\n' "$min_version" "$current_version" | sort -V | head -n1)" != "$min_version" ]; then
        print_error "Git $current_version still does not meet the minimum required version ($min_version). Please update Git manually."
        return 1
    fi

    print_info "Git $current_version is compatible (minimum required: $min_version)."
}

_clone_or_update_project() {
    local repo_url="$1"
    local project_dir="$2"
    local branch="${3:-main}"

    print_step "Clone or update project"
    _ensure_packages git

    if [ -d "$project_dir/.git" ]; then
        print_info "Project already exists. Pulling latest changes..."
        cd "$project_dir"
        git fetch --all
        git reset --hard "origin/$branch"
        return
    fi

    print_info "Cloning project..."
    git clone "$repo_url" "$project_dir"
}

_download_github_path() {
    local repo_url="$1"
    local repo_path="$2"
    local destination="$3"
    local branch="${4:-main}"
    local min_git_version="${5:-2.25.0}"

    if [ -z "$repo_url" ] || [ -z "$repo_path" ] || [ -z "$destination" ]; then
        print_error "Usage: _download_github_path <repo_url> <path_in_repo> <destination> [branch] [min_git_version]"
        return 1
    fi

    _ensure_git_compatible "$min_git_version" || return 1

    print_step "Download '$repo_path' from $repo_url"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    print_info "Fetching repository metadata (sparse checkout)..."
    if ! git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$branch" "$repo_url" "$tmp_dir"; then
        print_error "Failed to clone repository '$repo_url' (branch: $branch)."
        sudo rm -rf "$tmp_dir"
        return 1
    fi

    (
        cd "$tmp_dir" || exit 1
        git sparse-checkout set "$repo_path"
    )

    local source_path="$tmp_dir/$repo_path"

    if [ ! -e "$source_path" ]; then
        print_error "Path '$repo_path' was not found in the repository."
        sudo rm -rf "$tmp_dir"
        return 1
    fi

    if [ -d "$source_path" ]; then
        sudo rm -rf "$destination"
        sudo mkdir -p "$destination"
        cp -r "$source_path/." "$destination/"
    else
        sudo rm -f "$destination"
        sudo mkdir -p "$(dirname "$destination")"
        cp "$source_path" "$destination"
    fi

    sudo rm -rf "$tmp_dir"

    print_info "Downloaded '$repo_path' to '$destination'."
}

# تنزّل سكربتاً من مستودع GitHub (خاص أو عام) وتشغّله عبر bash
# تستخرج التوكن من ~/.git-credentials بعد تفعيل credential.helper store
# الاستخدام: _run_github_script [github_user] [repo] [script_path] [branch]
# القيم التلقائية من المتغيرات العامة: GITHUB_USER / GITHUB_REPO / GITHUB_SCRIPT_PATH / GITHUB_BRANCH
_run_github_script() {
    local github_user="${1:-${GITHUB_USER:-eeeob}}"
    local repo="${2:-${GITHUB_REPO:-}}"
    local script_path="${3:-${GITHUB_SCRIPT_PATH:-}}"
    local branch="${4:-${GITHUB_BRANCH:-main}}"

    if [ -z "$repo" ] || [ -z "$script_path" ]; then
        print_error "_run_github_script: repo and script_path are required (args or GITHUB_* globals)."
        return 1
    fi

    _ensure_packages git curl

    print_info "Enabling Git credential storage..."
    git config --global credential.helper store

    print_info "Testing GitHub access to ${github_user}/${repo}..."
    if ! git ls-remote "https://github.com/${github_user}/${repo}.git" >/dev/null; then
        print_error "GitHub authentication failed for ${github_user}/${repo}."
        return 1
    fi

    if [ ! -f "$HOME/.git-credentials" ]; then
        print_error "Git credentials not found at ~/.git-credentials."
        return 1
    fi

    local token
    token=$(grep "github.com" "$HOME/.git-credentials" | tail -n1 | sed -E 's#https://[^:]+:([^@]+)@.*#\1#')

    if [ -z "$token" ]; then
        print_error "Could not extract GitHub token from ~/.git-credentials."
        return 1
    fi

    print_info "Downloading and running '${script_path}' from ${github_user}/${repo} (${branch})..."
    curl -fsSL \
        -H "Authorization: token ${token}" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${github_user}/${repo}/contents/${script_path}?ref=${branch}" \
        | bash
}


# ==============================================================================
# Docker - دوكر (تثبيت، شبكات، حاويات)
# ==============================================================================

_install_docker() {

    if ! _package_installed docker; then
        print_step "Install Docker"

        _ensure_packages curl ca-certificates

        sudo install -m 0755 -d /etc/apt/keyrings

        print_info "Installing Docker from official repository..."

        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        _install_dependencies docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    if ! sudo systemctl is-active --quiet docker; then
        print_warning "Docker service is not running. Starting it..."
        sudo systemctl start docker
    fi

    if ! sudo systemctl is-enabled --quiet docker; then
        print_warning "Docker service is not enabled. Enabling it..."
        sudo systemctl enable docker >/dev/null 2>&1
    fi

    if ! groups "$USER" | grep -q docker; then
        print_info "Adding user to docker group..."
        sudo usermod -aG docker "$USER"
    fi

    if sudo docker info >/dev/null 2>&1; then
        return 0
    fi

    print_info "Waiting for Docker daemon to become ready..."
    local attempt
    for attempt in $(seq 1 30); do
        if sudo docker info >/dev/null 2>&1; then
            print_info "Docker daemon is up and ready."
            print_info "Docker setup completed."
            return 0
        fi
        sleep 1
    done

    print_error "Docker daemon did not become ready within 30 seconds."
    return 1
}

_docker_network_exists() {
    local network_name="${1:-${DOCKER_NETWORK_NAME:-}}"

    if [ -z "$network_name" ]; then
        print_error "_docker_network_exists: no network name provided and DOCKER_NETWORK_NAME is not set."
        return 1
    fi

    _package_installed docker || return 1

    sudo docker network inspect "$network_name" >/dev/null 2>&1
}

# تطبع subnet شبكة Docker المحددة
# الاسم التلقائي: من المتغير العام DOCKER_NETWORK_NAME أو bridge (شبكة docker0)
_get_docker_network_subnet() {
    local network_name="${1:-${DOCKER_NETWORK_NAME:-}}"

    if [ -z "$network_name" ]; then
        print_error "_get_docker_network_subnet: no network name provided and DOCKER_NETWORK_NAME is not set."
        return 1
    fi

    _package_installed docker || return 1

    sudo docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$network_name" 2>/dev/null
}

_create_docker_network() {
    local network_name="${1:-${DOCKER_NETWORK_NAME:-}}"
    local network_subnet="${2:-${DOCKER_NETWORK_SUBNET:-}}"

    if [ -z "$network_name" ]; then
        print_error "_create_docker_network: no network name provided and DOCKER_NETWORK_NAME is not set."
        exit 1
    fi

    _install_docker

    if _docker_network_exists "$network_name"; then
        if [ -n "$network_subnet" ]; then
            local existing_subnet
            existing_subnet=$(_get_docker_network_subnet "$network_name")

            if [ -n "$existing_subnet" ] && [ "$existing_subnet" != "$network_subnet" ]; then
                print_error "Docker network '$network_name' already exists with subnet '$existing_subnet', which does not match the requested subnet '$network_subnet'."
                exit 1
            fi
        fi

        print_info "Docker network '$network_name' already exists. Skipping creation."
        return 0
    fi

    print_info "Creating Docker network '$network_name'..."

    if [ -n "$network_subnet" ]; then
        sudo docker network create --subnet "$network_subnet" "$network_name" >/dev/null
    else
        sudo docker network create "$network_name" >/dev/null
    fi

    print_info "Docker network '$network_name' created successfully."
}

_container_exists() {
    _package_installed docker || return 1
    sudo docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

# تحذف container مع صورته، وتحذف الشبكات المرتبطة به إذا كانت أنشئت له:
# شبكة أنشأها compose (تحمل label الخاص به) أو شبكة لم يعد مرتبطاً بها أي container آخر
_remove_container() {
    local container_name="$1"

    _container_exists "$container_name" || return 0

    local image networks
    image=$(sudo docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)
    networks=$(sudo docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$container_name" 2>/dev/null || true)

    print_info "Removing container '$container_name'..."
    sudo docker rm -f "$container_name" >/dev/null 2>&1 || true

    if [ -n "$image" ]; then
        if sudo docker rmi "$image" >/dev/null 2>&1; then
            print_info "Image '$image' removed."
        else
            print_warning "Image '$image' is still in use by another container. Skipped removing it."
        fi
    fi

    local network compose_label attached_count
    for network in $networks; do
        # الشبكات الافتراضية في Docker لا تُحذف أبداً
        case "$network" in
            bridge|host|none) continue ;;
        esac

        _docker_network_exists "$network" || continue

        compose_label=$(sudo docker network inspect --format '{{index .Labels "com.docker.compose.network"}}' "$network" 2>/dev/null || true)
        attached_count=$(sudo docker network inspect --format '{{len .Containers}}' "$network" 2>/dev/null || echo 1)

        if [ -n "$compose_label" ] || [ "$attached_count" = "0" ]; then
            if sudo docker network rm "$network" >/dev/null 2>&1; then
                print_info "Network '$network' removed."
            else
                print_warning "Network '$network' is still in use. Skipped removing it."
            fi
        fi
    done
}

# إذا وجد container بنفس الاسم: تخيير المستخدم بحذفه وإعادة إنشائه (ترجع 0)
# أو الإبقاء عليه (ترجع 1 ليعرف المستدعي أنه لا حاجة لإنشاء جديد)
# الحذف يتم عبر _remove_container (الصورة والشبكات الخاصة به تُحذف معه)
_handle_existing_container() {
    local container_name="$1"

    _container_exists "$container_name" || return 0

    print_warning "A Docker container named '$container_name' already exists:"
    sudo docker ps -a --filter "name=^${container_name}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    echo

    if _confirm "Remove this container (with its image and its own networks) and create a fresh one? (y/n): "; then
        _remove_container "$container_name"
        return 0
    fi

    print_info "Keeping the existing container."
    return 1
}

_wait_for_container() {
    local container="$1"
    local timeout="${2:-30}"

    if ! _container_exists "$container"; then
        print_error "Container '$container' does not exist."
        return 1
    fi

    local max_attempts=$((timeout * 5))
    local attempt=0

    while [[ "$(sudo docker inspect -f '{{.State.Running}}' "$container")" != "true" ]]; do
        if (( attempt >= max_attempts )); then
            print_error "Timed out waiting for container '$container' to start."
            return 1
        fi

        sleep 0.20
        ((attempt++)) || true
    done
}


# ==============================================================================
# Cloudflare DNS - تحديث سجلات كلاودفلير
# ==============================================================================

# تنشئ أو تحدّث سجل DNS من نوع A في Cloudflare ليطابق الآي بي العام الحالي للسيرفر
# الاستخدام: _update_cloudflare_dns [api_token] [zone_id] [domain]
# القيم التلقائية من المتغيرات العامة: CLOUDFLARE_API_TOKEN / CLOUDFLARE_ZONE_ID / CLOUDFLARE_DOMAIN
_update_cloudflare_dns() {
    local api_token="${1:-${CLOUDFLARE_API_TOKEN:-}}"
    local zone_id="${2:-${CLOUDFLARE_ZONE_ID:-}}"
    local domain="${3:-${CLOUDFLARE_DOMAIN:-}}"

    if [ -z "$api_token" ] || [ -z "$zone_id" ] || [ -z "$domain" ]; then
        print_error "_update_cloudflare_dns: api_token, zone_id and domain are required (args or CLOUDFLARE_* globals)."
        return 1
    fi

    _ensure_packages curl

    print_info "Fetching current server public IP..."
    local current_ip
    current_ip=$(curl -s --max-time 10 https://api.ipify.org || echo "")

    if [ -z "$current_ip" ]; then
        print_error "Failed to fetch public IP from api.ipify.org."
        return 1
    fi
    print_info "Current server IP: $current_ip"

    local api_base="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"

    print_info "Fetching current DNS record for $domain from Cloudflare..."
    local record_info
    record_info=$(curl -s -X GET "${api_base}?name=${domain}&type=A" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json")

    if [[ "$record_info" == *'"success":false'* ]]; then
        print_error "Cloudflare API returned an error. Check your token and zone id."
        echo "$record_info"
        return 1
    fi

    # استخدام sed الآمن بدلاً من grep المستهلك للمدخلات
    local record_id cloudflare_ip
    record_id=$(echo "$record_info" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)
    cloudflare_ip=$(echo "$record_info" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -n1)

    local payload
    payload="{\"type\":\"A\",\"name\":\"${domain}\",\"content\":\"${current_ip}\",\"ttl\":120,\"proxied\":true}"

    local response
    if [ -z "$record_id" ]; then
        print_warning "DNS record for $domain not found. Creating a new one..."
        response=$(curl -s -X POST "$api_base" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json" \
            --data "$payload")
    elif [ "$current_ip" = "$cloudflare_ip" ]; then
        print_info "IP has not changed ($current_ip). Cloudflare is already up to date."
        return 0
    else
        print_info "IP changed from $cloudflare_ip to $current_ip. Updating Cloudflare..."
        response=$(curl -s -X PUT "${api_base}/${record_id}" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json" \
            --data "$payload")
    fi

    if [[ "$response" == *'"success":true'* ]]; then
        print_info "Cloudflare DNS record for $domain is now set to $current_ip."
        return 0
    fi

    print_error "Failed to apply the Cloudflare DNS change."
    echo "$response"
    return 1
}






_UTILS_FUNCTIONS=($(comm -13 <(printf '%s\n' "$_UTILS_PRELOAD_FUNCS" | sort -u) <(declare -F | awk '{print $3}' | sort -u)))
unset _UTILS_PRELOAD_FUNCS

_run_utils_menu() {
    if [ ${#_UTILS_FUNCTIONS[@]} -eq 0 ]; then
        print_error "No functions were captured from utils.sh."
        return 1
    fi

    trap 'echo; print_info "Exiting menu (Ctrl+C)."; trap - INT; return 0' INT

    while true; do
        echo
        print_step "utils.sh - Interactive function menu"

        local i
        for i in "${!_UTILS_FUNCTIONS[@]}"; do
            printf "  %2d) %s\n" "$((i + 1))" "${_UTILS_FUNCTIONS[$i]}"
        done
        printf "  %2d) Exit\n" 0
        echo

        local choice
        read -p "Select a function number to run (0 to exit): " choice </dev/tty

        if [ "$choice" = "0" ]; then
            print_info "Exiting menu."
            break
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#_UTILS_FUNCTIONS[@]}" ]; then
            print_error "Invalid selection: $choice"
            continue
        fi

        local selected="${_UTILS_FUNCTIONS[$((choice - 1))]}"

        local args_line
        read -p "Arguments to pass to '$selected' (space-separated, empty for none): " args_line </dev/tty

        local -a call_args=()
        [ -n "$args_line" ] && read -r -a call_args <<< "$args_line"

        print_step "Running: $selected ${call_args[*]}"
        "$selected" "${call_args[@]}"
        local exit_code=$?

        echo
        if [ $exit_code -eq 0 ]; then
            print_info "'$selected' finished successfully."
        else
            print_warning "'$selected' exited with code $exit_code."
        fi
    done

    trap - INT
}
