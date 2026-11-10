#!/usr/bin/env bash
# waits (max 4 h) until 3800 MB physical memory is free, then starts one pzt live client
cd "$(dirname "$0")/.." || exit 1
for i in $(seq 1 480); do
  free=$(powershell -NoProfile -Command "[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)" | tr -d '\r')
  if [ "$free" -ge 3800 ]; then echo "$(date +%T) free=${free}MB, launching"; exec bash ../PZTestHarness/pzt live; fi
  [ $((i % 10)) -eq 1 ] && echo "$(date +%T) free=${free}MB < 3800, waiting"
  sleep 30
done
echo "gave up waiting for memory"; exit 3
