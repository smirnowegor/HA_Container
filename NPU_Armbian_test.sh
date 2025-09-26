#!/bin/bash

ITER=5   # сколько раз обновить состояние
DELAY=2  # задержка между итерациями (сек)

echo "===== Universal NPU/CPU/GPU Report ====="
echo

# --- Проверка драйвера rknpu ---
echo "[INFO] Проверка драйвера rknpu..."
if [ -d /sys/kernel/debug/rknpu ]; then
    echo "[OK] Драйвер rknpu обнаружен"
    if [ -f /sys/kernel/debug/rknpu/version ]; then
        echo "[INFO] Версия драйвера:"
        cat /sys/kernel/debug/rknpu/version
    else
        # fallback через dmesg
        ver=$(dmesg | grep -i rknpu | grep -m1 "RKNPU")
        if [ -n "$ver" ]; then
            echo "[INFO] Версия драйвера (dmesg): $ver"
        else
            echo "[WARN] Версия драйвера не найдена"
        fi
    fi
else
    echo "[FAIL] Драйвер rknpu не найден"
fi
echo

# --- CPU загрузка ---
cpu_usage() {
    top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8"%"}'
}

# --- GPU поиск и загрузка ---
gpu_usage() {
    gpu_nodes=$(find /sys/class/devfreq -maxdepth 1 -type d -iname "gpu*" 2>/dev/null)
    if [ -n "$gpu_nodes" ]; then
        for node in $gpu_nodes; do
            freq=$(cat "$node/cur_freq" 2>/dev/null)
            load=$(cat "$node/load" 2>/dev/null)
            echo "[GPU] $node: load=${load:-N/A}, freq=${freq:-N/A}"
        done
    else
        echo "[GPU] интерфейс не найден"
    fi
}

# --- NPU загрузка ---
npu_usage() {
    if [ -f /sys/kernel/debug/rknpu/load ]; then
        cat /sys/kernel/debug/rknpu/load
    else
        npu_nodes=$(find /sys/class/devfreq -maxdepth 1 -type d -iname "rknpu*" 2>/dev/null)
        if [ -n "$npu_nodes" ]; then
            for node in $npu_nodes; do
                util=$(cat "$node/utilization" 2>/dev/null)
                freq=$(cat "$node/cur_freq" 2>/dev/null)
                echo "[NPU] $node: util=${util:-N/A}, freq=${freq:-N/A}"
            done
        else
            echo "[NPU] интерфейс не найден"
        fi
    fi
}

# --- Основной цикл ---
for i in $(seq 1 $ITER); do
    echo
    echo "===== Итерация $i из $ITER ====="
    echo "[CPU] $(cpu_usage)"
    gpu_usage
    npu_usage
    sleep $DELAY
done

echo
echo "===== Отчёт завершён ====="
