#!/usr/bin/env bash
# AISTVM: prepare this codespace as a Windows VM host.
# Runs unattended. Never prints passwords, keys or tokens.
set -uo pipefail

STATUS_DIR=".aistvm"
STATUS_FILE="${STATUS_DIR}/status.json"
LOG_FILE="${STATUS_DIR}/setup.log"
mkdir -p "${STATUS_DIR}"
: > "${LOG_FILE}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${LOG_FILE}"; }

# The app polls this file through the GitHub Contents API, so it must be pushed.
publish_status() {
  git add "${STATUS_FILE}" >/dev/null 2>&1 || return 0
  git -c user.email=aistvm@users.noreply.github.com -c user.name=AISTVM \
    commit -q -m "AISTVM: $1" >/dev/null 2>&1 || return 0
  git push -q origin HEAD >>"${LOG_FILE}" 2>&1 || log "status push failed (will retry on next write)"
}

write_status() {
  # $1 state, $2 tailscale ip, $3 error text (empty when fine)
  local state="$1" ip="$2" err="$3"
  cat > "${STATUS_FILE}" <<JSON
{"state":"${state}","ip":"${ip}","error":"${err}","user":"aistvm","updatedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
  publish_status "${state}"
}

fail() {
  log "FAILED: $*"
  write_status failed "" "$*"
  exit 1
}

# Run from the repository root so the status file lands next to the script.
cd "$(dirname "$0")/.." || exit 1

write_status starting "" ""

# --- 0. Idle-timeout keepalive --------------------------------------------
# Started before the long Windows download so the codespace is not stopped
# while the VM is still being set up. Best-effort; see keepalive.sh.
KEEPALIVE="${STATUS_DIR}/keepalive.sh"
if [ -f "${KEEPALIVE}" ]; then
  bash "${KEEPALIVE}" >>"${LOG_FILE}" 2>&1 || log "keepalive start failed"
fi

# --- 1. Mount the workspace volume at /mnt/data ---------------------------
mount_data() {
  local dev
  dev=$(lsblk -rno NAME,SIZE,TYPE | awk '$3=="part" && $2+0>=300 {print "/dev/"$1; exit}')
  sudo mkdir -p /mnt/data
  if [ -n "${dev}" ]; then
    log "data partition: ${dev}"
    if mountpoint -q /mnt/data; then
      log "/mnt/data already mounted"
    else
      sudo mount "${dev}" /mnt/data || return 1
      grep -qF "/mnt/data" /etc/fstab || echo "UUID=$(sudo blkid -s UUID -o value ${dev}) /mnt/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
    fi
  else
    # No large partition: keep a persistent loopback image on the codespace disk.
    local img="/workspaces/.aistvm-data.img"
    log "no large partition; using loopback image ${img}"
    if [ ! -f "${img}" ]; then
      sudo fallocate -l 100G "${img}" || sudo dd if=/dev/zero of="${img}" bs=1M count=102400 status=none || return 1
      sudo mkfs.ext4 -q -F "${img}" || return 1
    fi
    mountpoint -q /mnt/data || sudo mount -o loop "${img}" /mnt/data || return 1
  fi
  sudo chown -R codespace:codespace /mnt/data 2>/dev/null || true
  df -h /mnt/data | tail -1 >>"${LOG_FILE}"
}

mount_data || fail "khong mount duoc /mnt/data"

# --- 2. Swap on /tmp so the VM keeps real RAM ------------------------------
setup_swap() {
  local want_kb=$((12 * 1024 * 1024))
  local avail_kb cap_kb
  avail_kb=$(df --output=avail -k /tmp | tail -1)
  cap_kb=$(( avail_kb * 80 / 100 ))
  [ "${want_kb}" -gt "${cap_kb}" ] && want_kb="${cap_kb}"
  log "swap size: $((want_kb / 1024 / 1024)) GiB"
  sudo swapoff /tmp/vmswap 2>/dev/null || true
  rm -f /tmp/vmswap
  sudo fallocate -l "${want_kb}K" /tmp/vmswap || sudo dd if=/dev/zero of=/tmp/vmswap bs=1M count=$((want_kb / 1024)) status=none || return 1
  sudo chmod 600 /tmp/vmswap
  sudo mkswap /tmp/vmswap >/dev/null || return 1
  sudo swapon /tmp/vmswap || return 1
  sudo sysctl -w vm.swappiness=100 >/dev/null || true
}

setup_swap || fail "khong tao duoc swap"

# --- 3. KVM device permissions --------------------------------------------
# /dev/kvm is root:<kvm-gid> 660 and the container's root still needs the read
# bit widened, so open it up explicitly.
sudo chmod 666 /dev/kvm 2>/dev/null || log "no /dev/kvm (VM will be slow without KVM)"

# --- 4. Windows container --------------------------------------------------
if [ -z "${AISTVM_WIN_PASSWORD:-}" ]; then
  fail "thieu mat khau Windows"
fi

docker rm -f windows >/dev/null 2>&1 || true
docker run -d --name windows --restart unless-stopped \
  --oom-score-adj=-1000 \
  -e VERSION=11 -e CPU_CORES=4 -e RAM_SIZE=12G -e DISK_SIZE=500G \
  -e USERNAME=aistvm -e PASSWORD="${AISTVM_WIN_PASSWORD}" \
  -v "/mnt/data:/storage" -v "/mnt/data/oem:/oem" \
  -p "8006:8006" -p "3389:3389" \
  --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 \
  dockurr/windows >>"${LOG_FILE}" 2>&1 || fail "khong chay duoc container Windows"
unset AISTVM_WIN_PASSWORD

# --- 5. Tailscale so the machine is reachable from anywhere ----------------
TS_IP=""
if [ -n "${AISTVM_TAILSCALE_AUTHKEY:-}" ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sudo sh >>"${LOG_FILE}" 2>&1 || log "tailscale install failed"
  fi
  if command -v tailscale >/dev/null 2>&1; then
    sudo tailscale up --authkey="${AISTVM_TAILSCALE_AUTHKEY}" --hostname="aistvm-win" --accept-routes --ssh >>"${LOG_FILE}" 2>&1 || log "tailscale up failed"
    for _ in $(seq 1 30); do
      TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
      [ -n "${TS_IP}" ] && break
      sleep 2
    done
  fi
  unset AISTVM_TAILSCALE_AUTHKEY
fi

# --- 6. Report ready -------------------------------------------------------
write_status ready "${TS_IP}" ""
log "ready; tailscale ip=${TS_IP:-none}"
