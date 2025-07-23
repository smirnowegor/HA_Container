#!/bin/bash

# Начинаем удаление старого Docker и очистку...
echo "Начинаем удаление старого Docker и очистку..."

# Удаляем файл списка источников Docker (если он существует)
echo "Удаляем файл /etc/apt/sources.list.d/docker.list..."
sudo rm -f /etc/apt/sources.list.d/docker.list || true # Добавлено || true для пропуска ошибок

# Удаляем пакеты Docker
echo "Удаляем пакеты Docker..."
# Добавлено || true для пропуска ошибок, если пакеты не установлены
sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin -y || true

# Очищаем кеш пакетов
echo "Очищаем кеш пакетов APT..."
sudo apt clean

echo "Удаление старого Docker и очистка завершены успешно (или Docker не был установлен)."

# ---
echo "Переходим к обновлению системы и установке Docker CE..."

# Выполняем полное обновление системы
echo "Обновляем списки пакетов и устанавливаем доступные обновления..."
sudo apt update && sudo apt upgrade -y

echo "Обновление системы завершено успешно."

# Устанавливаем Docker CE и Docker Compose Plugin
echo "Скачиваем и запускаем скрипт установки Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

echo "Установка Docker CE завершена успешно."

# Проверяем установку Docker
echo "Проверяем установку Docker..."
sudo docker run hello-world

echo "Docker установлен и работает корректно. Вы видите сообщение 'Hello from Docker!'."

echo "Все этапы завершены успешно!"
