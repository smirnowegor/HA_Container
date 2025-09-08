#!/bin/bash
set -euo pipefail

# vscodeoneclick.sh — расширенная версия с выбором места установки конфигурации code-server
# Взято за основу: original script + выбор диска из fastDockerWb.sh
# Источники: https://raw.githubusercontent.com/smirnowegor/HA_Container/.../vscodeoneclick.sh
#           https://raw.githubusercontent.com/smirnowegor/ESP-WB/.../fastDockerWb.sh

LOG() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

echo "Привет! Мы сейчас обновим установку Code-Server."

# --- Пароль ---
read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD
echo ""
read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM
echo ""
while [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; do
  echo "Пароли не совпадают. Попробуй снова."
  read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD
  echo ""
  read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM
  echo ""
done
if [ -z "$USER_PASSWORD" ]; then
  ERR "Ошибка: Пароль не может быть пустым."
fi

# --- Порт ---
read -p "Пожалуйста, введи ПОРТ для Code-Server (по умолчанию 9091): " USER_PORT
USER_PORT=${USER_PORT:-9091}

echo ""
LOG "Начинаем процесс..."

# --- Выбор места установки конфигурации (новое) ---
LOG "Выбор места установки конфигурации code-server."

# Собираем подходящие монтирования (размер >1GB, исключая /boot)
mapfile -t _options < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%s free)\n", $6, substr($4/1073741824, 1, 4)"G"}' | sort -k2 -hr)

# Добавим вариант "по умолчанию" (/root)
_options+=("/root (по умолчанию)")

if [ ${#_options[@]} -eq 0 ]; then
  WARN "Не нашёл подходящих разделов. Использую /root."
  INSTALL_ROOT="/root"
else
  echo "Выберите базовый каталог для установки конфигурации code-server:"
  PS3="Введите номер и нажмите Enter: "
  select opt in "${_options[@]}"; do
    if [[ -n "$opt" ]]; then
      # если выбран /root (наш вариант с пометкой)
      if [[ "$opt" == "/root (по умолчанию)" ]]; then
        INSTALL_ROOT="/root"
      else
        # извлечь путь /path (первый токен строки)
        INSTALL_MOUNT=$(echo "$opt" | awk '{print $1}')
        # по умолчанию будем создавать подпапку code-server на выбранном монтировании
        INSTALL_ROOT="${INSTALL_MOUNT}/code-server"
      fi
      break
    else
      echo "Неверный выбор. Попробуйте снова."
    fi
  done
fi

LOG "Выбран каталог установки: $INSTALL_ROOT"

# --- Проверки прав: создадим каталоги (потребуются sudo, если не root) ---
create_dir() {
  target="$1"
  if [ ! -d "$target" ]; then
    LOG "Создаю каталог: $target"
    sudo mkdir -p "$target"
  fi
  # установить владельца root, права 755 (безопасно для сервисов)
  sudo chown root:root "$target"
  sudo chmod 0755 "$target"
}

# создаём структуру
create_dir "$INSTALL_ROOT"
create_dir "${INSTALL_ROOT}/.config"
create_dir "${INSTALL_ROOT}/.config/code-server"
create_dir "${INSTALL_ROOT}/.local"
create_dir "${INSTALL_ROOT}/.local/bin"

# --- Резервная копия существующей конфигурации в /root/.config/code-server (если есть) ---
ROOT_CONFIG_DIR="/root/.config"
ROOT_CS_DIR="${ROOT_CONFIG_DIR}/code-server"
if [ -e "$ROOT_CS_DIR" ] && [ ! -L "$ROOT_CS_DIR" ]; then
  TS=$(date +%Y%m%d%H%M%S)
  BACKUP="/root/.config_code-server_backup_${TS}"
  LOG "Найдена существующая конфигурация $ROOT_CS_DIR — делаю бэкап в $BACKUP"
  sudo mv "$ROOT_CS_DIR" "$BACKUP"
fi

# создаём /root/.config (если нет) и ставим symlink на выбранную папку (только code-server)
if [ ! -d "$ROOT_CONFIG_DIR" ]; then
  LOG "Создаю $ROOT_CONFIG_DIR"
  sudo mkdir -p "$ROOT_CONFIG_DIR"
  sudo chown root:root "$ROOT_CONFIG_DIR"
  sudo chmod 0755 "$ROOT_CONFIG_DIR"
fi

# если уже есть link — удалим и пересоздадим
if [ -L "$ROOT_CS_DIR" ]; then
  LOG "Пересоздаю символьную ссылку для /root/.config/code-server"
  sudo rm -f "$ROOT_CS_DIR"
fi

LOG "Создаю символьную ссылку: $ROOT_CS_DIR -> ${INSTALL_ROOT}/.config/code-server"
sudo ln -sfn "${INSTALL_ROOT}/.config/code-server" "$ROOT_CS_DIR"
sudo chown -h root:root "$ROOT_CS_DIR" || true

# --- Шаг 1: удаление старых сервисов/файлов (по оригиналу) ---
LOG "Проверка и удаление предыдущих установок Code-Server (если есть)..."

if sudo systemctl is-active --quiet code-server@root; then
  LOG "Останавливаем service code-server@root..."
  sudo systemctl stop code-server@root || true
fi
if sudo systemctl is-enabled --quiet code-server@root; then
  LOG "Отключаем автозапуск..."
  sudo systemctl disable code-server@root || true
  sudo systemctl daemon-reload || true
fi
if [ -f "/etc/systemd/system/code-server@.service" ]; then
  LOG "Удаляю старый systemd unit..."
  sudo rm -f /etc/systemd/system/code-server@.service
  sudo systemctl daemon-reload || true
fi

# удаляем старые конфиги в стандартном месте (если требуется)
if [ -f "/root/.config/code-server/config.yaml" ]; then
  LOG "Удаляю старый конфиг /root/.config/code-server/config.yaml"
  sudo rm -f /root/.config/code-server/config.yaml || true
fi

# --- Шаг 2: установка code-server ---
LOG "Устанавливаю code-server (официальный install.sh)..."
# установка official script; если не нужна - можно заменить другим способом
curl -fsSL https://code-server.dev/install.sh | sh || { ERR "Не удалось установить code-server."; }

# --- Шаг 3: создаём systemd unit с WorkingDirectory = INSTALL_ROOT ---
LOG "Создаю systemd unit для code-server (WorkingDirectory: $INSTALL_ROOT)..."
sudo tee /etc/systemd/system/code-server@.service > /dev/null <<EOF
[Unit]
Description=code-server for %i
After=network.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=$INSTALL_ROOT
ExecStart=/usr/bin/code-server
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# --- Шаг 4: Запуск один раз, чтобы создались файлы (как в оригинале) ---
LOG "Пробуем запустить сервис temporariy чтобы создать файлы..."
sudo systemctl daemon-reload || true
sudo systemctl start code-server@root || true
sleep 3
sudo systemctl stop code-server@root || true
sleep 1

# --- Шаг 5: Создаём config.yaml в выбранном месте (INSTALL_ROOT/.config/code-server/config.yaml) ---
CFG_FILE="${INSTALL_ROOT}/.config/code-server/config.yaml"
LOG "Создаю конфиг $CFG_FILE"
sudo mkdir -p "$(dirname "$CFG_FILE")"
sudo tee "$CFG_FILE" > /dev/null <<EOC
bind-addr: 0.0.0.0:$USER_PORT
auth: password
password: $USER_PASSWORD
cert: false
EOC
sudo chown root:root "$CFG_FILE"
sudo chmod 0600 "$CFG_FILE"

# --- Шаг 6: перезагрузка systemd, запуск и включение автозапуска ---
LOG "Перезагружаю systemd и запускаю сервис..."
sudo systemctl daemon-reload || { ERR "Не удалось reload systemd"; }
sudo systemctl start code-server@root || { ERR "Не удалось стартовать code-server@root. Проверьте /var/log/syslog или journalctl -u code-server@root."; }
sudo systemctl enable code-server@root || WARN "Не удалось включить автозапуск. Возможно уже включён."

# --- Шаг 7: Уведомление пользователю ---
IP_ADDRESS=$(hostname -I | awk '{print $1}' || true)
if [ -z "$IP_ADDRESS" ]; then
  echo ""
  echo "Установка завершена. Порт: $USER_PORT"
  echo "Файл конфигурации: $CFG_FILE"
  echo "Сервис работает: systemctl status code-server@root"
else
  echo ""
  echo "Установка завершена! Доступно по адресу:"
  echo "------------------------------------------------------"
  echo " http://$IP_ADDRESS:$USER_PORT "
  echo "------------------------------------------------------"
  echo "Пароль — тот, который вы ввели."
  echo "Файл конфигурации: $CFG_FILE"
  echo "Каталог установки (WorkingDirectory): $INSTALL_ROOT"
fi

LOG "Готово."
