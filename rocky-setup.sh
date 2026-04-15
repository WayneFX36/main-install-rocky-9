#!/bin/bash

# Скрипт первоначальной настройки Rocky Linux
# Выполнять с правами root

set -e

# Конфигурационные переменные
NEW_SSH_PORT=29650
FAIL2BAN_BANTIME="1h"
FAIL2BAN_FINDTIME="10m"
FAIL2BAN_MAXRETRY=3

echo "========================================="
echo "Начало первоначальной настройки Rocky Linux"
echo "========================================="

# 1. Настройка swap файла
echo "1. Создание swap файла (2GB)..."

if [ -f /swapfile ]; then
    echo "Swap файл уже существует. Деактивируем текущий swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
fi

dd if=/dev/zero of=/swapfile bs=1024 count=2097152 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
free -h

if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
    echo "Swap добавлен в fstab"
else
    echo "Swap уже есть в fstab"
fi

# 2. Настройка DNS
echo "2. Настройка DNS серверов..."
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
cat /etc/resolv.conf

# 3. Обновление системы и установка базовых пакетов
echo "3. Обновление системы и установка пакетов..."
dnf update -y
dnf install -y epel-release
dnf install -y nano vim net-tools htop wget curl firewalld crontabs \
    socat yum-utils tar gzip zip unzip logrotate policycoreutils-python-utils

# 4. Установка Docker
echo "4. Установка Docker..."
dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
echo "Docker установлен и запущен"

# 5. Настройка Firewalld
echo "5. Настройка Firewalld..."
systemctl start firewalld
systemctl enable --now firewalld

firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

echo "Firewalld настроен, открыты порты 80 и 443"

# 6. Смена порта SSH
echo "6. Смена порта SSH на ${NEW_SSH_PORT}..."

# Создаем бэкап конфига SSH
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

# Добавляем SELinux разрешение для нового порта
semanage port -a -t ssh_port_t -p tcp ${NEW_SSH_PORT} 2>/dev/null || \
    semanage port -m -t ssh_port_t -p tcp ${NEW_SSH_PORT}

# Изменяем порт в конфиге SSH
sed -i "s/^#Port 22/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config

# Если порт не был указан, добавляем его
if ! grep -q "^Port ${NEW_SSH_PORT}" /etc/ssh/sshd_config; then
    echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
fi

# Настройка firewall
firewall-cmd --permanent --add-port=${NEW_SSH_PORT}/tcp
firewall-cmd --permanent --remove-service=ssh
firewall-cmd --reload

echo "SSH порт изменен на ${NEW_SSH_PORT}"

# 7. Настройка fail2ban
echo "7. Настройка fail2ban..."

# Устанавливаем fail2ban
dnf install -y fail2ban fail2ban-firewalld

# Создаем jail.local
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
banaction = iptables-ipset-proto6
banaction_allports = iptables-allports

[sshd]
enabled     = true
maxretry    = 6
port        = ${NEW_SSH_PORT}
backend     = systemd
logpath     = %(sshd_log)s

[sshd-ddos]
enabled     = true
port        = ${NEW_SSH_PORT}
logpath     = %(sshd_log)s
maxretry    = 3
findtime    = 5m
bantime     = 2h

[recidive]
enabled     = true
logpath     = /var/log/fail2ban.log
maxretry    = 5
findtime    = 1d
bantime     = 1w
EOF

# Настройка fail2ban для работы с firewalld
cat > /etc/fail2ban/action.d/firewalld-cmd.local << EOF
[Definition]
actionstart = 
actionstop = 
actioncheck = 
actionban = firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<ip> port port=<port> protocol=tcp reject' && firewall-cmd --reload
actionunban = firewall-cmd --permanent --remove-rich-rule='rule family=ipv4 source address=<ip> port port=<port> protocol=tcp reject' && firewall-cmd --reload
EOF

# Создаем фильтр для дополнительной защиты
cat > /etc/fail2ban/filter.d/ssh-extra.conf << EOF
[Definition]
failregex = ^%(__prefix_line)sReceived disconnect from <HOST>: 11: .* \[preauth\]$
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers$
            ^%(__prefix_line)sInvalid user .* from <HOST>$
            ^%(__prefix_line)sConnection from <HOST> port .*$
ignoreregex =
EOF

# 8. Настройка автоблокировки при сканировании портов
echo "8. Настройка дополнительной защиты..."
cat > /etc/fail2ban/filter.d/port-scan.conf << EOF
[Definition]
failregex = ^<HOST> -.* \[.*\] "GET /.*" 40\d .*$
            ^<HOST> -.* \[.*\] "POST /.*" 40\d .*$
            ^<HOST> -.* \[.*\] "HEAD /.*" 40\d .*$
ignoreregex =
EOF

# 9. Установка micro редактора
echo "9. Установка micro редактора..."
if ! command -v micro &> /dev/null; then
    curl -s https://getmic.ro | bash
    mv micro /usr/local/bin/
    chmod +x /usr/local/bin/micro
    echo "Micro установлен"
else
    echo "Micro уже установлен"
fi

# 10. Настройка сетевых параметров
echo "10. Настройка сетевых параметров..."

# Применяем параметры напрямую без функции
for param in \
    "net.core.default_qdisc = fq" \
    "net.ipv4.tcp_congestion_control = bbr" \
    "net.core.netdev_max_backlog = 65536" \
    "net.core.somaxconn = 4096" \
    "net.ipv4.tcp_fastopen = 3" \
    "net.ipv4.tcp_max_syn_backlog = 4096" \
    "net.ipv4.tcp_mtu_probing = 1" \
    "net.ipv4.tcp_syncookies = 1" \
    "net.ipv4.tcp_syn_retries = 2" \
    "net.ipv4.tcp_synack_retries = 2"
do
    param_name=$(echo $param | cut -d'=' -f1 | sed 's/ $//')
    if grep -q "^$param_name" /etc/sysctl.conf; then
        sed -i "s/^$param_name.*/$param/" /etc/sysctl.conf
        echo "Обновлен: $param"
    else
        echo "$param" >> /etc/sysctl.conf
        echo "Добавлен: $param"
    fi
done

sysctl -p

echo "Проверка BBR:"
sysctl net.ipv4.tcp_congestion_control

# 11. Запуск и проверка сервисов
echo "11. Запуск сервисов..."

# Перезапускаем SSH с новым портом
systemctl restart sshd

# Запускаем fail2ban
systemctl enable --now fail2ban

# Проверяем статус fail2ban
sleep 2
fail2ban-client status sshd

# 12. Дополнительные настройки
echo "12. Дополнительные настройки..."

# Отключаем вход по паролю (рекомендуется использовать SSH ключи)
read -p "Отключить вход по паролю для SSH? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    echo "Вход по паролю отключен"
fi

# Настраиваем логирование
cat > /etc/logrotate.d/fail2ban << EOF
/var/log/fail2ban.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload fail2ban > /dev/null 2>&1 || true
    endscript
}
EOF

# 13. Очистка кеша
echo "13. Очистка кеша DNF..."
dnf clean all

echo "========================================="
echo "Первоначальная настройка завершена!"
echo "========================================="

echo ""
echo "Статус сервисов:"
echo "- Docker: $(systemctl is-active docker)"
echo "- Firewalld: $(systemctl is-active firewalld)"
echo "- fail2ban: $(systemctl is-active fail2ban)"
echo "- SSH: $(systemctl is-active sshd)"
echo ""
echo "Открытые порты:"
firewall-cmd --list-ports
echo ""
echo "SSH порт: ${NEW_SSH_PORT}"
echo "ВАЖНО! Не закрывайте текущую сессию, пока не проверите подключение на новом порту:"
echo "ssh -p ${NEW_SSH_PORT} user@$(curl -s ifconfig.me)"
echo ""
echo "Статус fail2ban:"
fail2ban-client status
echo ""
echo "Swap:"
free -h
echo ""
echo "Версия Docker:"
docker --version
echo ""
echo "Текущий алгоритм TCP:"
sysctl net.ipv4.tcp_congestion_control
echo ""
echo "Лимиты сети:"
sysctl net.core.somaxconn net.core.netdev_max_backlog
echo ""
echo "========================================="
echo "Логи fail2ban можно посмотреть командой:"
echo "sudo fail2ban-client log sshd"
echo ""
echo "Для просмотра забаненных IP:"
echo "sudo fail2ban-client status sshd"
echo "========================================="
