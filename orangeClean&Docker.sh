#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Начинаем удаление старого Docker и очистку..."

echo "Удаляем файл /etc/apt/sources.list.d/docker.list..."
sudo rm -f /etc/apt/sources.list.d/docker.list || true

echo "Удаляем пакеты Docker..."
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin || true

echo "Очищаем кеш пакетов APT..."
sudo apt-get clean

echo "Удаление старого Docker и очистка завершены успешно (или Docker не был установлен)."

echo
echo "Переходим к обновлению системы и установке Docker CE..."

echo "Обновляем списки пакетов..."
sudo apt-get update -y

echo "Устанавливаем доступные обновления без подтверждений..."
sudo apt-get upgrade -y

echo "Обновление системы завершено успешно."

echo
echo "Скачиваем и запускаем скрипт установки Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

echo "Установка Docker CE завершена успешно."

echo
echo "Проверяем установку Docker..."
sudo docker run --rm hello-world

echo "Docker установлен и работает корректно. Вы видите сообщение 'Hello from Docker!'."
echo
echo "Все этапы завершены успешно!"
