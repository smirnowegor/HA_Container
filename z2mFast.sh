version: '3.8'
services:
  zigbee2mqtt:
    container_name: zigbee2mqtt
    image: koenkk/zigbee2mqtt:latest
    volumes:
      - /udobnidom/zigbee2mqtt/data:/app/data # Здесь будет храниться configuration.yaml и другие данные
      - /run/udev:/run/udev:ro # Для доступа к USB-портам
    devices:
      - /dev/ttyUSB0:/dev/ttyACM0 #<---ИСПОЛЬЗУЕМ /dev/ttyUSB0 как источник, /dev/ttyACM0 как цель в контейнере
    environment:
      - TZ=Europe/Moscow # <-- ЗАМЕНИ НА СВОЮ ВРЕМЕННУЮ ЗОНУ (Moldova)
      - MQTT_SERVER=mqtt://mosquitto # Указываем адрес Mosquitto по имени сервиса (доступ через внутреннюю сеть Docker)
      # Логин и пароль MQTT не требуются, так как Mosquitto настроен на анонимный доступ
    ports:
      - '8080:8080' # Веб-интерфейс Zigbee2MQTT
    restart: unless-stopped
    privileged: true # Может потребоваться для доступа к USB-стику
    networks:
      - homeiot_internal
networks:
  homeiot_internal:
    external: true
