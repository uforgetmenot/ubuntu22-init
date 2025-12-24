#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

install_docker() {
    show_step "安装 Docker"

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        return 0
    fi

    log_info "开始安装 Docker..."

    if [ -f /etc/apt/sources.list.d/ubuntu.sources.backup ]; then
        log_warning "检测到 /etc/apt/sources.list.d/ubuntu.sources.backup，将被 apt 忽略；如无需保留可删除以消除警告"
    fi

    # 清理可能存在的损坏配置，防止 apt-get update 失败
    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        log_warning "清理现有的 Docker 源配置以避免冲突..."
        sudo rm -f /etc/apt/sources.list.d/docker.list
    fi

    # 更新包索引
    sudo apt-get update

    # 安装依赖
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # 处理 Docker 官方 GPG key 与源
    local keyring="/etc/apt/keyrings/docker.gpg"
    local repo_file="/etc/apt/sources.list.d/docker.list"

    log_info "刷新 Docker GPG key"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo rm -f "$keyring"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o "$keyring"
    sudo chmod a+r "$keyring"

    log_info "写入 Docker 源列表"
    sudo rm -f "$repo_file"
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | \
        sudo tee "$repo_file" > /dev/null

    # 验证 key 是否包含 Docker 的长 ID (7EA0A9C3F273FCD8)
    if ! gpg --show-keys --keyid-format=long "$keyring" | grep -q "7EA0A9C3F273FCD8"; then
        log_error "Docker GPG key 验证失败，请检查网络或手动获取 key 后重试"
        exit 1
    fi

    # 更新包索引
    sudo apt-get update

    # 安装 Docker Engine
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_success "Docker 安装完成: $(docker --version)"
}

configure_docker() {
    show_step "配置 Docker"

    local daemon_json="/etc/docker/daemon.json"
    local backup_json="${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"

    # 备份现有配置
    if [ -f "$daemon_json" ]; then
        log_info "备份现有配置到: $backup_json"
        sudo cp "$daemon_json" "$backup_json"
    fi

    # 创建配置目录
    sudo mkdir -p /etc/docker

    # 写入配置
    log_info "配置 insecure-registries..."
    cat <<'EOF' | sudo tee "$daemon_json" > /dev/null
{
  "insecure-registries": [
    "127.0.0.1:5000",
    "core.yuhuans.cn:5000"
  ],
  "registry-mirrors": [],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

    log_success "Docker 配置文件已更新: $daemon_json"
}

add_user_to_docker_group() {
    show_step "添加用户到 Docker 组"

    local username="${SUDO_USER:-$(whoami)}"

    if groups "$username" | grep -q '\bdocker\b'; then
        log_info "用户 $username 已在 docker 组中"
        return 0
    fi

    log_info "添加用户 $username 到 docker 组..."
    sudo usermod -aG docker "$username"

    log_success "用户 $username 已添加到 docker 组"
    log_warning "需要重新登录或执行 'newgrp docker' 使组权限生效"
}

start_docker_service() {
    show_step "启动 Docker 服务"

    log_info "重启 Docker 服务以应用配置..."
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    sudo systemctl enable docker

    log_success "Docker 服务已启动并设置为开机自启"
}

verify_docker() {
    show_step "验证 Docker 安装"

    log_info "Docker 版本:"
    docker --version

    log_info "Docker Compose 版本:"
    docker compose version

    log_info "Docker 服务状态:"
    sudo systemctl status docker --no-pager | head -n 5

    log_info "Docker 配置:"
    sudo cat /etc/docker/daemon.json

    log_success "Docker 安装和配置验证完成"
}

main() {
    show_step "开始安装和配置 Docker"

    install_docker
    configure_docker
    add_user_to_docker_group
    start_docker_service
    verify_docker

    show_step "Docker 安装和配置完成!"
    log_info "提示: 如果无法使用 docker 命令，请重新登录或执行 'newgrp docker'"
}

main "$@"
