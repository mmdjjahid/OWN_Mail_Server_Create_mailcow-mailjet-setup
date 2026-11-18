#!/usr/bin/env bash
# =============================================================================
# install-mailcow.sh - Ubuntu/Debian server-e Mailcow (Docker) auto install
#
# Run:
#   sudo MAIL_HOSTNAME=mail.example.com TZ_NAME=Asia/Dhaka bash install-mailcow.sh
# Ba:
#   sudo bash install-mailcow.sh      (hostname jiggesh korbe)
#
# Ki kore:
#   1. Check (root, OS, RAM, port, DNS)
#   2. Update, hostname, swap
#   3. Docker + Compose install
#   4. Mailcow clone, config generate, pull, start
# Idempotent: abar run korle already-kora step skip hoy.
# =============================================================================
set -euo pipefail

MAIL_HOSTNAME="${MAIL_HOSTNAME:-}"
TZ_NAME="${TZ_NAME:-Asia/Dhaka}"
INSTALL_DIR="${INSTALL_DIR:-/opt/mailcow-dockerized}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-1}"
MIN_RAM_MB=5800

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 1. Pre-checks ----------
[ "$(id -u)" -eq 0 ] || die "root hisebe run korun: sudo bash $0"

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Shudhu Ubuntu/Debian support kore (apnar OS: ${ID:-unknown})" ;;
esac

if [ -z "$MAIL_HOSTNAME" ]; then
  read -rp "Mail server hostname (jemon mail.example.com): " MAIL_HOSTNAME
fi
[[ "$MAIL_HOSTNAME" == *.*.* || "$MAIL_HOSTNAME" == *.* ]] || die "Hostname FQDN hote hobe (jemon mail.example.com)"

# Virtualization: LXC container-e Mailcow cholbe na
if command -v systemd-detect-virt >/dev/null 2>&1; then
  virt="$(systemd-detect-virt || true)"
  case "$virt" in
    lxc|openvz) die "Eta $virt container. Mailcow-er jonno KVM VM lagbe." ;;
  esac
fi

ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$ram_mb" -lt "$MIN_RAM_MB" ]; then
  warn "RAM ${ram_mb} MB; Mailcow-er jonno komporkhe ~6 GiB dorkar. Cholte pare kintu ClamAV bondho rakhte hote pare."
fi

disk_free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$disk_free_gb" -ge 20 ] || die "Disk-e ${disk_free_gb} GB faka; komporkhe 20 GB lagbe."

# Port dokhol check
log "Port check (25, 80, 143, 443, 465, 587, 993, 995, 4190)"
busy=0
for p in 25 80 143 443 465 587 993 995 4190; do
  if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
    warn "Port $p already dokhol kora: $(ss -ltnpH "sport = :$p" | head -1 | awk '{print $NF}')"
    busy=1
  fi
done
if [ "$busy" -eq 1 ]; then
  warn "Upore dekha service (nginx/apache/postfix ityadi) bondho na korle Mailcow start hobe na."
  warn "Bondho korte: systemctl disable --now nginx apache2 postfix"
  read -rp "Ei service-gulo ekhon bondho (stop+disable) korte chan? [y/N] " ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    for s in nginx apache2 postfix exim4 sendmail; do
      if systemctl list-unit-files | grep -q "^$s.service"; then
        systemctl disable --now "$s" || true
      fi
    done
  else
    die "Port khali kore abar run korun."
  fi
fi

# DNS check (warning only)
pub_ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
dns_ip="$(getent ahostsv4 "$MAIL_HOSTNAME" 2>/dev/null | awk '{print $1; exit}' || true)"
if [ -z "$dns_ip" ]; then
  warn "$MAIL_HOSTNAME-er A record ekhono resolve hocche na. Cloudflare-e A record (DNS only) din; na hole SSL certificate ashbe na."
elif [ -n "$pub_ip" ] && [ "$dns_ip" != "$pub_ip" ]; then
  warn "$MAIL_HOSTNAME -> $dns_ip, kintu ei server-er public IP $pub_ip (NAT/router-er pechone hole eta sabhabik)."
fi

# UFW / firewalld warning
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  warn "UFW active. Docker-er shathe songhorsho hote pare; Mailcow docs onujayi bondho rakha bhalo (ufw disable)."
fi

# ---------- 2. Base system ----------
log "System update + dorkari package"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl git ca-certificates gnupg openssl jq lsb-release \
  apt-transport-https chrony

systemctl enable --now chrony >/dev/null 2>&1 || true
timedatectl set-timezone "$TZ_NAME" || warn "Timezone set hoyni: $TZ_NAME"
timedatectl set-ntp true || true

log "Hostname set: $MAIL_HOSTNAME"
hostnamectl set-hostname "$MAIL_HOSTNAME"
if ! grep -q "$MAIL_HOSTNAME" /etc/hosts; then
  echo "127.0.1.1 $MAIL_HOSTNAME ${MAIL_HOSTNAME%%.*}" >> /etc/hosts
fi

# Swap
if ! swapon --show | grep -q .; then
  log "${SWAP_SIZE_GB} GiB swap toiri"
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  log "Swap already ache, skip"
fi

# ---------- 3. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker install"
  curl -fsSL https://get.docker.com | sh
else
  log "Docker already install kora ache, skip"
fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || die "docker compose v2 paoa jayni. Docker apt repo diye docker-compose-plugin install korun."

# ---------- 4. Mailcow ----------
if [ ! -d "$INSTALL_DIR/.git" ]; then
  log "Mailcow clone -> $INSTALL_DIR"
  umask 0022
  git clone https://github.com/mailcow/mailcow-dockerized "$INSTALL_DIR"
else
  log "Mailcow already clone kora ache, skip"
fi

cd "$INSTALL_DIR"

if [ ! -f mailcow.conf ]; then
  log "mailcow.conf generate"
  MAILCOW_HOSTNAME="$MAIL_HOSTNAME" MAILCOW_TZ="$TZ_NAME" MAILCOW_BRANCH="master" \
    ./generate_config.sh
  # Kom RAM hole ClamAV/FTS bondho
  if [ "$ram_mb" -lt "$MIN_RAM_MB" ]; then
    warn "Kom RAM, tai SKIP_CLAMD=y ebong SKIP_FTS=y set kora holo"
    sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    sed -i 's/^SKIP_FTS=.*/SKIP_FTS=y/' mailcow.conf
  fi
else
  log "mailcow.conf already ache, skip"
fi

log "Docker image pull (kichhu minute lagte pare)"
docker compose pull

log "Mailcow start"
docker compose up -d

log "Container status"
sleep 20
docker compose ps

# ---------- 5. Summary ----------
cat <<EOF

=============================================================
 Mailcow install shesh.

 Admin panel : https://$MAIL_HOSTNAME/admin
 Default login: admin / moohoo     <-- ekhoni password bodlan + 2FA on korun!
 User/SOGo   : https://$MAIL_HOSTNAME/SOGo
 Folder      : $INSTALL_DIR

 Ekhon baki kaj:
  1. Router-e port forward: 25, 80, 443, 465, 587, 993 -> $(hostname -I | awk '{print $1}')
  2. Cloudflare-e DNS (DNS only, proxy off): A, MX, SPF, DKIM, DMARC
  3. Mailjet relay set kore Mailcow-e Sender-dependent transport assign
  4. SSL certificate dekhte:
       cd $INSTALL_DIR && docker compose logs --tail=20 acme-mailcow
=============================================================
EOF
