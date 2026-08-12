#!/usr/bin/env bash
# === KaChat self-hosted cloud: full uninstall ===
# Removes the KaChat cloud stack (containers, volumes, images), the ~/kachat-cloud
# folder, and Docker itself — reverting everything the setup put on this machine.
echo "This removes the KaChat cloud, ALL its data, and Docker itself."
KC_DIR="$HOME/kachat-cloud"
OS="$(uname)"

# Pick a working docker command (with or without sudo), if Docker is present
if docker info >/dev/null 2>&1; then DK="docker"
elif sudo docker info >/dev/null 2>&1; then DK="sudo docker"
else DK=""; fi

# 1) Tear the stack down and remove its images/volumes, then clear leftovers
if [ -n "$DK" ]; then
  [ -d "$KC_DIR" ] && ( cd "$KC_DIR" && $DK compose --profile public down -v --rmi all --remove-orphans )
  $DK system prune -af --volumes
fi
rm -rf "$KC_DIR"

# 2) Uninstall Docker itself
if [ "$OS" = "Darwin" ]; then
  osascript -e 'quit app "Docker"' 2>/dev/null || true
  command -v brew >/dev/null 2>&1 && { brew uninstall --cask docker 2>/dev/null || brew uninstall --cask docker-desktop 2>/dev/null; }
  rm -rf "$HOME/Library/Group Containers/group.com.docker" "$HOME/Library/Containers/com.docker.docker" "$HOME/.docker" 2>/dev/null || true
else
  sudo systemctl stop docker docker.socket 2>/dev/null || true
  sudo apt-get purge -y docker.io docker-ce docker-ce-cli containerd.io docker-compose-v2 docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras 2>/dev/null
  command -v dnf >/dev/null 2>&1 && sudo dnf remove -y docker docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null
  command -v pacman >/dev/null 2>&1 && sudo pacman -Rns --noconfirm docker docker-compose 2>/dev/null
  sudo apt-get autoremove -y 2>/dev/null
  sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker "$HOME/.docker" /usr/local/lib/docker 2>/dev/null || true
fi

echo ""
echo "Done — KaChat cloud and Docker have been removed from this machine."
