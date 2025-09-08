#!/bin/bash
set -euo pipefail

# vscodeoneclick_fixed_v2.sh
# Исправления и защита от "Too many levels of symbolic links"
# - аккуратная обработка /root/.config/code-server (не создаём self-symlink)
# - если обнаружен битый/самоссылочный симлинк — он бэкапится/удаляется и создаётся реальная папка
# - безопасное создание директорий с учётом симлинков
# - перенос старой установки (rsync + бэкап)
# - спиннер для долгих операций

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

SPINNER_PID=""
spinner_start() {
  local msg="${1:-Working...}"
  printf "%s " "$msg"
  ( while :; do for c in '\\' '/' '-' '\\'; do printf "\b%s" "$c"; sleep 0.12; done; done ) &
  SPINNER_PID=$!
  trap 'spinner_stop 130; exit 130' INT TERM
}
spinner_stop() {
  local rc=${1:-0}
  if [ -n "$SPINNER_PID" ] && ps -p "$SPINNER_PID" > /dev/null 2>&1; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf "\b"
  if [ "$rc" -eq 0 ]; then
    echo -e " \e[1;32mOK\e[0m"
  else
    echo -e " \e[1;31mFAIL (rc=$rc)\e[0m"
  fi
  trap - INT TERM
  return $rc
}
run_with_spinner() {
  local msg="$1"; shift
  local cmd="$*"
  spinner_start "$msg"
  bash -c "$cmd"
  local rc=$?
  spinner_stop $rc
  return $rc
}

# Ввод
echo "Привет! Обновим/установим code-server."
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
[ -n "$USER_PASSWORD" ] || ERR "Ошибка: Пароль не может быть пустым."
read -p "Пожалуйста, введи ПОРТ для Code-Server (по умолчанию 9091): " USER_PORT
USER_PORT=${USER_PORT:-9091}

LOG "Начинаем процесс..."

# --- выбор места ---
LOG "Выбор места установки конфигурации code-server."
mapfile -t _options < <(
  df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%.2fG free)\n", $6, $4/1073741824}' | sort -k2 -hr
)
if df -B1 /root >/dev/null 2>&1; then
  ROOT_DF_LINE=$(df -B1 /root 2>/dev/null | awk 'NR==2{print $6, $4}')
else
  ROOT_DF_LINE=$(df -B1 / 2>/dev/null | awk 'NR==2{print $6, $4}')
fi
if [ -n "${ROOT_DF_LINE:-}" ]; then
  ROOT_FREE_BYTES=$(echo "$ROOT_DF_LINE" | awk '{print $2}')
  ROOT_FREE_GB=$(awk "BEGIN{printf \"%.2f\", ${ROOT_FREE_BYTES}/1073741824}")
  _options+=("/root (${ROOT_FREE_GB}G free) (по умолчанию)")
else
  _options+=("/root (по умолчанию)")
fi
if [ ${#_options[@]} -eq 0 ]; then
  WARN "Не нашёл подходящих разделов. Использую /root."
  INSTALL_ROOT="/root"
else
  echo "Выберите базовый каталог для установки конфигурации code-server:"
  PS3="Введите номер и нажмите Enter: "
  select opt in "${_options[@]}"; do
    if [[ -n "$opt" ]]; then
      CHOSEN_PATH=$(echo "$opt" | awk '{print $1}')
      if [[ "$CHOSEN_PATH" == "/root" ]]; then
        INSTALL_ROOT="/root"
      else
        INSTALL_ROOT="${CHOSEN_PATH}/code-server"
      fi
      break
    else
      echo "Неверный выбор. Попробуйте снова."
    fi
  done
fi
LOG "Выбран каталог установки: $INSTALL_ROOT"

# --- пути ---
ROOT_CONFIG_DIR="/root/.config"
ROOT_CS_DIR="$ROOT_CONFIG_DIR/code-server"
TARGET_CFG="${INSTALL_ROOT}/.config/code-server"

# --- вспомогательные функции ---
# безопасно создать реальную директорию (удаляет самоссылки, делает бэкап, если нужно)
ensure_real_dir() {
  local path="$1"
  if [ -L "$path" ]; then
    # симлинк — выясним, куда он ведёт
    target=$(readlink -f "$path" 2>/dev/null || true)
    if [ -z "$target" ]; then
      WARN "Найден битый/петлящий симлинк: $path — удаляю его и создаю реальную директорию"
      sudo rm -f "$path"
    else
      # если симлинк указывает на сам себя или эквивалентный путь
      if [ "$(readlink -f "$path" 2>/dev/null)" = "$(readlink -f "$path" 2>/dev/null)" ]; then
        # не пытаемся делать странные проверки — если текущий симлинк ведёт в петлю, просто удалим
        sudo rm -f "$path" || true
      fi
      # если симлинк указывал на другое место — делаем бэкап этого места, затем удаляем симлинк
      if [ -n "$target" ] && [ "$target" != "$path" ]; then
        TS=$(date +%Y%m%d%H%M%S)
        BACKUP="/root/backup_symlink_target_${TS}.tar.gz"
        LOG "Симлинк $path указывал на $target — делаю бэкап целевого каталога в $BACKUP"
        sudo tar -C "$(dirname "$target")" -czf "$BACKUP" "$(basename "$target")" || true
        sudo rm -f "$path" || true
      fi
    fi
  fi
  # если теперь существует реальный файл/директория — ничего не делаем
  if [ -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  # создаём реальную директорию
  sudo mkdir -p "$path"
  sudo chown root:root "$path"
  sudo chmod 0755 "$path"
}

# безопасно создать целевую директорию (для TARGET_CFG), но учитывать что TARGET_CFG может быть /root/.config/code-server
safe_create_target() {
  local target="$1"
  # если target — в /root и INSTALL_ROOT == /root, хотим реальную директорию
  ensure_real_dir "$target"
}

# поиск существующих конфигураций
find_existing_configs() {
  local -a arr=()
  local -a candidates=( "/root/.config/code-server" "/opt/code-server" "/var/lib/code-server" "/etc/code-server" )
  for p in "${candidates[@]}"; do
    if [ -e "$p" ]; then
      real=$(readlink -f "$p" 2>/dev/null || true)
      [ -n "$real" ] && arr+=("$real")
    fi
  done
  for h in /home/*; do
    cfg="$h/.config/code-server"
    if [ -d "$cfg" ]; then
      real=$(readlink -f "$cfg" 2>/dev/null || true)
      [ -n "$real" ] && arr+=("$real")
    fi
  done
  printf "%s\n" "${arr[@]}" | grep -v '^$' | sort -u
}

backup_path() {
  local src="$1"
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  local base
  base=$(basename "$src" 2>/dev/null || true)
  [ -n "$base" ] || base="code-server"
  echo "/root/backup_${base}_${ts}.tar.gz"
}

migrate_existing() {
  local src="$1" dst_root="$2"
  [ -n "$src" ] || { WARN "пустой src"; return 1; }
  local dst_cfg="${dst_root}/.config/code-server"
  LOG "Найдена существующая установка: $src"
  local backup
  backup=$(backup_path "$src")
  LOG "Создаю резервную копию $src -> $backup"
  local src_dir=$(dirname "$src")
  local src_base=$(basename "$src")
  [ -n "$src_base" ] || src_base="code-server"
  run_with_spinner "Архивирую $src" "sudo tar -C '$src_dir' -czf '$backup' '$src_base'"
  if [ $? -ne 0 ]; then
    ERR "Не удалось создать резервную копию $src в $backup. Операция прервана."
  fi
  LOG "Перенос содержимого $src -> $dst_cfg (rsync)..."
  sudo mkdir -p "$dst_cfg"
  run_with_spinner "Копирую данные (rsync)" "sudo rsync -a --delete -- '$src/' '$dst_cfg/'"
  if [ $? -ne 0 ]; then
    WARN "rsync вернул ошибку. Оставляю резервную копию и не удаляю старые файлы."
    return 1
  fi
  if [ "$(sudo find "$dst_cfg" -mindepth 1 2>/dev/null | wc -l)" -eq 0 ]; then
    WARN "После rsync папка назначения пуста — откат."
    return 1
  fi
  LOG "Удаляю старый каталог $src"
  run_with_spinner "Удаляю старый каталог" "sudo rm -rf '$src'"
  return 0
}

# --- перед созданием директорий: аккуратно обработаем /root/.config/code-server, чтобы не получить петлю ---
# если ранее был создан самоссылочный симлинк, то ensure_real_dir его уберёт
if [ "$INSTALL_ROOT" = "/root" ]; then
  LOG "INSTALL_ROOT == /root -> обеспечиваем реальный каталог: $ROOT_CS_DIR"
  ensure_real_dir "$ROOT_CS_DIR"
else
  # цель вне /root — убедимся, что целевая папка существует
  safe_create_target "$TARGET_CFG"
fi

# --- теперь найдём и переместим старые установки (если есть) ---
mapfile -t EXISTING < <(find_existing_configs)
if [ ${#EXISTING[@]} -gt 0 ]; then
  LOG "Найдены существующие установки code-server:"
  for e in "${EXISTING[@]}"; do
    src_norm=$(readlink -f "$e" 2>/dev/null || true)
    dst_norm=$(readlink -f "$TARGET_CFG" 2>/dev/null || true)
    [ -n "$src_norm" ] || { WARN "пустой путь"; continue; }
    if [ -n "$dst_norm" ] && [ "$src_norm" = "$dst_norm" ]; then
      LOG " - $src_norm (уже в выбранном месте) — пропускаю"
      continue
    fi
    migrate_existing "$src_norm" "$INSTALL_ROOT" || WARN "Перенос $src_norm завершился с проблемой"
  done
else
  LOG "Существующие установки не найдены."
fi

# --- после миграции: если INSTALL_ROOT != /root создаём/обновляем симлинк /root/.config/code-server -> TARGET_CFG ---
if [ "$INSTALL_ROOT" != "/root" ]; then
  # если в /root/.config/code-server есть реальная директория — бекапим её и удаляем
  if [ -e "$ROOT_CS_DIR" ] && [ ! -L "$ROOT_CS_DIR" ]; then
    if [ "$(readlink -f "$ROOT_CS_DIR" 2>/dev/null)" != "$(readlink -f "$TARGET_CFG" 2>/dev/null)" ]; then
      TS=$(date +%Y%m%d%H%M%S)
      BACKUP="/root/.config_code-server_backup_${TS}.tar.gz"
      LOG "Резервный бэкап существующей /root/.config/code-server в $BACKUP"
      sudo tar -czf "$BACKUP" -C /root/.config code-server || true
      LOG "Удаляю старую /root/.config/code-server"
      sudo rm -rf "$ROOT_CS_DIR" || true
    fi
  fi
  # удалим старую симлинку, если есть
  if [ -L "$ROOT_CS_DIR" ]; then
    sudo rm -f "$ROOT_CS_DIR"
  fi
  LOG "Создаю символьную ссылку: $ROOT_CS_DIR -> ${TARGET_CFG}"
  sudo ln -sfn "${TARGET_CFG}" "$ROOT_CS_DIR"
  sudo chown -h root:root "$ROOT_CS_DIR" || true
else
  LOG "/root/.config/code-server оставляем реальной директорией (INSTALL_ROOT == /root)"
fi

# --- systemd + установка code-server ---
if sudo systemctl is-active --quiet code-server@root 2>/dev/null; then
  run_with_spinner "Останавливаю старый сервис" "sudo systemctl stop code-server@root || true"
fi
if sudo systemctl is-enabled --quiet code-server@root 2>/dev/null; then
  run_with_spinner "Отключаю автозапуск" "sudo systemctl disable code-server@root || true; sudo systemctl daemon-reload || true"
fi
if [ -f "/etc/systemd/system/code-server@.service" ]; then
  LOG "Удаляю старый systemd unit"
  sudo rm -f /etc/systemd/system/code-server@.service
  sudo systemctl daemon-reload || true
fi

LOG "Устанавливаю code-server (официальный install.sh)..."
run_with_spinner "Устанавливаю code-server (curl|sh)" "curl -fsSL https://code-server.dev/install.sh | sh"

LOG "Создаю systemd unit (WorkingDirectory: $INSTALL_ROOT)"
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

run_with_spinner "daemon-reload" "sudo systemctl daemon-reload || true"
run_with_spinner "Запуск code-server для первичной генерации файлов" "sudo systemctl start code-server@root || true"
sleep 2
run_with_spinner "Остановка тестового запуска" "sudo systemctl stop code-server@root || true"

# --- создаём конфиг в целевом месте ---
CFG_FILE="${TARGET_CFG}/config.yaml"
LOG "Создаю конфиг $CFG_FILE"
# создаём родительские директории безопасно
sudo mkdir -p "$(dirname "$CFG_FILE")"
sudo tee "$CFG_FILE" > /dev/null <<EOC
bind-addr: 0.0.0.0:${USER_PORT}
auth: password
password: ${USER_PASSWORD}
cert: false
EOC
sudo chown root:root "$CFG_FILE"
sudo chmod 0600 "$CFG_FILE"

run_with_spinner "daemon-reload" "sudo systemctl daemon-reload || true"
run_with_spinner "Старт service code-server@root" "sudo systemctl start code-server@root"
run_with_spinner "Включение автозапуска" "sudo systemctl enable code-server@root || true"

IP_ADDRESS=$(hostname -I | awk '{print $1}' || true)
echo ""
if [ -z "$IP_ADDRESS" ]; then
  echo "Установка завершена. Порт: $USER_PORT"
  echo "Файл конфигурации: $CFG_FILE"
  echo "Каталог установки (WorkingDirectory): $INSTALL_ROOT"
  echo "Проверьте статус: sudo systemctl status code-server@root"
else
  echo "Установка завершена! Доступно по адресу:"
  echo "------------------------------------------------------"
  echo " http://$IP_ADDRESS:$USER_PORT "
  echo "------------------------------------------------------"
  echo "Пароль — тот, который вы ввели."
  echo "Файл конфигурации: $CFG_FILE"
  echo "Каталог установки (WorkingDirectory): $INSTALL_ROOT"
fi
LOG "Готово."
