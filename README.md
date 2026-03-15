# 🚀 Node Setup

Скрипт оптимизации ВМ для нод на базе Remnawave/Xray-core.

Одна команда — полная настройка сервера с интерактивным вводом портов и IP панели.

## ⚡ Быстрый старт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ibmaga/fast-setting-node/main/node-setup.sh)
```

Скрипт запросит:
- **Порты VLESS Reality** (через запятую, например: `443,8443,9443`)
- **NODE_PORT** для API Remnawave (по умолчанию `2222`)
- **IP панели Remnawave** — NODE_PORT будет открыт только для этого IP
- **IP Prometheus** (опционально, для node_exporter)
- **Swap** — да/нет (рекомендуется для защиты от OOM)
- **Reboot** — автоматически предложит перезагрузку в конце

## 📋 Что настраивается

| Компонент | Что делает |
|-----------|-----------|
| **BBR** | TCP congestion control — быстрее чем cubic |
| **sysctl** | TCP буферы, backlog, conntrack, keepalive |
| **RPS** | Распределение пакетов по всем ядрам CPU |
| **Swap** | Защита от OOM-kill (опционально, размер по RAM) |
| **Conntrack** | Автоматический расчёт по RAM (262K–1M) |
| **nofile** | Лимит файловых дескрипторов 1048576 |
| **UFW** | Firewall с комментариями, NODE_PORT только для IP панели |
| **Fail2ban** | Защита SSH от брутфорса |
| **DNS over TLS** | Cloudflare + Google DoT |
| **Docker** | Установка если отсутствует |
| **Logrotate** | Ротация логов remnanode (50MB, 5 файлов) |
| **Auto-update** | Cron обновления контейнера (суббота 05:00 UTC) |

## 🧮 Автоматические расчёты по RAM

| RAM | Conntrack max | TCP buf max | Swap |
|-----|--------------|-------------|------|
| ≤4 ГБ | 262,144 | 8 МБ | 2 ГБ |
| 5–8 ГБ | 524,288 | 16 МБ | 2 ГБ |
| 9–16 ГБ | 524,288 | 16 МБ | 4 ГБ |
| >16 ГБ | 1,048,576 | 16 МБ | 4 ГБ |

## 🔧 RPS (Receive Packet Steering)

На VPS с single-queue VirtIO NIC (99% серверов) все пакеты обрабатывает одно ядро CPU. Скрипт автоматически:

1. Определяет интерфейс и количество RX queues
2. Если single-queue — включает RPS на все ядра
3. Если multiqueue (≥ кол-во CPU) — пропускает
4. Создаёт systemd service для persistence после ребута

## 📁 Что создаётся

```
/opt/remnanode/                                # Директория для docker-compose.yml
/var/log/remnanode/                            # Логи Xray
/etc/sysctl.d/99-vpn-node.conf                # BBR, TCP буферы, conntrack
/etc/sysctl.d/99-swap.conf                     # swappiness (если swap включён)
/etc/security/limits.d/99-vpn-node.conf        # nofile limits
/etc/systemd/system/rps-tuning.service         # RPS persistent
/etc/logrotate.d/remnanode                     # Ротация логов
/etc/cron.d/remnawave-update                   # Автообновление ноды
```

## ✅ Проверка после ребута

```bash
sysctl net.ipv4.tcp_congestion_control          # → bbr
sysctl net.netfilter.nf_conntrack_max            # → 524288
cat /sys/class/net/eth0/queues/rx-0/rps_cpus     # → f (4 ядра) или ff (8 ядер)
ulimit -n                                         # → 1048576
swapon --show                                     # → /swapfile (если включён)
ufw status                                        # → правила на месте
```

## ⚠️ Важно

- Поддерживается **только Ubuntu/Debian**
- Требуется **root** доступ
- В конце скрипт предложит **reboot** — для полного применения настроек ребут обязателен
- Скрипт **не устанавливает** Remnawave Node — только подготавливает ВМ
- `Automatic-Reboot` в unattended-upgrades **не включается** (опасно для VPN)
- Access log Xray **не рекомендуется** для production (гигабайты записей)

## 🔄 Повторный запуск

Скрипт можно запускать повторно. UFW сбрасывается и создаётся заново, sysctl конфиги перезаписываются без дублирования.

## 📚 После настройки и ребута

1. Создайте ноду в панели Remnawave
2. Скопируйте `docker-compose.yml` в `/opt/remnanode/`
3. Запустите: `cd /opt/remnanode && docker compose up -d`

## 📝 Лицензия

MIT
