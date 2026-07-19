#!/usr/bin/env bash


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

_prompt_paste_file() {
    local prompt_text="$1"
    local target_file="$2"

    echo
    echo "================================================================="
    echo " $prompt_text"
    echo "================================================================="
    echo "File to edit:"
    echo " $target_file"
    echo

    read -p "Press ENTER to open the file..." </dev/tty
    nano "$target_file" </dev/tty
}

_install_dependencies() {
    if [ "$#" -eq 0 ]; then
        print_error "No dependencies specified to install."
        return 1
    fi

    print_step "Update system and install dependencies"
    sudo apt-get update -y
    sudo apt-get install -y "$@"
}

_install_docker() {
    print_step "Install Docker"

    if command -v docker >/dev/null 2>&1; then
        print_info "Docker is already installed."
    else
        print_info "Installing Docker from official repository..."

        _install_dependencies curl ca-certificates

        sudo install -m 0755 -d /etc/apt/keyrings

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

    print_info "Checking Docker service status..."

    if ! sudo systemctl is-active --quiet docker; then
        print_warning "Docker service is not running. Starting it..."
        sudo systemctl start docker
    fi

    if ! sudo systemctl is-enabled --quiet docker; then
        print_warning "Docker service is not enabled. Enabling it..."
        sudo systemctl enable docker >/dev/null 2>&1
    else
        print_info "Docker service already enabled."
    fi

    print_info "Docker service is running."

    if ! groups "$USER" | grep -q docker; then
        print_info "Adding user to docker group..."
        sudo usermod -aG docker "$USER"
    else
        print_info "User already in docker group."
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

_clone_or_update_project() {
    local repo_url="$1"
    local project_dir="$2"
    local branch="${3:-main}"

    print_step "Clone or update project"

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
            var_name="$arg"
        fi
        vars_list+="\${$var_name} "
    done

    sudo mkdir -p "$(dirname "$output_file")"

    env "${env_assignments[@]}" envsubst "$vars_list" \
        < "$template_file" \
        | sudo tee "$output_file" > /dev/null
}

_create_systemd_service() {
    local service_name="$1"
    local template_file="$2"
    shift 2
    local -a template_vars=("$@")

    print_step "Creating Systemd Service: ${service_name}"

    local service_file="/etc/systemd/system/${service_name}.service"

    if systemctl list-unit-files | grep -q "${service_name}.service" || [ -f "$service_file" ]; then
        print_info "Existing service '${service_name}' detected. Stopping and removing it first..."

        sudo systemctl stop "${service_name}.service" >/dev/null 2>&1 || true
        sudo systemctl disable "${service_name}.service" >/dev/null 2>&1 || true
        sudo rm -f "$service_file"
        sudo systemctl daemon-reload
        print_info "Old service successfully cleaned up."
    fi

    print_info "Configuring systemd service file at ${service_file}..."

    _render_template_file "$template_file" "$service_file" "${template_vars[@]}"

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service" >/dev/null 2>&1
    print_info "✅ Systemd service ${service_name}.service successfully created and enabled."
    print_info "for show logs run   sudo journalctl -u $service_name -e"
}

_ensure_git_compatible() {
    local min_version="${1:-2.25.0}"
    local current_version

    if ! command -v git >/dev/null 2>&1; then
        print_warning "Git is not installed. Installing it..."
        _install_dependencies git
    fi

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

_detect_ssh_port() {
    local detected_port=""

    detected_port=$(sudo ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')

    if [ -z "$detected_port" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    fi

    echo "${detected_port:-22}"
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

    local service cleanup_command
    service=$(_read_config_value "$config_file" SERVICE)
    cleanup_command=$(_read_config_value "$config_file" CLEANUP_COMMAND)

    if [ -n "$cleanup_command" ]; then
        print_step "Cleaning up previous '${service:-unknown}' installation"
        sudo bash -c "$cleanup_command" || print_warning "Cleanup command finished with errors. Continuing anyway."
    else
        print_warning "No CLEANUP_COMMAND found in the config. Only the config file will be removed."
    fi

    # حذف معلومات MOTD الخاصة بالخدمة إن وجدت
    [ -n "$service" ] && sudo rm -f "/etc/update-motd.d/99-${service}-info"

    # حذف ملف الكونفج، ومجلد الخدمة كاملاً إذا كان لها مجلد خاص داخل /root/.configs
    local parent_dir
    parent_dir=$(dirname "$config_file")
    sudo rm -f "$config_file"
    if [ "$parent_dir" != "/root/.configs" ]; then
        sudo rm -rf "$parent_dir"
    fi

    print_info "Previous installation cleaned up. Continuing with a fresh setup..."
}

# ترفع حظر الجدار الناري (ufw) عن بورت، مع إمكانية تقييد السماح بمصدر محدد
# لا تفعل شيئاً إذا كان ufw غير مثبت أو غير مفعل
# الاستخدام: _allow_port_through_firewall <port> [source_subnet]
_allow_port_through_firewall() {
    local port="$1"
    local source_subnet="${2:-}"

    command -v ufw >/dev/null 2>&1 || return 0

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

# تطبع subnet شبكة Docker المحددة
# الاسم التلقائي: من المتغير العام DOCKER_NETWORK_NAME أو bridge (شبكة docker0)
_get_docker_network_subnet() {
    local network_name="${1:-${DOCKER_NETWORK_NAME:-bridge}}"

    sudo docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$network_name" 2>/dev/null
}

_docker_network_exists() {
    sudo docker network inspect "$1" >/dev/null 2>&1
}

# تنشئ شبكة Docker إذا لم تكن موجودة مسبقاً، مع إمكانية تحديد نطاق IP
# الاستخدام: _create_docker_network [network_name] [ip_range]
# القيم التلقائية: من المتغيرات العالمية DOCKER_NETWORK_NAME و DOCKER_NETWORK_SUBNET
# وإذا لم تكن معرفة يتم استخدام main_network و 172.20.0.0/16
_create_docker_network() {
    local network_name="${1:-${DOCKER_NETWORK_NAME:-main_network}}"
    local ip_range="${2:-${DOCKER_NETWORK_SUBNET:-172.20.0.0/16}}"

    if _docker_network_exists "$network_name"; then
        print_info "Docker network '$network_name' already exists. Skipping creation."
        return 0
    fi

    print_info "Creating Docker network '$network_name'..."

    if [ -n "$ip_range" ]; then
        sudo docker network create --subnet "$ip_range" "$network_name" >/dev/null
    else
        sudo docker network create "$network_name" >/dev/null
    fi

    print_info "Docker network '$network_name' created successfully."
}

_container_exists() {
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
        rm -rf "$tmp_dir"
        return 1
    fi

    (
        cd "$tmp_dir" || exit 1
        git sparse-checkout set "$repo_path"
    )

    local source_path="$tmp_dir/$repo_path"

    if [ ! -e "$source_path" ]; then
        print_error "Path '$repo_path' was not found in the repository."
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$destination"

    if [ -d "$source_path" ]; then
        mkdir -p "$destination"
        cp -r "$source_path/." "$destination/"
    else
        mkdir -p "$(dirname "$destination")"
        cp "$source_path" "$destination"
    fi

    rm -rf "$tmp_dir"

    print_info "Downloaded '$repo_path' to '$destination'."
}






