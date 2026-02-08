#!/bin/bash
if [[ -z $(pgrep kodi) ]]; then
  cur_vol="$(sudo /usr/local/bin/current_volume)"
  DEVICE="Playback"
  if [ -f /dev/shm/VOLUME_BEFORE_MAX ]; then
    amixer -q set ${DEVICE} $(cat /dev/shm/VOLUME_BEFORE_MAX)
    rm -f /dev/shm/VOLUME_BEFORE_MAX
  else
    echo $cur_vol > /dev/shm/VOLUME_BEFORE_MAX
    amixer -q set ${DEVICE} 100%
  fi
fi
