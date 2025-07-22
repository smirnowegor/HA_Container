#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status, except where explicitly handled

echo "--- Начинаем установку Duplicati ---"

# --- Запрос версии у пользователя ---
echo "Выберите версию Duplicati для установки:"
echo "1) Новая версия (Canary 2.1.0.125_canary_2025-07-15 - arm7/armhf GUI)"
echo "2) Стабильная версия (Stable 2.1.0.5_stable_2025-03-04 - arm64 GUI)"
read -p "Введите номер (1 или 2): " VERSION_CHOICE

DUPLICATI_DEB_FILENAME=""
DOWNLOAD_URL=""
DUPLICATI_ARCH=""

case "$VERSION_CHOICE" in
    1)
        DUPLICATI_DEB_FILENAME="duplicati-2.1.0.125_canary_2025-07-15-linux-arm7-gui.deb"
        DOWNLOAD_URL="https://github.com/duplicati/duplicati/releases/download/v2.1.0.125_canary_2025-07-15/${DUPLICATI_DEB_FILENAME}"
        DUPLICATI_ARCH="arm7/armhf"
        ;;
    2)
        DUPLICATI_DEB_FILENAME="duplicati-2.1.0.5_stable_2025-03-04-linux-arm64-gui.deb"
        DOWNLOAD_URL="https://github.com/duplicati/duplicati/releases/download/v2.1.0.5_stable_2025-03-04/${DUPLICATI_DEB_FILENAME}"
        DUPLICATI_ARCH="arm64"
        ;;
    *)
        echo "Некорректный выбор. Выход."
        exit 1
        ;;
esac

echo "Выбрана версия для ${DUPLICATI_ARCH}: ${DUPLICATI_DEB_FILENAME}"

# --- Запрос и подтверждение пароля для веб-интерфейса Duplicati ---
DUPLICATI_PASSWORD=""
CONFIRM_PASSWORD=""

while true; do
    read -s -p "Введите пароль для веб-интерфейса Duplicati: " DUPLICATI_PASSWORD
    echo
    read -s -p "Повторите пароль: " CONFIRM_PASSWORD
    echo

    if [ -z "$DUPLICATI_PASSWORD" ]; then
        echo "Пароль не может быть пустым. Пожалуйста, введите пароль."
    elif [ "$DUPLICATI_PASSWORD" = "$CONFIRM_PASSWORD" ]; then
        echo "Пароли совпадают."
        break
    else
        echo "Пароли не совпадают. Пожалуйста, попробуйте снова."
    fi
done


# --- Очистка предыдущих установок Duplicati ---
echo "--- Проверяем и удаляем предыдущие установки Duplicati ---"

# Останавливаем и отключаем systemd сервис Duplicati
echo "Поиск и остановка сервисов Duplicati..."
if systemctl is-active --quiet duplicati.service; then
    echo "Останавливаем и отключаем сервис duplicati..."
    sudo systemctl stop duplicati.service
    sudo systemctl disable duplicati.service
    sudo rm -f /etc/systemd/system/duplicati.service
    sudo systemctl daemon-reload
else
    echo "Сервис duplicati не запущен или не существует."
fi

# Удаляем пакеты Duplicati (любые версии)
echo "Удаляем любые установленные пакеты Duplicati..."
# Find all installed duplicati packages and purge them
INSTALLED_DUPLICATI_PACKAGES=$(dpkg -l | grep duplicati | awk '{print $2}')
if [ -n "$INSTALLED_DUPLICATI_PACKAGES" ]; then
    echo "Обнаружены пакеты Duplicati: ${INSTALLED_DUPLICATI_PACKAGES}"
    sudo apt purge ${INSTALLED_DUPLICATI_PACKAGES} -y || true
else
    echo "Пакеты Duplicati не найдены."
fi

# Удаляем старые .deb пакеты Duplicati из /tmp/ и текущей директории
echo "Удаляем старые .deb пакеты Duplicati из /tmp/ и текущей директории..."
sudo rm -f /tmp/duplicati-*.deb || true
sudo rm -f ./duplicati-*.deb || true

# Удаляем оставшиеся файлы конфигурации Duplicati
echo "Удаляем остаточные файлы конфигурации Duplicati..."
sudo rm -rf /root/.config/Duplicati || true
sudo rm -rf /var/lib/duplicati || true # Для некоторых установок может быть здесь
sudo find / -name "Duplicati.sqlite" -delete || true # Ищем и удаляем основные файлы баз данных
sudo find / -name "duplicati-server.sqlite" -delete || true
sudo find / -name "log_data.sqlite" -delete || true
echo "Очистка завершена."

# --- Скачиваем правильный .deb пакет во временную директорию ---
echo "--- Скачиваем .deb пакет Duplicati в /tmp/ ---"
wget "${DOWNLOAD_URL}" -O "/tmp/${DUPLICATI_DEB_FILENAME}"
echo "Пакет ${DUPLICATI_DEB_FILENAME} скачан в /tmp/."

# --- Обновление системы перед установкой ---
echo "--- Обновляем списки пакетов и систему ---"
sudo apt update && sudo apt upgrade -y

# --- Устанавливаем пакет ---
echo "--- Устанавливаем Duplicati ---"
sudo apt install "/tmp/${DUPLICATI_DEB_FILENAME}" -y
echo "Duplicati успешно установлен."

# --- Создаём systemd-сервис для автозапуска ---
echo "--- Создаем systemd-сервис для автозапуска Duplicati ---"
cat <<EOF | sudo tee /etc/systemd/system/duplicati.service > /dev/null
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
User=root
ExecStart=/usr/bin/duplicati-server --webservice-interface=any --webservice-port=8200 --webservice-password="${DUPLICATI_PASSWORD}"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
echo "Файл systemd-сервиса создан."

# --- Перезагружаем systemd и запускаем сервис ---
echo "--- Перезагружаем systemd, запускаем и проверяем сервис Duplicati ---"
sudo systemctl daemon-reload
sudo systemctl enable duplicati.service
sudo systemctl start duplicati.service
sudo systemctl status duplicati.service | grep -E "Active|Loaded"

# --- Проверяем, что Duplicati слушает на всех интерфейсах ---
echo "--- Проверяем, что Duplicati слушает на порту 8200 ---"
echo "Даем сервису 15 секунд на запуск..."
sleep 15

if ! sudo lsof -i :8200 -sTCP:LISTEN; then
    echo "--- ОШИБКА: Duplicati не слушает на порту 8200! ---"
    echo "Возможные причины: порт занят, проблема с конфигурацией или правами."
    echo "Для детального анализа ошибок сервиса Duplicati используйте команду:"
    echo "  sudo journalctl -u duplicati.service --since '5 minutes ago' -e"
    echo "Пожалуйста, проверьте логи и устраните проблему вручную."
    exit 1
fi
echo "Duplicati успешно слушает на порту 8200."

# --- Проверяем доступность веб-интерфейса и выводим ссылку ---
echo ""
echo "---------------------------------------------------------"
echo "Duplicati установлен и настроен!"
echo "Для доступа к веб-интерфейсу Duplicati перейдите по следующей ссылке:"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
fi
if [ -z "$SERVER_IP" ]; then
    echo "Не удалось автоматически определить IP-адрес. Проверьте его вручную командой 'ip a'."
    SERVER_IP="localhost"
fi

echo "   http://${SERVER_IP}:8200/"
echo ""
echo "Пароль для входа в веб-интерфейс: ${DUPLICATI_PASSWORD}"
echo "---------------------------------------------------------"

# Возвращаемся в домашнюю директорию пользователя
cd ~
echo "Скрипт завершен. Вы вернулись в домашнюю директорию."
