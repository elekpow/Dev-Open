#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   ПРОВЕРКА КОНТРОЛЛЕРА ДОМЕНА${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 1. Проверка имени хоста и домена
echo -e "${YELLOW}1. ИНФОРМАЦИЯ О СИСТЕМЕ:${NC}"
echo "   Hostname: $(hostname -f)"
echo "   Domain: $(hostname -d)"
echo "   IP: $(hostname -I | awk '{print $1}')"
echo ""

# 2. Проверка служб
echo -e "${YELLOW}2. СТАТУС СЛУЖБ:${NC}"
for service in samba-ad-dc winbind bind9; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo -e "   ${GREEN}✓ $service активен${NC}"
    else
        echo -e "   ${RED}✗ $service НЕ активен${NC}"
    fi
done
echo ""

# 3. Проверка портов
echo -e "${YELLOW}3. КРИТИЧЕСКИЕ ПОРТЫ:${NC}"
ports=(53 88 135 139 389 445 464 636 3268 3269)
for port in "${ports[@]}"; do
    if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        PROCESS=$(netstat -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d/ -f2 | head -1)
        echo -e "   ${GREEN}✓ Порт $port открыт ($PROCESS)${NC}"
    else
        echo -e "   ${RED}✗ Порт $port ЗАКРЫТ${NC}"
    fi
done
echo ""

# 4. Проверка DNS
echo -e "${YELLOW}4. DNS ПРОВЕРКА:${NC}"
DOMAIN=$(hostname -d)
if [ -z "$DOMAIN" ]; then
    DOMAIN="test.local"
fi

# Проверка резолвинга домена
if nslookup $DOMAIN 127.0.0.1 &>/dev/null; then
    echo -e "   ${GREEN}✓ Домен $DOMAIN резолвится${NC}"
    nslookup $DOMAIN 127.0.0.1 | grep -A 1 "Name:" | tail -1
else
    echo -e "   ${RED}✗ Домен $DOMAIN НЕ резолвится${NC}"
fi

# Проверка SRV записей
echo -e "\n   SRV записи:"
for srv in "_kerberos._tcp" "_ldap._tcp" "_kpasswd._tcp"; do
    if host -t SRV $srv.$DOMAIN 127.0.0.1 &>/dev/null; then
        echo -e "   ${GREEN}✓ $srv.$DOMAIN найдена${NC}"
        host -t SRV $srv.$DOMAIN 127.0.0.1 | head -1
    else
        echo -e "   ${RED}✗ $srv.$DOMAIN НЕ найдена${NC}"
    fi
done
echo ""

# 5. Проверка Kerberos
echo -e "${YELLOW}5. KERBEROS ПРОВЕРКА:${NC}"
klist -5 2>/dev/null | grep -q "Default principal"
if [ $? -eq 0 ]; then
    echo -e "   ${GREEN}✓ Есть активные тикеты${NC}"
    klist | head -3
else
    echo -e "   ${YELLOW}⚠ Нет активных тикетов${NC}"
    echo -e "   Попробуйте: kinit administrator@${DOMAIN^^}"
fi
echo ""

# 6. Проверка Samba
echo -e "${YELLOW}6. SAMBA ПРОВЕРКА:${NC}"
if command -v samba-tool &>/dev/null; then
    # Уровень домена
    DOMAIN_LEVEL=$(sudo samba-tool domain level show 2>/dev/null | grep "Domain" | head -1)
    echo -e "   ${GREEN}✓ $DOMAIN_LEVEL${NC}"
    
    # Роль сервера
    SERVER_ROLE=$(sudo testparm -s 2>/dev/null | grep "server role" | cut -d= -f2)
    echo -e "   ${GREEN}✓ Роль: $SERVER_ROLE${NC}"
    
    # Информация о домене
    DOMAIN_INFO=$(sudo samba-tool domain info 127.0.0.1 2>/dev/null | head -3)
    echo -e "   ${GREEN}✓ Информация о домене:${NC}"
    echo "$DOMAIN_INFO" | sed 's/^/     /'
else
    echo -e "   ${RED}✗ samba-tool не найден${NC}"
fi
echo ""

# 7. Проверка пользователей
echo -e "${YELLOW}7. ПОЛЬЗОВАТЕЛИ ДОМЕНА:${NC}"
# Через wbinfo
if command -v wbinfo &>/dev/null; then
    # Проверка доверительных отношений
    if wbinfo -t &>/dev/null; then
        echo -e "   ${GREEN}✓ Доверительные отношения в порядке${NC}"
        
        # Количество пользователей
        USERS_COUNT=$(wbinfo -u 2>/dev/null | wc -l)
        echo -e "   ${GREEN}✓ Найдено $USERS_COUNT пользователей${NC}"
        
        # Количество групп
        GROUPS_COUNT=$(wbinfo -g 2>/dev/null | wc -l)
        echo -e "   ${GREEN}✓ Найдено $GROUPS_COUNT групп${NC}"
        
        # Проверка administrator
        if wbinfo -i administrator &>/dev/null; then
            echo -e "   ${GREEN}✓ Пользователь administrator найден${NC}"
            wbinfo -i administrator | sed 's/^/     /'
        else
            echo -e "   ${RED}✗ Пользователь administrator НЕ найден${NC}"
        fi
    else
        echo -e "   ${RED}✗ Проблема с доверительными отношениями${NC}"
    fi
else
    echo -e "   ${RED}✗ wbinfo не найден${NC}"
fi
echo ""

# 8. Проверка getent
echo -e "${YELLOW}8. GETENT ПРОВЕРКА:${NC}"
if getent passwd administrator &>/dev/null; then
    echo -e "   ${GREEN}✓ administrator виден через getent${NC}"
    getent passwd administrator | sed 's/^/     /'
else
    echo -e "   ${RED}✗ administrator НЕ виден через getent${NC}"
fi
echo ""

# 9. Проверка конфигурационных файлов
echo -e "${YELLOW}9. КОНФИГУРАЦИОННЫЕ ФАЙЛЫ:${NC}"
# /etc/resolv.conf
echo -e "   /etc/resolv.conf:"
cat /etc/resolv.conf | sed 's/^/     /'

# /etc/hosts
echo -e "\n   /etc/hosts (последние 3 строки):"
tail -3 /etc/hosts | sed 's/^/     /'

# /etc/nsswitch.conf (passwd/group)
echo -e "\n   /etc/nsswitch.conf (passwd/group):"
grep -E "passwd|group" /etc/nsswitch.conf | sed 's/^/     /'
echo ""

# 10. Проверка аутентификации
echo -e "${YELLOW}10. ПРОВЕРКА АУТЕНТИФИКАЦИИ:${NC}"
# Проверка через smbclient
if command -v smbclient &>/dev/null; then
    echo -e "   ${YELLOW}Проверка smbclient (требует пароль):${NC}"
    echo "   smbclient -L localhost -U administrator"
fi

# Проверка через sudo
echo -e "\n   ${YELLOW}Проверка переключения пользователя:${NC}"
echo "   sudo -u administrator -c 'whoami'"
echo ""

# Итог
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}   ПРОВЕРКА ЗАВЕРШЕНА${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Полезные команды для ручной проверки:${NC}"
echo "1. Получить тикет Kerberos:  kinit administrator@${DOMAIN^^}"
echo "2. Проверить тикеты:          klist"
echo "3. Список пользователей:      wbinfo -u | head -10"
echo "4. Информация о домене:       samba-tool domain info 127.0.0.1"
echo "5. Статус репликации:         samba-tool drs showrepl"