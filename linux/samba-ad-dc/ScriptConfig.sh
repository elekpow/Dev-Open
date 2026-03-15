#!/bin/bash

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


DOMAIN="test.local"           # Имя домена в нижнем регистре для DNS
REALM="TEST.LOCAL"            # Realm для Kerberos 
HOSTNAME=$(hostname -s)       # Имя хоста
FQDN="$HOSTNAME.$DOMAIN"      # FQDN доменное имя
NETBIOS_NAME="TEST"           # NetBIOS имя домена
ADMIN_PASS="Pas1234Pas10Kd"  # Пароль
SERVER_IP="192.168.10.10"     # IP адрес сервера

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   НАСТРОЙКА SAMBA AD DC${NC}"
echo -e "${BLUE}   Домен: $DOMAIN (DNS) / $REALM (Kerberos)${NC}"
echo -e "${BLUE}   Сервер: $FQDN${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

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
required_packages=("samba" "winbind" "bind9" "bind9utils" "krb5-user" "libnss-winbind" "libpam-winbind")
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

# Шаг 4: Настройка /etc/hosts - ИСПРАВЛЕНО
echo -e "${YELLOW}[4] Настройка /etc/hosts...${NC}"

# Создание резервной копии
BACKUP_FILE="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/hosts "$BACKUP_FILE"
echo -e "${GREEN}Создана резервная копия: $BACKUP_FILE${NC}"

# Создание нового hosts файла с правильным доменом
cat > /etc/hosts << EOF
# Локальные записи
127.0.0.1	localhost
127.0.1.1	$FQDN $HOSTNAME

# IPv6 записи
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters

# Запись для контроллера домена
$SERVER_IP	$FQDN $HOSTNAME
EOF

echo -e "${GREEN}/etc/hosts настроен:${NC}"
cat /etc/hosts
echo ""

# Шаг 5: Создание домена (НЕИНТЕРАКТИВНЫЙ режим)
echo -e "${YELLOW}[5] Создание домена $REALM...${NC}"

samba-tool domain provision \
    --server-role=dc \
    --dns-backend=BIND9_DLZ \
    --realm="$REALM" \
    --domain="$NETBIOS_NAME" \
    --adminpass="$ADMIN_PASS" \
    --use-rfc2307

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Домен $REALM успешно создан${NC}"
else
    echo -e "${RED}Ошибка при создании домена${NC}"
    exit 1
fi
echo ""

# Шаг 6: Размаскировка и включение службы Samba AD DC
echo -e "${YELLOW}[6] Настройка службы samba-ad-dc...${NC}"
systemctl unmask samba-ad-dc
check_success "Служба samba-ad-dc размаскирована"

systemctl enable samba-ad-dc
check_success "Служба samba-ad-dc добавлена в автозапуск"
echo ""

# Шаг 7: Настройка Bind9 для работы с Samba
echo -e "${YELLOW}[7] Настройка Bind9...${NC}"

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
    echo -e "${RED}Ошибка при перезапуске Bind9${NC}"
    journalctl -u bind9 --no-pager | tail -20
fi
echo ""

# Шаг 8: Настройка логирования в smb.conf
echo -e "${YELLOW}[8] Настройка логирования Samba...${NC}"
sudo sed -i '/\[global\]/a # Logging settings\nlog file = /var/log/samba/log.%m\nlog level = 1\nmax log size = 1000' /etc/samba/smb.conf
echo -e "${GREEN}Логирование настроено${NC}"
echo ""

# Шаг 9: Копирование конфигурации Kerberos
echo -e "${YELLOW}[9] Копирование конфигурации Kerberos...${NC}"
cp -b /var/lib/samba/private/krb5.conf /etc/krb5.conf
check_success "Конфигурация Kerberos скопирована"
echo ""

# Шаг 10: Настройка nsswitch.conf
echo -e "${YELLOW}[10] Настройка nsswitch.conf...${NC}"

BACKUP_FILE="/etc/nsswitch.conf.backup.$(date +%Y%m%d_%H%M%S)"
if [ -f /etc/nsswitch.conf ]; then
    cp /etc/nsswitch.conf "$BACKUP_FILE"
    echo -e "${GREEN}Создана резервная копия: $BACKUP_FILE${NC}"
else
    echo -e "${YELLOW}Файл /etc/nsswitch.conf не найден, будет создан новый${NC}"
fi

cat > /etc/nsswitch.conf << 'EOF'
# /etc/nsswitch.conf
passwd:         compat winbind systemd
group:          compat winbind systemd
shadow:         compat

gshadow:        files
hosts:          files dns
networks:       files
protocols:      files
services:       files
ethers:         files
rpc:            files
netgroup:       files
EOF

echo -e "${GREEN}nsswitch.conf настроен${NC}"
echo ""

# Шаг 11: Запуск службы Samba AD DC
echo -e "${YELLOW}[11] Запуск службы samba-ad-dc...${NC}"
systemctl start samba-ad-dc
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Служба samba-ad-dc запущена${NC}"
else
    echo -e "${RED}Ошибка при запуске samba-ad-dc${NC}"
    systemctl status samba-ad-dc --no-pager
    journalctl -u samba-ad-dc --no-pager | tail -20
fi
sleep 5
echo ""

# Шаг 12: Проверка работы DNS
echo -e "${YELLOW}[12] Проверка работы DNS...${NC}"

if nslookup $FQDN 127.0.0.1 &>/dev/null; then
    echo -e "${GREEN} DNS работает: $FQDN -> $(nslookup $FQDN 127.0.0.1 | grep Address | tail -1)${NC}"
else
    echo -e "${RED} DNS не отвечает для $FQDN${NC}"
fi

if nslookup -type=SRV _ldap._tcp.$DOMAIN 127.0.0.1 &>/dev/null; then
    echo -e "${GREEN} SRV записи работают${NC}"
else
    echo -e "${RED} SRV записи не найдены${NC}"
fi
echo ""

# Шаг 13: Создание реверсивных зон
echo -e "${YELLOW}[13] Создание реверсивных зон...${NC}"

# Извлекаем октеты для реверсивной зоны
REV_ZONE=$(echo $SERVER_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
LAST_OCTET=$(echo $SERVER_IP | awk -F. '{print $4}')

echo -e "Реверсивная зона: ${GREEN}$REV_ZONE${NC}"
echo -e "Сеть: ${GREEN}$(echo $SERVER_IP | awk -F. '{print $1"."$2"."$3".0/24"}')${NC}"
echo ""

# Создание реверсивной зоны
samba-tool dns zonecreate $FQDN $REV_ZONE -U Administrator --password="$ADMIN_PASS"

if [ $? -eq 0 ]; then
    echo -e "${GREEN} Реверсивная зона $REV_ZONE создана${NC}"

    # Добавление PTR записи для сервера
    samba-tool dns add $FQDN $REV_ZONE $LAST_OCTET PTR $FQDN -U Administrator --password="$ADMIN_PASS"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN} PTR запись для $SERVER_IP добавлена${NC}"
    else
        echo -e "${RED} Ошибка при добавлении PTR записи${NC}"
    fi
else
    echo -e "${RED} Ошибка при создании реверсивной зоны${NC}"
fi
echo ""

# Шаг 14: Настройка firewall
echo -e "${YELLOW}[14] Настройка firewall...${NC}"
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
    echo -e "${GREEN} Правила firewall добавлены${NC}"
else
    echo -e "${YELLOW} ufw не установлен, пропускаем настройку firewall${NC}"
fi
echo ""

# Шаг 15: Настройка /etc/resolv.conf
echo -e "${YELLOW}[15] Настройка /etc/resolv.conf...${NC}"

# Снимаем защиту если была
chattr -i /etc/resolv.conf 2>/dev/null

cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search $DOMAIN
domain $DOMAIN
EOF

# Защищаем от изменений
chattr +i /etc/resolv.conf
echo -e "${GREEN}/etc/resolv.conf настроен на использование локального DNS${NC}"
echo ""

# Шаг 16: Проверка аутентификации Kerberos
echo -e "${YELLOW}[16] Проверка аутентификации Kerberos...${NC}"

# Используем expect для автоматического ввода пароля (если установлен)
if command -v expect &>/dev/null; then
    expect << EOF > /dev/null 2>&1
set timeout 10
spawn kinit administrator@$REALM
expect "Password for administrator@$REALM:"
send "$ADMIN_PASS\r"
expect eof
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN} Аутентификация Kerberos успешна${NC}"
        klist
        kdestroy
    else
        echo -e "${RED} Ошибка аутентификации Kerberos${NC}"
    fi
else
    echo -e "${YELLOW} expect не установлен, пропускаем проверку Kerberos${NC}"
    echo "Проверьте вручную: kinit administrator@$REALM"
fi
echo ""

# Шаг 17: Итоговая проверка
echo -e "${YELLOW}[17] Итоговая проверка:${NC}"
echo "----------------------------------------"

# Проверка служб
for service in samba-ad-dc bind9; do
    if systemctl is-active "$service" &>/dev/null; then
        echo -e "${GREEN} $service: активен${NC}"
    else
        echo -e "${RED} $service: не активен${NC}"
    fi
done

# Проверка DNS
if nslookup $DOMAIN 127.0.0.1 &>/dev/null; then
    echo -e "${GREEN} DNS: работает${NC}"
else
    echo -e "${RED} DNS: не работает${NC}"
fi

# Проверка пользователя
if wbinfo -i administrator &>/dev/null; then
    echo -e "${GREEN} Пользователь administrator: доступен${NC}"
else
    echo -e "${RED} Пользователь administrator: НЕ доступен${NC}"
fi

echo "----------------------------------------"
echo ""

# Финальное сообщение
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   НАСТРОЙКА ЗАВЕРШЕНА${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Информация о домене:"
echo "  Домен (DNS): $DOMAIN"
echo "  Realm (Kerberos): $REALM"
echo "  Сервер: $FQDN"
echo "  IP адрес: $SERVER_IP"
echo "  Администратор: administrator@$REALM"
echo "  Пароль: $ADMIN_PASS"
echo ""
echo "Проверка работы:"
echo "  kinit administrator@$REALM"
echo "  samba-tool domain level show -U administrator%'$ADMIN_PASS'"
echo "  wbinfo -u | head -5"
echo ""
echo -e "${YELLOW}ВАЖНО: После перезагрузки проверьте:${NC}"
echo "  getent passwd administrator"
echo "  sudo -u administrator -i whoami"
echo ""
read -p "Перезагрузить систему сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Перезагрузка..."
    reboot
fi