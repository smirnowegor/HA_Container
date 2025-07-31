#!/bin/bash
set -e

echo "--- Начинаем настройку Mosquitto и Zigbee2MQTT ---"

# --- Создание Docker сети ---
echo "Проверяем и создаем Docker сеть 'homeiot_internal'..."
sudo docker network create homeiot_internal || true
echo "Docker сеть 'homeiot_internal' готова."

# --- 1. Настройка Mosquitto ---
echo "--- 1. Настройка Mosquitto ---"
sudo mkdir -p /udobnidom/mosquitto/{config,data,logs}
cat <<EOL | sudo tee /udobnidom/mosquitto/config/mosquitto.conf > /dev/null
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
allow_anonymous true
listener 1883
protocol mqtt
listener 9001
protocol websockets
EOL
echo "Mosquitto настроен."

# --- 2. Настройка Zigbee2MQTT ---
echo "--- 2. Настройка Zigbee2MQTT ---"
sudo mkdir -p /udobnidom/zigbee2mqtt/data

echo ""
echo "Выберите модель Zigbee-адаптера:"
echo "1) Sonoff Zigbee 3.0 USB Dongle Plus V2 (Ember)"
echo "2) SLZB-06P7 по TCP"
echo "3) SLZB-06P7 по USB"
read -p "Введите номер (1-3): " STICK_MODEL

# Значения по умолчанию для SLZB-06P7
DEFAULT_SLZB_ADAPTER="zstack"
DEFAULT_SLZB_LED="false"

case "$STICK_MODEL" in
  1)
    echo "Настройка Sonoff Zigbee 3.0 USB Dongle Plus V2 (Ember)..."
    ADAPTER_TYPE="ember"
    DEFAULT_BAUD=115200

    # Поиск USB-устройства
    SERIAL_DEVICES=$(ls -l /dev/serial/by-id/ 2>/dev/null | awk '{print $9 " -> " $11}')
    if [ -z "$SERIAL_DEVICES" ]; then
      read -p "Путь к устройству (например, /dev/ttyUSB0): " USER_PATH
      ZIGBEE_PATH=${USER_PATH:-/dev/ttyUSB0}
    else
      if [ "$(echo "$SERIAL_DEVICES" | wc -l)" -eq 1 ]; then
        NODE=$(echo "$SERIAL_DEVICES" | awk -F'-> ../../' '{print $2}')
        ZIGBEE_PATH="/dev/$NODE"
      else
        echo "Найдено несколько устройств:"
        echo "$SERIAL_DEVICES"
        read -p "Введите полный путь: " USER_PATH
        ZIGBEE_PATH=${USER_PATH:-/dev/ttyUSB0}
      fi
    fi

    read -p "Введите baudrate [${DEFAULT_BAUD}]: " USER_BAUDRATE
    BAUDRATE=${USER_BAUDRATE:-$DEFAULT_BAUD}

    DISABLE_LED=""  # не используется
    ;;

  2)
    echo "Настройка SLZB-06P7 по TCP..."
    ADAPTER_TYPE=${DEFAULT_SLZB_ADAPTER}
    read -p "IP-адрес устройства: " SLZB_IP
    read -p "Порт устройства [6638]: " SLZB_PORT
    SLZB_PORT=${SLZB_PORT:-6638}
    ZIGBEE_PATH="tcp://${SLZB_IP}:${SLZB_PORT}"

    read -p "Введите baudrate [460800]: " USER_BAUDRATE
    BAUDRATE=${USER_BAUDRATE:-460800}

    DISABLE_LED="disable_led: ${DEFAULT_SLZB_LED}"
    ;;

  3)
    echo "Настройка SLZB-06P7 по USB..."
    ADAPTER_TYPE=${DEFAULT_SLZB_ADAPTER}

    # Поиск SLZB-06P7 в /dev/serial/by-id
    SLZB_DEVICES=$(ls -l /dev/serial/by-id/ 2>/dev/null \
      | grep -i SLZB-06P7 \
      | awk '{print $9 " -> " $11}')
    if [ -z "$SLZB_DEVICES" ]; then
      read -p "Путь к USB-устройству SLZB-06P7: " USER_PATH
      ZIGBEE_PATH=${USER_PATH:-/dev/ttyUSB0}
    else
      if [ "$(echo "$SLZB_DEVICES" | wc -l)" -eq 1 ]; then
        NODE=$(echo "$SLZB_DEVICES" | awk -F'-> ../../' '{print $2}')
        ZIGBEE_PATH="/dev/$NODE"
      else
        echo "Найдено несколько SLZB-06P7:"
        echo "$SLZB_DEVICES"
        read -p "Введите путь из списка: " USER_PATH
        ZIGBEE_PATH=${USER_PATH:-/dev/ttyUSB0}
      fi
    fi

    read -p "Введите baudrate [460800]: " USER_BAUDRATE
    BAUDRATE=${USER_BAUDRATE:-460800}

    DISABLE_LED="disable_led: ${DEFAULT_SLZB_LED}"
    ;;

  *)
    echo "Некорректный выбор. Скрипт будет завершён."
    exit 1
    ;;
esac

echo ""
echo "Итоги настройки:"
echo "  Путь:       ${ZIGBEE_PATH}"
echo "  Baudrate:   ${BAUDRATE}"
echo "  Adapter:    ${ADAPTER_TYPE}"
[ -n "$DISABLE_LED" ] && echo "  ${DISABLE_LED}"

# Генерация configuration.yaml
cat <<EOL | sudo tee /udobnidom/zigbee2mqtt/data/configuration.yaml > /dev/null
homeassistant:
  enabled: true

mqtt:
  server: 'mqtt://mosquitto:1883'

serial:
  port: ${ZIGBEE_PATH}
  adapter: '${ADAPTER_TYPE}'
  baudrate: ${BAUDRATE}
  rtscts: false
${DISABLE_LED}

frontend:
  enabled: true
  port: 8080
  host: 0.0.0.0

permit_join: true

advanced:
  pan_id: GENERATE
  ext_pan_id: GENERATE
  network_key: GENERATE

data_path: /app/data
EOL

echo "--- Настройка Mosquitto и Zigbee2MQTT завершена! ---"
cd ~
echo "Скрипт завершен. Вы в домашней директории."
