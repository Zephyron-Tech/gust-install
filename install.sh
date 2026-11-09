#!/usr/bin/env bash
# Gust installer. Published at https://get.zephyron.tech/gust
#
#   curl -fsSL https://get.zephyron.tech/gust | sudo bash
#
# Only the script is public. The Gust image stays private: the installer asks
# for a GitHub token with read:packages to pull it.
#
# The body runs inside main so that bash has read the whole file before the
# stdin redirect below; a piped script would otherwise read the rest from the
# terminal.
main() {
  # Piped from curl, stdin is the script itself: take the answers from the terminal.
  if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi
set -euo pipefail

export GUST_DIR="${GUST_DIR:-/opt/gust}"
GUST_IMAGE="${GUST_IMAGE:-ghcr.io/zephyron-tech/gust:latest}"
SKIP_SYSTEM="${GUST_SKIP_SYSTEM:-0}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

ask() { # ask VAR "Question" default [secret]
  local var="$1" q="$2" def="${3:-}" secret="${4:-}" val="${!1:-}"
  # Prompt only when the value was not given and someone is at the keyboard.
  if [ -z "$val" ] && [ -t 0 ]; then
    if [ -n "$secret" ]; then read -r -s -p "$q: " val; echo
    else read -r -p "$q${def:+ [$def]}: " val; fi
  fi
  val="${val:-$def}"
  printf -v "$var" '%s' "$val"
}

rand() { openssl rand -base64 "$1" | tr -d '\n'; }
randpw() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# Keeps a value already in .env, so running the script again changes nothing.
existing() { [ -f "$GUST_DIR/.env" ] && sed -n "s/^$1=//p" "$GUST_DIR/.env" | head -n1 | sed -e 's/^"//' -e 's/"$//' || true; }

if [ "$SKIP_SYSTEM" != 1 ]; then
  [ "$(id -u)" = 0 ] || die "Run as root: sudo bash install.sh"
  . /etc/os-release
  case "$ID" in debian | ubuntu) ;; *) die "Debian or Ubuntu only (found $ID)." ;; esac
fi

say "Gust installer"
ask GUST_DOMAIN "Gust domain" "$(existing GUST_DOMAIN | grep . || echo gust.zephyron.tech)"
ask REGISTRY_DOMAIN "Registry domain" "$(existing REGISTRY_DOMAIN | grep . || echo "registry.$GUST_DOMAIN")"
ask ACME_EMAIL "E-mail for Let's Encrypt" "$(existing ACME_EMAIL)"
[ -n "$ACME_EMAIL" ] || die "An e-mail for Let's Encrypt is required."
ask GHCR_USER "GitHub user for pulling the Gust image (empty: already logged in)" ""
GHCR_TOKEN="${GHCR_TOKEN:-}"
[ -n "$GHCR_USER" ] && ask GHCR_TOKEN "GitHub token with read:packages" "" secret
ask AUTHENTIK_ISSUER "Authentik issuer (empty: break-glass only)" "$(existing AUTHENTIK_ISSUER)"
AUTHENTIK_ISSUER="${AUTHENTIK_ISSUER:-}"
if [ -n "$AUTHENTIK_ISSUER" ]; then
  ask AUTHENTIK_CLIENT_ID "Authentik client ID" "$(existing AUTHENTIK_CLIENT_ID)"
  prev="$(existing AUTHENTIK_CLIENT_SECRET)"
  ask AUTHENTIK_CLIENT_SECRET "Authentik client secret${prev:+ (Enter keeps the current one)}" "" secret
  AUTHENTIK_CLIENT_SECRET="${AUTHENTIK_CLIENT_SECRET:-$prev}"
fi
ask GITHUB_APP_ID "GitHub App ID (empty: no commit statuses)" "$(existing GITHUB_APP_ID)"
GITHUB_APP_ID="${GITHUB_APP_ID:-}"
GITHUB_APP_KEY=""
if [ -n "$GITHUB_APP_ID" ]; then
  ask GITHUB_APP_KEY_FILE "Path to the GitHub App private key (.pem, Enter keeps the current one)" ""
  if [ -n "${GITHUB_APP_KEY_FILE:-}" ]; then
    [ -f "$GITHUB_APP_KEY_FILE" ] || die "No such file: $GITHUB_APP_KEY_FILE"
    GITHUB_APP_KEY="$(awk '{printf "%s\\n", $0}' "$GITHUB_APP_KEY_FILE")"
  else
    GITHUB_APP_KEY="$(existing GITHUB_APP_PRIVATE_KEY)"
  fi
fi
ask BREAK_GLASS_EMAIL "Break-glass admin e-mail" "$(existing BREAK_GLASS_EMAIL)"
BREAK_GLASS_EMAIL="${BREAK_GLASS_EMAIL:-admin@$GUST_DOMAIN}"

if [ "$SKIP_SYSTEM" != 1 ]; then
  say "System packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq ca-certificates curl openssl ufw unattended-upgrades cron gzip

  if ! command -v docker >/dev/null; then
    say "Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    echo '{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }' > /etc/docker/daemon.json
    systemctl restart docker
  fi
  systemctl enable --now docker

  say "Firewall: SSH, HTTP and HTTPS only"
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
fi

command -v docker >/dev/null || die "Docker is missing."

say "Checking DNS"
for d in "$GUST_DOMAIN" "$REGISTRY_DOMAIN"; do
  ip="$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -z "$ip" ]; then warn "  $d does not resolve yet. Certificates will follow once it points here."
  else echo "  $d -> $ip"; fi
done

say "Gust image"
mkdir -p "$GUST_DIR"
chmod 700 "$GUST_DIR"
if [ -n "$GHCR_TOKEN" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
fi
docker pull -q "$GUST_IMAGE" 2>/dev/null || docker image inspect "$GUST_IMAGE" >/dev/null 2>&1 || die "Cannot pull $GUST_IMAGE. Check the GitHub token."

say "Configuration in $GUST_DIR/.env"
pg="$(existing POSTGRES_PASSWORD)"
auth="$(existing BETTER_AUTH_SECRET)"
master="$(existing GUST_MASTER_KEY)"
engine="$(existing ENGINE_TOKEN)"
ci="$(existing REGISTRY_CI_PASSWORD)"
pull="$(existing REGISTRY_PULL_PASSWORD)"
bg="$(existing BREAK_GLASS_PASSWORD)"
umask 077
cat > "$GUST_DIR/.env" <<EOF
# Gust configuration, written by install.sh. Keep it private (chmod 600).
GUST_IMAGE=$GUST_IMAGE
GUST_DOMAIN=$GUST_DOMAIN
REGISTRY_DOMAIN=$REGISTRY_DOMAIN
ACME_EMAIL=$ACME_EMAIL

POSTGRES_PASSWORD=${pg:-$(randpw 32)}
BETTER_AUTH_SECRET=${auth:-$(rand 32)}
GUST_MASTER_KEY=${master:-$(rand 32)}
ENGINE_TOKEN=${engine:-$(randpw 40)}

REGISTRY_CI_PASSWORD=${ci:-$(randpw 32)}
REGISTRY_PULL_PASSWORD=${pull:-$(randpw 32)}

AUTHENTIK_ISSUER=$AUTHENTIK_ISSUER
AUTHENTIK_CLIENT_ID=${AUTHENTIK_CLIENT_ID:-}
AUTHENTIK_CLIENT_SECRET=${AUTHENTIK_CLIENT_SECRET:-}
GUST_ADMIN_GROUP=$(existing GUST_ADMIN_GROUP | grep . || echo gust-admin)

GITHUB_APP_ID=$GITHUB_APP_ID
GITHUB_APP_PRIVATE_KEY="$GITHUB_APP_KEY"
GITHUB_ALLOWED_OWNERS=$(existing GITHUB_ALLOWED_OWNERS | grep . || echo Zephyron-Tech)

BREAK_GLASS_EMAIL=$BREAK_GLASS_EMAIL
BREAK_GLASS_PASSWORD=${bg:-$(randpw 24)}
EOF
chmod 600 "$GUST_DIR/.env"

say "Files from the image"
cid="$(docker create "$GUST_IMAGE")"
mkdir -p "$GUST_DIR/traefik" "$GUST_DIR/zot" "$GUST_DIR/backups"
docker cp "$cid:/gust/infra/prod/compose.yml" "$GUST_DIR/compose.yml"
docker cp "$cid:/gust/infra/prod/traefik/dynamic.yml" "$GUST_DIR/traefik/dynamic.yml"
docker cp "$cid:/gust/infra/prod/zot/config.json" "$GUST_DIR/zot/config.json"
docker cp "$cid:/gust/infra/prod/gust" "$GUST_DIR/gust"
docker rm "$cid" >/dev/null
chmod +x "$GUST_DIR/gust"

say "Registry accounts"
htp() { docker run --rm httpd:2.4-alpine htpasswd -nbB "$1" "$2" | head -n1; }
{
  htp ci "$(sed -n 's/^REGISTRY_CI_PASSWORD=//p' "$GUST_DIR/.env")"
  htp gust "$(sed -n 's/^REGISTRY_PULL_PASSWORD=//p' "$GUST_DIR/.env")"
} > "$GUST_DIR/zot/htpasswd"
chmod 644 "$GUST_DIR/zot/htpasswd"

say "Starting Gust"
"$GUST_DIR/gust" up

printf 'Waiting for the web UI'
for _ in $(seq 1 60); do
  if (cd "$GUST_DIR" && docker compose exec -T web wget -qO /dev/null http://127.0.0.1:3100/login) 2>/dev/null; then ok=1; break; fi
  printf '.'; sleep 2
done
echo
[ "${ok:-}" = 1 ] || die "The web UI did not start. See: gust logs web"

"$GUST_DIR/gust" break-glass

if [ "$SKIP_SYSTEM" != 1 ]; then
  ln -sf "$GUST_DIR/gust" /usr/local/bin/gust
  echo "15 3 * * * root GUST_DIR=$GUST_DIR /usr/local/bin/gust backup >/dev/null 2>&1" > /etc/cron.d/gust-backup
fi

say "Gust is running"
cat <<EOF
  UI:           https://$GUST_DOMAIN
  Break-glass:  $BREAK_GLASS_EMAIL, password in $GUST_DIR/.env (BREAK_GLASS_PASSWORD)
  Registry:     https://$REGISTRY_DOMAIN

Next:
  1. Put the registry account into GitHub organisation secrets:  gust registry
  2. Add a project:  gust project add <slug> --repo Zephyron-Tech/<repo> --service web --port 3000 --domain <domain>
  3. Add the repository to the Zephyron Gust GitHub App installation and its deploy workflow (docs/github.md).

Backups run every night at 03:15 into $GUST_DIR/backups. Update Gust with: gust update
EOF
}
main "$@"
