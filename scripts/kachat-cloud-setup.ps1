# === KaChat self-hosted cloud (Windows / PowerShell as Administrator) ===
$KC = "$HOME\kachat-cloud"; New-Item -ItemType Directory -Force -Path $KC | Out-Null; Set-Location $KC

# 1) Install Docker Desktop if missing
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
  Write-Host "Docker Desktop installed. Launch it from the Start Menu, finish first-run setup, then paste this block again." -ForegroundColor Yellow
  return
}
Write-Host "Waiting for the Docker engine to be ready..."
while (-not (docker info 2>$null)) { Start-Sleep 3 }

# 2) Secrets + LAN IP
function Gen { -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
$LAN = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } | Select-Object -First 1).IPAddress
if (-not $LAN) { $LAN = "127.0.0.1" }
if (-not (Test-Path .env)) {
@"
DB_ROOT_PASSWORD=$(Gen)
DB_PASSWORD=$(Gen)
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=$(Gen)
IMAGINARY_SECRET=$(Gen)
NC_TRUSTED_DOMAINS=localhost 127.0.0.1 $LAN
DUCKDNS_SUBDOMAIN=changeme
DUCKDNS_TOKEN=changeme
"@ | Set-Content -Encoding ASCII .env
}

# 3) Custom Nextcloud image with ffmpeg (needed for video thumbnails)
@'
FROM nextcloud:stable
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
'@ | Set-Content -Encoding ASCII Dockerfile.nextcloud

# 4) The stack
@'
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
      - //var/run/docker.sock:/var/run/docker.sock
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
'@ | Set-Content -Encoding ASCII docker-compose.yml

# 5) Build and start (only continue to preview setup if this succeeds)
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
  Write-Host "!! Build or start failed — scroll up to read the error, fix it, then paste this block again." -ForegroundColor Yellow
} else {

# 6) Wait for setup, then switch on photo/video previews
Write-Host "Waiting for Nextcloud to finish first-time setup (can take a few minutes)..."
$tries = 0
do { Start-Sleep 5; $tries++; $st = docker compose exec -T -u www-data nextcloud php occ status 2>$null } until ($st -match "installed: true" -or $tries -gt 120)
$SECRET = (Select-String -Path .env -Pattern 'IMAGINARY_SECRET=(.*)').Matches.Groups[1].Value
function occ { docker compose exec -T -u www-data nextcloud php occ @args }
occ config:system:set enable_previews --value=true --type=boolean
occ config:system:set preview_max_x --value=2048
occ config:system:set preview_max_y --value=2048
occ config:system:set preview_imaginary_url --value=http://imaginary:9000
occ config:system:set preview_imaginary_key --value="$SECRET"
occ config:system:delete enabledPreviewProviders 2>$null
occ config:system:set enabledPreviewProviders 0 --value='OC\Preview\Imaginary'
occ config:system:set enabledPreviewProviders 1 --value='OC\Preview\Movie'
occ config:system:set enabledPreviewProviders 2 --value='OC\Preview\MP4'
occ config:system:set enabledPreviewProviders 3 --value='OC\Preview\MOV'
occ config:system:set enabledPreviewProviders 4 --value='OC\Preview\MKV'
occ config:system:set enabledPreviewProviders 5 --value='OC\Preview\AVI'
occ app:install previewgenerator 2>$null

Write-Host ""
Write-Host "================ KaChat cloud is ready ================"
Write-Host "Nextcloud            ->  http://$LAN:8080"
Write-Host "Nginx Proxy Manager  ->  http://$LAN:81   (first login: admin@example.com / changeme)"
Write-Host "Portainer            ->  https://$LAN:9443 (create your admin user within 5 min)"
Write-Host ""
Write-Host "Your Nextcloud admin username/password is saved in:  $KC\.env"
Write-Host "======================================================"
}
