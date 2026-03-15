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

# Шаг 1: Проверка запущенных процессов
echo -e "${YELLOW}[1] Проверка запущенных процессов...${NC}"
ps_output=$(ps ax | grep -E "samba|smbd|nmbd|winbindd|krb5-kdc" | grep -v grep | grep -v "$$")
if [ -n "$ps_output" ]; then
    echo -e "${RED}Найдены процессы:${NC}"
    echo "$ps_output"
else
    echo -e "${GREEN} Процессы не найдены${NC}"
fi
echo ""

# Шаг 2: Остановка служб
echo -e "${YELLOW}[2] Остановка служб...${NC}"
systemctl stop winbind smbd nmbd krb5-kdc 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN} Службы остановлены${NC}"
else
    echo -e "${YELLOW} Некоторые службы не были остановлены (возможно, они не запущены)${NC}"
fi

# Шаг 3: Маскировка служб
echo -e "${YELLOW}[3] Маскировка служб...${NC}"
systemctl mask winbind smbd nmbd krb5-kdc 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN} Службы замаскированы${NC}"
else
    echo -e "${YELLOW} Службы уже замаскированы или не существуют${NC}"
fi

# Шаг 4: Удаление конфигурационного файла Samba
echo -e "${YELLOW}[4] Удаление конфигурационного файла Samba...${NC}"
if [ -f /etc/samba/smb.conf ]; then
    rm -f /etc/samba/smb.conf
    echo -e "${GREEN} Файл /etc/samba/smb.conf удален${NC}"
else
    echo -e "${GREEN} Файл /etc/samba/smb.conf не существует${NC}"
fi

# Шаг 5: Обновление списка пакетов
echo -e "${YELLOW}[5] Обновление списка пакетов...${NC}"
apt update
echo -e "${GREEN} Список пакетов обновлен${NC}"
echo ""

# Шаг 6: Установка пакетов
echo -e "${YELLOW}[6] Установка пакетов...${NC}"

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
	#"bind9utils"
    "ldap-utils"
    "ldb-tools"
)

# Проверка доступности пакетов
echo -e "${YELLOW}Проверка доступности пакетов:${NC}"
available_packages=""
unavailable_packages=""

for pkg in "${packages[@]}"; do
    if apt-cache show "$pkg" 2>/dev/null | grep -q "Package:"; then
        echo -e "${GREEN}  $pkg доступен${NC}"
        available_packages="$available_packages $pkg"
    else
        echo -e "${RED}  $pkg не доступен${NC}"
        unavailable_packages="$unavailable_packages $pkg"
    fi
done

echo ""

if [ -n "$unavailable_packages" ]; then
    echo -e "${YELLOW} Следующие пакеты не доступны и не будут установлены:${NC}"
    for pkg in $unavailable_packages; do
        echo "  - $pkg"
    done
    echo ""
fi

if [ -n "$available_packages" ]; then
    echo -e "${YELLOW}Установка доступных пакетов...${NC}"

    # Установка с автоматическим подтверждением
    apt install -y $available_packages

    if [ $? -eq 0 ]; then
        echo -e "${GREEN} Пакеты успешно установлены${NC}"
    else
        echo -e "${RED} Ошибка при установке пакетов${NC}"

        # Попытка исправить зависимости
        echo -e "${YELLOW}Попытка исправить зависимости...${NC}"
        apt --fix-broken install -y

        # Повторная попытка установки
        apt install -y $available_packages
    fi
else
    echo -e "${RED}✗ Нет доступных пакетов для установки${NC}"
fi

# Шаг 7: Проверка установленных пакетов
echo ""
echo -e "${YELLOW}[7] Проверка установленных пакетов:${NC}"

installed_count=0
total_count=${#packages[@]}

for pkg in "${packages[@]}"; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*$pkg"; then
        echo -e "${GREEN}  $pkg установлен${NC}"
        installed_count=$((installed_count + 1))
    else
        echo -e "${RED}  $pkg НЕ установлен${NC}"
    fi
done

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   ИТОГ УСТАНОВКИ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Установлено: $installed_count из $total_count пакетов${NC}"

# Шаг 8: Информация о версиях
echo ""
echo -e "${YELLOW}Версии установленных пакетов:${NC}"
if command -v samba --version &>/dev/null; then
    echo -n "Samba: "
    samba --version 2>&1 | head -1
fi

if command -v smbd --version &>/dev/null; then
    echo -n "smbd: "
    smbd --version 2>&1 | head -1
fi

if command -v winbind --version &>/dev/null; then
    echo -n "winbind: "
    winbind --version 2>&1 | head -1
fi

if command -v krb5kdc --version &>/dev/null; then
    echo -n "krb5-kdc: "
    krb5kdc --version 2>&1 | head -1
fi

if command -v named --version &>/dev/null; then
    echo -n "bind9: "
    named --version 2>&1 | head -1
fi

# Шаг 9: Рекомендации
echo ""
echo -e "${YELLOW}Рекомендации:${NC}"
echo "1. Для настройки Samba как AD DC выполните:"
echo "   sudo samba-tool domain provision"
echo ""
echo "2. Для настройки как файлового сервера:"
echo "   sudo nano /etc/samba/smb.conf"
echo "   sudo smbpasswd -a пользователь"
echo "   sudo systemctl unmask smbd nmbd winbind"
echo "   sudo systemctl enable --now smbd nmbd winbind"
echo ""
echo "3. Для настройки Kerberos:"
echo "   sudo nano /etc/krb5.conf"
echo ""
echo "4. Для настройки Bind9:"
echo "   sudo nano /etc/bind/named.conf.options"
echo "   sudo systemctl enable --now bind9"
echo ""

# Шаг 10: Снятие маскировки со служб (опционально, закомментировано)
# echo -e "${YELLOW}Снятие маскировки со служб...${NC}"
# systemctl unmask winbind smbd nmbd krb5-kdc 2>/dev/null
# echo -e "${GREEN} Маскировка снята${NC}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}========================================${NC}"
# поготовка к настройке (автонастройка сервера)
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}  запустить скрипт ScriptConfig.sh${NC}"
echo -e "${GREEN}========================================${NC}"