<div align="center">

# 🖥️ RustDesk Server
**Интерактивный Bash-установщик сервера RustDesk**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](rustdesk.sh)
[![RustDesk](https://img.shields.io/badge/RustDesk-Server-0078D7?logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMSAxNEg5VjhoMnY4em00IDBIMTNWOGgydjh6Ii8+PC9zdmc+)](https://rustdesk.com)
[![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)](https://kernel.org)
[![Architecture](https://img.shields.io/badge/Arch-amd64%20%7C%20arm64%20%7C%20armv7-lightgrey)](#)

</div>

---

## 💡 О проекте

Этот скрипт автоматизирует полную установку **сервера RustDesk** на Linux-машину. Вместо ручной загрузки бинарников, настройки systemd и открытия портов — один интерактивный мастер-установщик.

**Что делает скрипт:**

- Определяет операционную систему и архитектуру процессора
- Устанавливает зависимости через нативный пакетный менеджер
- Скачивает последний релиз `hbbs` + `hbbr` с GitHub
- Создаёт и активирует `systemd`-сервисы с авто-перезапуском
- Опционально открывает порты в `ufw` / `firewalld`
- Опционально разворачивает HTTP-сервер с готовыми установщиками для Windows и Linux клиентов
- Выводит готовую конфигурацию: адрес, публичный ключ, порты

---

## ✅ Требования

| Компонент | Минимум |
|-----------|---------|
| ОС | Debian / Ubuntu / CentOS / RHEL / Arch Linux |
| Архитектура | `x86_64`, `aarch64`, `armv7l` |
| Права | `root` или пользователь с `sudo` |
| Утилиты | `curl` или `wget`, `unzip`, `dig` |
| Сеть | Открытый публичный IP или доменное имя |

---

## 🚀 Быстрый старт

```bash
# Скачать и запустить установщик
curl -fsSL https://raw.githubusercontent.com/avar-soft/rustdesk-server/main/rustdesk.sh | bash
```

Или с явной загрузкой файла:

```bash
wget https://raw.githubusercontent.com/avar-soft/rustdesk-server/main/rustdesk.sh
chmod +x rustdesk.sh
./rustdesk.sh
```

Скрипт задаст несколько вопросов и проведёт через все шаги установки.

---

## ⚙️ Параметры запуска

Для неинтерактивного или автоматизированного развёртывания доступны флаги:

```
./rustdesk.sh [опции]
```

| Флаг | Описание |
|------|----------|
| `--resolveip` | Определить публичный IP автоматически (через OpenDNS / ipify) |
| `--resolvedns "fqdn"` | Использовать указанный домен (например `rdsk.example.com`) |
| `--install-http` | Установить HTTP-сервер для раздачи установщиков клиентам |
| `--skip-http` | Пропустить установку HTTP-сервера |
| `--no-sudo` | Не использовать `sudo` (для запуска от root) |
| `--yes` | Принять все значения по умолчанию без подтверждений |
| `--help` | Показать справку |

**Примеры:**

```bash
# Полностью автоматическая установка с auto-detect IP
./rustdesk.sh --resolveip --install-http --yes

# Установка с доменным именем
./rustdesk.sh --resolvedns rustdesk.example.com --install-http

# Только сервер relay/signal, без HTTP
./rustdesk.sh --resolveip --skip-http --yes
```

---

## 📦 Что устанавливается

```
/opt/rustdesk/
├── hbbs          # Signal-сервер (ID/NAT traversal)
├── hbbr          # Relay-сервер
├── *.pub         # Публичный ключ сервера
└── ...

/var/log/rustdesk/
├── signalserver.log
├── signalserver.error
├── relayserver.log
└── relayserver.error

/etc/systemd/system/
├── rustdesksignal.service
└── rustdeskrelay.service

/opt/gohttp/               # (опционально, если --install-http)
└── public/
    ├── WindowsAgentAIOInstall.ps1
    └── linuxclientinstall.sh
```

---

## 🔥 Порты и firewall

Скрипт предложит автоматически открыть нужные порты (через `ufw` или `firewalld`).

| Порт | Протокол | Назначение |
|------|----------|------------|
| `21115` | TCP | hbbs — проверка типа NAT |
| `21116` | TCP + UDP | hbbs — регистрация ID, keepalive, hole-punching |
| `21117` | TCP | hbbr — relay-трафик |
| `21118` | TCP | hbbs — WebSocket |
| `21119` | TCP | hbbr — WebSocket |
| `8000` | TCP | HTTP-сервер установщиков *(опционально)* |

> При необходимости базовый порт можно изменить — скрипт автоматически назначит смежные.

---

## 🛠️ Управление сервисами

```bash
# Статус сервисов
systemctl status rustdesksignal rustdeskrelay

# Просмотр логов в реальном времени
journalctl -u rustdesksignal -f
journalctl -u rustdeskrelay -f

# Перезапуск
systemctl restart rustdesksignal rustdeskrelay

# Остановка
systemctl stop rustdesksignal rustdeskrelay
```

---

## 📱 Настройка клиента

После завершения установки скрипт выведет:

```
Адрес сервера:   your.ip.or.domain
Публичный ключ:  AbCdEfGhIjKlMnOpQrStUvWx=
```

В приложении RustDesk перейдите в **Настройки → Сеть** и укажите:

- **ID-сервер:** `your.ip.or.domain`
- **Relay-сервер:** `your.ip.or.domain`
- **Ключ:** вставьте публичный ключ из вывода установщика

> Если был установлен HTTP-сервер, готовые установщики доступны по адресу  
> `http://your.ip.or.domain:8000` (логин: `admin`, пароль выводится в финальном отчёте)

---

## 🐧 Поддерживаемые ОС

| Дистрибутив | Менеджер пакетов |
|-------------|------------------|
| Ubuntu / Debian и производные | `apt-get` |
| CentOS / RHEL и производные | `yum` |
| Arch Linux и производные | `pacman` |

---

## 🗂️ Структура проекта

```
.
└── rustdesk.sh    # Основной скрипт установки
```

---

## 📄 Лицензия

Распространяется под лицензией [MIT](LICENSE). Свободно для личного и коммерческого использования.

---

<div align="center">
  <sub>Сделано с ❤️ для тех, кто держит свои данные у себя</sub>
</div>
