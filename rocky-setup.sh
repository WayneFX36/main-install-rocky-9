#!/bin/bash

# Скрипт первоначальной настройки Rocky Linux
# Выполнять с правами root

set -e

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
    socat yum-utils tar gzip zip unzip logrotate fail2ban fail2ban-firewalld

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

# 6. Установка micro редактора
echo "6. Установка micro редактора..."
if ! command -v micro &> /dev/null; then
    curl -s https://getmic.ro | bash
    mv micro /usr/local/bin/
    chmod +x /usr/local/bin/micro
    echo "Micro установлен"
else
    echo "Micro уже установлен"
fi

# 7. Настройка сетевых параметров
echo "7. Настройка сетевых параметров..."

add_sysctl_param() {
    local param="$1"
    local value="$2"
    if grep -q "^$param" /etc/sysctl.conf; then
        sed -i "s/^$param.*/$param = $value/" /etc/sysctl.conf
        echo "Обновлен параметр: $param = $value"
    else
        echo "$param = $value" >> /etc/sysctl.conf
        echo "Добавлен параметр: $param = $value"
    fi
}

add_sysctl_param "net.core.default_qdisc" "fq"
add_sysctl_param "net.ipv4.tcp_congestion_control" "bbr"
add_sysctl_param "net.core.netdev_max_backlog" "65536"
add_sysctl_param "net.core.somaxconn" "4096"
add_sysctl_param "net.ipv4.tcp_fastopen" "3"
add_sysctl_param "net.ipv4.tcp_max_syn_backlog" "4096"
add_sysctl_param "net.ipv4.tcp_mtu_probing" "1"

sysctl -p

echo "Проверка BBR:"
sysctl net.ipv4.tcp_congestion_control

# 8. Дополнительные настройки
echo "8. Дополнительные настройки..."

if systemctl is-enabled fail2ban &>/dev/null; then
    echo "fail2ban уже настроен"
else
    systemctl enable fail2ban
    systemctl start fail2ban
    echo "fail2ban запущен"
fi

systemctl enable firewalld docker

# 9. Очистка кеша
echo "9. Очистка кеша DNF..."
dnf clean all

echo "========================================="
echo "Первоначальная настройка завершена!"
echo "========================================="

echo ""
echo "Статус сервисов:"
echo "- Docker: $(systemctl is-active docker)"
echo "- Firewalld: $(systemctl is-active firewalld)"
echo "- fail2ban: $(systemctl is-active fail2ban)"
echo ""
echo "Открытые порты:"
firewall-cmd --list-ports
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
