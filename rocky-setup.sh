#!/bin/bash

# Скрипт первоначальной настройки Rocky Linux
# Выполнять с правами root

set -e  # Остановка при ошибке

echo "========================================="
echo "Начало первоначальной настройки Rocky Linux"
echo "========================================="

# 1. Настройка swap файла
echo "1. Создание swap файла (2GB)..."

# Проверяем, существует ли уже swap файл
if [ -f /swapfile ]; then
    echo "Swap файл уже существует. Деактивируем текущий swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
fi

# Создаем новый swap файл
dd if=/dev/zero of=/swapfile bs=1024 count=2097152 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
free -h

# Добавляем в fstab, если еще нет
if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
    echo "Swap добавлен в fstab"
else
    echo "Swap уже есть в fstab"
fi

# 2. Настройка DNS
echo "2. Настройка DNS серверов..."
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
cat /etc/resolv.conf

# 3. Обновление системы и установка базовых пакетов
echo "3. Обновление системы и установка пакетов..."
dnf update -y
dnf install -y epel-release
dnf install -y nano vim net-tools htop wget curl firewalld crontabs \
    socat yum-utils tar gzip zip unzip logrotate fail2ban fail2ban-firewalld

# 4. Установка Docker
echo "4. Установка Docker..."
# Удаление старых версий
dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

# Добавление репозитория Docker
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Установка Docker
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Запуск Docker
systemctl enable --now docker
echo "Docker установлен и запущен"

# 5. Настройка Firewalld
echo "5. Настройка Firewalld..."
systemctl start firewalld
systemctl enable --now firewalld

# Открытие портов
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

# 7. Настройка сетевых параметров (BBR и оптимизация)
echo "7. Настройка сетевых параметров..."

# Функция добавления параметров sysctl
add_sysctl_param() {
    local param="$1"
    local value="$2"
    if grep -q "^$param" /etc/sysctl.conf; then
        # Заменяем существующий параметр
        sed -i "s/^$param.*/$param = $value/" /etc/sysctl.conf
        echo "Обновлен параметр: $param = $value"
    else
        # Добавляем новый параметр
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

# Применение параметров
sysctl -p

# Проверка BBR
echo "Проверка BBR:"
sysctl net.ipv4.tcp_congestion_control

# 8. Дополнительные настройки
echo "8. Дополнительные настройки..."

# Настройка fail2ban
if systemctl is-enabled fail2ban &>/dev/null; then
    echo "fail2ban уже настроен"
else
    systemctl enable fail2ban
    systemctl start fail2ban
    echo "fail2ban запущен"
fi

# Настройка автозагрузки сервисов
systemctl enable firewalld docker

# 9. Очистка кеша
echo "9. Очистка кеша DNF..."
dnf clean all

echo "========================================="
echo "Первоначальная настройка завершена!"
echo "========================================="

# Вывод информации о состоянии
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