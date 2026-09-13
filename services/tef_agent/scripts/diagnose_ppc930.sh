#!/usr/bin/env bash
set -u
printf '=== Sistema ===\n'; uname -a
printf '\n=== USB ===\n'; lsusb || true
printf '\n=== Serial candidates ===\n'; ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true
printf '\n=== Kernel (Gertec/PPC/tty) ===\n'; (dmesg 2>/dev/null || journalctl -k -n 300 2>/dev/null) | grep -Ei 'gertec|ppc|pin.?pad|ttyACM|ttyUSB|usb' | tail -100 || true
for d in /dev/ttyACM* /dev/ttyUSB*; do
  [[ -e "$d" ]] || continue
  printf '\n=== udev %s ===\n' "$d"
  udevadm info --query=property --name="$d" 2>/dev/null | grep -E 'ID_VENDOR|ID_MODEL|ID_SERIAL|ID_VENDOR_ID|ID_MODEL_ID' || true
done
