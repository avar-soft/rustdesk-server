#!/bin/bash
# =============================================================================
#  RustDesk Server — Автономный интерактивный установщик
# =============================================================================

set -o pipefail

# ---------- Базовые URL автономных ресурсов ----------
BASE_URL="https://raw.githubusercontent.com/avar-soft/rustdesk-server/main/scr"
GO_URL="https://github.com/avar-soft/wireguard-webui/releases/download/main/go1.26.3.linux-amd64.tar.gz"

RUSTDESK_ARCHIVE="rustdesk-server-linux-amd64.zip"
GOHTTP_ARCHIVE="gohttpserver_1.3.0_linux_amd64.tar.gz"
WIN_INSTALLER="WindowsAgentAIOInstall.ps1"
LINUX_INSTALLER="linuxclientinstall.sh"
WIN_CLIENT_INSTALL="clientinstall.ps1"
WIN_CLIENT_ID="windowsclientID.ps1"

# ---------- Цвета и оформление ----------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

# Ширина рамок: внутреннее поле = 62 символа, всего ширина 64
# Все рамки строго одной ширины — проверено посимвольно.
banner() {
    clear 2>/dev/null || true
    printf "%b\n" "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║        ██████  ██    ██ ███████ ████████ ██████              ║"
    echo "║        ██   ██ ██    ██ ██         ██    ██   ██             ║"
    echo "║        ██████  ██    ██ ███████    ██    ██   ██             ║"
    echo "║        ██   ██ ██    ██      ██    ██    ██   ██             ║"
    echo "║        ██   ██  ██████  ███████    ██    ██████              ║"
    echo "║                                                              ║"
    echo "║              D E S K   S E R V E R   S E T U P               ║"
    echo "║                  (offline / autonomous)                      ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    printf "%b\n" "${NC}"
}

hr()      { printf "%b\n" "${DIM}──────────────────────────────────────────────────────────────${NC}"; }
section() { printf "%b\n" "\n${MAGENTA}${BOLD}▸ $1${NC}"; hr; }
info()    { printf "%b\n" "${BLUE}ℹ${NC}  $1"; }
ok()      { printf "%b\n" "${GREEN}✔${NC}  $1"; }
warn()    { printf "%b\n" "${YELLOW}⚠${NC}  $1"; }
err()     { printf "%b\n" "${RED}✖${NC}  $1" >&2; }
ask()     { printf "%b" "${CYAN}?${NC} ${BOLD}$1${NC} "; }

# Открываем /dev/tty для интерактивного ввода — это позволяет скрипту
# работать при запуске через  curl ... | bash  или  bash <(...)
_read_tty() {
    local _var="$1"
    if [ -t 0 ]; then
        read -r "$_var"
    elif [ -r /dev/tty ]; then
        read -r "$_var" </dev/tty
    else
        echo ""
        err "Невозможно прочитать ввод: нет доступа к терминалу."
        err "Запустите скрипт напрямую: bash rustdesk.sh [--ip <IP>] [--yes]"
        exit 1
    fi
}

# ---------- Утилиты ----------
ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    while true; do
        ask "$prompt $hint:"; _read_tty reply
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) warn "Введите y или n" ;;
        esac
    done
}

# Глобальная переменная для возврата значения из интерактивных функций
# (обходит ограничение bash: local в дочерней функции не видна в родительской)
_ASK_RESULT=""

# ask_default PROMPT DEFAULT VARNAME  — результат пишется в VARNAME
ask_default() {
    local _prompt="$1" _default="$2" _var="$3"
    printf "%b" "${CYAN}?${NC} ${BOLD}${_prompt}${NC} ${DIM}[${_default}]${NC}: " >/dev/tty
    _read_tty _ASK_RESULT
    _ASK_RESULT="${_ASK_RESULT:-$_default}"
    printf -v "$_var" '%s' "$_ASK_RESULT"
}

# ask_port PROMPT DEFAULT VARNAME
ask_port() {
    local _prompt="$1" _default="$2" _var="$3"
    while true; do
        ask_default "$_prompt" "$_default" "$_var"
        local _val="${!_var}"
        if [[ "$_val" =~ ^[0-9]+$ ]] && (( _val >= 1 && _val <= 65535 )); then
            return 0
        fi
        warn "Некорректный порт: $_val (допустимо 1–65535)"
    done
}

is_valid_host() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    local n
    for n in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        (( n >= 0 && n <= 255 )) || return 1
    done
    return 0
}

require_root_or_sudo() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    elif command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        SUDO=""
        warn "Скрипт запущен не от root и sudo не найден — часть шагов может завершиться ошибкой."
    fi
}

# Скачивание с проверкой результата
download() {
    local url="$1" out="$2"
    info "Загрузка: $(basename "$out")"
    if ! wget -q --show-progress -O "$out" "$url"; then
        err "Не удалось скачать: $url"
        return 1
    fi
    if [[ ! -s "$out" ]]; then
        err "Пустой файл после загрузки: $out"
        return 1
    fi
    return 0
}

# ---------- Аргументы ----------
usesudo="true"
http=""
wanip_arg=""
resolvedns=""
ASSUME_YES=""

while getopts "i:h-:" option; do
    case "${option}" in
        -)
            case "${OPTARG}" in
                help)         help="true" ;;
                ip)           wanip_arg="${!OPTIND}"; OPTIND=$(( OPTIND + 1 )) ;;
                resolvedns)   resolvedns="${!OPTIND}"; OPTIND=$(( OPTIND + 1 )) ;;
                install-http) http="true" ;;
                skip-http)    http="false" ;;
                no-sudo)      usesudo="false" ;;
                yes|y)        ASSUME_YES="true" ;;
            esac ;;
        i) wanip_arg="$OPTARG" ;;
        h) help="true" ;;
    esac
done

if [[ -n "$help" ]]; then
    cat <<EOF
Использование: rustdesk.sh [опции]
  -i <IP>                    IP адрес сервера (пропустить интерактивный ввод)
  --ip <IP>                  То же, что -i
  --resolvedns <fqdn>        Использовать указанный домен вместо IP
  --install-http             Установить HTTP сервер для раздачи установщиков
  --skip-http                Не устанавливать HTTP сервер
  --no-sudo                  Не использовать sudo
  --yes                      Согласиться со всеми предложенными значениями
  --help / -h                Показать эту справку

Примеры:
  bash rustdesk.sh --ip 1.2.3.4 --yes
  bash rustdesk.sh --resolvedns rustdesk.example.com --install-http

Скрипт автономен: все бинарники и установщики берутся с
  ${BASE_URL}
EOF
    exit 0
fi

if [[ "$usesudo" == "false" ]]; then
    SUDO=""
else
    require_root_or_sudo
fi

# ---------- Старт ----------
banner
printf "%b\n" "${BOLD}Добро пожаловать в автономный установщик RustDesk Server!${NC}"
printf "%b\n" "${DIM}Скрипт проведёт вас по шагам и задаст несколько вопросов.${NC}"
printf "%b\n" "${DIM}Все ресурсы скачиваются с avar-soft/rustdesk-server (без GitHub API).${NC}\n"

uname_user=$(whoami)
gname=$(id -gn "${uname_user}")
ARCH=$(uname -m)

# ---------- Определение ОС ----------
section "Определение операционной системы"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME; VER=$VERSION_ID
    UPSTREAM_ID=${ID_LIKE,,}
    if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
        UPSTREAM_ID="$(echo "${ID_LIKE,,}" | sed 's/"//g' | cut -d' ' -f1)"
    fi
elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si); VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release; OS=$DISTRIB_ID; VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    OS=Debian; VER=$(cat /etc/debian_version)
elif [ -f /etc/redhat-release ]; then
    OS=RedHat; VER=$(cat /etc/redhat-release)
else
    OS=$(uname -s); VER=$(uname -r)
fi
ok "Обнаружено: ${BOLD}${OS} ${VER}${NC} (${ARCH})"

if [[ "$ARCH" != "x86_64" ]]; then
    warn "Автономные архивы собраны под x86_64/amd64."
    warn "Текущая архитектура: ${ARCH} — установка может завершиться ошибкой."
    ask_yes_no "Продолжить?" "n" || exit 1
fi

# ---------- ИНТЕРАКТИВНОЕ МЕНЮ ----------
section "Параметры установки"

if [[ -n "$wanip_arg" ]]; then
    # IP передан через аргумент -i / --ip
    if is_valid_ip "$wanip_arg"; then
        wanip="$wanip_arg"
        ok "IP: ${BOLD}${wanip}${NC}"
    else
        err "Некорректный IP адрес: $wanip_arg"
        exit 1
    fi
elif [[ -n "$resolvedns" ]]; then
    wanip="$resolvedns"
    is_valid_host "$wanip" || { err "Некорректный домен: $wanip"; exit 1; }
    ok "Домен: ${BOLD}${wanip}${NC}"
else
    printf "%b\n" "${BOLD}Как клиенты будут подключаться к серверу?${NC}"
    printf "%b\n" "  1) Ввести IP вручную   ${DIM}(рекомендуется для автономной установки)${NC}"
    echo    "  2) Ввести доменное имя (FQDN)"
    while true; do
        ask "Выбор [1-2]:"; _read_tty choice
        choice="${choice:-1}"
        case "$choice" in
            1) while true; do
                   ask "Введите IP адрес сервера:"; _read_tty wanip
                   if is_valid_ip "$wanip"; then ok "IP: ${BOLD}${wanip}${NC}"; break 2
                   else err "Некорректный IP адрес"; fi
               done ;;
            2) while true; do
                   ask "Введите домен (например rustdesk.example.com):"; _read_tty wanip
                   if is_valid_host "$wanip"; then ok "Домен: ${BOLD}${wanip}${NC}"; break 2
                   else err "Некорректное доменное имя"; fi
               done ;;
            *) warn "Введите 1 или 2" ;;
        esac
    done
fi

# Порты
echo
if [[ "$ASSUME_YES" == "true" ]] || ask_yes_no "Использовать стандартные порты RustDesk (21115-21119)?" "y"; then
    PORT_HBBS_TCP=21115
    PORT_HBBS_NAT=21116
    PORT_HBBS_RELAY=21117
    PORT_HBBS_WEB=21118
    PORT_HBBR_WEB=21119
else
    info "Введите базовый порт (NAT/ID). Остальные будут смежными:"
    ask_port "  hbbs основной (NAT/ID, UDP+TCP)" 21116 PORT_HBBS_NAT
    PORT_HBBS_TCP=$((PORT_HBBS_NAT - 1))
    PORT_HBBS_RELAY=$((PORT_HBBS_NAT + 1))
    PORT_HBBS_WEB=$((PORT_HBBS_NAT + 2))
    PORT_HBBR_WEB=$((PORT_HBBS_NAT + 3))
    info "Будут использованы: ${PORT_HBBS_TCP}, ${PORT_HBBS_NAT}, ${PORT_HBBS_RELAY}, ${PORT_HBBS_WEB}, ${PORT_HBBR_WEB}"
fi
PORT_RELAY=$PORT_HBBS_RELAY

# Каталоги
echo
ask_default "Каталог установки сервера RustDesk" "/opt/rustdesk" INSTALL_DIR
ask_default "Каталог логов" "/var/log/rustdesk" LOG_DIR

# HTTP
echo
if [[ -z "$http" ]]; then
    if ask_yes_no "Установить HTTP сервер для раздачи установщиков клиентам?" "y"; then
        http="true"
    else
        http="false"
    fi
fi

HTTP_PORT=8000
HTTP_USER=""
HTTP_PASS=""
if [[ "$http" == "true" ]]; then
    ask_port "Порт для HTTP сервера установщиков" 8000 HTTP_PORT
    ask_default "Логин для HTTP сервера" "admin" HTTP_USER
    while true; do
        printf "%b" "${CYAN}?${NC} ${BOLD}Пароль для HTTP сервера${NC} (мин. 6 символов): " >/dev/tty
        _read_tty HTTP_PASS
        if [[ ${#HTTP_PASS} -ge 6 ]]; then
            break
        fi
        warn "Пароль слишком короткий, минимум 6 символов"
    done
fi

# Firewall
echo
OPEN_FW="false"
if command -v ufw &>/dev/null || command -v firewall-cmd &>/dev/null; then
    if ask_yes_no "Открыть необходимые порты в firewall?" "y"; then
        OPEN_FW="true"
    fi
fi

# Сводка
echo
section "Сводка параметров"
printf "%b\n" "  ${BOLD}Адрес сервера:${NC}    ${wanip}"
printf "%b\n" "  ${BOLD}Порты RustDesk:${NC}   ${PORT_HBBS_TCP}, ${PORT_HBBS_NAT}, ${PORT_HBBS_RELAY}, ${PORT_HBBS_WEB}, ${PORT_HBBR_WEB}"
printf "%b\n" "  ${BOLD}Каталог:${NC}          ${INSTALL_DIR}"
printf "%b\n" "  ${BOLD}Логи:${NC}             ${LOG_DIR}"
if [[ "$http" == "true" ]]; then
    printf "%b\n" "  ${BOLD}HTTP сервер:${NC}      да (порт ${HTTP_PORT})"
else
    printf "%b\n" "  ${BOLD}HTTP сервер:${NC}      нет"
fi
if [[ "$OPEN_FW" == "true" ]]; then
    printf "%b\n" "  ${BOLD}Firewall:${NC}         открыть порты"
else
    printf "%b\n" "  ${BOLD}Firewall:${NC}         не трогать"
fi
printf "%b\n" "  ${BOLD}Пользователь:${NC}     ${uname_user}:${gname}"
echo
if [[ "$ASSUME_YES" != "true" ]]; then
    ask_yes_no "Продолжить установку с этими параметрами?" "y" || { warn "Установка отменена пользователем"; exit 0; }
fi

# ---------- Зависимости ----------
section "Установка зависимостей"
PREREQ="curl wget unzip tar"

if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ] || \
   [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
    $SUDO apt-get update
    $SUDO apt-get install -y ${PREREQ}
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ] || [ "${UPSTREAM_ID}" = "rhel" ]; then
    $SUDO yum install -y ${PREREQ}
elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
    $SUDO pacman -Syu --noconfirm
    $SUDO pacman -S --noconfirm ${PREREQ}
else
    warn "Неподдерживаемая ОС: $OS"
    ask_yes_no "Продолжить без автоматической установки зависимостей?" "n" || exit 1
fi
ok "Зависимости установлены"

# ---------- Каталоги ----------
section "Подготовка каталогов"
$SUDO mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"
$SUDO chown "${uname_user}:${gname}" -R "${INSTALL_DIR}" "${LOG_DIR}"
cd "${INSTALL_DIR}" || { err "Не удалось перейти в ${INSTALL_DIR}"; exit 1; }
ok "Каталоги готовы"

# ---------- Скачивание RustDesk (автономно) ----------
section "Загрузка RustDesk Server (offline)"
info "Источник: ${BASE_URL}/${RUSTDESK_ARCHIVE}"

download "${BASE_URL}/${RUSTDESK_ARCHIVE}" "${INSTALL_DIR}/${RUSTDESK_ARCHIVE}" \
    || { err "Загрузка RustDesk Server не удалась"; exit 1; }

unzip -o "${INSTALL_DIR}/${RUSTDESK_ARCHIVE}" -d "${INSTALL_DIR}" >/dev/null \
    || { err "Не удалось распаковать ${RUSTDESK_ARCHIVE}"; exit 1; }

# Архив может содержать подкаталог amd64/ или сразу бинарники
if [[ -d "${INSTALL_DIR}/amd64" ]]; then
    mv "${INSTALL_DIR}/amd64/"* "${INSTALL_DIR}/" 2>/dev/null || true
    rm -rf "${INSTALL_DIR}/amd64"
fi

if [[ ! -f "${INSTALL_DIR}/hbbs" || ! -f "${INSTALL_DIR}/hbbr" ]]; then
    err "После распаковки не найдены бинарники hbbs/hbbr в ${INSTALL_DIR}"
    exit 1
fi

chmod +x "${INSTALL_DIR}/hbbs" "${INSTALL_DIR}/hbbr"
rm -f "${INSTALL_DIR}/${RUSTDESK_ARCHIVE}"
ok "RustDesk Server установлен в ${INSTALL_DIR}"

# ---------- systemd ----------
section "Настройка systemd сервисов"

HBBS_ARGS="-r ${wanip}:${PORT_RELAY}"
[[ "$PORT_HBBS_NAT" != "21116" ]] && HBBS_ARGS="${HBBS_ARGS} -p ${PORT_HBBS_NAT}"
HBBR_ARGS=""
[[ "$PORT_HBBS_RELAY" != "21117" ]] && HBBR_ARGS="-p ${PORT_HBBS_RELAY}"

$SUDO tee /etc/systemd/system/rustdesksignal.service >/dev/null <<EOF
[Unit]
Description=RustDesk Signal Server (hbbs)
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${INSTALL_DIR}/hbbs ${HBBS_ARGS}
WorkingDirectory=${INSTALL_DIR}/
User=${uname_user}
Group=${gname}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/signalserver.log
StandardError=append:${LOG_DIR}/signalserver.error

[Install]
WantedBy=multi-user.target
EOF

$SUDO tee /etc/systemd/system/rustdeskrelay.service >/dev/null <<EOF
[Unit]
Description=RustDesk Relay Server (hbbr)
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${INSTALL_DIR}/hbbr ${HBBR_ARGS}
WorkingDirectory=${INSTALL_DIR}/
User=${uname_user}
Group=${gname}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/relayserver.log
StandardError=append:${LOG_DIR}/relayserver.error

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now rustdesksignal.service rustdeskrelay.service \
    || { err "Не удалось запустить systemd сервисы"; exit 1; }
ok "Сервисы rustdesksignal и rustdeskrelay запущены"

info "Ожидание запуска relay сервера..."
for i in $(seq 1 20); do
    if $SUDO systemctl is-active --quiet rustdeskrelay.service; then ok "Relay активен"; break; fi
    sleep 2
done

# ---------- Firewall ----------
if [[ "$OPEN_FW" == "true" ]]; then
    section "Настройка firewall"
    PORTS_TO_OPEN=("${PORT_HBBS_TCP}/tcp" "${PORT_HBBS_NAT}/tcp" "${PORT_HBBS_NAT}/udp" \
                   "${PORT_HBBS_RELAY}/tcp" "${PORT_HBBS_WEB}/tcp" "${PORT_HBBR_WEB}/tcp")
    [[ "$http" == "true" ]] && PORTS_TO_OPEN+=("${HTTP_PORT}/tcp")

    if command -v ufw &>/dev/null; then
        for p in "${PORTS_TO_OPEN[@]}"; do $SUDO ufw allow "$p" || true; done
        ok "Порты добавлены в ufw"
    elif command -v firewall-cmd &>/dev/null; then
        for p in "${PORTS_TO_OPEN[@]}"; do $SUDO firewall-cmd --permanent --add-port="$p" || true; done
        $SUDO firewall-cmd --reload || true
        ok "Порты добавлены в firewalld"
    fi
fi

# ---------- Публичный ключ ----------
section "Получение публичного ключа"
pubname=""
for i in $(seq 1 15); do
    pubname=$(find "${INSTALL_DIR}" -maxdepth 2 -name "*.pub" 2>/dev/null | head -1)
    [[ -n "$pubname" ]] && break
    sleep 1
done
if [[ -z "$pubname" ]]; then
    err "Публичный ключ не найден — возможно, hbbs не успел запуститься"
    err "Проверьте: journalctl -u rustdesksignal -n 50"
    exit 1
fi
key=$(cat "${pubname}")
ok "Публичный ключ получен"

string="{\"host\":\"${wanip}\",\"relay\":\"${wanip}\",\"key\":\"${key}\",\"api\":\"https://${wanip}\"}"
string64=$(echo -n "$string" | base64 -w 0 | tr -d '=')
string64rev=$(echo -n "$string64" | rev)

# ---------- HTTP сервер (автономно) ----------
setuphttp() {
    section "Установка HTTP сервера для установщиков (offline)"

    cd "${INSTALL_DIR}" || exit 1

    download "${BASE_URL}/${WIN_INSTALLER}"  "${INSTALL_DIR}/${WIN_INSTALLER}"  || return 1
    download "${BASE_URL}/${LINUX_INSTALLER}" "${INSTALL_DIR}/${LINUX_INSTALLER}" || return 1
    # Дополнительные клиентские скрипты (опционально)
    download "${BASE_URL}/${WIN_CLIENT_INSTALL}" "${INSTALL_DIR}/${WIN_CLIENT_INSTALL}" || true
    download "${BASE_URL}/${WIN_CLIENT_ID}"      "${INSTALL_DIR}/${WIN_CLIENT_ID}"      || true

    $SUDO sed -i "s|secure-string|${string64rev}|g" "${INSTALL_DIR}/${WIN_INSTALLER}"
    $SUDO sed -i "s|secure-string|${string64rev}|g" "${INSTALL_DIR}/${LINUX_INSTALLER}"
    [[ -f "${INSTALL_DIR}/${WIN_CLIENT_INSTALL}" ]] && \
        $SUDO sed -i "s|secure-string|${string64rev}|g" "${INSTALL_DIR}/${WIN_CLIENT_INSTALL}"

    $SUDO mkdir -p /opt/gohttp/public /var/log/gohttp
    $SUDO chown "${uname_user}:${gname}" -R /opt/gohttp /var/log/gohttp
    cd /opt/gohttp || exit 1

    download "${BASE_URL}/${GOHTTP_ARCHIVE}" "/opt/gohttp/${GOHTTP_ARCHIVE}" \
        || { err "Не удалось скачать gohttpserver"; return 1; }

    tar -xf "/opt/gohttp/${GOHTTP_ARCHIVE}" -C /opt/gohttp \
        || { err "Не удалось распаковать gohttpserver"; return 1; }
    rm -f "/opt/gohttp/${GOHTTP_ARCHIVE}"

    if [[ ! -x /opt/gohttp/gohttpserver ]]; then
        chmod +x /opt/gohttp/gohttpserver 2>/dev/null || true
    fi
    if [[ ! -f /opt/gohttp/gohttpserver ]]; then
        err "Бинарник gohttpserver не найден после распаковки"
        return 1
    fi

    mv "${INSTALL_DIR}/${WIN_INSTALLER}"  /opt/gohttp/public/
    mv "${INSTALL_DIR}/${LINUX_INSTALLER}" /opt/gohttp/public/
    [[ -f "${INSTALL_DIR}/${WIN_CLIENT_INSTALL}" ]] && \
        mv "${INSTALL_DIR}/${WIN_CLIENT_INSTALL}" /opt/gohttp/public/
    [[ -f "${INSTALL_DIR}/${WIN_CLIENT_ID}" ]] && \
        mv "${INSTALL_DIR}/${WIN_CLIENT_ID}" /opt/gohttp/public/

    $SUDO tee /etc/systemd/system/gohttpserver.service >/dev/null <<EOF
[Unit]
Description=Go HTTP Server (RustDesk installers)
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/opt/gohttp/gohttpserver -r ./public --port ${HTTP_PORT} --auth-type http --auth-http ${HTTP_USER}:${HTTP_PASS}
WorkingDirectory=/opt/gohttp/
User=${uname_user}
Group=${gname}
Restart=always
RestartSec=10
StandardOutput=append:/var/log/gohttp/gohttpserver.log
StandardError=append:/var/log/gohttp/gohttpserver.error

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now gohttpserver.service \
        || { err "Не удалось запустить gohttpserver"; return 1; }
    ok "HTTP сервер запущен на порту ${HTTP_PORT}"
}

if [[ "$http" == "true" ]]; then
    setuphttp || warn "HTTP сервер не установлен — см. сообщения выше"
fi

# ---------- Финальный отчёт ----------
echo
printf "%b\n" "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║              УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА                     ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
printf "%b\n" "${NC}"

printf "%b\n" "${BOLD}Адрес сервера:${NC}     ${wanip}"
printf "%b\n" "${BOLD}Публичный ключ:${NC}    ${key}"
echo
printf "%b\n" "${BOLD}Порты:${NC}"
echo "  • hbbs (ID/NAT):   ${PORT_HBBS_NAT}/tcp+udp"
echo "  • hbbs TCP:        ${PORT_HBBS_TCP}/tcp"
echo "  • hbbr (relay):    ${PORT_HBBS_RELAY}/tcp"
echo "  • Web (hbbs):      ${PORT_HBBS_WEB}/tcp"
echo "  • Web (hbbr):      ${PORT_HBBR_WEB}/tcp"

if [[ "$http" == "true" ]]; then
    echo
    printf "%b\n" "${BOLD}HTTP установщики:${NC} http://${wanip}:${HTTP_PORT}"
    echo "  • Логин:    ${HTTP_USER}"
    echo "  • Пароль:   ${HTTP_PASS}"
fi

echo
printf "%b\n" "${BOLD}Управление сервисами:${NC}"
echo "  systemctl status rustdesksignal rustdeskrelay"
echo "  journalctl -u rustdesksignal -f"
echo "  journalctl -u rustdeskrelay  -f"
echo
printf "%b\n" "${DIM}В клиенте RustDesk укажите адрес ${wanip} и публичный ключ выше.${NC}"
