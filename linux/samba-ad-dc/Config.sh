#!/bin/bash
# Комплексный скрипт настройки Samba AD DC и BIND9 для Astra Linux
# Версия: 2.2 (с настройками winbind и правильным krb5.conf)

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться от root (используйте sudo)"
   exit 1
fi

# Конфигурационные переменные (можно изменить под вашу сеть)
DOMAIN="test.local"           # Имя домена в нижнем регистре для DNS
REALM="TEST.LOCAL"            # Realm для Kerberos (ВЕРХНИЙ РЕГИСТР!)
NETBIOS_NAME="TEST"           # NetBIOS имя домена
ADMIN_PASS="Pas1234Pas10Kd"   # Пароль администратора домена
SERVER_IP="192.168.10.10"     # IP адрес сервера
HOSTNAME=$(hostname -s)       # Имя хоста
FQDN="$HOSTNAME.$DOMAIN"      # Полное доменное имя
NETWORK="192.168.10.0/24"     # Ваша локальная сеть

clear
echo "========================================================="
echo "    ПОЛНАЯ НАСТРОЙКА SAMBA AD DC + BIND9 (Astra Linux)   "
echo "========================================================="
echo ""
print_info "Параметры настройки:"
echo "  • Домен (DNS):      $DOMAIN"
echo "  • Realm (Kerberos): $REALM"
echo "  • NetBIOS имя:      $NETBIOS_NAME"
echo "  • Сервер:           $FQDN"
echo "  • IP адрес:         $SERVER_IP"
echo "  • Сеть:             $NETWORK"
echo "  • Пароль админа:    $ADMIN_PASS"
echo ""
read -p "Продолжить настройку? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Настройка отменена"
    exit 0
fi
echo ""

# Функция проверки успешности
check_success() {
    if [ $? -eq 0 ]; then
        print_success "$1"
    else
        print_error "$1"
        exit 1
    fi
}

# ----------------------------------------------------------------------
# ЧАСТЬ 1: ПОДГОТОВКА СИСТЕМЫ
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 1: Подготовка системы"

# Шаг 1.1: Проверка наличия необходимых пакетов
print_info "[1.1] Проверка необходимых пакетов..."
required_packages=("samba" "winbind" "bind9" "bind9utils" "krb5-user" "libnss-winbind" "libpam-winbind" "dnsutils")
missing_packages=()
for pkg in "${required_packages[@]}"; do
    if ! dpkg -l | grep -q "^ii.*$pkg"; then
        missing_packages+=("$pkg")
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    print_warning "Отсутствуют пакеты: ${missing_packages[*]}"
    print_info "Установка отсутствующих пакетов..."
    apt update
    apt install -y "${missing_packages[@]}"
    check_success "Пакеты установлены"
else
    print_success "Все необходимые пакеты установлены"
fi
echo ""

# Шаг 1.2: Остановка и маскировка стандартных служб Samba
print_info "[1.2] Остановка стандартных служб Samba..."
systemctl stop smbd nmbd winbind 2>/dev/null
systemctl disable smbd nmbd winbind 2>/dev/null
systemctl mask smbd nmbd winbind 2>/dev/null
print_success "Службы smbd, nmbd, winbind остановлены и замаскированы"
echo ""

# Шаг 1.3: Остановка BIND9 если запущен
print_info "[1.3] Остановка BIND9..."
systemctl stop named 2>/dev/null
systemctl disable named 2>/dev/null
print_success "BIND9 остановлен"
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 2: НАСТРОЙКА СЕТИ И ИМЕН
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 2: Настройка сети и имен"

# Шаг 2.1: Настройка /etc/hosts
print_info "[2.1] Настройка /etc/hosts..."

# Создание резервной копии
BACKUP_FILE="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/hosts "$BACKUP_FILE"
print_success "Создана резервная копия: $BACKUP_FILE"

# Создание нового hosts файла
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

print_success "/etc/hosts настроен"
cat /etc/hosts
echo ""

# Шаг 2.2: Настройка /etc/resolv.conf
print_info "[2.2] Настройка /etc/resolv.conf..."

# Снимаем защиту если была
chattr -i /etc/resolv.conf 2>/dev/null

# Создание резервной копии
cp /etc/resolv.conf "/etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
search $DOMAIN
domain $DOMAIN
EOF

print_success "/etc/resolv.conf настроен на использование локального DNS"
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 3: ПРОВИЗИОНИРОВАНИЕ ДОМЕНА
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 3: Создание домена"

# Шаг 3.1: Удаление старой конфигурации Samba
print_info "[3.1] Удаление старой конфигурации Samba..."
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/*
rm -rf /var/lib/samba/sysvol/*
print_success "Старая конфигурация удалена"
echo ""

# Шаг 3.2: Создание домена
print_info "[3.2] Создание домена $REALM с DNS-бэкендом BIND9_DLZ..."

samba-tool domain provision \
    --server-role=dc \
    --dns-backend=BIND9_DLZ \
    --realm="$REALM" \
    --domain="$NETBIOS_NAME" \
    --adminpass="$ADMIN_PASS" \
    --use-rfc2307

check_success "Домен $REALM успешно создан"
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 3.3: ДОБАВЛЕНИЕ НАСТРОЕК WINBIND В SMB.CONF
# ----------------------------------------------------------------------

print_info "[3.3] Добавление настроек winbind в /etc/samba/smb.conf..."

# Добавляем настройки winbind в секцию [global]
sed -i '/\[global\]/a \\n    # Winbind settings\n    template shell = /bin/bash\n    winbind use default domain = true\n    winbind offline logon = false\n    winbind nss info = rfc2307\n    winbind enum users = yes\n    winbind enum groups = yes' /etc/samba/smb.conf

print_success "Настройки winbind добавлены в smb.conf"

# Показываем добавленные настройки
echo ""
print_info "Текущие настройки winbind в smb.conf:"
grep -A7 "Winbind settings" /etc/samba/smb.conf || grep -E "winbind|template shell" /etc/samba/smb.conf
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 3.4: НАСТРОЙКА KRB5.CONF
# ----------------------------------------------------------------------

print_info "[3.4] Настройка /etc/krb5.conf..."

# Создание резервной копии
if [ -f /etc/krb5.conf ]; then
    cp /etc/krb5.conf "/etc/krb5.conf.backup.$(date +%Y%m%d_%H%M%S)"
    print_success "Создана резервная копия существующего krb5.conf"
fi

# Создаем правильный krb5.conf
cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}

[realms]
    $REALM = {
        kdc = $FQDN
        admin_server = $FQDN
        default_domain = $DOMAIN
    }

[domain_realm]
    .$DOMAIN = $REALM
    $DOMAIN = $REALM

[kdc]
    profile = /var/lib/samba/private/kdc.conf

[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log
EOF

check_success "Файл /etc/krb5.conf настроен"

# Показываем содержимое
print_info "Содержимое /etc/krb5.conf:"
cat /etc/krb5.conf
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 4: НАСТРОЙКА BIND9
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 4: Настройка BIND9"

# Шаг 4.1: Создание конфигурации BIND9 для работы с Samba DLZ
print_info "[4.1] Настройка конфигурационных файлов BIND9..."

# Основной конфиг
cat > /etc/bind/named.conf << 'EOF'
// Основной конфигурационный файл BIND9
include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
include "/etc/bind/named.conf.default-zones";
EOF

# Конфигурация опций
cat > /etc/bind/named.conf.options << EOF
options {
        directory "/var/cache/bind";

        // Отключаем IPv6 для предотвращения ошибок в логах
        listen-on-v6 { none; };

        // Слушаем на всех IPv4 интерфейсах
        listen-on { any; };

        // Разрешаем рекурсивные запросы из локальной сети
        allow-query {
                127.0.0.1;
                $NETWORK;
        };

        recursion yes;

        // DNS-серверы для внешних запросов
        forwarders {
                8.8.8.8;
                8.8.4.4;
        };

        forward first;
        dnssec-validation auto;
        max-cache-size 256M;
        allow-transfer { none; };
};
EOF

# Локальные зоны - подключаем конфиг от Samba
cat > /etc/bind/named.conf.local << EOF
// Зона Active Directory, управляемая через Samba DLZ
include "/var/lib/samba/bind-dns/named.conf";

// Здесь можно добавлять другие зоны, если необходимо
EOF

print_success "Конфигурационные файлы BIND9 созданы"

# Шаг 4.2: Настройка прав доступа
print_info "[4.2] Настройка прав доступа для BIND9..."
chown -R root:bind /var/lib/samba/bind-dns
chmod 755 /var/lib/samba/bind-dns
print_success "Права на /var/lib/samba/bind-dns установлены"

# Шаг 4.3: Настройка параметров запуска (только IPv4)
print_info "[4.3] Настройка параметров запуска BIND9..."
echo 'OPTIONS="-4 -u bind"' > /etc/default/named
print_success "Параметры запуска настроены (только IPv4)"

# Шаг 4.4: Обновление корневых подсказок
print_info "[4.4] Обновление файла корневых подсказок..."
wget -q -O /etc/bind/db.root https://www.internic.net/domain/named.root
if [ $? -eq 0 ]; then
    print_success "Корневые подсказки обновлены"
else
    print_warning "Не удалось обновить корневые подсказки"
fi

# Шаг 4.5: Проверка конфигурации BIND9
print_info "[4.5] Проверка конфигурации BIND9..."
if named-checkconf /etc/bind/named.conf; then
    print_success "Конфигурация BIND9 корректна"
else
    print_error "Ошибка в конфигурации BIND9!"
    exit 1
fi
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 5: ЗАПУСК СЛУЖБ
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 5: Запуск служб"

# Шаг 5.1: Запуск BIND9
print_info "[5.1] Запуск BIND9..."
systemctl start named
systemctl enable named
sleep 2

if systemctl is-active --quiet named; then
    print_success "BIND9 успешно запущен"
else
    print_error "BIND9 не запустился. Проверьте логи: journalctl -u named"
    exit 1
fi

# Шаг 5.2: Настройка и запуск Samba AD DC
print_info "[5.2] Настройка службы samba-ad-dc..."
systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc
sleep 5

if systemctl is-active --quiet samba-ad-dc; then
    print_success "Samba AD DC успешно запущена"
else
    print_error "Samba AD DC не запустилась. Проверьте логи: journalctl -u samba-ad-dc"
    exit 1
fi
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 6: НАСТРОЙКА ДОПОЛНИТЕЛЬНЫХ КОМПОНЕНТОВ
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 6: Дополнительные настройки"

# Шаг 6.1: Настройка nsswitch.conf
print_info "[6.1] Настройка nsswitch.conf..."

BACKUP_FILE="/etc/nsswitch.conf.backup.$(date +%Y%m%d_%H%M%S)"
if [ -f /etc/nsswitch.conf ]; then
    cp /etc/nsswitch.conf "$BACKUP_FILE"
    print_success "Создана резервная копия: $BACKUP_FILE"
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

print_success "nsswitch.conf настроен"

# Шаг 6.2: Настройка логирования в smb.conf
print_info "[6.2] Настройка логирования Samba..."
sed -i '/\[global\]/a # Logging settings\n\tlog file = /var/log/samba/log.%m\n\tlog level = 1\n\tmax log size = 1000' /etc/samba/smb.conf
print_success "Логирование настроено"

# Шаг 6.3: Настройка firewall
print_info "[6.3] Настройка firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 53/tcp comment 'DNS TCP'
    ufw allow 53/udp comment 'DNS UDP'
    ufw allow 88/tcp comment 'Kerberos TCP'
    ufw allow 88/udp comment 'Kerberos UDP'
    ufw allow 135/tcp comment 'RPC'
    ufw allow 137-138/udp comment 'NetBIOS UDP'
    ufw allow 139/tcp comment 'NetBIOS TCP'
    ufw allow 389/tcp comment 'LDAP TCP'
    ufw allow 389/udp comment 'LDAP UDP'
    ufw allow 445/tcp comment 'SMB'
    ufw allow 464/tcp comment 'kpasswd TCP'
    ufw allow 464/udp comment 'kpasswd UDP'
    ufw allow 636/tcp comment 'LDAPS'
    ufw allow 3268-3269/tcp comment 'Global Catalog'
    ufw allow 49152-65535/tcp comment 'RPC dynamic'
    print_success "Правила firewall добавлены"
else
    print_warning "ufw не установлен, пропускаем настройку firewall"
fi
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 7: СОЗДАНИЕ РЕВЕРСИВНЫХ ЗОН
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 7: Создание реверсивных зон"

# Извлекаем октеты для реверсивной зоны
REV_ZONE=$(echo $SERVER_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
LAST_OCTET=$(echo $SERVER_IP | awk -F. '{print $4}')

print_info "Реверсивная зона: $REV_ZONE"
print_info "Сеть: $(echo $SERVER_IP | awk -F. '{print $1"."$2"."$3".0/24"}')"

# Создание реверсивной зоны
samba-tool dns zonecreate $FQDN $REV_ZONE -U Administrator --password="$ADMIN_PASS" 2>/dev/null

if [ $? -eq 0 ]; then
    print_success "Реверсивная зона $REV_ZONE создана"

    # Добавление PTR записи для сервера
    samba-tool dns add $FQDN $REV_ZONE $LAST_OCTET PTR $FQDN -U Administrator --password="$ADMIN_PASS" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "PTR запись для $SERVER_IP добавлена"
    else
        print_warning "Ошибка при добавлении PTR записи (возможно уже существует)"
    fi
else
    print_warning "Ошибка при создании реверсивной зоны (возможно уже существует)"
fi
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 8: ПРОВЕРКА РАБОТОСПОСОБНОСТИ
# ----------------------------------------------------------------------

print_info "ЧАСТЬ 8: Проверка работоспособности"
echo ""
echo "========================================================="
echo "                    РЕЗУЛЬТАТЫ ПРОВЕРКИ                  "
echo "========================================================="

# Проверка 1: Статус служб
echo -e "\n${YELLOW}▶ Статус служб:${NC}"
for service in named samba-ad-dc winbind; do
    echo -n "  $service: "
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo -e "${GREEN}активен${NC}"
    else
        echo -e "${RED}не активен${NC}"
    fi
done

# Проверка 2: Порты
echo -e "\n${YELLOW}▶ Критические порты:${NC}"
for port in 53 88 389 445; do
    echo -n "  Порт $port: "
    if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        echo -e "${GREEN}открыт${NC}"
    else
        echo -e "${RED}закрыт${NC}"
    fi
done

# Проверка 3: DNS A-запись
echo -e "\n${YELLOW}▶ DNS A-запись для $FQDN:${NC}"
if nslookup $FQDN 127.0.0.1 >/dev/null 2>&1; then
    IP=$(nslookup $FQDN 127.0.0.1 | grep Address | grep -v "#" | tail -1 | awk '{print $2}')
    echo -e "  ${GREEN}$FQDN → $IP${NC}"
else
    echo -e "  ${RED}A-запись не найдена${NC}"
fi

# Проверка 4: DNS PTR-запись
echo -e "\n${YELLOW}▶ DNS PTR-запись для $SERVER_IP:${NC}"
if nslookup $SERVER_IP 127.0.0.1 >/dev/null 2>&1; then
    NAME=$(nslookup $SERVER_IP 127.0.0.1 | grep name | awk '{print $4}')
    echo -e "  ${GREEN}$SERVER_IP → $NAME${NC}"
else
    echo -e "  ${RED}PTR-запись не найдена${NC}"
fi

# Проверка 5: DNS SRV-запись
echo -e "\n${YELLOW}▶ DNS SRV-запись LDAP:${NC}"
if nslookup -type=SRV _ldap._tcp.$DOMAIN 127.0.0.1 >/dev/null 2>&1; then
    echo -e "  ${GREEN}SRV-записи найдены${NC}"
else
    echo -e "  ${RED}SRV-записи не найдены${NC}"
fi

# Проверка 6: Внешний резолвинг
echo -e "\n${YELLOW}▶ Внешний резолвинг (yandex.ru):${NC}"
if nslookup yandex.ru 127.0.0.1 >/dev/null 2>&1; then
    echo -e "  ${GREEN}работает${NC}"
else
    echo -e "  ${RED}не работает${NC}"
fi

# Проверка 7: Пользователь administrator через winbind
echo -e "\n${YELLOW}▶ Пользователь administrator в домене (winbind):${NC}"
if wbinfo -i administrator &>/dev/null; then
    USER_INFO=$(wbinfo -i administrator 2>/dev/null | head -1)
    echo -e "  ${GREEN}доступен: $USER_INFO${NC}"
else
    echo -e "  ${RED}не доступен${NC}"
fi

# Проверка 8: Перечисление пользователей через winbind
echo -e "\n${YELLOW}▶ Перечисление пользователей через winbind:${NC}"
USER_COUNT=$(wbinfo -u 2>/dev/null | wc -l)
if [ $USER_COUNT -gt 0 ]; then
    echo -e "  ${GREEN}найдено $USER_COUNT пользователей${NC}"
    echo "  Первые 3: $(wbinfo -u 2>/dev/null | head -3 | tr '\n' ' ')"
else
    echo -e "  ${RED}пользователи не найдены${NC}"
fi

# Проверка 9: Перечисление групп через winbind
echo -e "\n${YELLOW}▶ Перечисление групп через winbind:${NC}"
GROUP_COUNT=$(wbinfo -g 2>/dev/null | wc -l)
if [ $GROUP_COUNT -gt 0 ]; then
    echo -e "  ${GREEN}найдено $GROUP_COUNT групп${NC}"
    echo "  Первые 3: $(wbinfo -g 2>/dev/null | head -3 | tr '\n' ' ')"
else
    echo -e "  ${RED}группы не найдены${NC}"
fi

# Проверка 10: Аутентификация Kerberos
echo -e "\n${YELLOW}▶ Аутентификация Kerberos:${NC}"
if command -v expect &>/dev/null; then
    # Создаем временный файл с expect скриптом
    expect << EOF > /tmp/krb_test.log 2>&1
set timeout 10
spawn kinit administrator@$REALM
expect "Password for administrator@$REALM:"
send "$ADMIN_PASS\r"
expect eof
EOF
    if [ $? -eq 0 ] && klist 2>/dev/null | grep -q "administrator@$REALM"; then
        echo -e "  ${GREEN}успешна${NC}"
        klist | grep "Default principal" || echo "  Билет получен"
        kdestroy
    else
        echo -e "  ${RED}ошибка аутентификации${NC}"
        echo "  Проверьте вручную: kinit administrator@$REALM"
    fi
else
    echo -e "  ${YELLOW}expect не установлен, пропускаем автоматическую проверку${NC}"
    echo "  Проверьте вручную: kinit administrator@$REALM"
fi

echo "========================================================="
echo ""

# ----------------------------------------------------------------------
# ЧАСТЬ 9: ЗАВЕРШЕНИЕ
# ----------------------------------------------------------------------

print_success "НАСТРОЙКА ЗАВЕРШЕНА!"
echo ""
echo "📋 Информация о домене:"
echo "  • Домен (DNS):      $DOMAIN"
echo "  • Realm (Kerberos): $REALM"
echo "  • NetBIOS имя:      $NETBIOS_NAME"
echo "  • Сервер:           $FQDN"
echo "  • IP адрес:         $SERVER_IP"
echo "  • Администратор:    administrator@$REALM"
echo "  • Пароль:           $ADMIN_PASS"
echo ""
echo "🔧 Настройки winbind в smb.conf:"
grep -A7 "Winbind settings" /etc/samba/smb.conf 2>/dev/null || echo "  не найдены"
echo ""
echo "🔧 Настройки Kerberos в /etc/krb5.conf:"
grep -A3 "libdefaults" /etc/krb5.conf 2>/dev/null | head -4
echo "  ..."
echo ""
echo "📌 Дальнейшие действия:"
echo "  1. Настройте клиенты на использование DNS-сервера $SERVER_IP"
echo "  2. Для проверки Kerberos: kinit administrator@$REALM"
echo "  3. Для проверки Samba: samba-tool domain level show -U administrator%'$ADMIN_PASS'"
echo "  4. Для проверки winbind: wbinfo -u | head -5"
echo "  5. Для проверки getent: getent passwd administrator"
echo ""
echo "📁 Важные файлы конфигурации:"
echo "  • Samba:      /etc/samba/smb.conf"
echo "  • BIND9:      /etc/bind/named.conf"
echo "  • Kerberos:   /etc/krb5.conf"
echo "  • Nsswitch:   /etc/nsswitch.conf"
echo "  • Hosts:      /etc/hosts"
echo "  • Resolv:     /etc/resolv.conf"
echo ""
echo "📊 Логи для мониторинга:"
echo "  • Samba:  journalctl -u samba-ad-dc -f"
echo "  • BIND9:  journalctl -u named -f"
echo "  • Winbind: journalctl -u winbind -f"
echo "  • Kerberos: tail -f /var/log/krb5libs.log"
echo ""
echo -e "${YELLOW}⚠️  ВАЖНО: После перезагрузки проверьте:${NC}"
echo "  getent passwd administrator"
echo "  sudo -u administrator -i whoami"
echo ""
echo ""
echo "# На клиенте (от администратора)"
echo 'Add-Computer -DomainName "test.local\" -Credential "TEST\administrator" -Restart'
echo ""

read -p "Перезагрузить систему сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Перезагрузка..."
    reboot
else
    print_info "Перезагрузка отменена. Рекомендуется перезагрузить позже."
fi