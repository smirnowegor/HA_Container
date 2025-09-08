#!/bin/bash
set -euo pipefail

# vscodeoneclick_fixed_v3.sh
# Надёжная установка code-server с выбором тома, переносом данных, спиннером,
# проверкой места и исправлением ошибки создания симлинка /root/.config/code-server.

LOG(){ echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR(){ echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# ---------------- spinner ----------------
SPINNER_PID=""
spinner_start(){ local msg="${1:-Working...}"; printf "%s " "$msg"; ( while :; do for c in '\|' '/' '-' '\\' ; do printf "\b%s" "$c"; sleep 0.12; done; done ) & SPINNER_PID=$!; trap 'spinner_stop 130; exit 130' INT TERM; }
spinner_stop(){ local rc=${1:-0}; if [ -n "$SPINNER_PID" ] && ps -p "$SPINNER_PID" >/dev/null 2>&1; then kill "$SPINNER_PID" >/dev/null 2>&1 || true; wait "$SPINNER_PID" 2>/dev/null || true; SPINNER_PID=""; fi; printf "\b"; if [ "$rc" -eq 0 ]; then echo -e " \e[1;32mOK\e[0m"; else echo -e " \e[1;31mFAIL (rc=$rc)\e[0m"; fi; trap - INT TERM; return $rc; }
run_with_spinner(){ local msg="$1"; shift; spinner_start "$msg"; bash -c "$*"; local rc=$?; spinner_stop $rc; return $rc; }

# ---------------- input ----------------
echo "Привет! Обновим/установим code-server."

read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD; echo ""
read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM; echo ""
while [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; do
  echo "Пароли не совпадают. Попробуй снова."
  read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD; echo ""
  read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM; echo ""
done
[ -n "$USER_PASSWORD" ] || ERR "Ошибка: Пароль не может быть пустым."

read -p "Пожалуйста, введи ПОРТ для Code-Server (по умолчанию 9091): " USER_PORT
USER_PORT=${USER_PORT:-9091}

LOG "Начинаем процесс..."

# ---------------- mounts/options ----------------
mapfile -t _options < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%.2fG free)\n", $6, $4/1073741824}' | sort -k2 -hr)
if df -B1 /root >/dev/null 2>&1; then ROOT_DF_LINE=$(df -B1 /root 2>/dev/null | awk 'NR==2{print $6, $4}'); else ROOT_DF_LINE=$(df -B1 / 2>/dev/null | awk 'NR==2{print $6, $4}'); fi
if [ -n "${ROOT_DF_LINE:-}" ]; then
  ROOT_FREE_BYTES=$(echo "$ROOT_DF_LINE" | awk '{print $2}')
  ROOT_FREE_GB=$(awk "BEGIN{printf \"%.2f\", ${ROOT_FREE_BYTES}/1073741824}")
  _options+=("/root (${ROOT_FREE_GB}G free) (по умолчанию)")
else
  _options+=("/root (по умолчанию)")
fi

echo "Выберите базовый каталог для установки конфигурации code-server:"
PS3="Введите номер и нажмите Enter: "
select opt in "${_options[@]}"; do
  if [[ -n "$opt" ]]; then
    CHOSEN_PATH=$(echo "$opt" | awk '{print $1}')
    if [[ "$CHOSEN_PATH" == "/root" ]]; then INSTALL_ROOT="/root"; else INSTALL_ROOT="${CHOSEN_PATH}/code-server"; fi
    break
  else
    echo "Неверный выбор. Попробуйте снова."
  fi
done

LOG "Выбран каталог установки: $INSTALL_ROOT"

# ---------------- helpers ----------------
free_bytes_on_path(){ df -B1 "$1" 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }
MIN_REQUIRED_BYTES=$((500 * 1024 * 1024))   # 500MB

check_and_prepare_space(){
  LOG "Проверяю свободное место на корне и на выбранном томе..."
  root_free=$(free_bytes_on_path /)
  install_free=$(free_bytes_on_path "${INSTALL_ROOT:-/}")
  LOG "Свободно на / : $(awk "BEGIN{printf \"%.2fG\", $root_free/1073741824}")"
  LOG "Свободно на выбранном томе: $(awk "BEGIN{printf \"%.2fG\", $install_free/1073741824}")"
  if [ "$root_free" -ge "$MIN_REQUIRED_BYTES" ]; then
    LOG "Достаточно места на корне."
    return 0
  fi
  LOG "Места на корне мало (<500MB). Попробую очистить /root/.cache/code-server"
  if [ -d "/root/.cache/code-server" ]; then run_with_spinner "Очистка /root/.cache/code-server" "sudo rm -rf /root/.cache/code-server/* || true"; fi
  root_free=$(free_bytes_on_path /)
  LOG "После очистки на / : $(awk "BEGIN{printf \"%.2fG\", $root_free/1073741824}")"
  if [ "$root_free" -ge "$MIN_REQUIRED_BYTES" ]; then LOG "Достаточно места после очистки."; return 0; fi

  # fallback: выбрать монт с местом >= MIN_REQUIRED_BYTES
  mapfile -t MOUNTS < <(df -B1 | awk 'NR>1 {print $6" "$4}' | sort -k2 -nr)
  for line in "${MOUNTS[@]}"; do
    mnt=$(echo "$line" | awk '{print $1}')
    freeb=$(echo "$line" | awk '{print $2}')
    if [ "$freeb" -ge "$MIN_REQUIRED_BYTES" ] && [ "$mnt" != "/" ]; then
      LOG "Найден альтернативный том с местом: $mnt ($(awk "BEGIN{printf \"%.2fG\", $freeb/1073741824}"))"
      INSTALL_ROOT="${mnt}/code-server"
      LOG "Переключаю INSTALL_ROOT -> $INSTALL_ROOT"
      return 0
    fi
  done
  ERR "Недостаточно места на корне и нет другого тома с >=500MB. Освободите место или подключите диск."
}

# ensure parent real dir (удалит битые link'и, сделает бэкап target если нужно)
ensure_real_dir(){
  local path="$1"
  # make parent dir exist always
  parent="$(dirname "$path")"
  sudo mkdir -p "$parent"
  sudo chown root:root "$parent"
  sudo chmod 0755 "$parent"
  if [ -L "$path" ]; then
    target=$(readlink -f "$path" 2>/dev/null || true)
    if [ -n "$target" ] && [ "$target" != "$path" ]; then
      TS=$(date +%Y%m%d%H%M%S); BACKUP="/root/backup_symlink_target_${TS}.tar.gz"
      LOG "Симлинк $path указывал на $target — бэкап цели -> $BACKUP"
      sudo tar -C "$(dirname "$target")" -czf "$BACKUP" "$(basename "$target")" || true
    fi
    sudo rm -f "$path" || true
  fi
  if [ ! -d "$path" ]; then
    sudo mkdir -p "$path"
    sudo chown root:root "$path"
    sudo chmod 0755 "$path"
  fi
}

# ---------------- prepare space and targets ----------------
check_and_prepare_space

ROOT_CONFIG_DIR="/root/.config"
ROOT_CS_DIR="${ROOT_CONFIG_DIR}/code-server"
TARGET_CFG="${INSTALL_ROOT}/.config/code-server"

# Ensure parent /root/.config exists before any ln or mkdir under it
sudo mkdir -p "$ROOT_CONFIG_DIR"
sudo chown root:root "$ROOT_CONFIG_DIR"
sudo chmod 0755 "$ROOT_CONFIG_DIR"

if [ "$INSTALL_ROOT" = "/root" ]; then
  LOG "INSTALL_ROOT == /root -> обеспечиваем реальный каталог: $ROOT_CS_DIR"
  ensure_real_dir "$ROOT_CS_DIR"
else
  # create target parents on chosen mount
  sudo mkdir -p "${TARGET_CFG}"
  sudo chown root:root "${TARGET_CFG}"
  sudo chmod 0755 "${TARGET_CFG}"

  # if existing real dir in /root -> backup+remove
  if [ -e "$ROOT_CS_DIR" ] && [ ! -L "$ROOT_CS_DIR" ]; then
    if [ "$(readlink -f "$ROOT_CS_DIR" 2>/dev/null)" != "$(readlink -f "$TARGET_CFG" 2>/dev/null)" ]; then
      TS=$(date +%Y%m%d%H%M%S); BACKUP="/root/.config_code-server_backup_${TS}.tar.gz"
      LOG "Резервный бэкап существующей /root/.config/code-server -> $BACKUP"
      sudo tar -czf "$BACKUP" -C "$ROOT_CONFIG_DIR" code-server || true
      LOG "Удаляю старую /root/.config/code-server"
      sudo rm -rf "$ROOT_CS_DIR" || true
    fi
  fi

  # Ensure parent exists (already ensured), remove any existing symlink and create new one
  if [ -L "$ROOT_CS_DIR" ]; then sudo rm -f "$ROOT_CS_DIR"; fi
  LOG "Создаю символьную ссылку: $ROOT_CS_DIR -> ${TARGET_CFG}"
  sudo ln -sfn "${TARGET_CFG}" "$ROOT_CS_DIR"
  sudo chown -h root:root "$ROOT_CS_DIR" || true
fi

# ---------------- find & migrate (simple) ----------------
find_existing_configs(){
  local -a arr=()
  for p in "/opt/code-server" "/var/lib/code-server" "/etc/code-server"; do [ -e "$p" ] && arr+=("$(readlink -f "$p")"); done
  for h in /home/*; do cfg="$h/.config/code-server"; [ -d "$cfg" ] && arr+=("$(readlink -f "$cfg")"); done
  if [ -d "/root/.config/code-server" ] && [ ! -L "/root/.config/code-server" ]; then arr+=("$(readlink -f /root/.config/code-server)"); fi
  printf "%s\n" "${arr[@]}" | sort -u
}

migrate_existing(){
  local src="$1"; local dst_root="$2"
  [ -n "$src" ] || return 1
  local dst_cfg="${dst_root}/.config/code-server"
  LOG "Найдена существующая установка: $src"
  TS=$(date +%Y%m%d%H%M%S); BACKUP="/root/backup_$(basename "$src")_${TS}.tar.gz"
  run_with_spinner "Архивирую $src" "sudo tar -C '$(dirname "$src")' -czf '$BACKUP' '$(basename "$src")'"
  run_with_spinner "Копирую данные (rsync)" "sudo mkdir -p '$dst_cfg' && sudo rsync -a --delete -- '$src/' '$dst_cfg/'"
  if [ "$(sudo find "$dst_cfg" -mindepth 1 2>/dev/null | wc -l)" -gt 0 ]; then
    run_with_spinner "Удаляю старый каталог" "sudo rm -rf '$src'"
    LOG "Перенос выполнен, резерв: $BACKUP"
  else
    WARN "Перенос завершён, но целевая папка пуста. Смотрите резерв $BACKUP"
  fi
}

mapfile -t EXISTING < <(find_existing_configs)
if [ ${#EXISTING[@]} -gt 0 ]; then
  LOG "Найдены существующие установки:"
  for e in "${EXISTING[@]}"; do
    dst_norm=$(readlink -f "${TARGET_CFG}" 2>/dev/null || true)
    src_norm=$(readlink -f "$e" 2>/dev/null || true)
    if [ -n "$src_norm" ] && [ "$src_norm" != "$dst_norm" ]; then
      migrate_existing "$src_norm" "$INSTALL_ROOT" || WARN "Проблема при переносе $src_norm"
    else
      LOG " - $src_norm (уже в выбранном месте) — пропускаю"
    fi
  done
else
  LOG "Существующие установки не найдены."
fi

# ---------------- systemd / install ----------------
LOG "Останавливаю старый сервис (если есть)..."
if sudo systemctl is-active --quiet code-server@root 2>/dev/null; then run_with_spinner "Останавливаю старый сервис" "sudo systemctl stop code-server@root || true"; fi
if sudo systemctl is-enabled --quiet code-server@root 2>/dev/null; then run_with_spinner "Отключаю автозапуск" "sudo systemctl disable code-server@root || true; sudo systemctl daemon-reload || true"; fi
if [ -f "/etc/systemd/system/code-server@.service" ]; then LOG "Удаляю старый systemd unit"; sudo rm -f /etc/systemd/system/code-server@.service; sudo systemctl daemon-reload || true; fi

# Final check before running install.sh: warn if root low on space (install may still fail)
root_free=$(free_bytes_on_path /)
if [ "$root_free" -lt "$MIN_REQUIRED_BYTES" ]; then
  WARN "Мало свободного места на корневом разделе (<500MB). dpkg может упасть. Рассмотрите установку бинарной версии в /opt на большом разделе."
fi

LOG "Устанавливаю code-server (официальный install.sh)..."
run_with_spinner "Устанавливаю code-server (curl|sh)" "curl -fsSL https://code-server.dev/install.sh | sh"

# write systemd unit using chosen WorkingDirectory
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
sleep 1

# create config
CFG_FILE="${TARGET_CFG}/config.yaml"
LOG "Создаю конфиг $CFG_FILE"
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
# Удалить только .deb файлы (консервативно):
run_with_spinner "Удаляю скачанные .deb из кеша code-server" "sudo rm -f /root/.cache/code-server/*.deb || true"

LOG "Готово."
