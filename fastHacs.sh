#!/usr/bin/env bash
set -e

# 1. Имя контейнера (по умолчанию homeassistant)
CONTAINER_NAME=${1:-homeassistant}

# 2. Поиск ID запущенного контейнера
CONTAINER_ID=$(docker ps -qf "name=${CONTAINER_NAME}")

if [ -z "$CONTAINER_ID" ]; then
  echo "❌ Контейнер с именем ‘${CONTAINER_NAME}’ не найден."
  exit 1
fi

echo "🔍 Найден контейнер ${CONTAINER_NAME} (${CONTAINER_ID})"

# 3. Проверка наличия каталога /config внутри контейнера
docker exec "$CONTAINER_ID" bash -c '
  if [ ! -d /config ]; then
    echo "❌ Директория /config не найдена внутри контейнера."
    exit 1
  fi
'

# 4. Установка HACS
docker exec "$CONTAINER_ID" bash -c '
  echo "⬇️ Скачиваю и устанавливаю HACS..."
  cd /config
  wget -O - https://install.hacs.xyz | bash
'

# 5. Перезапуск контейнера
docker restart "$CONTAINER_ID"
echo "✅ Установка завершена и контейнер перезапущен."
