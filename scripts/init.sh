#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/../assets" && pwd)"
TOOLS_DIR="${ASSETS_DIR}/tools"

trap 'log_error "Script failed at line ${LINENO}"' ERR

resolve_username() {
    # INIT_USERNAME>USERNAME envs take precedence; fall back to first arg
    USERNAME="${INIT_USERNAME:-${USERNAME:-${1:-}}}"
    if [ -z "${USERNAME:-}" ]; then
        log_error "未提供目标用户名 (INIT_USERNAME/USERNAME/参数)"
        exit 1
    fi

    if ! id -u "$USERNAME" >/dev/null 2>&1; then
        log_error "用户不存在: $USERNAME"
        exit 1
    fi
}

resolve_user_home() {
    local home=""

    home="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || true)"
    if [ -z "$home" ]; then
        home="$(awk -F: -v u="$USERNAME" '$1==u{print $6; exit}' /etc/passwd 2>/dev/null || true)"
    fi

    if [ -z "$home" ] || [ ! -d "$home" ]; then
        return 1
    fi

    printf '%s' "$home"
}

write_pip_conf() {
    local target_home="$1"
    local target_user="$2"

    mkdir -p "$target_home/.pip"
    cat > "$target_home/.pip/pip.conf" << 'EOF'
[global]
index-url=https://mirrors.aliyun.com/pypi/simple/
disable-pip-version-check=true
timeout=120

[install]
trusted-host=mirrors.aliyun.com
EOF

    if [ -n "${target_user:-}" ] && [ "$target_user" != "root" ]; then
        chown -R "$target_user:$target_user" "$target_home/.pip" || true
    fi
}

configure_user_privileges() {
    show_step "配置用户组与 sudo 权限"

    for group in adm users sudo; do
        if ! groups "$USERNAME" | grep -q "\\b${group}\\b"; then
            log_info "将用户 ${USERNAME} 添加到 ${group} 组..."
            usermod -aG "$group" "$USERNAME" || log_warning "添加到 ${group} 组失败"
        fi
    done

    local sudoers_file="/etc/sudoers.d/${USERNAME}"
    log_info "为用户 ${USERNAME} 配置免密sudo: ${sudoers_file}"

    cat <<EOF > "$sudoers_file"
${USERNAME} ALL=(ALL) NOPASSWD: ALL
EOF

    chmod 0440 "$sudoers_file"

    if visudo -c >/dev/null 2>&1; then
        log_success "sudoers 配置校验通过"
    else
        log_error "sudoers 配置校验失败，请检查 ${sudoers_file}"
    fi
}


install_basic_packages() {
    show_step "安装基础软件包"
    export DEBIAN_FRONTEND=noninteractive

    log_info "更新软件包索引..."
    apt-get update -y || log_warning "apt-get update 可能失败"

    log_info "安装核心工具包..."
    apt-get install -y build-essential \
        tar python3 python3-pip python3-venv \
        unzip xz-utils zip jq coreutils curl gzip unzip \
        qrencode wget lsof ca-certificates \
        software-properties-common git gnupg || log_warning "部分基础包安装失败"

    # updatedb 由 mlocate/plocate 提供：Ubuntu 22.04 常用 mlocate，新版默认 plocate
    if ! command -v updatedb >/dev/null 2>&1; then
        apt-get install -y plocate || apt-get install -y mlocate || true
    fi

    # 配置 mlocate 忽略路径
    UPDATEDB_CONF="/etc/updatedb.conf"
    if [ -w "$UPDATEDB_CONF" ] || [ ! -f "$UPDATEDB_CONF" ]; then
        touch "$UPDATEDB_CONF" && chmod 644 "$UPDATEDB_CONF" || true
        tmpfile="$(mktemp)"
        awk '
BEGIN {
    found = 0
}
{
    if ($0 ~ /^[[:space:]]*PRUNEPATHS=/ && $0 !~ /^[[:space:]]*#/) {
        found = 1
        paths = ""
        # 提取双引号内的内容（不依赖 match 的数组参数，兼容最小 awk）
        if (match($0, /PRUNEPATHS="[^"]*"/)) {
            paths = substr($0, RSTART + 11, RLENGTH - 12)
        }
        if (paths !~ /(^|[[:space:]])\/mnt([[:space:]]|$)/) {
            paths = paths " /mnt"
        }
        if (paths !~ /(^|[[:space:]])\/tmp([[:space:]]|$)/) {
            paths = paths " /tmp"
        }
        gsub(/[[:space:]]+/, " ", paths)
        sub(/^[[:space:]]+/, "", paths)
        print "PRUNEPATHS=\"" paths "\""
        next
    }
    print
}
END {
    if (found == 0) {
        print "PRUNEPATHS=\"/tmp /mnt\""
    }
}
' "$UPDATEDB_CONF" > "$tmpfile" && mv "$tmpfile" "$UPDATEDB_CONF" || rm -f "$tmpfile"
    fi

    updatedb || log_warning "updatedb 执行失败"
    log_success "基础软件包安装完成"
}


disable_automatic_updates() {
    show_step "禁用系统自动更新 (APT)"

    local units=(apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer)
    for u in "${units[@]}"; do
        if systemctl list-unit-files | grep -q "^${u}"; then
            systemctl stop "$u" >/dev/null 2>&1 || true
            systemctl disable "$u" >/dev/null 2>&1 || true
            [[ "$u" == *.service ]] && systemctl mask "$u" >/dev/null 2>&1 || true
        fi
    done

    for u in apt-news.timer apt-news.service; do
        systemctl stop "$u" >/dev/null 2>&1 || true
        systemctl disable "$u" >/dev/null 2>&1 || true
        systemctl mask "$u" >/dev/null 2>&1 || true
    done

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    mkdir -p /etc/apt/apt.conf.d
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    cat >/etc/apt/apt.conf.d/10periodic <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
EOF

    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        systemctl stop unattended-upgrades >/dev/null 2>&1 || true
        systemctl disable unattended-upgrades >/dev/null 2>&1 || true
    fi

    if [ -f /etc/cron.daily/apt-compat ]; then
        sed -i 's/^exec .*/exit 0 # disabled by initializer/' /etc/cron.daily/apt-compat 2>/dev/null || true
        chmod -x /etc/cron.daily/apt-compat 2>/dev/null || true
    fi

    log_success "APT 自动更新已禁用"
}


setup_repositories() {
    show_step "配置软件源"

    local DEB822_FILE="/etc/apt/sources.list.d/ubuntu.sources"
    local LEGACY_FILE="/etc/apt/sources.list"

    local MIRROR_HOST="https://mirrors.aliyun.com/ubuntu"

    if [ -f "$DEB822_FILE" ]; then
        log_info "检测到 deb822 软件源文件: $DEB822_FILE"
        if [ ! -f "${DEB822_FILE}.backup" ]; then
            cp "$DEB822_FILE" "${DEB822_FILE}.backup"
            log_info "已备份: ${DEB822_FILE}.backup"
        fi
        for host in archive.ubuntu.com security.ubuntu.com ports.ubuntu.com us.archive.ubuntu.com; do
            if grep -q "^URIs: http://$host/ubuntu" "$DEB822_FILE"; then
                sed -i "s#^URIs: http://$host/ubuntu#URIs: $MIRROR_HOST#" "$DEB822_FILE" || true
            fi
        done
        if grep -q "mirrors.aliyun.com" "$DEB822_FILE"; then
            log_success "deb822 源镜像已切换为阿里云"
        else
            log_warning "deb822 源镜像替换可能失败 (未匹配到 URIs 行)"
        fi
    else
        log_info "未发现 deb822 文件，尝试使用传统 sources.list"
    fi

    if [ -f "$LEGACY_FILE" ]; then
        log_info "备份 $LEGACY_FILE ..."
        if [ ! -f "${LEGACY_FILE}.backup" ]; then
            cp "$LEGACY_FILE" "${LEGACY_FILE}.backup"
        fi

        # Replace specific regional archive hosts (cn/us) as well as generic archive/ports
        sed -i 's|http://cn.archive.ubuntu.com|https://mirrors.aliyun.com|g' "$LEGACY_FILE" || true
        sed -i 's|http://us.archive.ubuntu.com|https://mirrors.aliyun.com|g' "$LEGACY_FILE" || true
        sed -i 's|http://\(archive\|ports\)\.ubuntu\.com|https://mirrors.aliyun.com|g' "$LEGACY_FILE" || true
        sed -i 's|http://security\.ubuntu\.com|https://mirrors.aliyun.com|g' "$LEGACY_FILE" || true
    fi

    apt-get update || log_error "apt 源更新失败"
    log_success "软件源配置完成"
}


setup_python() {
    show_step "配置 Python 环境"

    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
        log_info "当前Python版本: $PYTHON_VERSION"
    fi

    log_info "尝试安装 Python 3..."
    apt-get install -y python3 python3-dev python3-pip || {
        log_warning "Python 3 安装失败，使用系统默认Python版本"
    }

    log_info "配置 pip 阿里云镜像源..."
    write_pip_conf "$HOME" "root"
    if user_home="$(resolve_user_home)"; then
        write_pip_conf "$user_home" "$USERNAME"
    else
        log_warning "无法解析用户 Home 目录，跳过写入用户级 pip.conf: $USERNAME"
    fi

    EXTERNALLY_MANAGED_FILE=$(python3 -c 'import sysconfig,os;print(os.path.join(sysconfig.get_paths()["purelib"],"EXTERNALLY-MANAGED"))' 2>/dev/null || echo /nonexistent)
    PIP_CMD="python3 -m pip"
    PY_VENV_DIR="/opt/initializer-venv"
    if [ -f "$EXTERNALLY_MANAGED_FILE" ]; then
        log_info "检测到 PEP 668 受管环境，创建虚拟环境: $PY_VENV_DIR"
        apt-get install -y python3-venv >/dev/null 2>&1 || true
        if [ ! -d "$PY_VENV_DIR" ]; then
            python3 -m venv "$PY_VENV_DIR" || log_error "虚拟环境创建失败"
        fi
        PIP_CMD="$PY_VENV_DIR/bin/pip"
        log_info "升级虚拟环境 pip/setuptools/wheel..."
        "$PIP_CMD" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            --upgrade pip wheel setuptools || log_warning "虚拟环境基础组件升级失败"
        cat > /etc/profile.d/initializer_python.sh <<EOF_PYENV
# initializer python venv
if [ -d "$PY_VENV_DIR" ]; then
    export PATH="$PY_VENV_DIR/bin:\$PATH"
fi
EOF_PYENV
        chmod 644 /etc/profile.d/initializer_python.sh || true
    else
        log_info "未检测到 EXTERNALLY-MANAGED，升级系统 pip"
        $PIP_CMD install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            --upgrade pip wheel setuptools || log_warning "系统 pip 升级部分失败"
    fi

    log_info "安装Python依赖包 (使用: $PIP_CMD) ..."
    if [ -f "$EXTERNALLY_MANAGED_FILE" ]; then
        # 在受管环境中，只在虚拟环境里安装依赖
        $PIP_CMD install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            ansible jmespath dnspython docker jinja2-cli || log_warning "虚拟环境中部分Python依赖包安装失败"
    else
        # 非受管环境下（Ubuntu 22.04 等）可直接安装到系统环境
        $PIP_CMD install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            ansible jmespath dnspython docker jinja2-cli || log_warning "系统环境中部分Python依赖包安装失败"
    fi

    log_info "配置 mlocate 忽略目录: /mnt, /tmp"
    UPDATEDB_CONF="/etc/updatedb.conf"
    touch "$UPDATEDB_CONF" && chmod 644 "$UPDATEDB_CONF"
    tmpfile="$(mktemp)"
    awk '
BEGIN {
    found = 0
}
{
    if ($0 ~ /^[[:space:]]*PRUNEPATHS=/ && $0 !~ /^[[:space:]]*#/) {
        found = 1
        paths = ""
        if (match($0, /PRUNEPATHS="[^"]*"/)) {
            paths = substr($0, RSTART + 11, RLENGTH - 12)
        }
        if (paths !~ /(^|[[:space:]])\/mnt([[:space:]]|$)/) {
            paths = paths " /mnt"
        }
        if (paths !~ /(^|[[:space:]])\/tmp([[:space:]]|$)/) {
            paths = paths " /tmp"
        }
        gsub(/[[:space:]]+/, " ", paths)
        sub(/^[[:space:]]+/, "", paths)
        print "PRUNEPATHS=\"" paths "\""
        next
    }
    print
}
END {
    if (found == 0) {
        print "PRUNEPATHS=\"/tmp /mnt\""
    }
}
' "$UPDATEDB_CONF" > "$tmpfile" && mv "$tmpfile" "$UPDATEDB_CONF" || { rm -f "$tmpfile"; log_warning "mlocate 忽略目录配置失败"; }
    updatedb || log_warning "updatedb 执行失败"
    log_success "Python环境配置完成"
}


# 安装yq工具
install_yq() {
    show_step "安装 yq 工具"

    if command -v yq &> /dev/null; then
        log_info "yq 已安装，跳过"
        return 0
    fi

    local yq_path="${TOOLS_DIR}/yq_linux_amd64"
    if [ ! -f "$yq_path" ]; then
        log_warning "yq 二进制文件不存在: $yq_path，跳过安装"
        return 0
    fi

    install -m 0755 "$yq_path" /usr/local/bin/yq || {
        log_warning "yq 安装命令执行失败"
        return 0
    }

    if ! command -v yq &> /dev/null; then
        log_error "yq 安装失败"
    fi

    log_success "yq 安装成功"
}


setup_ssh() {
    show_step "配置 SSH 服务"

    if ! dpkg -s openssh-server >/dev/null 2>&1; then
        log_info "安装OpenSSH服务器..."
        apt-get install -y openssh-server || log_error "OpenSSH服务器安装失败"
    else
        log_info "OpenSSH服务器已安装"
    fi

    SSHD_CONFIG="/etc/ssh/sshd_config"
    if [ ! -f "${SSHD_CONFIG}.bak" ]; then
        cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"
    fi

    log_info "修改SSH配置..."
    set_sshd_config() {
        local param="$1"
        local value="$2"
        local config_file="$3"

        if grep -q "^[[:space:]]*${param}[[:space:]]*" "$config_file"; then
            sed -i -E "s|^[[:space:]]*${param}[[:space:]]*.*|${param} ${value}|" "$config_file"
        elif grep -q "^[[:space:]]*#[[:space:]]*${param}" "$config_file"; then
            sed -i -E "s|^[[:space:]]*#[[:space:]]*${param}[[:space:]]*.*|${param} ${value}|" "$config_file"
        else
            echo "${param} ${value}" >> "$config_file"
        fi
    }

    set_sshd_config "PermitRootLogin" "yes" "$SSHD_CONFIG"
    set_sshd_config "PasswordAuthentication" "yes" "$SSHD_CONFIG"
    set_sshd_config "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
    set_sshd_config "AuthorizedKeysFile" ".ssh/authorized_keys" "$SSHD_CONFIG"

    log_info "启动SSH服务..."
    systemctl enable ssh || true
    systemctl restart ssh || true

    if systemctl is-active --quiet ssh; then
        log_success "SSH服务启动成功"
    else
        log_error "SSH服务启动失败"
    fi
}


setup_firewall() {
    show_step "配置防火墙"

    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw || log_warning "UFW 安装失败"
    fi

    if command -v ufw >/dev/null 2>&1; then
        log_info "配置 UFW 以允许 SSH..."
        ufw allow OpenSSH >/dev/null 2>&1 || ufw allow ssh >/dev/null 2>&1 || true
        yes | ufw enable >/dev/null 2>&1 || true
        ufw status verbose || true
        log_success "UFW 已配置"
    else
        log_warning "UFW 不可用，跳过防火墙配置"
    fi
}


main() {
	resolve_username "${1:-}"
	configure_user_privileges

    # Immediately try to disable automatic updates to avoid apt locks
    disable_automatic_updates

    setup_repositories
    install_basic_packages
    setup_python
    install_yq

    # 安装gum
    log_info "安装gum工具..."
    local gum_deb="${TOOLS_DIR}/gum_0.16.0_amd64.deb"
    if [ -f "$gum_deb" ]; then
        dpkg -i "$gum_deb" || apt-get install -f -y || log_warning "gum安装可能失败"
        if command -v gum &> /dev/null; then
            log_success "gum安装成功"
        fi
    else
        log_warning "gum DEB 文件不存在: $gum_deb"
    fi

    setup_ssh
    setup_firewall

    log_success "初始化完成"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
