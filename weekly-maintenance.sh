#!/usr/bin/env bash
# weekly-maintenance.sh
# Runs apt maintenance + housekeeping (Filesystem Trim, Temp file deletion) + reboot, logging everything.
# Intended for weekly cron job.

# ---- Set: Strict Mode ----
# This set of options makes the script stop immediately on any failure, undefined variable or pipeline failure.
# -E  — ERR traps are inherited by shell functions and subshells
# -e  — exit immediately on any non-zero return code
# -u  — treat unset variables as errors
# -o pipefail — a pipeline fails if any stage fails (not just the last)
set -Eeuo pipefail
# umask is setting permissions on the created log files. 027 = rwxr-s--- (files will be rw-r-----, dirs will be rwxr-s---)
umask 027

# ---- Config ----
# Storing log path as a variable.
LOG_DIR="/var/log/weekly-maintenance"
# This is creating a timestamp for the log file name, formatted as YYYY-MM-DD_HH-MM-SS. This is better for filesystems and sorting.
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
# This is creating the log file name.
LOG_FILE="${LOG_DIR}/weekly-maintenance-${STAMP}.log"
# This is how long to wait for apt/dpkg locks before giving up. 1800 seconds = 30 minutes.
LOCK_WAIT_SECONDS=1800
# This gives a timestamp at the creation of this variable. It will be calculated against END_TIME_EPOCH at the end to get total runtime.
START_TIME_EPOCH=$(date +%s)
# This gives a timestamp in human-readable form for the log header.
START_TIME_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"t

# ---- Helpers ----
# Create the log directory if it doesn't exist.
mkdir -p "$LOG_DIR"
# Ensure the log directory is owned by root with group 'loggers'
chown root:loggers "$LOG_DIR"
# Set permissions on the log directory to 2750 (rwxr-s---)
chmod 2750 "$LOG_DIR"

# Redirect all stdout and stderr to the log file for the rest of the script.
# tee -a writes to the file while also printing to the terminal (For manual runs).
exec > >(tee -a "$LOG_FILE") 2>&1

# ---- Log Function ----
# Log function to prefix messages with timestamps.
log() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

# ---- Apt Locks Function ----
# Waits for all apt/dpkg locks to be released with a timeout. Avoid conflicts if another process (like unattended-upgrades) is running.
wait_for_apt_locks() {
  log "Waiting for apt/dpkg locks (timeout: ${LOCK_WAIT_SECONDS}s) ..."
  # Polls every 15 seconds to check if any of the common apt/dpkg lock files are in use.
  # bash -c runs the loop in a separate subshell so it can be terminated by timeout.
  timeout "${LOCK_WAIT_SECONDS}" bash -c '
    set -e
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "[$(date -Is)] apt/dpkg busy; sleeping 15s..."
      sleep 15
    done
  '
  log "Apt/dpkg locks cleared."
}

# ---- Run Wrapper Logging Function ----
# Wrapper function that logs each command before and after running it, including the exit code.
run() {
  log ">>> $*"
  "$@"
  log "<<< exit=$?"
}

# ---- Error Function ----
# Called whenever a command fails (due to set -e)
# Logs exit code, the command that failed, and the log file location before exiting with the same code.
on_error() {
  local ec=$?
  log "ERROR: Script failed (exit=${ec}). Last command: ${BASH_COMMAND}"
  log "Log file: ${LOG_FILE}"
  exit "$ec"
}
trap on_error ERR

# ************************
# ---- Start of Script----
# ************************

# Kicks off the logging process and records basic system information.
log "=== Weekly maintenance START ==="
log "Host: $(hostnamectl --static 2>/dev/null || hostname)"
log "Uptime: $(uptime -p || true)"
log "Kernel: $(uname -r)"

# Prevents interactive prompts due to being an unattended script.
export DEBIAN_FRONTEND=noninteractive

# Begins apt lock wait.
wait_for_apt_locks

# Package downloads, installation and cleanup/removal.
run apt-get update
run apt-get -y upgrade
run apt-get -y full-upgrade
run apt-get -y autoremove --purge
run apt-get -y autoclean

# Rebuilds initramfs for all installed kernels and updates grub configuration.
# Ensures proper setup for next boot as this script ends in a reboot.
run update-initramfs -u -k all
run update-grub

# This simply records if a reboot was required after updates. The script will reboot anyways.
if [[ -f /var/run/reboot-required ]]; then
  log "Reboot-required file present:"
  cat /var/run/reboot-required || true
  [[ -f /var/run/reboot-required.pkgs ]] && { log "Packages requiring reboot:"; cat /var/run/reboot-required.pkgs || true; }
else
  log "No /var/run/reboot-required file present."
fi

# TRIM command for SSDs to optimize performance and longevity.
run fstrim -av
# Cleans temporary files.
run systemd-tmpfiles --clean

# Log systemd units in a failed state. || true prevents ERR trap if there are no failed services.
log "Failed services (if any):"
systemctl --failed || true

# Log disk usage.
log "Disk usage:"
df -h || true

# Flush pending writes and sync disks before rebooting.
run sync

# ---- Logging and reboot ----
# END variables are set here and subtract START variables to get total runtime.
log "=== Weekly maintenance COMPLETE — rebooting now ==="
log "Log file: ${LOG_FILE}"
END_TIME_EPOCH=$(date +%s)
END_TIME_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
ELAPSED_SECONDS=$((END_TIME_EPOCH - START_TIME_EPOCH))

# Format time taken.
ELAPSED_FMT=$(printf '%02dh:%02dm:%02ds\n' \
  $((ELAPSED_SECONDS/3600)) \
  $(((ELAPSED_SECONDS%3600)/60)) \
  $((ELAPSED_SECONDS%60))
)

log "=== Runtime Summary ==="
log "Started : ${START_TIME_HUMAN}"
log "Finished: ${END_TIME_HUMAN}"
log "Total runtime: ${ELAPSED_FMT}"

# Final command to reboot the system
shutdown -r now

# ***********************
# ---- End of Script ----
# ***********************