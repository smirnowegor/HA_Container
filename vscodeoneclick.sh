#!/bin/bash
set -e

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    ERR "Запусти скрипт от root или через sudo."
fi

echo "=== Установка code-server на большой раздел ==="

# --- Запрос пароля ---
read -s -p "Введите пароль для входа в code-server: " USER_PASSWORD; echo ""
read -s -p "Повторите пароль: " USER_PASSWORD_CONFIRM; echo ""
while [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; do
    echo "Пароли не совпадают. Попробуйте снова."
    read -s -p "Введите пароль: " USER_PASSWORD; echo ""
    read -s -p "Повторите пароль: " USER_PASSWORD_CONFIRM; echo ""
done
[ -n "$USER_PASSWORD" ] || ERR "Пароль не может быть пустым."

# --- Запрос порта ---
read -p "Введите порт для code-server (по умолчанию 8080): " USER_PORT
USER_PORT=${USER_PORT:-8080}

# --- Выбор раздела ---
mapfile -t raw_opts < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%0.1fG free)\n", $6, $4/1073741824}' | sort -k2 -hr)
if [ ${#raw_opts[@]} -eq 0 ]; then
    ERR "Нет разделов с >1ГБ свободного места."
fi
if [ ${#raw_opts[@]} -eq 1 ]; then
    MOUNT_POINT=$(echo "${raw_opts[0]}" | sed -E 's/ \([0-9.]+G free\)//')
else
    echo "Выберите раздел для установки:"
    for i in "${!raw_opts[@]}"; do
        echo " $((i+1))) ${raw_opts[i]}"
    done
    read -rp "Номер: " CHOICE
    MOUNT_POINT=$(echo "${raw_opts[$((CHOICE-1))]}" | sed -E 's/ \([0-9.]+G free\)//')
fi

INSTALL_DIR="${MOUNT_POINT%/}/code-server"
LOG "Установка в: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# --- Скачивание code-server ---
ARCH=$(uname -m)
case "$ARCH" in
    armv7l)   PLATFORM="linux-armv7l" ;;
    aarch64)  PLATFORM="linux-arm64" ;;
    x86_64)   PLATFORM="linux-amd64" ;;
    *) ERR "Неизвестная архитектура: $ARCH" ;;
esac
URL=$(curl -s https://api.github.com/repos/coder/code-server/releases/latest \
    | grep "browser_download_url" \
    | grep "$PLATFORM" \
    | cut -d '"' -f 4)
curl -fsSL "$URL" | tar -xz --strip-components=1 -C "$INSTALL_DIR"

# --- Симлинк ---
ln -sf "$INSTALL_DIR/bin/code-server" /usr/local/bin/code-server

# --- Конфиг ---
mkdir -p "$INSTALL_DIR/config"
cat > "$INSTALL_DIR/config/config.yaml" <<EOF
bind-addr: 0.0.0.0:${USER_PORT}
auth: password
password: ${USER_PASSWORD}
cert: false
EOF

# --- systemd ---
cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/code-server --config $INSTALL_DIR/config/config.yaml
Restart=always
Environment=HOME=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now code-server

# --- Финальное сообщение ---
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo ""
echo "=============================================="
echo " Code-Server установлен!"
echo " Адрес: http://${IP_ADDRESS}:${USER_PORT}"
echo " Пароль: ${USER_PASSWORD}"
echo " Конфиг: $INSTALL_DIR/config/config.yaml"
echo "=============================================="
