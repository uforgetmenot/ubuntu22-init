#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

install_codeserver() {
    show_step "安装 code-server"

    if command -v code-server &>/dev/null; then
        log_info "code-server 已安装: $(code-server --version)"
    else
        log_info "开始安装 code-server..."
        # 官方安装脚本
        curl -fsSL https://code-server.dev/install.sh | sh
        log_success "code-server 安装完成"
    fi
}

configure_service() {
    show_step "配置 code-server 服务"

    # 获取当前非 root 用户名 (如果通过 sudo 运行) 或者当前用户名
    local username="${SUDO_USER:-$(whoami)}"
    
    log_info "为用户 $username 启用并启动 code-server 服务..."
    
    # 启用并立即启动服务
    # 注意：install.sh 可能会安装 systemd service 文件到 /lib/systemd/system/
    sudo systemctl enable --now "code-server@$username"
    
    log_success "code-server 服务已启动并设置为开机自启"
    
    # 等待配置文件生成
    sleep 2
    
    # 配置文件通常在 ~/.config/code-server/config.yaml
    # 如果是 sudo 运行脚本但服务是针对用户的，配置文件应该在用户目录下
    local user_home
    if [ "$username" = "root" ]; then
        user_home="/root"
    else
        user_home="/home/$username"
    fi
    
    local config_file="$user_home/.config/code-server/config.yaml"
    
    if [ -f "$config_file" ]; then
        log_info "配置文件位置: $config_file"
        log_info "当前配置内容 (密码在此文件中):"
        # 使用 sudo 读取，因为如果是其他用户的文件可能无法直接读取
        sudo cat "$config_file"
    else
        log_warning "配置文件尚未生成: $config_file"
        log_info "请尝试手动运行一次 'code-server' 或检查服务状态"
    fi
}

main() {
    show_step "开始安装和配置 code-server"

    install_codeserver
    configure_service

    local username="${SUDO_USER:-$(whoami)}"
    show_step "code-server 安装和配置完成!"
    log_info "访问地址: http://127.0.0.1:8080 (默认)"
    log_info "查看状态: systemctl status code-server@$username"
    log_info "修改配置: ~/.config/code-server/config.yaml (重启服务生效)"
}

main "$@"
