#!/bin/bash
# /usr/local/bin/r36_config.sh
# Early boot: detect hardware → select correct battery LED warning script → apply if needed
# Handles gamma + ALSA audio path/volume every boot (persistent in config.ini, default from devices.ini)
# Writes current gamma to /dev/shm/CURRENT_GAMMA every boot (volatile runtime file)
# FIXED: 80% default volume ONLY on first boot/hardware change.  No alsa_volume line = manual control.

set -euo pipefail

CONFIG_FILE="/etc/r36_config.ini"
DEVICES_FILE="/boot/dtb/r36_devices.ini"
SCRIPT_DIR="/usr/local/bin/r36_config/batt_life_warning"
TARGET_LINK="/usr/local/bin/batt_life_warning.py"
LOG_FILE="/boot/darkosre_device.log"
GAMMA_BIN="/usr/local/bin/gamma"
OGAGE_DIR="/usr/local/bin/r36_config/ogage"

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [r36_config] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" > /dev/kmsg 2>/dev/null || true
}

log "Early boot LED variant + gamma + ALSA audio config starting..."

# Hardware detection
HARDWARE_RAW=$(grep -i '^Hardware' /proc/cpuinfo | awk -F': ' '{print $2}' | head -n1 | sed 's/^[ \t]*//;s/[ \t]*$//')
[ -z "$HARDWARE_RAW" ] && HARDWARE_RAW="Unknown RK3326"
log "Hardware string: '$HARDWARE_RAW'"

HARDWARE_NORM=$(echo "$HARDWARE_RAW" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')

# Variant lookup (unchanged)
lookup_variant() {
    local orig="$1" norm="$2"
    local variant=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^]]+)\] ]]; then
            local sec="${BASH_REMATCH[1]}"
            local sec_norm=$(echo "$sec" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')
            if [ "$sec_norm" = "$norm" ]; then
                variant=$(sed -n "/^\[$sec\]/,/^\[/ s/^variant[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
                [ -n "$variant" ] && echo "$variant" && return 0
            fi
        fi
    done < "$DEVICES_FILE"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^]]+)\] ]]; then
            local sec="${BASH_REMATCH[1]}"
            local sec_norm=$(echo "$sec" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')
            if echo "$norm" | grep -q "$sec_norm"; then
                variant=$(sed -n "/^\[$sec\]/,/^\[/ s/^variant[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
                [ -n "$variant" ] && echo "$variant" && return 0
            fi
        fi
    done < "$DEVICES_FILE"
    echo "unknown"
}

VARIANT=$(lookup_variant "$HARDWARE_RAW" "$HARDWARE_NORM")
log "Determined variant: $VARIANT"

# ALSA path lookup (defaults to SPK_HP)
ALSA_PATH=""
if [ -f "$DEVICES_FILE" ]; then
    ALSA_PATH=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^alsa_path[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$ALSA_PATH" ]; then
        ALSA_PATH=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^alsa_path[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
fi
[ -z "$ALSA_PATH" ] && ALSA_PATH="SPK_HP"
log "ALSA path from devices.ini (or default): $ALSA_PATH"

# LED + config handling (first boot / hardware change)
NEEDS_LED_UPDATE=0
if [ ! -f "$CONFIG_FILE" ]; then
    NEEDS_LED_UPDATE=1
    log "Config file missing (first boot) - performing full LED + ALSA setup"
else
    CURRENT_HARDWARE=$(grep '^hardware[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || echo "")
    if [ "$CURRENT_HARDWARE" != "$HARDWARE_RAW" ]; then
        NEEDS_LED_UPDATE=1
        log "Hardware change detected: '$CURRENT_HARDWARE' → '$HARDWARE_RAW' - updating LED + ALSA"
    else
        log "No hardware change - skipping LED update"
    fi
fi

if [ "$NEEDS_LED_UPDATE" = "1" ]; then
    case "$VARIANT" in
        r36s)     SELECTED="R36S_Green_30_Red.py" ;;
        soysauce) SELECTED="SoySauce_Blue_30_Pink_10_Red.py" ;;
        unknown)  SELECTED="Clone_PMIC_Controlled.py" ;;
        *)        SELECTED="Clone_Blue_30_Purple_10_Red.py" ;;
    esac

    SELECTED_PATH="$SCRIPT_DIR/$SELECTED"
    log "Selected LED script: $SELECTED"

    rm -f "$TARGET_LINK" 2>/dev/null || true
    if [ -f "$SELECTED_PATH" ]; then
        cp "$SELECTED_PATH" "$TARGET_LINK" 2>>"$LOG_FILE" && chmod +x "$TARGET_LINK" && log "Copied and made executable: $SELECTED"
    else
        log "CRITICAL: Source script missing: $SELECTED_PATH"
    fi

    # Config write (NO alsa_volume line - we only set default volume once)
    log "Writing config (with alsa_path only)"
    TMP_CONFIG=$(mktemp /tmp/r36_config.XXXXXX 2>/dev/null) || true
    if [ -n "$TMP_CONFIG" ]; then
        cat > "$TMP_CONFIG" <<EOF
[Device]
hardware = $HARDWARE_RAW
variant = $VARIANT
config_version = 1.0
active_script = $SELECTED
alsa_path = $ALSA_PATH
EOF
        mv "$TMP_CONFIG" "$CONFIG_FILE" && sync && chmod 666 "$CONFIG_FILE"
        log "Config written via temp: $CONFIG_FILE"
    else
        # fallback
        > "$CONFIG_FILE"
        echo "[Device]" >> "$CONFIG_FILE"
        echo "hardware = $HARDWARE_RAW" >> "$CONFIG_FILE"
        echo "variant = $VARIANT" >> "$CONFIG_FILE"
        echo "config_version = 1.0" >> "$CONFIG_FILE"
        echo "active_script = $SELECTED" >> "$CONFIG_FILE"
        echo "alsa_path = $ALSA_PATH" >> "$CONFIG_FILE"
        sync
        chmod 666 "$CONFIG_FILE"
        log "Fallback config written"
    fi
fi

# Gamma handling (unchanged)
GAMMA_VALUE=""
if [ -f "$CONFIG_FILE" ]; then
    GAMMA_VALUE=$(grep '^gamma[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || true)
fi
if [ -z "$GAMMA_VALUE" ] && [ -f "$DEVICES_FILE" ]; then
    GAMMA_VALUE=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^gamma[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    [ -z "$GAMMA_VALUE" ] && GAMMA_VALUE=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^gamma[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
fi
if [ -n "$GAMMA_VALUE" ] && [ -x "$GAMMA_BIN" ]; then
    log "Applying gamma $GAMMA_VALUE"
    "$GAMMA_BIN" -s "$GAMMA_VALUE" 2>>"$LOG_FILE" && log "Gamma applied"
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '^gamma[ \t]*=' "$CONFIG_FILE"; then
            sed -i "s/^gamma[ \t]*=.*/gamma = $GAMMA_VALUE/" "$CONFIG_FILE"
        else
            echo "gamma = $GAMMA_VALUE" >> "$CONFIG_FILE"
        fi
        sync
    fi
fi
[ -n "$GAMMA_VALUE" ] && echo "$GAMMA_VALUE" > /dev/shm/CURRENT_GAMMA && chmod 666 /dev/shm/CURRENT_GAMMA

# ────────────────────────────────────────────────
# ALSA AUDIO HANDLING – FIXED
# ────────────────────────────────────────────────
log "=== Starting ALSA audio configuration ==="

# Playback Path (always)
CUR_ALSA_PATH=$(grep '^alsa_path[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || echo "$ALSA_PATH")
log "Applying ALSA Playback Path: $CUR_ALSA_PATH"
amixer -c 0 cset iface=MIXER,name='Playback Path' "$CUR_ALSA_PATH" 2>>"$LOG_FILE" || log "WARNING: amixer Playback Path failed"

# ogage binary
OGAGE_SRC="$OGAGE_DIR/ogage.${CUR_ALSA_PATH}"
if [ -f "$OGAGE_SRC" ]; then
    log "Copying ogage for $CUR_ALSA_PATH"
    cp "$OGAGE_SRC" /usr/local/bin/ogage && chmod +x /usr/local/bin/ogage
else
    log "WARNING: ogage source missing"
fi

# FIXED VOLUME LOGIC
ALSA_VOLUME=""
if [ -f "$CONFIG_FILE" ]; then
    ALSA_VOLUME=$(grep '^alsa_volume[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || true)
fi

if [ -n "$ALSA_VOLUME" ]; then
    log "Setting persistent boot volume from config: ${ALSA_VOLUME}%"
    amixer -c 0 -M sset 'Playback' "${ALSA_VOLUME}%" 2>>"$LOG_FILE" || log "amixer volume (config) failed"
elif [ "$NEEDS_LED_UPDATE" = "1" ]; then
    log "First boot/hardware change - setting default boot volume 80%"
    amixer -c 0 -M sset 'Playback' 80% 2>>"$LOG_FILE" || log "amixer default volume failed"
    # Do NOT write alsa_volume=80 - user can clear it later
else
    log "No alsa_volume in config and not first boot - leaving volume untouched (manual control)"
fi

log "ALSA audio configuration complete."
log "Early LED + gamma + ALSA audio config complete."
exit 0