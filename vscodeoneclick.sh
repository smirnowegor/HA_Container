#!/bin/bash

# --- 1. Выясняем требования ---
echo "Привет! Мы сейчас обновим установку Code-Server."
echo "Сначала мы проверим и удалим предыдущие версии, а затем установим новую."
echo ""

# Запрашиваем у пользователя пароль
read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD
echo ""
read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM
echo ""

# Проверяем, совпадают ли пароли
while [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; do
    echo "Пароли не совпадают. Пожалуйста, попробуй снова."
    read -s -p "Пожалуйста, введи ПАРОЛЬ для доступа к Code-Server: " USER_PASSWORD
    echo ""
    read -s -p "Пожалуйста, повтори ПАРОЛЬ: " USER_PASSWORD_CONFIRM
    echo ""
done

if [ -z "$USER_PASSWORD" ]; then
    echo "Ошибка: Пароль не может быть пустым. Пожалуйста, запустите скрипт снова и введите пароль."
    exit 1
fi

# НОВОЕ: Запрашиваем у пользователя порт
read -p "Пожалуйста, введи ПОРТ для Code-Server (по умолчанию 9091): " USER_PORT
# Если пользователь ничего не ввел, используем 9091
USER_PORT=${USER_PORT:-9091}

echo "Начинаем процесс..."
echo ""

# --- 2. Проверка и удаление старых установок ---
echo "Шаг 1/6: Проверка и удаление предыдущих установок Code-Server..."

# Останавливаем и отключаем сервис systemd, если он существует
if sudo systemctl is-active --quiet code-server@root; then
    echo "Останавливаем сервис code-server@root..."
    sudo systemctl stop code-server@root
fi

if sudo systemctl is-enabled --quiet code-server@root; then
    echo "Отключаем автозапуск code-server@root..."
    sudo systemctl disable code-server@root
    # НОВОЕ: Перезагружаем systemd, чтобы он забыл о сервисе, если он был включен
    sudo systemctl daemon-reload
    echo "Автозапуск code-server@root отключен и systemd перезагружен."
fi

# Удаляем файл сервиса systemd
if [ -f "/etc/systemd/system/code-server@.service" ]; then
    echo "Удаляем файл сервиса systemd..."
    sudo rm /etc/systemd/system/code-server@.service
    sudo systemctl daemon-reload # Перезагружаем systemd, чтобы он забыл о старом сервисе
    echo "Файл сервиса systemd удален и systemd перезагружен."
fi

# НОВОЕ: Удаляем файл конфигурации Code-Server (ГАРАНТИРУЕМ УДАЛЕНИЕ ПАРОЛЯ)
CONFIG_FILE="/root/.config/code-server/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    echo "Удаляем старый файл конфигурации Code-Server ($CONFIG_FILE)..."
    sudo rm "$CONFIG_FILE"
    echo "Файл конфигурации удален."
fi

# Удаляем каталог конфигурации Code-Server
CONFIG_DIR="/root/.config/code-server"
if [ -d "$CONFIG_DIR" ]; then
    echo "Удаляем каталог конфигурации Code-Server ($CONFIG_DIR)..."
    sudo rm -rf "$CONFIG_DIR"
    echo "Каталог конфигурации удален."
fi

# Удаляем исполняемый файл Code-Server, если он в ~/.local/bin
CODE_SERVER_BIN="$HOME/.local/bin/code-server"
if [ -f "$CODE_SERVER_BIN" ]; then
    echo "Удаляем исполняемый файл Code-Server ($CODE_SERVER_BIN)..."
    rm "$CODE_SERVER_BIN"
    echo "Исполняемый файл Code-Server удален."
fi

echo "Предыдущие установки Code-Server удалены (если они были)."
echo ""

# --- 3. Установка Code-Server ---
# Используем официальный скрипт установки
echo "Шаг 2/6: Установка Code-Server..."
curl -fsSL https://code-server.dev/install.sh | sh || { echo "Ошибка: Не удалось установить Code-Server. Проверьте подключение к интернету или права доступа."; exit 1; }
echo "Code-Server успешно установлен."
echo ""

# --- 4. Настройка автозапуска через systemd ---
echo "Шаг 3/6: Настройка автозапуска Code-Server через systemd..."
sudo tee /etc/systemd/system/code-server@.service > /dev/null << 'EOF'
[Unit]
Description=code-server for %i
After=network.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/root
ExecStart=/usr/bin/code-server # Убедись, что это правильный путь к исполняемому файлу code-server
Restart=always

[Install]
WantedBy=multi-user.target
EOF
echo "Файл сервиса systemd создан."
echo ""

# --- 5. Настройка Code-Server (установка пароля и порта) ---
echo "Шаг 4/6: Настройка Code-Server (установка пароля и порта)..."

# Запускаем Code-Server один раз для создания конфигурационных файлов
echo "Запускаем Code-Server временно, чтобы он создал конфигурационные файлы..."
# НОВОЕ: Добавим `|| true` на случай, если code-server не запустится с первого раза
sudo systemctl start code-server@root || true

# Даем Code-Server время на создание файлов
echo "Ждем несколько секунд, пока Code-Server создаст файлы..."
sleep 5

# Останавливаем службу Code-Server
echo "Останавливаем службу Code-Server для редактирования конфигурации..."
sudo systemctl stop code-server@root || true # НОВОЕ: || true, чтобы скрипт не падал, если сервис уже не активен
sleep 2

# Проверяем существование каталога и создаем его, если он не существует
CONFIG_DIR="/root/.config/code-server"
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Каталог конфигурации $CONFIG_DIR не найден, создаем его..."
    sudo mkdir -p "$CONFIG_DIR" || { echo "Ошибка: Не удалось создать каталог конфигурации $CONFIG_DIR. Проверьте права доступа."; exit 1; }
    sudo chown root:root "$CONFIG_DIR" # Убедимся, что владельцем является root
fi

CONFIG_FILE="/root/.config/code-server/config.yaml"

# Создаем файл config.yaml, если он не существует.
# Это уже не так критично, так как мы его удаляем в начале,
# но хорошая практика на случай, если удаление не сработало по какой-то причине.
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Файл конфигурации $CONFIG_FILE не найден, создаем его..."
    sudo touch "$CONFIG_FILE" || { echo "Ошибка: Не удалось создать файл конфигурации $CONFIG_FILE. Проверьте права доступа."; exit 1; }
    sudo chown root:root "$CONFIG_FILE" # Убедимся, что владельцем является root
fi

echo "Редактируем файл конфигурации $CONFIG_FILE..."

# ИСПРАВЛЕНИЕ: Используем переменные $USER_PORT и $USER_PASSWORD
# Используем sudo sh -c для записи в файл от имени root
sudo sh -c "echo 'bind-addr: 0.0.0.0:$USER_PORT' > $CONFIG_FILE"
sudo sh -c "echo 'auth: password' >> $CONFIG_FILE"
sudo sh -c "echo 'password: $USER_PASSWORD' >> $CONFIG_FILE" # ВОТ ЗДЕСЬ ИСПРАВЛЕНИЕ ПАРОЛЯ
sudo sh -c "echo 'cert: false' >> $CONFIG_FILE"

echo "Файл конфигурации обновлен."
echo ""

# --- 6. Активация и запуск сервиса Code-Server ---
echo "Шаг 5/6: Активация и запуск сервиса Code-Server..."
sudo systemctl daemon-reload || { echo "Ошибка: Не удалось перезагрузить systemd daemon. Проверьте конфигурацию systemd."; exit 1; }
sudo systemctl start code-server@root || { echo "Ошибка: Не удалось запустить service code-server@root. Проверьте логи systemd."; exit 1; }
sudo systemctl enable code-server@root || { echo "Ошибка: Не удалось включить автозапуск code-server@root. Возможно, сервис уже включен."; }
echo "Сервис Code-Server запущен и включен для автозапуска."
echo ""

# --- 7. Проверка доступа к Code-Server ---
echo "Шаг 6/6: Проверка доступа к Code-Server..."

# Получаем IP-адрес сервера
IP_ADDRESS=$(hostname -I | awk '{print $1}')

if [ -z "$IP_ADDRESS" ]; then
    echo "Не удалось автоматически определить IP-адрес. Пожалуйста, найдите его вручную (например, с помощью команды ip a или ifconfig)."
    echo "Порт для доступа: $USER_PORT"
    echo "Формат ссылки: http://<ВАШ_IP_АДРЕС>:$USER_PORT"
else
    echo "Установка завершена! Code-Server должен быть доступен по следующей ссылке:"
    echo "------------------------------------------------------"
    echo "                   http://$IP_ADDRESS:$USER_PORT            "
    echo "------------------------------------------------------"
    echo "Используй введенный тобой пароль для входа."
fi

echo ""
echo "Спасибо за использование скрипта!!!!!!!!!!!!!!! Заходи на мой канал -  https://t.me/u2smart4home  Там еще больше автоматизаций"
