#!/usr/bin/env bash
set -u
printf '\nCloud Android ADB terminal\nOnly adb commands are accepted on the host. Type exit to close.\n\n'
while true; do
  IFS= read -r -p 'adb> ' line || exit 0
  [[ -z "$line" ]] && continue
  [[ "$line" == 'exit' ]] && exit 0
  read -r -a parts <<< "$line"
  if [[ "${parts[0]:-}" != 'adb' ]]; then
    echo 'Rejected: enter an adb command, for example: adb devices'
    continue
  fi
  if [[ "${#parts[@]}" -eq 1 ]]; then
    adb help
  else
    adb "${parts[@]:1}"
  fi
done
