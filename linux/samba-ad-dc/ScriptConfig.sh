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

# Параметры домена
DOMAIN="TEST.LOCAL"
REALM="TEST.LOCAL"
HOST="testserver.local"
NETBIOS_NAME="TEST"
ADMIN_PASS="Pas1234Pas$10Kd"  # Пароль с экранированным символом $
SERVER_IP=192.168.10.10



echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   НАСТРОЙКА SAMBA AD DC${NC}"
echo -e "${BLUE}   Домен: "$REALM" ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""





# Функция для проверки успешности выполнения
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}$1${NC}"
    else
        echo -e "${RED} $1${NC}"
        exit 1
    fi
}

# Шаг 1: Проверка наличия необходимых пакетов
echo -e "${YELLOW}[1] Проверка необходимых пакетов...${NC}"
required_packages=("samba" "winbind" "bind9" "bind9utils" "krb5-user")
for pkg in "${required_packages[@]}"; do
    if ! dpkg -l | grep -q "^ii.*$pkg"; then
        echo -e "${RED}   $pkg не установлен${NC}"
        echo "  Установите пакеты командой: sudo apt install $pkg"
        exit 1
    else
        echo -e "${GREEN}  $pkg установлен${NC}"
    fi
done
echo ""

# Шаг 2: Остановка и маскировка стандартных служб Samba
echo -e "${YELLOW}[2] Остановка стандартных служб Samba...${NC}"
systemctl stop smbd nmbd winbind 2>/dev/null
systemctl disable smbd nmbd winbind 2>/dev/null
systemctl mask smbd nmbd winbind 2>/dev/null
echo -e "${GREEN}Службы smbd, nmbd, winbind остановлены и замаскированы${NC}"
echo ""

# Шаг 3: Удаление старой конфигурации
echo -e "${YELLOW}[3] Удаление старой конфигурации...${NC}"
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
echo -e "${GREEN}Старая конфигурация удалена${NC}"
echo ""


# Настройка hosts

HOSTNAME=$(hostname -s 2>/dev/null || hostname)
DOMAINNAME=$(hostname -d 2>/dev/null)

if [ -z "$DOMAINNAME" ] || [ "$DOMAINNAME" = "(none)" ]; then
    if [ -f /etc/samba/smb.conf ]; then
        DOMAINNAME=$(grep -i "realm" /etc/samba/smb.conf 2>/dev/null | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    fi
    
    if [ -z "$DOMAINNAME" ] && [ -f /etc/krb5.conf ]; then
        DOMAINNAME=$(grep -i "default_realm" /etc/krb5.conf 2>/dev/null | grep -v "^#" | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    fi
fi

DOMAINNAME=$(echo "$DOMAINNAME" | tr '[:upper:]' '[:lower:]')

IP_ADDRESS=$(hostname -I | awk '{print $1}')
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="127.0.1.1"
fi

echo -e "${YELLOW}Информация о системе:${NC}"
echo "  Hostname: $HOSTNAME"
echo "  Domain:   $DOMAINNAME"
echo "  FQDN:     $HOSTNAME.$DOMAINNAME"
echo "  IP:       $IP_ADDRESS"
echo ""

BACKUP_FILE="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"

cat > /etc/hosts << EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME.$DOMAINNAME $HOSTNAME

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters

$IP_ADDRESS	$HOSTNAME.$DOMAINNAME $HOSTNAME


EOF


# Шаг 4: Создание домена (НЕИНТЕРАКТИВНЫЙ режим - БЕЗ ЗАПРОСОВ ПАРОЛЯ)
echo -e "${YELLOW}[4] Создание домена $DOMAIN...${NC}"

# Используем неинтерактивный режим, который не запрашивает пароль
samba-tool domain provision \
    --server-role=dc \
    --dns-backend=BIND9_DLZ \
    --realm="$REALM" \
    --domain="$NETBIOS_NAME" \
    --adminpass="$ADMIN_PASS" \
    --use-rfc2307

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Домен $DOMAIN успешно создан${NC}"
else
    echo -e "${RED} Ошибка при создании домена${NC}"
    exit 1
fi
echo ""

# Шаг 5: Размаскировка и включение службы Samba AD DC
echo -e "${YELLOW}[5] Настройка службы samba-ad-dc...${NC}"
systemctl unmask samba-ad-dc
check_success "Служба samba-ad-dc размаскирована"

systemctl enable samba-ad-dc
check_success "Служба samba-ad-dc добавлена в автозапуск"
echo ""

# Шаг 6: Настройка Bind9 для работы с Samba
echo -e "${YELLOW}[6] Настройка Bind9...${NC}"

# Добавление include в named.conf
echo 'include "/var/lib/samba/bind-dns/named.conf";' | tee -a /etc/bind/named.conf
check_success "Конфигурация Bind9 обновлена"

# Настройка прав доступа
chown -R root:bind /var/lib/samba/bind-dns
check_success "Права на /var/lib/samba/bind-dns установлены"

# Настройка опций Bind9
cat > /etc/bind/named.conf.options << 'EOF'
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { any; };
    allow-query { any; };
    recursion no;
    dnssec-validation auto;
    auth-nxdomain no;
};
EOF

# Перезапуск Bind9
systemctl restart bind9
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Bind9 перезапущен${NC}"
else
    echo -e "${RED} Ошибка при перезапуске Bind9${NC}"
    journalctl -u bind9 --no-pager | tail -20
fi
echo ""

# Шаг 7: Копирование конфигурации Kerberos
echo -e "${YELLOW}[7] Копирование конфигурации Kerberos...${NC}"
cp -b /var/lib/samba/private/krb5.conf /etc/krb5.conf
check_success "Конфигурация Kerberos скопирована"
echo ""

# Шаг 8: Запуск службы Samba AD DC
echo -e "${YELLOW}[8] Запуск службы samba-ad-dc...${NC}"
systemctl start samba-ad-dc
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Служба samba-ad-dc запущена${NC}"
else
    echo -e "${RED} Ошибка при запуске samba-ad-dc${NC}"
    systemctl status samba-ad-dc --no-pager
    journalctl -u samba-ad-dc --no-pager | tail -20
fi
echo ""

# Шаг 9: Проверка работы DNS
echo -e "${YELLOW}[9] Проверка работы DNS...${NC}"
sleep 5  # Даем время на запуск

if host -t A $HOST 127.0.0.1 &>/dev/null; then
    echo -e "${GREEN}DNS работает: $(host -t A $HOST 127.0.0.1)${NC}"
else
    echo -e "${RED} DNS не отвечает${NC}"
fi

if host -t SRV _ldap._tcp.$HOST 127.0.0.1 &>/dev/null; then
    echo -e "${GREEN}SRV записи работают${NC}"
else
    echo -e "${RED} SRV записи не найдены${NC}"
fi
echo ""

# Шаг 10: Создание реверсивных зон (БЕЗ ЗАПРОСА ПАРОЛЯ)
echo -e "${YELLOW}[10] Создание реверсивных зон...${NC}"

# Определяем IP адрес сервера
#SERVER_IP=$(ip route get 1 | awk '{print $NF;exit}')
#if [ -z "$SERVER_IP" ]; then
#    SERVER_IP=$(hostname -I | awk '{print $1}')
#fi

echo -e "IP адрес сервера: ${GREEN}$SERVER_IP${NC}"

# Извлекаем первые три октета для реверсивной зоны
REV_ZONE=$(echo $SERVER_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
REV_ZONE_NET=$(echo $SERVER_IP | awk -F. '{print $1"."$2"."$3}')

echo -e "Реверсивная зона: ${GREEN}$REV_ZONE${NC}"
echo -e "Сеть: ${GREEN}$REV_ZONE_NET.0/24${NC}"
echo ""

# Создание реверсивной зоны с передачей пароля в аргументе (НЕ ИНТЕРАКТИВНО)
samba-tool dns zonecreate $HOST $REV_ZONE -U Administrator --password="$ADMIN_PASS"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Реверсивная зона $REV_ZONE создана${NC}"

    # Добавление PTR записи для сервера
    LAST_OCTET=$(echo $SERVER_IP | awk -F. '{print $4}')
    samba-tool dns add $HOST $REV_ZONE $LAST_OCTET PTR $HOST -U Administrator --password="$ADMIN_PASS"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}PTR запись для $SERVER_IP добавлена${NC}"
    else
        echo -e "${RED} Ошибка при добавлении PTR записи${NC}"
    fi
else
    echo -e "${RED} Ошибка при создании реверсивной зоны${NC}"
fi
echo ""

# Шаг 11: Настройка firewall
echo -e "${YELLOW}[11] Настройка firewall...${NC}"
if command -v ufw &>/dev/null; then
    ufw allow 53/tcp
    ufw allow 53/udp
    ufw allow 88/tcp
    ufw allow 88/udp
    ufw allow 135/tcp
    ufw allow 137-138/udp
    ufw allow 139/tcp
    ufw allow 389/tcp
    ufw allow 389/udp
    ufw allow 445/tcp
    ufw allow 464/tcp
    ufw allow 464/udp
    ufw allow 636/tcp
    ufw allow 3268-3269/tcp
    ufw allow 49152-65535/tcp
    echo -e "${GREEN}Правила firewall добавлены${NC}"
else
    echo -e "${YELLOW} ufw не установлен, пропускаем настройку firewall${NC}"
fi
echo ""

# Шаг 12: Настройка /etc/resolv.conf
echo -e "${YELLOW}[12] Настройка /etc/resolv.conf...${NC}"
cat > /etc/resolv.conf << EOF
domain $HOST
search $HOST
nameserver 127.0.0.1
EOF
echo -e "${GREEN}/etc/resolv.conf настроен на использование локального DNS${NC}"
echo ""

# Шаг 13: Проверка аутентификации (БЕЗ ЗАПРОСА ПАРОЛЯ)
echo -e "${YELLOW}[13] Проверка аутентификации Kerberos...${NC}"

# Используем expect для автоматического ввода пароля (если установлен)
if command -v expect &>/dev/null; then
    expect << EOF > /dev/null 2>&1
set timeout 10
spawn kinit administrator@$HOST
expect "Password for administrator@$HOST:"
send "$ADMIN_PASS\r"
expect eof
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Аутентификация Kerberos успешна${NC}"
        kdestroy
    else
        echo -e "${RED} Ошибка аутентификации Kerberos${NC}"
    fi
else
    echo -e "${YELLOW} expect не установлен, пропускаем проверку Kerberos${NC}"
fi
echo ""

# Шаг 14: Итоговая проверка
echo -e "${YELLOW}[14] Итоговая проверка:${NC}"
echo "----------------------------------------"

# Проверка служб
for service in samba-ad-dc bind9; do
    if systemctl is-active "$service" &>/dev/null; then
        echo -e "${GREEN}$service: активен${NC}"
    else
        echo -e "${RED} $service: не активен${NC}"
    fi
done

echo "----------------------------------------"
echo ""

# Финальное сообщение
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   НАСТРОЙКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Информация о домене:"
echo "  Домен: $HOST"
echo "  Администратор: Administrator"
echo "  Пароль: $ADMIN_PASS"
echo "  IP адрес: $SERVER_IP"
echo ""
echo "Проверка работы (без запроса пароля):"
echo "  samba-tool domain level show -U Administrator%'$ADMIN_PASS'"
echo "  samba-tool user list -U Administrator%'$ADMIN_PASS'"
echo ""
echo -e "${YELLOW}ВАЖНО: Перезагрузите систему для применения всех настроек!${NC}"
echo ""
read -p "Перезагрузить сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi


# Финальные тесты
echo -e "${GREEN}========================================${NC}"
echo $ADMIN_PASS | samba-tool dns query localhost test.local @ ALL -U administrator
echo $ADMIN_PASS | samba-tool dns query localhost test.local _ldap._tcp.Default-First-Site-Name SRV -U administrator
echo $ADMIN_PASS | samba-tool dns query localhost test.local ForestDnsZones A -U administrator

# обновление DNS
echo -e "${GREEN}========================================${NC}"
samba_dnsupdate --verbose
read -p "Перезагрузить сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
