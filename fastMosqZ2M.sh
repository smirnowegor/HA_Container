#!/usr/bin/env bash
set -euo pipefail

echo "--- Начинаем настройку Mosquitto и Zigbee2MQTT ---"

# --- Создание Docker-сети ---
echo "Проверяем и создаем Docker-сеть 'homeiot_internal'…"
sudo docker network create homeiot_internal >/dev/null 2>&1 || true
echo "Docker-сеть готова."

# --- Функция поиска USB-адаптера по /dev/serial/by-id ---
get_serial_path() {
  local filter="$1" candidates=()
  for link in /dev/serial/by-id/*; do
    [[ -e "$link" ]] || continue
    [[ -n "$filter" && "$link" != *"$filter"* ]] && continue
    candidates+=( "$(readlink -f "$link")" )
  done

  if (( ${#candidates[@]} == 1 )); then
    echo "${candidates[0]}"
  elif (( ${#candidates[@]} > 1 )); then
    echo "Найдено несколько устройств (`$filter`):"
    for i in "${!candidates[@]}"; do
      echo "  $((i+1))) ${candidates[i]}"
    done
    read -p "Выберите номер [1]: " idx
    idx=${idx:-1}
    echo "${candidates[idx-1]}"
  else
    # ни одного не нашли
    echo ""
  fi
}

# --- 1. Настройка Mosquitto ---
echo "--- 1. Настройка Mosquitto ---"
sudo mkdir -p /udobnidom/mosquitto/{config,data,logs}

cat <<EOF | sudo tee /udobnidom/mosquitto/config/mosquitto.conf >/dev/null
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
allow_anonymous true

listener 1883
protocol mqtt

listener 9001
protocol websockets
EOF

echo "✔ Mosquitto настроен."

# --- 2. Настройка Zigbee2MQTT ---
echo "--- 2. Настройка Zigbee2MQTT ---"
sudo mkdir -p /udobnidom/zigbee2mqtt/data

cat <<EOF

Выберите модель Zigbee-адаптера:
 1) Sonoff Zigbee 3.0 USB Dongle Plus V2 (EZSP)
 2) SLZB-06P7 по TCP
 3) SLZB-06P7 по USB
EOF

read -p "Номер (1–3) [3]: " STICK_MODEL
STICK_MODEL=${STICK_MODEL:-3}

case "$STICK_MODEL" in
  1)
    echo "Настройка Sonoff EZSP-донгла…"
    ADAPTER_TYPE="ezsp"
    DEFAULT_BAUD=115200

    # попробуем найти любой /dev/serial/by-id
    ZIGBEE_PATH=$(get_serial_path "")
    if [[ -z "$ZIGBEE_PATH" ]]; then
      echo "Не найден /dev/serial/by-id/*, ставим /dev/ttyUSB0 по-умолчанию."
      ZIGBEE_PATH="/dev/ttyUSB0"
    fi

    BAUDRATE=$DEFAULT_BAUD
    DISABLE_LED=""  # не используется
    ;;

  2)
    echo "Настройка SLZB-06P7 по TCP…"
    ADAPTER_TYPE="zstack"
    read -p "IP-адрес устройства: " SLZB_IP
    read -p "Порт [6638]: " SLZB_PORT
    SLZB_PORT=${SLZB_PORT:-6638}

    ZIGBEE_PATH="tcp://${SLZB_IP}:${SLZB_PORT}"
    DEFAULT_BAUD=460800
    BAUDRATE=$DEFAULT_BAUD
    DISABLE_LED="disable_led: false"
    ;;

  3)
    echo "Настройка SLZB-06P7 по USB…"
    ADAPTER_TYPE="zstack"
    DEFAULT_BAUD=460800

    ZIGBEE_PATH=$(get_serial_path "SLZB-06P7")
    if [[ -z "$ZIGBEE_PATH" ]]; then
      echo "Не найден SLZB-06P7 в /dev/serial/by-id, ставим /dev/ttyUSB0."
      ZIGBEE_PATH="/dev/ttyUSB0"
    fi

    BAUDRATE=$DEFAULT_BAUD
    DISABLE_LED="disable_led: false"
    ;;

  *)
    echo "Неверный выбор. Завершаем."
    exit 1
    ;;
esac

echo ""
echo "Итоги:"
echo "  serial.port     = ${ZIGBEE_PATH}"
echo "  serial.adapter  = ${ADAPTER_TYPE}"
echo "  serial.baudrate = ${BAUDRATE}"
[[ -n "$DISABLE_LED" ]] && echo "  ${DISABLE_LED}"

# --- Запись configuration.yaml ---
cat <<EOF | sudo tee /udobnidom/zigbee2mqtt/data/configuration.yaml >/dev/null
homeassistant:
  enabled: true

mqtt:
  server: 'mqtt://mosquitto:1883'

serial:
  port: ${ZIGBEE_PATH}
  adapter: '${ADAPTER_TYPE}'
  baudrate: ${BAUDRATE}
  rtscts: false
${DISABLE_LED:+  $DISABLE_LED}

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
EOF

echo "--- Скрипт завершён. Mosquitto и Zigbee2MQTT готовы к запуску. ---"
