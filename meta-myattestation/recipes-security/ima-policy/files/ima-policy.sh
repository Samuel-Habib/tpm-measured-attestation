#!/bin/sh
### BEGIN INIT INFO
# Provides:          ima-policy
# Required-Start:    mountall
# Required-Stop:     
# Default-Start:     S
# Default-Stop:      
# Short-Description: Load custom Linux IMA policy
### END INIT INFO

POLICY_FILE="/etc/ima/ima-policy"
IMA_SYSFS="/sys/kernel/security/ima/policy"

case "$1" in
  start)
    if [ ! -d /sys/kernel/security ]; then
      mount -t securityfs securityfs /sys/kernel/security 2>/dev/null || true
    fi

    if [ -w "$IMA_SYSFS" ] && [ -f "$POLICY_FILE" ]; then
      echo "Loading Linux IMA measurement policy from $POLICY_FILE..."
      if cat "$POLICY_FILE" > "$IMA_SYSFS"; then
        echo "Linux IMA policy successfully loaded into $IMA_SYSFS"
      else
        echo "Warning: Failed to load IMA policy into $IMA_SYSFS (it may already be locked or invalid)" >&2
      fi
    else
      echo "IMA policy sysfs interface ($IMA_SYSFS) not writable or policy file not found."
    fi
    ;;
  stop|status|restart|reload|force-reload)
    ;;
  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 1
    ;;
esac

exit 0
