#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "============================================="
echo "   ПОЛНОЕ УДАЛЕНИЕ СЛУЖБ С ПРОВЕРКОЙ МАСКИРОВКИ"
echo "============================================="
echo ""

# Проверка на root права
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен быть запущен с правами root (sudo)${NC}"
    exit 1
fi

# Функция для подтверждения действий
confirm() {
    read -p "$1 (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Операция отменена${NC}"
        return 1
    fi
    return 0
}

# Функция проверки статуса служб (включая маскировку)
check_services_status() {
    echo -e "${BLUE}Проверка текущего статуса служб...${NC}"
    echo "----------------------------------------"

    services=(
        "smbd"
        "nmbd"
        "winbind"
        "samba-ad-dc"
        "samba"
        "krb5-kdc"
        "krb5-admin-server"
        "bind9"
        "named"
    )

    local masked_found=0

    # Заголовок таблицы
    printf "%-20s | %-15s | %-20s\n" "СЛУЖБА" "СТАТУС" "ЗАМАСКИРОВАНА"
    printf "%-20s-+-%-15s-+-%-20s\n" "--------------------" "---------------" "--------------------"

    for service in "${services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$service"; then
            # Проверяем статус
            local status=$(systemctl is-active "$service" 2>/dev/null)
            local is_masked=$(systemctl is-enabled "$service" 2>/dev/null | grep -c "masked")

            # Устанавливаем цвета для статуса
            local status_display
            case $status in
                "active")
                    status_display="${GREEN}active${NC}"
                    ;;
                "inactive")
                    status_display="${YELLOW}inactive${NC}"
                    ;;
                "failed")
                    status_display="${RED}failed${NC}"
                    ;;
                *)
                    status_display="${CYAN}unknown${NC}"
                    ;;
            esac

            # Проверка на маскировку
            local masked_display
            if [ "$is_masked" -eq 1 ]; then
                masked_display="${RED}YES (MASKED)${NC}"
                masked_found=$((masked_found + 1))
            else
                masked_display="${GREEN}NO${NC}"
            fi

            printf "%-20s | %-15b | %-20b\n" "$service" "$status_display" "$masked_display"
        else

            printf "%-20s | %-15b | %-20b\n" "$service" "${CYAN}not found${NC}" "${GREEN}N/A${NC}"
        fi
    done

    echo "----------------------------------------"
    if [ $masked_found -gt 0 ]; then
        echo -e "${RED}Найдено замаскированных служб: $masked_found${NC}"
    else
        echo -e "${GREEN}Замаскированных служб не найдено${NC}"
    fi
    echo ""
}

# Функция поиска всех замаскированных служб
find_all_masked_services() {
    echo -e "${BLUE}Поиск всех замаскированных служб...${NC}"

    local masked_services=$(systemctl list-unit-files | grep "masked" | awk '{print $1}')

    if [ -n "$masked_services" ]; then
        echo -e "${RED}Найдены замаскированные службы:${NC}"
        echo "$masked_services" | while read service; do
            echo "  - $service"
        done
    else
        echo -e "${GREEN}Замаскированных служб не найдено${NC}"
    fi
    echo ""
}

# Функция снятия маскировки со служб 
unmask_services() {
    echo -e "${YELLOW}Снимаем маскировку со служб...${NC}"

    services=(
        "smbd"
        "nmbd"
        "winbind"
        "samba-ad-dc"
        "samba"
        "krb5-kdc"
        "krb5-admin-server"
        "bind9"
        "named"
        "samba-ad-dc.service"
    )

    for service in "${services[@]}"; do
        # Проверяем, замаскирована ли служба
        if systemctl list-unit-files 2>/dev/null | grep -q "^$service" && \
           systemctl is-enabled "$service" 2>/dev/null | grep -q "masked"; then
            echo "Снимаем маскировку с $service..."
            systemctl unmask "$service"
        fi
    done

    # Дополнительно ищем все службы с маскировкой, содержащие ключевые слова
    for pattern in "samba" "smb" "nmb" "winbind" "krb5" "kerberos" "kdc" "bind" "named"; do
        for service in $(systemctl list-unit-files | grep "$pattern" | grep "masked" | awk '{print $1}'); do
            echo "Снимаем маскировку с $service..."
            systemctl unmask "$service"
        done
    done
}

# Функция остановки и отключения служб
stop_and_disable_services() {
    echo -e "${YELLOW}Останавливаем и отключаем службы...${NC}"

    services=(
        "smbd"
        "nmbd"
        "winbind"
        "samba-ad-dc"
        "samba"
        "krb5-kdc"
        "krb5-admin-server"
        "bind9"
        "named"
    )

    for service in "${services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$service"; then
            echo "Обрабатываем $service..."
            systemctl stop "$service" 2>/dev/null
            systemctl disable "$service" 2>/dev/null
        fi
    done
}

# Функция удаления пакетов
remove_packages() {
    echo -e "${YELLOW}Удаляем пакеты...${NC}"

    # Поиск всех установленных пакетов по маскам
    echo "Поиск установленных пакетов..."

    packages=(
        "samba"
        "samba-common"
        "samba-common-bin"
        "samba-dsdb-modules"
        "samba-vfs-modules"
        "samba-libs"
        "libsamba-*"
        "smbclient"
        "winbind"
        "libnss-winbind"
        "libpam-winbind"
        "krb5-kdc"
        "krb5-admin-server"
        "krb5-config"
        "krb5-user"
        "libkrb5-*"
        "bind9"
        "bind9utils"
        "bind9-doc"
        "bind9-host"
        "dnsutils"
    )

    # Получаем список реально установленных пакетов
    installed_packages=""
    for pattern in "${packages[@]}"; do
        installed_packages="$installed_packages $(dpkg -l 2>/dev/null | grep -E "^ii.*$pattern" | awk '{print $2}')"
    done

    if [ -n "$installed_packages" ]; then
        echo "Удаляем пакеты: $installed_packages"
        apt-get update
        apt-get remove -y $installed_packages
        apt-get autoremove -y
        apt-get autoclean
    else
        echo -e "${GREEN}Пакеты для удаления не найдены${NC}"
    fi
}

# Функция удаления конфигурационных файлов и каталогов
remove_config_dirs() {
    echo -e "${YELLOW}Удаляем конфигурационные файлы и каталоги...${NC}"

    # Поиск всех возможных каталогов
    search_dirs=(
        "/etc/samba"
        "/etc/samba*"
        "/var/lib/samba"
        "/var/lib/samba*"
        "/var/cache/samba"
        "/var/log/samba"
        "/var/run/samba"
        "/var/lib/samba/private"
        "/var/lib/samba/sysvol"
        "/usr/local/samba"
        "/etc/krb5kdc"
        "/var/lib/krb5kdc"
        "/var/log/kerberos"
        "/etc/krb5.conf*"
        "/var/lib/krb5"
        "/etc/bind"
        "/var/cache/bind"
        "/var/log/bind"
        "/var/lib/bind"
        "/etc/default/samba*"
        "/etc/default/bind9*"
        "/etc/default/krb5*"
        "/var/backups/samba*"
        "/var/backups/bind9*"
        "/var/backups/krb5*"
    )

    for dir_pattern in "${search_dirs[@]}"; do
        # ИСПРАВЛЕНО: Используем ls с подавлением ошибок через 2>/dev/null
        for dir in $(ls -d $dir_pattern 2>/dev/null); do
            if [ -e "$dir" ]; then
                echo "Удаляем $dir"
                rm -rf "$dir"
            fi
        done
    done
}

# Функция очистки systemd юнитов
cleanup_systemd_units() {
    echo -e "${YELLOW}Очищаем systemd юниты...${NC}"

    # Поиск и удаление оставшихся systemd юнитов
    systemd_dirs=(
        "/etc/systemd/system/multi-user.target.wants/samba*"
        "/etc/systemd/system/multi-user.target.wants/smb*"
        "/etc/systemd/system/multi-user.target.wants/nmb*"
        "/etc/systemd/system/multi-user.target.wants/winbind*"
        "/etc/systemd/system/multi-user.target.wants/krb5*"
        "/etc/systemd/system/multi-user.target.wants/bind9*"
        "/lib/systemd/system/samba*"
        "/lib/systemd/system/smb*"
        "/lib/systemd/system/nmb*"
        "/lib/systemd/system/winbind*"
        "/lib/systemd/system/krb5*"
        "/lib/systemd/system/bind9*"
    )

    for pattern in "${systemd_dirs[@]}"; do
        # ИСПРАВЛЕНО: Используем ls с подавлением ошибок
        for file in $(ls $pattern 2>/dev/null); do
            if [ -f "$file" ]; then
                echo "Удаляем systemd юнит: $file"
                rm -f "$file"
            fi
        done
    done

    # Перезагрузка systemd
    systemctl daemon-reload
}

# Функция очистки пользователей и групп
cleanup_users_groups() {
    echo -e "${YELLOW}Очищаем пользователей и группы ${NC}"

    # Удаление системных пользователей
    system_users=(
        "samba"
        "sambauser"
        "bind"
        "bind9"
        "krb5kdc"
        "krbadm"
        "kerberos"
    )

    for user in "${system_users[@]}"; do
        if id "$user" &>/dev/null; then
            echo "Удаляем системного пользователя: $user"
            # Завершаем процессы пользователя
            pkill -u "$user" 2>/dev/null
            userdel -r "$user" 2>/dev/null
        fi
    done

    # Удаление групп
    system_groups=(
        "samba"
        "bind"
        "bind9"
        "krb5kdc"
        "kerberos"
    )

    for group in "${system_groups[@]}"; do
        if getent group "$group" &>/dev/null; then
            echo "Удаляем группу: $group"
            groupdel "$group" 2>/dev/null
        fi
    done
}

# Функция очистки dpkg статуса
cleanup_dpkg_status() {
    echo -e "${YELLOW}Очищаем dpkg статус...${NC}"

    # Проверяем наличие сломанных пакетов
    if dpkg -l 2>/dev/null | grep -E "^(rc|iU)" | grep -E "samba|bind9|krb5"; then
        echo "Найдены сломанные пакеты, очищаем..."

        # Принудительное удаление пакетов в статусе 'rc' (удалены, но конфиги остались)
        dpkg -l 2>/dev/null | grep "^rc" | grep -E "samba|bind9|krb5" | awk '{print $2}' | xargs -r dpkg --purge 2>/dev/null

        # Очистка dpkg статуса
        dpkg --configure -a
    fi

    # Очистка кэша apt
    apt-get clean
}

# Функция поиска оставшихся процессов
check_remaining_processes() {
    echo -e "${BLUE}Проверка оставшихся процессов...${NC}"

    processes_found=0

    for pattern in "smbd" "nmbd" "winbind" "samba" "krb5" "kdc" "bind" "named"; do
        pids=$(pgrep -f "$pattern" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo -e "${RED}Найдены процессы $pattern: $pids${NC}"
            processes_found=$((processes_found + 1))

            # Спрашиваем, убить ли процессы
            if confirm "Завершить процессы $pattern?"; then
                pkill -f "$pattern" 2>/dev/null
                sleep 2
                # Проверяем, завершились ли
                if pgrep -f "$pattern" >/dev/null 2>&1; then
                    echo -e "${RED}Процессы не завершились, используем SIGKILL...${NC}"
                    pkill -9 -f "$pattern" 2>/dev/null
                fi
            fi
        fi
    done

    if [ $processes_found -eq 0 ]; then
        echo -e "${GREEN}Активных процессов не найдено${NC}"
    fi
}

# Функция поиска оставшихся файлов конфигурации
find_remaining_configs() {
    echo -e "${BLUE}Поиск оставшихся файлов конфигурации...${NC}"

    local search_paths=(
        "/etc/*samba*"
        "/etc/*krb5*"
        "/etc/*bind*"
        "/var/lib/*samba*"
        "/var/lib/*krb5*"
        "/var/lib/*bind*"
        "/var/log/*samba*"
        "/var/log/*krb5*"
        "/var/log/*bind*"
    )

    local found=0

    for path in "${search_paths[@]}"; do
        # ИСПРАВЛЕНО: Используем ls с подавлением ошибок
        for file in $(ls -d $path 2>/dev/null); do
            if [ -e "$file" ]; then
                echo -e "${YELLOW}Найден: $file${NC}"
                found=$((found + 1))
            fi
        done
    done

    if [ $found -eq 0 ]; then
        echo -e "${GREEN}Оставшихся файлов конфигурации не найдено${NC}"
    else
        echo -e "${YELLOW}Всего найдено файлов: $found${NC}"
        if confirm "Удалить все найденные файлы?"; then
            for path in "${search_paths[@]}"; do
                for file in $(ls -d $path 2>/dev/null); do
                    if [ -e "$file" ]; then
                        echo "Удаляем $file"
                        rm -rf "$file"
                    fi
                done
            done
            echo -e "${GREEN}Файлы удалены${NC}"
        fi
    fi
}

# Основная логика скрипта
main() {
    echo -e "${RED}=============================================${NC}"
    echo -e "${RED}   ПОЛНАЯ ОЧИСТКА СИСТЕМЫ ПЕРЕД ПЕРЕУСТАНОВКОЙ${NC}"
    echo -e "${RED}=============================================${NC}"
    echo ""

    # Показываем текущий статус
    check_services_status
    echo ""
    find_all_masked_services
    echo ""
    check_remaining_processes
    echo ""

    echo -e "${RED}ВНИМАНИЕ! Это действие полностью удалит:${NC}"
    echo "  - Samba, Kerberos и Bind9"
    echo "  - Все конфигурационные файлы"
    echo "  - Все базы данных и кэш"
    echo "  - Все логи этих служб"
    echo "  - Системных пользователей"
    echo -e "  - ${RED}Снимит маскировку со всех связанных служб${NC}"
    echo ""

    if ! confirm "Вы уверены, что хотите продолжить полную очистку?"; then
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}Начинаем очистку...${NC}"
    echo ""

    # Выполнение всех шагов
    stop_and_disable_services
    unmask_services
    remove_packages
    cleanup_dpkg_status
    cleanup_systemd_units
    remove_config_dirs
    cleanup_users_groups
    find_remaining_configs
    check_remaining_processes

    # Финальная проверка маскировки
    echo ""
    echo -e "${BLUE}Финальная проверка статуса служб:${NC}"
    check_services_status

    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}ПОЛНАЯ ОЧИСТКА ЗАВЕРШЕНА УСПЕШНО${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Система полностью готова к переустановке Samba AD DC"
    echo ""
    echo "Рекомендуемые действия:"
    echo "  1. Перезагрузить систему: sudo reboot"
    echo "  2. После перезагрузки проверить: systemctl status smbd (должен вернуть 'not found')"
    echo "  3. Приступать к установке"	
    echo ""
    echo "Нужно проверить не удалилась ли SSH"
    echo "инача пропадет доступк серверу"	
	

    if confirm "Перезагрузить систему сейчас?"; then
        reboot
    fi
}

# Запуск основной функции
main