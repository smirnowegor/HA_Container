#!/usr/bin/env bash
set -euo pipefail

# Версия релиза (точно как в теге на GitHub)
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"

# Кандидаты (порядок: gui -> cli -> agent)
declare -A CANDIDATES
CANDIDATES["x86_64"]="linux-x64-gui.deb linux-x64-cli.deb linux-x64-agent.deb"
CANDIDATES["aarch64"]="linux-arm64-gui.deb linux-arm64-cli.deb linux-arm64-agent.deb"
CANDIDATES["armv7l"]="linux-arm7-gui.deb linux-arm7-cli.deb linux-arm7-agent.deb"

# sudo если нужен
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Требуются права root или sudo, но sudo не найден." >&2
    exit 1
  fi
fi

# 1) Запрос паролей (как в оригинале)
read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек: " ENC_KEY; echo

# 2) Определение ОС/архитектуры
OS_NAME=$(uname -s)
ARCH=$(uname -m)
echo "Detected OS: ${OS_NAME}, ARCH: ${ARCH}"

if [ "$OS_NAME" != "Linux" ]; then
  echo "Скрипт поддерживает только Linux (Armbian/Debian/Ubuntu)." >&2
  exit 1
fi

# Нормализуем ARCH к ключам массива
case "$ARCH" in
  aarch64|arm64) ARCH_KEY="aarch64" ;;
  armv7l|armhf|armv7*) ARCH_KEY="armv7l" ;;
  x86_64|amd64) ARCH_KEY="x86_64" ;;
  *) echo "Неизвестная/неподдерживаемая архитектура: $ARCH" >&2; exit 1;;
esac

# 3) Удаление предыдущих установок (как в оригинале)
echo "Удаляю старые установки Duplicati..."
$SUDO systemctl stop duplicati.service 2>/dev/null || true
$SUDO systemctl disable duplicati.service 2>/dev/null || true
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get remove --purge -y 'duplicati*' 2>/dev/null || true
fi
$SUDO rm -f /etc/systemd/system/duplicati.service
$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati || true

# 4) Установка зависимостей
echo "Устанавливаю зависимости (wget, unzip, ca-certificates, libicu)..."
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -y
  $SUDO apt-get install -y wget unzip ca-certificates libicu-dev || true
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y wget unzip ca-certificates libicu || true
else
  echo "Пакетный менеджер не поддерживается автоматически. Установите wget и libicu вручную." >&2
fi

# 5) Подбор и скачивание подходящего .deb
VERSION="${TAG#v}"   # убираем ведущую 'v' чтобы получить '2.1.1...'
FOUND_URL=""
FOUND_FNAME=""

for suffix in ${CANDIDATES[$ARCH_KEY]}; do
  FNAME="duplicati-${VERSION}-${suffix}"
  URL="${GITHUB_BASE}/${TAG}/${FNAME}"
  echo -n "Проверяю: ${URL} ... "
  # Попытка получить HEAD, если нет curl — используем wget --spider
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -L -I -o /dev/null -w '%{http_code}' "$URL" || echo "000")
    if [ "$code" = "200" ]; then
      echo "OK"
      FOUND_URL="$URL"
      FOUND_FNAME="$FNAME"
      break
    else
      echo "нет ($code)"
    fi
  else
    if wget --spider --timeout=10 --tries=1 "$URL" 2>&1 | grep -q "200 OK"; then
      echo "OK"
      FOUND_URL="$URL"
      FOUND_FNAME="$FNAME"
      break
    else
      echo "нет"
    fi
  fi
done

if [ -z "$FOUND_URL" ]; then
  echo "Не найдено .deb для релиза ${TAG} и архитектуры ${ARCH}. Попробуйте вручную проверить:"
  echo "  https://github.com/duplicati/duplicati/releases/tag/${TAG}"
  exit 1
fi

echo "Скачиваю ${FOUND_FNAME} ..."
$SUDO rm -f "./${FOUND_FNAME}" || true
if ! wget --progress=bar:force -O "./${FOUND_FNAME}" "$FOUND_URL"; then
  echo "Ошибка при скачивании ${FOUND_URL}" >&2
  exit 1
fi

# 6) Установка .deb с корректной обработкой зависимостей
echo "Устанавливаю пакет ${FOUND_FNAME} ..."
if command -v apt-get >/dev/null 2>&1; then
  if ! $SUDO apt-get install -y "./${FOUND_FNAME}"; then
    echo "apt-get install завершился с ошибкой, пробуем dpkg + исправление зависимостей..."
    $SUDO dpkg -i "./${FOUND_FNAME}" || true
    $SUDO apt-get -y -f install
  fi
else
  if command -v dpkg >/dev/null 2>&1; then
    $SUDO dpkg -i "./${FOUND_FNAME}" || true
  else
    echo "Невозможно автоматически установить .deb: нет apt/dpkg." >&2
    exit 1
  fi
fi

# 7) Создание systemd-сервиса (сохраняем оригинальную логику)
echo "Создаём unit-файл /etc/systemd/system/duplicati.service ..."
$SUDO tee /etc/systemd/system/duplicati.service > /dev/null <<EOF
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

# 8) Перезапуск systemd и запуск сервиса
$SUDO systemctl daemon-reload
$SUDO systemctl enable duplicati.service
$SUDO systemctl restart duplicati.service

# небольшая пауза, чтобы сервис успел подняться
sleep 1

# 9) Вывод IP и паролей (как в оригинале)
echo -e "\n===== Установка завершена ====="
echo "Доступно по адресам:"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read -r ip; do
  echo "  http://${ip}:8200"
done

echo -e "\nИспользованные пароли:"
echo "  • Веб-пароль:         ${WEB_PASS}"
echo "  • Ключ шифрования:    ${ENC_KEY}"

exit 0
