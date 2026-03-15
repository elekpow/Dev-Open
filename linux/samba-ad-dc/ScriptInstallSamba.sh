#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Проверка на root права
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен быть запущен с правами root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   УСТАНОВКА SAMBA AD DC${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Функция для проверки статуса службы
check_service_status() {
    local service=$1
    if systemctl is-enabled --quiet $service 2>/dev/null; then
        if systemctl is-active --quiet $service 2>/dev/null; then
            echo -e "${YELLOW}  Служба $service активна и включена${NC}"
            return 0
        else
            echo -e "${YELLOW}  Служба $service включена, но не активна${NC}"
            return 0
        fi
    elif systemctl is-masked --quiet $service 2>/dev/null; then
        echo -e "${YELLOW}  Служба $service замаскирована${NC}"
        return 1
    else
        echo -e "${GREEN}  Служба $service не установлена или не замаскирована${NC}"
        return 2
    fi
}

# Шаг 1: Проверка запущенных процессов
echo -e "${YELLOW}[1] Проверка запущенных процессов...${NC}"
ps_output=$(ps ax | grep -E "samba|smbd|nmbd|winbindd|krb5-kdc|bind9|named" | grep -v grep | grep -v "$$")
if [ -n "$ps_output" ]; then
    echo -e "${RED}Найдены процессы:${NC}"
    echo "$ps_output"

    echo -e "${YELLOW}Останавливаем процессы...${NC}"
    pkill -f "samba|smbd|nmbd|winbindd|krb5-kdc|named" 2>/dev/null
    sleep 2
else
    echo -e "${GREEN} Процессы не найдены${NC}"
fi
echo ""

# Шаг 2: Проверка и снятие маскировки со служб
echo -e "${YELLOW}[2] Проверка статуса служб...${NC}"

services=("smbd" "nmbd" "winbind" "krb5-kdc" "bind9" "samba-ad-dc")
for service in "${services[@]}"; do
    check_service_status $service
    if [ $? -eq 1 ]; then
        echo -e "${YELLOW}  Снимаем маскировку с $service...${NC}"
        systemctl unmask $service 2>/dev/null
    fi
done
echo ""

# Шаг 3: Остановка служб
echo -e "${YELLOW}[3] Остановка служб...${NC}"
for service in samba-ad-dc winbind smbd nmbd krb5-kdc bind9; do
    if systemctl list-unit-files | grep -q $service; then
        systemctl stop $service 2>/dev/null
        systemctl disable $service 2>/dev/null
        echo -e "${GREEN}  $service остановлен и отключен${NC}"
    fi
done
echo ""

# Шаг 4: Маскировка 
echo -e "${YELLOW}[4] Маскировка стандартных служб Samba...${NC}"
for service in smbd nmbd winbind; do
    if systemctl list-unit-files | grep -q $service; then
        systemctl mask $service 2>/dev/null
        echo -e "${GREEN}  $service замаскирован${NC}"
    fi
done
echo ""

# Шаг 5: Полное удаление старых конфигураций
echo -e "${YELLOW}[5] Удаление старых конфигураций...${NC}"
rm -f /etc/samba/smb.conf
rm -rf /etc/samba/smb.conf.d/
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
rm -rf /var/cache/samba/*
rm -f /etc/krb5.conf
rm -f /etc/krb5.conf.d/* 2>/dev/null

# Очистка DNS кеша
rm -rf /var/lib/samba/bind-dns/dns/*
echo -e "${GREEN} Старые конфигурации удалены${NC}"
echo ""

# Шаг 6: Обновление списка пакетов
echo -e "${YELLOW}[6] Обновление списка пакетов...${NC}"
apt update
echo -e "${GREEN} Список пакетов обновлен${NC}"
echo ""

# Шаг 7: Переустановка пакетов (с удалением старых)
echo -e "${YELLOW}[7] Переустановка пакетов...${NC}"

# Список пакетов для установки
packages=(
    "samba"
    "winbind"
    "libpam-winbind"
    "libnss-winbind"
    "libpam-krb5"
    "krb5-config"
    "krb5-user"
    "krb5-kdc"
    "bind9"
    "bind9utils"
    "ldap-utils"
    "ldb-tools"
)

# Сначала удалим старые версии (если есть)
echo -e "${YELLOW}Удаление старых версий пакетов...${NC}"
for pkg in "${packages[@]}"; do
    if dpkg -l | grep -q "^ii.*$pkg"; then
        echo "  Переустановка $pkg..."
        apt remove --purge -y $pkg 2>/dev/null
    fi
done
apt autoremove -y
apt autoclean

echo ""

# Проверка доступности пакетов
echo -e "${YELLOW}Проверка доступности пакетов:${NC}"
available_packages=""
unavailable_packages=""

for pkg in "${packages[@]}"; do
    if apt-cache show "$pkg" 2>/dev/null | grep -q "Package:"; then
        echo -e "${GREEN}   $pkg доступен${NC}"
        available_packages="$available_packages $pkg"
    else
        echo -e "${RED}   $pkg не доступен${NC}"
        unavailable_packages="$unavailable_packages $pkg"
    fi
done

echo ""

if [ -n "$unavailable_packages" ]; then
    echo -e "${YELLOW} Следующие пакеты не доступны:${NC}"
    for pkg in $unavailable_packages; do
        echo "  - $pkg"
    done
    echo ""
fi

if [ -n "$available_packages" ]; then
    echo -e "${YELLOW}Установка доступных пакетов...${NC}"
    
    # Очистка кеша apt
    apt clean
    
    # Установка с автоматическим подтверждением
    apt install -y $available_packages --reinstall

    if [ $? -eq 0 ]; then
        echo -e "${GREEN} Пакеты успешно установлены${NC}"
    else
        echo -e "${RED} Ошибка при установке пакетов${NC}"

        echo -e "${YELLOW}Попытка исправить зависимости...${NC}"
        apt --fix-broken install -y

        # Повторная попытка установки
        apt install -y $available_packages --reinstall
    fi
else
    echo -e "${RED} Нет доступных пакетов для установки${NC}"
    exit 1
fi

# Шаг 8: Проверка установленных пакетов
echo ""
echo -e "${YELLOW}[8] Проверка установленных пакетов:${NC}"

installed_count=0
total_count=${#packages[@]}

for pkg in "${packages[@]}"; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*$pkg"; then
        echo -e "${GREEN}   $pkg установлен${NC}"
        installed_count=$((installed_count + 1))
    else
        echo -e "${RED}   $pkg НЕ установлен${NC}"
    fi
done

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   ИТОГ УСТАНОВКИ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Установлено: $installed_count из $total_count пакетов${NC}"

# Шаг 9: Информация о версиях
echo ""
echo -e "${YELLOW}[9] Версии установленных пакетов:${NC}"
if command -v samba --version &>/dev/null; then
    echo -n "  Samba: "
    samba --version 2>&1 | head -1
fi

if command -v smbd --version &>/dev/null; then
    echo -n "  smbd: "
    smbd --version 2>&1 | head -1
fi

if command -v winbind --version &>/dev/null; then
    echo -n "  winbind: "
    winbind --version 2>&1 | head -1
fi

if command -v krb5kdc --version &>/dev/null; then
    echo -n "  krb5-kdc: "
    krb5kdc --version 2>&1 | head -1
fi

if command -v named --version &>/dev/null; then
    echo -n "  bind9: "
    named --version 2>&1 | head -1
fi
echo ""

# Шаг 10: Создание необходимых директорий
echo -e "${YELLOW}[10] Создание необходимых директорий...${NC}"
mkdir -p /var/log/samba
mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/sysvol
mkdir -p /var/lib/samba/bind-dns
chmod 755 /var/log/samba
chmod 755 /var/lib/samba/private
echo -e "${GREEN} Директории созданы${NC}"
echo ""

# Шаг 11: Проверка, что порт 53 свободен
echo -e "${YELLOW}[11] Проверка порта 53...${NC}"
if netstat -tulpn 2>/dev/null | grep -q ":53 "; then
    echo -e "${RED} Порт 53 занят. Освобождаем...${NC}"
    fuser -k 53/tcp 2>/dev/null
    fuser -k 53/udp 2>/dev/null
    sleep 2
    echo -e "${GREEN} Порт 53 освобожден${NC}"
else
    echo -e "${GREEN} Порт 53 свободен${NC}"
fi
echo ""

# Шаг 12: Рекомендации
echo -e "${YELLOW}[12] Рекомендации:${NC}"
echo "1. Теперь запустите скрипт настройки:"
echo "   sudo ./ScriptConfig.sh"
echo ""
echo "2. Или вручную:"
echo "   sudo samba-tool domain provision --use-rfc2307 --interactive"
echo ""
echo "   - Проверить DNS: host -t A $(hostname -f) 127.0.0.1"
echo "   - Проверить Kerberos: kinit administrator@$(hostname -d | tr '[:lower:]' '[:upper:]')"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}скрипт настройки: ./ScriptConfig.sh${NC}"
echo -e "${GREEN}========================================${NC}"