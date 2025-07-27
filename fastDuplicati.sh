#!/usr/bin/env bash
set -euo pipefail

# 1. Запрос паролей
read -rsp "Введите пароль для веб‑интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек: " ENC_KEY; echo

# 2. Удаление предыдущих установок
echo "Удаляю старые установки Duplicati..."
sudo systemctl stop duplicati.service 2>/dev/null || true
sudo systemctl disable duplicati.service 2>/dev/null || true
sudo apt purge -y duplicati* 2>/dev/null || true
sudo rm -f /etc/systemd/system/duplicati.service
sudo rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati

# 3. Скачивание .deb пакета
DEB_URL="https://github.com/duplicati/duplicati/releases/download/v2.1.0.125_canary_2025-07-15/duplicati-2.1.0.125_canary_2025-07-15-linux-arm7-gui.deb"
FNAME="${DEB_URL##*/}"
echo "Скачиваем $FNAME..."
wget --progress=bar:force "$DEB_URL" -O "$FNAME"

# 4. Установка пакета
echo "Устанавливаем $FNAME..."
sudo apt update
sudo apt install -y "./$FNAME"

# 5. Создание systemd-сервиса
echo "Создаём unit-файл /etc/systemd/system/duplicati.service..."
sudo tee /etc/systemd/system/duplicati.service > /dev/null <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
User=root
ExecStart=/usr/bin/duplicati-server --webservice-interface=any --webservice-port=8200 --webservice-password="${WEB_PASS}" --settings-encryption-key="${ENC_KEY}" --webservice-allowed-hostnames=*
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 6. Перезапуск systemd и запуск сервиса
sudo systemctl daemon-reload
sudo systemctl enable duplicati.service
sudo systemctl restart duplicati.service

# 7. Вывод IP и паролей
echo -e "\n===== Установка завершена ====="
echo "Доступно по адресам:"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read ip; do
  echo "  http://${ip}:8200"
done

echo -e "\nИспользованные пароли:"
echo "  • Веб‑пароль:         ${WEB_PASS}"
echo "  • Ключ шифрования:    ${ENC_KEY}"
