#!/usr/bin/env bash
# === KaChat self-hosted cloud: Nextcloud + Portainer + Nginx Proxy Manager ===
# Wrapped in a function so any fatal step can stop cleanly without closing your terminal.
kachat_install() {
  KC_DIR="$HOME/kachat-cloud"; mkdir -p "$KC_DIR"; cd "$KC_DIR" || return 1
  OS="$(uname)"

  # 1) Make sure Docker is installed
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed."
  elif [ "$OS" = "Darwin" ]; then
    echo "Docker not found — installing Docker Desktop (Homebrew)..."
    command -v brew >/dev/null 2>&1 || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install --cask docker && open -a Docker
  else
    echo "Docker not found — installing..."
    # get.docker.com needs curl; install it first if missing
    if ! command -v curl >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y curl \
        || sudo dnf install -y curl || sudo yum install -y curl \
        || sudo pacman -Sy --noconfirm curl || sudo zypper install -y curl || true
    fi
    # Official installer — run as ROOT so its package step can't stall on a hidden sudo prompt
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sudo sh /tmp/get-docker.sh
    # Fallback to the distro's own package if the convenience script didn't land a working docker
    if ! command -v docker >/dev/null 2>&1; then
      echo "Convenience script didn't install Docker — trying the distro package..."
      sudo apt-get update && sudo apt-get install -y docker.io \
        || sudo dnf install -y docker || sudo yum install -y docker \
        || sudo pacman -Sy --noconfirm docker || sudo zypper install -y docker || true
    fi
    sudo usermod -aG docker "$USER" 2>/dev/null || true
  fi

  # Stop here (cleanly) if Docker still isn't present
  if ! command -v docker >/dev/null 2>&1; then
    echo "!! Docker could not be installed automatically."
    echo "   Install it manually from https://docs.docker.com/engine/install/ then run this block again."
    return 1
  fi

  # 2) Start the engine and wait until it actually responds
  if [ "$OS" != "Darwin" ]; then
    sudo systemctl enable --now docker 2>/dev/null || sudo service docker start 2>/dev/null || true
  fi
  echo "Waiting for the Docker engine to be ready..."
  tries=0
  until docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    [ "$tries" -eq 20 ] && echo "Still waiting — in another terminal check:  sudo systemctl status docker   (WSL:  sudo service docker start)"
    if [ "$tries" -ge 60 ]; then
      echo "!! Docker engine did not become ready. Start it with the hint above, then run this block again."
      return 1
    fi
    sleep 3
  done
  if docker info >/dev/null 2>&1; then DK="docker"; else DK="sudo docker"; fi
  echo "Docker engine is ready."

  # 2b) Ensure Docker Compose v2 — the distro 'docker.io' package ships without it
  if [ "$OS" != "Darwin" ] && ! $DK compose version >/dev/null 2>&1; then
    echo "Installing Docker Compose v2..."
    sudo apt-get install -y docker-compose-v2 2>/dev/null \
      || sudo apt-get install -y docker-compose-plugin 2>/dev/null \
      || sudo dnf install -y docker-compose-plugin 2>/dev/null \
      || sudo pacman -Sy --noconfirm docker-compose 2>/dev/null || true
    # last resort: drop the official compose plugin binary in place
    if ! $DK compose version >/dev/null 2>&1; then
      sudo mkdir -p /usr/local/lib/docker/cli-plugins
      sudo curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose && sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
  fi
  if ! $DK compose version >/dev/null 2>&1; then
    echo "!! Docker Compose v2 is unavailable and could not be installed."
    echo "   See https://docs.docker.com/compose/install/ then run this block again."
    return 1
  fi

  # 3) Generate secrets and detect this machine's LAN IP
  gen() { openssl rand -hex 16; }
  LAN_IP=$( (ipconfig getifaddr en0 2>/dev/null) || (hostname -I 2>/dev/null | awk '{print $1}') || echo 127.0.0.1 )
  if [ ! -f .env ]; then cat > .env <<EOF
DB_ROOT_PASSWORD=$(gen)
DB_PASSWORD=$(gen)
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=$(gen)
IMAGINARY_SECRET=$(gen)
NC_TRUSTED_DOMAINS=localhost 127.0.0.1 ${LAN_IP}
DUCKDNS_SUBDOMAIN=changeme
DUCKDNS_TOKEN=changeme
EOF
  fi

  # 4) Custom Nextcloud image with ffmpeg (needed for video thumbnails)
  cat > Dockerfile.nextcloud <<'EOF'
FROM nextcloud:stable
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
EOF

  # 5) The stack
  cat > docker-compose.yml <<'EOF'
name: kachat-cloud
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports: ["80:80", "443:443", "81:81"]
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    networks: [cloud]
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks: [cloud]
  nextcloud-db:
    image: mariadb:10.11
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes: ["nextcloud_db:/var/lib/mysql"]
    networks: [cloud]
  nextcloud-redis:
    image: redis:7-alpine
    restart: unless-stopped
    networks: [cloud]
  imaginary:
    image: nextcloud/aio-imaginary:latest
    restart: unless-stopped
    cap_add: ["SYS_NICE"]
    environment:
      IMAGINARY_SECRET: ${IMAGINARY_SECRET}
    networks: [cloud]
  nextcloud:
    build:
      context: .
      dockerfile: Dockerfile.nextcloud
    restart: unless-stopped
    ports: ["8080:80"]
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${DB_PASSWORD}
      REDIS_HOST: nextcloud-redis
      NEXTCLOUD_ADMIN_USER: ${NC_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NC_TRUSTED_DOMAINS}
      TRUSTED_PROXIES: 172.16.0.0/12
    depends_on: [nextcloud-db, nextcloud-redis, imaginary]
    volumes: ["nextcloud_data:/var/www/html"]
    networks: [cloud]
  duckdns:
    image: linuxserver/duckdns:latest
    restart: unless-stopped
    profiles: [public]
    environment:
      SUBDOMAINS: ${DUCKDNS_SUBDOMAIN}
      TOKEN: ${DUCKDNS_TOKEN}
    networks: [cloud]
volumes:
  npm_data:
  npm_letsencrypt:
  portainer_data:
  nextcloud_db:
  nextcloud_data:
networks:
  cloud:
EOF

  # 6) Build and start
  if ! $DK compose up -d --build; then
    echo ""
    echo "!! Build or start failed — scroll up to read the error, fix it, then run this block again."
    return 1
  fi

  # 7) Wait for first-time setup, then switch on photo/video previews
  echo "Waiting for Nextcloud to finish first-time setup (can take a few minutes)..."
  tries=0
  until $DK compose exec -T -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; do
    tries=$((tries+1)); [ "$tries" -gt 120 ] && { echo "Timed out waiting for setup; check: $DK compose logs nextcloud"; break; }
    sleep 5
  done
  SECRET=$(grep IMAGINARY_SECRET .env | cut -d= -f2)
  occ() { $DK compose exec -T -u www-data nextcloud php occ "$@"; }
  occ config:system:set enable_previews --value=true --type=boolean
  occ config:system:set preview_max_x --value=2048
  occ config:system:set preview_max_y --value=2048
  occ config:system:set preview_imaginary_url --value=http://imaginary:9000
  occ config:system:set preview_imaginary_key --value="$SECRET"
  occ config:system:delete enabledPreviewProviders 2>/dev/null || true
  occ config:system:set enabledPreviewProviders 0 --value='OC\Preview\Imaginary'
  occ config:system:set enabledPreviewProviders 1 --value='OC\Preview\Movie'
  occ config:system:set enabledPreviewProviders 2 --value='OC\Preview\MP4'
  occ config:system:set enabledPreviewProviders 3 --value='OC\Preview\MOV'
  occ config:system:set enabledPreviewProviders 4 --value='OC\Preview\MKV'
  occ config:system:set enabledPreviewProviders 5 --value='OC\Preview\AVI'
  occ app:install previewgenerator 2>/dev/null || occ app:enable previewgenerator 2>/dev/null || true

  echo ""
  echo "================ KaChat cloud is ready ================"
  echo "Nextcloud            ->  http://${LAN_IP}:8080"
  echo "Nginx Proxy Manager  ->  http://${LAN_IP}:81   (first login: admin@example.com / changeme)"
  echo "Portainer            ->  https://${LAN_IP}:9443 (create your admin user within 5 min)"
  echo ""
  echo "Your Nextcloud admin username/password is saved in:  ${KC_DIR}/.env"
  echo "======================================================"
}
kachat_install
