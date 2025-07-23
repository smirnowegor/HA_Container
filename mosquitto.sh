version: '3.8'
services:
  mosquitto:
    container_name: mosquitto
    image: eclipse-mosquitto:latest
    volumes:
      - /udobnidom/mosquitto/config:/mosquitto/config
      - /udobnidom/mosquitto/data:/mosquitto/data
      - /udobnidom/mosquitto/logs:/mosquitto/log
    ports:
      - '1883:1883' # Стандартный порт MQTT
      - '9001:9001' # Порт для Websockets
    restart: unless-stopped
    networks:
      - homeiot_internal
networks:
  homeiot_internal:
    external: true
