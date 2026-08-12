# === KaChat self-hosted cloud: full uninstall (Windows / PowerShell as Administrator) ===
# Removes the KaChat cloud stack (containers, volumes, images), the kachat-cloud
# folder, and Docker Desktop — reverting everything the setup put on this machine.
Write-Host "This removes the KaChat cloud, ALL its data, and Docker Desktop."
$KC = "$HOME\kachat-cloud"

# 1) Tear the stack down and clear leftovers (only if Docker is present)
if (Get-Command docker -ErrorAction SilentlyContinue) {
  if (Test-Path $KC) {
    Push-Location $KC
    docker compose --profile public down -v --rmi all --remove-orphans 2>$null
    Pop-Location
  }
  docker system prune -af --volumes 2>$null
}
Remove-Item -Recurse -Force $KC -ErrorAction SilentlyContinue

# 2) Uninstall Docker Desktop
winget uninstall -e --id Docker.DockerDesktop --accept-source-agreements 2>$null

Write-Host ""
Write-Host "Done — KaChat cloud and Docker Desktop have been removed from this machine."
