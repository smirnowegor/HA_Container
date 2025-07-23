#!/bin/bash
set -e # Выходим сразу при любой ошибке

echo "--- Начинаем настройку Mosquitto и Zigbee2MQTT ---"

# --- Создание Docker сети ---
echo "Проверяем и создаем Docker сеть 'homeiot_internal'..."
# Создаем сеть, если она не существует. '|| true' позволяет скрипту не прерываться, если сеть уже есть.
sudo docker network create homeiot_internal || true
echo "Docker сеть 'homeiot_internal' готова."

# --- 1. Настройка Mosquitto ---
echo "--- 1. Настройка Mosquitto ---"

# Создаем необходимые директории для Mosquitto
echo "Создаем директории для Mosquitto: /udobnidom/mosquitto/config, /udobnidom/mosquitto/data, /udobnidom/mosquitto/logs..."
sudo mkdir -p /udobnidom/mosquitto/config /udobnidom/mosquitto/data /udobnidom/mosquitto/logs

# Создаем и настраиваем файл mosquitto.conf
echo "Создаем и настраиваем файл /udobnidom/mosquitto/config/mosquitto.conf..."
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
echo "Файл mosquitto.conf создан."

# --- 2. Настройка Zigbee2MQTT ---
echo "--- 2. Настройка Zigbee2MQTT ---"

# Создаем необходимые директории для Zigbee2MQTT
echo "Создаем директории для Zigbee2MQTT: /udobnidom/zigbee2mqtt/data..."
sudo mkdir -p /udobnidom/zigbee2mqtt/data

# Определяем путь к Zigbee-стику
echo "Поиск Zigbee-стиков в /dev/serial/by-id/..."
echo "Рекомендация: Для максимальной стабильности рекомендуется использовать полный путь /dev/serial/by-id/..."
echo "(например, /dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_...-if00-port0),"
echo "так как /dev/ttyUSB0 может измениться после перезагрузки."

ZIGBEE_PATH=""
# Используем `readlink -f` для получения абсолютного пути, если это симлинк
SERIAL_DEVICES=$(ls -l /dev/serial/by-id/ 2>/dev/null | awk '{print $9 " -> " $11}')

if [ -z "$SERIAL_DEVICES" ]; then
    echo "ВНИМАНИЕ: Zigbee-стик не найден в /dev/serial/by-id/."
    read -p "Пожалуйста, введите полный путь к вашему Zigbee-стику вручную (например, /dev/ttyUSB0): " USER_ZIGBEE_PATH
    if [ -z "$USER_ZIGBEE_PATH" ]; then
        echo "Путь не введен. Настройка Zigbee2MQTT будет выполнена без указания стика."
        echo "Вам нужно будет отредактировать /udobnidom/zigbee2mqtt/data/configuration.yaml вручную."
        ZIGBEE_PATH="/dev/ttyUSB0" # Устанавливаем значение по умолчанию, но с предупреждением
    else
        ZIGBEE_PATH="$USER_ZIGBEE_PATH"
    fi
else
    NUM_DEVICES=$(echo "$SERIAL_DEVICES" | wc -l)
    if [ "$NUM_DEVICES" -eq 1 ]; then
        # Извлекаем конечный путь (например, ../../ttyUSB0) и преобразуем его в /dev/ttyUSB0
        DEV_NODE=$(echo "$SERIAL_DEVICES" | awk -F'-> ../../' '{print $2}')
        ZIGBEE_PATH="/dev/${DEV_NODE}"
        echo "Обнаружен Zigbee-стик по пути: ${ZIGBEE_PATH}"
    else
        echo "Обнаружено несколько Zigbee-стиков:"
        echo "$SERIAL_DEVICES"
        read -p "Пожалуйста, введите полный путь к вашему Zigbee-стику (например, /dev/ttyUSB0 или полный путь из списка выше): " USER_ZIGBEE_PATH
        if [ -z "$USER_ZIGBEE_PATH" ]; then
            echo "Путь не введен. Настройка Zigbee2MQTT будет выполнена без указания стика."
            echo "Вам нужно будет отредактировать /udobnidom/zigbee2mqtt/data/configuration.yaml вручную."
            ZIGBEE_PATH="/dev/ttyUSB0" # Устанавливаем значение по умолчанию, но с предупреждением
        else
            ZIGBEE_PATH="$USER_ZIGBEE_PATH"
        fi
    fi
fi

# --- Запрос типа Zigbee-адаптера ---
echo ""
echo "Выберите тип вашего Zigbee-адаптера:"
echo "1) Z-Stack (Texas Instruments CC253x, CC2652, CC1352 - большинство стиков Sonoff, CC2531)"
echo "2) Deconz (ConBee, RaspBee)"
echo "3) Ember (Silicon Labs EZSP - большинство стиков Sonoff EFR32MG21, SkyConnect)"
echo "4) ZiGate"
echo "5) EZSP (старое название для Ember)"
read -p "Введите номер (1-5): " ADAPTER_CHOICE

ZIGBEE_ADAPTER=""
case "$ADAPTER_CHOICE" in
    1) ZIGBEE_ADAPTER="zstack" ;;
    2) ZIGBEE_ADAPTER="deconz" ;;
    3) ZIGBEE_ADAPTER="ember" ;;
    4) ZIGBEE_ADAPTER="zigate" ;;
    5) ZIGBEE_ADAPTER="ezsp" ;; # EZSP - это старое название для Ember
    *)
        echo "Некорректный выбор адаптера. Будет использован 'ember' по умолчанию."
        ZIGBEE_ADAPTER="ember"
        ;;
esac
echo "Выбран тип адаптера: ${ZIGBEE_ADAPTER}"


# Создаем и настраиваем файл configuration.yaml для Zigbee2MQTT
echo "Создаем и настраиваем файл /udobnidom/zigbee2mqtt/data/configuration.yaml..."
cat <<EOL | sudo tee /udobnidom/zigbee2mqtt/data/configuration.yaml > /dev/null
# Home Assistant integration
homeassistant:
  enabled: true

# MQTT settings
mqtt:
  server: 'mqtt://mosquitto:1883'

# Serial port settings for your Zigbee adapter
serial:
  port: ${ZIGBEE_PATH} # <-- ПУТЬ К ТВОЕМУ ZIGBEE СТИКУ (автоматически определен или введен вручную)
  adapter: '${ZIGBEE_ADAPTER}' # <-- ТИП АДАПТЕРА (выбран пользователем)
  baudrate: 115200
  rtscts: false

# Frontend settings (веб-интерфейс)
frontend:
  enabled: true
  port: 8080
  host: 0.0.0.0

# Permit joining new devices
permit_join: true

# Advanced settings
advanced:
  channel: 11
  pan_id: 0x1aef
  ext_pan_id: GENERATE
  network_key: GENERATE

# Data directory (необязательно, если используется Docker volume)
data_path: /app/data
EOL
echo "Файл configuration.yaml создан."

echo "--- Настройка Mosquitto и Zigbee2MQTT завершена! ---"

# Возвращаемся в домашнюю диреторию пользователя
cd ~
echo "Скрипт завершен. Вы вернулись в домашнюю диреторию."
