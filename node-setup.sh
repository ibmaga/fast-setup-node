#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  VPN Node Setup — Оптимизация ВМ для Remnawave/Xray            ║
# ║  Автор: ibmaga                                                   ║
# ║  Версия: 1.0.0                                                  ║
# ║                                                                  ║
# ║  Включает: BBR, sysctl tuning, RPS, swap, conntrack,           ║
# ║  UFW, fail2ban, DNS over TLS, logrotate                        ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Цвета ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Логирование ───────────────────────────────────────────────────
log_info()    { echo -e "${WHITE}ℹ️  $*${NC}"; }
log_success() { echo -e "${GREEN}✅ $*${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error()   { echo -e "${RED}❌ $*${NC}" >&2; }
log_step()    { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

# ── Проверки ──────────────────────────────────────────────────────
check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        log_error "Скрипт должен запускаться от root (sudo)"
        exit 1
    fi
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        log_error "Поддерживаются только Ubuntu/Debian"
        exit 1
    fi
    log_success "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
}

# ── Определение сетевого интерфейса ──────────────────────────────
detect_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show up | awk -F': ' '!/lo/{print $2}' | head -1)
    fi
    echo "$iface"
}

# ── Определение количества CPU ───────────────────────────────────
get_cpu_count() {
    nproc
}

# ── Расчёт RPS маски ─────────────────────────────────────────────
calc_rps_mask() {
    local cpus=$1
    printf '%x' $(( (1 << cpus) - 1 ))
}

# ── Определение RAM в ГБ ─────────────────────────────────────────
get_ram_gb() {
    awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo
}

# ── Расчёт swap размера ──────────────────────────────────────────
calc_swap_size() {
    local ram_gb=$1
    if (( ram_gb <= 4 )); then
        echo "2G"
    elif (( ram_gb <= 8 )); then
        echo "2G"
    elif (( ram_gb <= 16 )); then
        echo "4G"
    else
        echo "4G"
    fi
}

# ── Расчёт conntrack_max ─────────────────────────────────────────
calc_conntrack_max() {
    local ram_gb=$1
    if (( ram_gb <= 4 )); then
        echo 262144
    elif (( ram_gb <= 8 )); then
        echo 524288
    elif (( ram_gb <= 16 )); then
        echo 524288
    else
        echo 1048576
    fi
}

# ── Расчёт TCP буферов ───────────────────────────────────────────
calc_tcp_buffers() {
    local ram_gb=$1
    if (( ram_gb <= 4 )); then
        echo "8388608"   # 8 MB
    else
        echo "16777216"  # 16 MB
    fi
}

# ── Валидация IP ──────────────────────────────────────────────────
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# ── Валидация порта ───────────────────────────────────────────────
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    return 1
}

# ══════════════════════════════════════════════════════════════════
#  ИНТЕРАКТИВНЫЙ ВВОД
# ══════════════════════════════════════════════════════════════════

interactive_setup() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       VPN Node Setup — Настройка ВМ                 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local iface ram_gb cpus
    iface=$(detect_interface)
    ram_gb=$(get_ram_gb)
    cpus=$(get_cpu_count)

    echo -e "${WHITE}Обнаружено:${NC}"
    echo -e "  Интерфейс:  ${GREEN}$iface${NC}"
    echo -e "  CPU:        ${GREEN}${cpus} ядер${NC}"
    echo -e "  RAM:        ${GREEN}${ram_gb} ГБ${NC}"
    echo ""

    # ── Порты VLESS Reality ──
    echo -e "${WHITE}Введите порты для VLESS Reality (через запятую):${NC}"
    echo -e "${YELLOW}  Пример: 443,8443,9443${NC}"
    read -rp "Порты: " VLESS_PORTS_INPUT

    # Парсинг и валидация портов
    VLESS_PORTS=()
    IFS=',' read -ra PORT_ARRAY <<< "$VLESS_PORTS_INPUT"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        if validate_port "$port"; then
            VLESS_PORTS+=("$port")
        else
            log_error "Невалидный порт: $port"
            exit 1
        fi
    done

    if [[ ${#VLESS_PORTS[@]} -eq 0 ]]; then
        log_error "Не указано ни одного порта"
        exit 1
    fi
    log_success "Порты VLESS: ${VLESS_PORTS[*]}"
    echo ""

    # ── NODE_PORT (API Remnawave) ──
    echo -e "${WHITE}Введите NODE_PORT для API Remnawave (Enter = 2222):${NC}"
    read -rp "NODE_PORT: " NODE_PORT_INPUT
    NODE_PORT=${NODE_PORT_INPUT:-2222}

    if ! validate_port "$NODE_PORT"; then
        log_error "Невалидный NODE_PORT: $NODE_PORT"
        exit 1
    fi
    echo ""

    # ── Master IP для NODE_PORT ──
    echo -e "${WHITE}Введите IP панели Remnawave (для ограничения доступа к NODE_PORT):${NC}"
    read -rp "IP панели: " MASTER_IP

    if ! validate_ip "$MASTER_IP"; then
        log_error "Невалидный IP: $MASTER_IP"
        exit 1
    fi
    log_success "NODE_PORT $NODE_PORT будет открыт только для $MASTER_IP"
    echo ""

    # ── Prometheus IP (опционально) ──
    echo -e "${WHITE}Введите IP Prometheus сервера для node_exporter (Enter = пропустить):${NC}"
    read -rp "IP Prometheus: " PROMETHEUS_IP

    if [[ -n "$PROMETHEUS_IP" ]] && ! validate_ip "$PROMETHEUS_IP"; then
        log_error "Невалидный IP: $PROMETHEUS_IP"
        exit 1
    fi
    echo ""

    # ── Swap ──
    echo -e "${WHITE}Настроить swap? Рекомендуется для защиты от OOM-kill (y/n, Enter = y):${NC}"
    read -rp "Swap: " SWAP_INPUT
    SETUP_SWAP=true
    if [[ "$SWAP_INPUT" =~ ^[Nn]$ ]]; then
        SETUP_SWAP=false
    fi
    echo ""

    # ── Подтверждение ──
    echo -e "${CYAN}━━━ Подтверждение настроек ━━━${NC}"
    echo ""
    echo -e "  Интерфейс:        ${GREEN}$iface${NC}"
    echo -e "  CPU / RAM:        ${GREEN}${cpus} ядер / ${ram_gb} ГБ${NC}"
    echo -e "  VLESS порты:      ${GREEN}${VLESS_PORTS[*]}${NC}"
    echo -e "  NODE_PORT:        ${GREEN}$NODE_PORT (только $MASTER_IP)${NC}"
    echo -e "  Prometheus:       ${GREEN}${PROMETHEUS_IP:-не установлен}${NC}"
    if [[ "$SETUP_SWAP" == "true" ]]; then
        echo -e "  Swap:             ${GREEN}$(calc_swap_size "$ram_gb")${NC}"
    else
        echo -e "  Swap:             ${YELLOW}пропущен${NC}"
    fi
    echo -e "  Conntrack max:    ${GREEN}$(calc_conntrack_max "$ram_gb")${NC}"
    echo -e "  TCP buf max:      ${GREEN}$(calc_tcp_buffers "$ram_gb")${NC}"
    echo -e "  RPS mask:         ${GREEN}$(calc_rps_mask "$cpus") ($cpus ядер)${NC}"
    echo ""
    read -rp "Начать настройку? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_warning "Отменено"
        exit 0
    fi

    # Экспорт переменных
    export IFACE="$iface"
    export RAM_GB="$ram_gb"
    export CPUS="$cpus"
}

# ══════════════════════════════════════════════════════════════════
#  УСТАНОВКА
# ══════════════════════════════════════════════════════════════════

step_system_update() {
    log_step "1/9 — Обновление системы"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get install -y -qq curl wget mc htop btop iftop logrotate fail2ban ufw \
        >/dev/null 2>&1
    log_success "Система обновлена, пакеты установлены"
}

step_docker() {
    log_step "2/9 — Docker"
    if command -v docker &>/dev/null; then
        log_success "Docker уже установлен: $(docker --version)"
    else
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        log_success "Docker установлен: $(docker --version)"
    fi
}

step_sysctl() {
    log_step "3/9 — Оптимизация ядра (sysctl)"

    local conntrack_max tcp_buf_max
    conntrack_max=$(calc_conntrack_max "$RAM_GB")
    tcp_buf_max=$(calc_tcp_buffers "$RAM_GB")

    cat > /etc/sysctl.d/99-vpn-node.conf << EOF
# ── VPN Node Optimization ─────────────────────────────────────
# Сгенерировано vpn-node-setup.sh ($(date +%Y-%m-%d))
# RAM: ${RAM_GB}GB, CPU: ${CPUS} cores

# ── BBR ───────────────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Backlog & Connections ─────────────────────────────────────
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535

# ── TCP Buffers ───────────────────────────────────────────────
net.core.rmem_max = ${tcp_buf_max}
net.core.wmem_max = ${tcp_buf_max}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 ${tcp_buf_max}
net.ipv4.tcp_wmem = 4096 65536 ${tcp_buf_max}

# ── TCP Timers ────────────────────────────────────────────────
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ── Conntrack ─────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${conntrack_max}

# ── IPv6 (disable if not needed) ─────────────────────────────
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

    # Убедимся что conntrack модуль загружен
    echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
    modprobe nf_conntrack 2>/dev/null || true

    sysctl --system >/dev/null 2>&1
    log_success "sysctl: BBR, conntrack=$conntrack_max, tcp_buf=$tcp_buf_max"
}

step_limits() {
    log_step "4/9 — Лимиты (nofile, systemd)"

    cat > /etc/security/limits.d/99-vpn-node.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    systemctl daemon-reload
    log_success "nofile limits: 1048576"
}

step_rps() {
    log_step "5/9 — RPS (Receive Packet Steering)"

    local rps_mask queues_dir
    rps_mask=$(calc_rps_mask "$CPUS")

    # Проверяем количество RX queues
    queues_dir="/sys/class/net/${IFACE}/queues"
    if [[ ! -d "$queues_dir" ]]; then
        log_warning "Не удалось найти queues для $IFACE — RPS пропущен"
        return 0
    fi

    local hw_queues
    hw_queues=$(ls -d "${queues_dir}"/rx-* 2>/dev/null | wc -l)

    if (( hw_queues > 1 )); then
        # Проверяем multiqueue через ethtool если доступен
        local combined=1
        if command -v ethtool &>/dev/null; then
            combined=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/{val=$2} END{print val+0}')
        fi
        if (( combined >= CPUS )); then
            log_success "Multiqueue NIC ($combined queues) — RPS не нужен"
            return 0
        fi
    fi

    # Применяем RPS
    for rxdir in "${queues_dir}"/rx-*; do
        echo "$rps_mask" > "${rxdir}/rps_cpus" 2>/dev/null || true
        echo 4096 > "${rxdir}/rps_flow_cnt" 2>/dev/null || true
    done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries

    # Persistent через systemd
    cat > /etc/systemd/system/rps-tuning.service << EOF
[Unit]
Description=RPS Tuning for ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for rx in /sys/class/net/${IFACE}/queues/rx-*; do echo ${rps_mask} > \$rx/rps_cpus; echo 4096 > \$rx/rps_flow_cnt; done; echo 32768 > /proc/sys/net/core/rps_sock_flow_entries'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rps-tuning.service >/dev/null 2>&1
    log_success "RPS: mask=0x${rps_mask} на $IFACE ($CPUS ядер), persistent через systemd"
}

step_swap() {
    if [[ "${SETUP_SWAP}" != "true" ]]; then
        log_step "6/9 — Swap (пропущен)"
        log_info "Swap пропущен по выбору пользователя"
        return 0
    fi

    log_step "6/9 — Swap"

    if swapon --show | grep -q '/'; then
        log_success "Swap уже настроен: $(swapon --show --noheadings | awk '{print $3}')"
        return 0
    fi

    local swap_size
    swap_size=$(calc_swap_size "$RAM_GB")

    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    cat > /etc/sysctl.d/99-swap.conf << 'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl --system >/dev/null 2>&1

    log_success "Swap: $swap_size, swappiness=10"
}

step_dns() {
    log_step "7/9 — DNS over TLS"

    cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF

    systemctl restart systemd-resolved
    log_success "DNS: Cloudflare + Google over TLS"
}

step_firewall() {
    log_step "8/9 — Firewall (UFW) + Fail2ban"

    # UFW
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # SSH
    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1

    # VLESS Reality порты
    for port in "${VLESS_PORTS[@]}"; do
        ufw allow "$port"/tcp comment 'VLESS Reality' >/dev/null 2>&1
    done

    # NODE_PORT — только для IP панели
    ufw allow from "$MASTER_IP" to any port "$NODE_PORT" proto tcp comment 'Remnanode API' >/dev/null 2>&1

    # Prometheus node_exporter (опционально)
    if [[ -n "${PROMETHEUS_IP:-}" ]]; then
        ufw allow from "$PROMETHEUS_IP" to any port 9100 proto tcp comment 'Prometheus' >/dev/null 2>&1
        ufw allow from "$PROMETHEUS_IP" to any port 9101 proto tcp comment 'Prometheus TLS' >/dev/null 2>&1
    fi

    ufw --force enable >/dev/null 2>&1
    log_success "UFW: SSH, VLESS(${VLESS_PORTS[*]}), NODE_PORT($NODE_PORT→$MASTER_IP)"

    # Fail2ban
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_success "Fail2ban: enabled"
}

step_logrotate() {
    log_step "9/9 — Директории и логирование"

    mkdir -p /opt/remnanode /var/log/remnanode

    cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    daily
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    # Cron для автообновления ноды (суббота 05:00 UTC)
    cat > /etc/cron.d/remnawave-update << 'EOF'
0 5 * * 6 root cd /opt/remnanode && docker compose pull -q && docker compose down && docker compose up -d >> /var/log/remnawave-update.log 2>&1
EOF
    chmod 644 /etc/cron.d/remnawave-update

    log_success "Директории, logrotate, auto-update cron"
}

# ══════════════════════════════════════════════════════════════════
#  ИТОГИ
# ══════════════════════════════════════════════════════════════════

print_summary() {
    local conntrack_max
    conntrack_max=$(calc_conntrack_max "$RAM_GB")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Настройка завершена!                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Что было сделано:${NC}"
    echo -e "  ✅ Система обновлена, пакеты установлены"
    echo -e "  ✅ Docker установлен"
    echo -e "  ✅ BBR включён"
    echo -e "  ✅ sysctl: conntrack=${conntrack_max}, TCP буферы оптимизированы"
    echo -e "  ✅ nofile limits: 1048576"
    echo -e "  ✅ RPS настроен для $IFACE"
    if [[ "${SETUP_SWAP}" == "true" ]]; then
        echo -e "  ✅ Swap: $(calc_swap_size "$RAM_GB")"
    else
        echo -e "  ⏭️  Swap: пропущен"
    fi
    echo -e "  ✅ DNS over TLS (Cloudflare + Google)"
    echo -e "  ✅ UFW: порты ${VLESS_PORTS[*]}, NODE_PORT $NODE_PORT→$MASTER_IP"
    echo -e "  ✅ Fail2ban включён"
    echo -e "  ✅ Logrotate + auto-update cron"
    echo ""
    echo -e "${YELLOW}После ребута:${NC}"
    echo -e "  1. ${WHITE}Создайте ноду в панели Remnawave${NC}"
    echo -e "  2. ${WHITE}Скопируйте docker-compose.yml в${NC} /opt/remnanode/"
    echo -e "  3. ${WHITE}Запустите:${NC} cd /opt/remnanode && docker compose up -d"
    echo ""
    echo -e "${YELLOW}Проверка после ребута:${NC}"
    echo -e "  sysctl net.ipv4.tcp_congestion_control     # → bbr"
    echo -e "  sysctl net.netfilter.nf_conntrack_max       # → ${conntrack_max}"
    echo -e "  cat /sys/class/net/${IFACE}/queues/rx-0/rps_cpus  # → $(calc_rps_mask "$CPUS")"
    echo -e "  ulimit -n                                    # → 1048576"
    if [[ "${SETUP_SWAP}" == "true" ]]; then
        echo -e "  swapon --show                                # → swap активен"
    fi
    echo -e "  ufw status                                   # → правила на месте"
    echo ""

    # ── Reboot ──
    read -rp "Перезагрузить сервер сейчас? (y/n): " REBOOT_CONFIRM
    if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Перезагрузка через 5 секунд..."
        sleep 5
        reboot
    else
        log_warning "Не забудьте перезагрузить сервер: reboot"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

main() {
    check_root
    check_os
    interactive_setup

    step_system_update
    step_docker
    step_sysctl
    step_limits
    step_rps
    step_swap
    step_dns
    step_firewall
    step_logrotate

    print_summary
}

main "$@"
