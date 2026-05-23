#!/usr/bin/env bash

set -euo pipefail

SYSTEMD_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/media-stack/config"
NAS_ROOT="/mnt/nas"

SERVICES=(
  jellyfin
  sonarr
  radarr
  prowlarr
  bazarr
  qbittorrent
  seerr
)

LEGACY_SERVICES=(
  jellyseerr
)

echo "Creating folders..."

mkdir -p "$SYSTEMD_DIR"

mkdir -p "$CONFIG_DIR"/{jellyfin,sonarr,radarr,prowlarr,bazarr,qbittorrent,seerr,lidarr,readarr}

if [ -d "$CONFIG_DIR/jellyseerr" ] && [ -z "$(find "$CONFIG_DIR/seerr" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  echo "Copying existing Jellyseerr config to Seerr..."
  cp -a "$CONFIG_DIR/jellyseerr"/. "$CONFIG_DIR/seerr"/
fi

chown -R 1000:1000 "$CONFIG_DIR/seerr" || true

mkdir -p "$NAS_ROOT/media"/{movies,tv,music,books}
mkdir -p "$NAS_ROOT/downloads"/{complete,incomplete}
mkdir -p "$NAS_ROOT/downloads/complete"/{movies,tv}

echo "Writing Quadlet network..."

cat > "$SYSTEMD_DIR/media.network" <<'EOF'
[Network]
NetworkName=media
EOF

echo "Writing Jellyfin Quadlet..."

cat > "$SYSTEMD_DIR/jellyfin.container" <<'EOF'
[Unit]
Description=Jellyfin Media Server
After=media-network.service
Requires=media-network.service

[Container]
Image=docker.io/jellyfin/jellyfin:latest
ContainerName=jellyfin
Network=media.network

PublishPort=8096:8096

Volume=%h/media-stack/config/jellyfin:/config:Z
Volume=/mnt/nas/media:/media:Z
Volume=/mnt/nas/downloads:/downloads:Z

Environment=TZ=Pacific/Auckland

# Intel/AMD GPU
AddDevice=/dev/dri:/dev/dri

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Sonarr Quadlet..."

cat > "$SYSTEMD_DIR/sonarr.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=lscr.io/linuxserver/sonarr:latest
ContainerName=sonarr
Network=media.network
PublishPort=8989:8989
User=1000:0

Environment=PUID=1000
Environment=PGID=0
Environment=TZ=Pacific/Auckland

Volume=%h/media-stack/config/sonarr:/config:z
Volume=/mnt/nas/media/tv:/tv
Volume=/mnt/nas/downloads:/downloads

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Radarr Quadlet..."

cat > "$SYSTEMD_DIR/radarr.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=lscr.io/linuxserver/radarr:latest
ContainerName=radarr
Network=media.network
PublishPort=7878:7878

Environment=PUID=1000
Environment=PGID=0
Environment=TZ=Pacific/Auckland

Volume=%h/media-stack/config/radarr:/config:z
Volume=/mnt/nas/media/movies:/movies
Volume=/mnt/nas/downloads:/downloads

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Prowlarr Quadlet..."

cat > "$SYSTEMD_DIR/prowlarr.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=lscr.io/linuxserver/prowlarr:latest
ContainerName=prowlarr
Network=media.network
PublishPort=9696:9696

Environment=PUID=1000
Environment=PGID=0
Environment=TZ=Pacific/Auckland

Volume=%h/media-stack/config/prowlarr:/config:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Bazarr Quadlet..."

cat > "$SYSTEMD_DIR/bazarr.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=lscr.io/linuxserver/bazarr:latest
ContainerName=bazarr
Network=media.network
PublishPort=6767:6767

Environment=PUID=1000
Environment=PGID=0
Environment=TZ=Pacific/Auckland

Volume=%h/media-stack/config/bazarr:/config:Z
Volume=/mnt/nas/media/movies:/movies:Z
Volume=/mnt/nas/media/tv:/tv:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing qBittorrent Quadlet..."

cat > "$SYSTEMD_DIR/qbittorrent.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=lscr.io/linuxserver/qbittorrent:latest
ContainerName=qbittorrent
Network=media.network

PublishPort=8080:8080
PublishPort=6881:6881
PublishPort=6881:6881/udp

Environment=PUID=1000
Environment=PGID=0
Environment=TZ=Pacific/Auckland
Environment=WEBUI_PORT=8080

Volume=%h/media-stack/config/qbittorrent:/config:Z
Volume=/mnt/nas/downloads:/downloads:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Seerr Quadlet..."

cat > "$SYSTEMD_DIR/seerr.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=ghcr.io/seerr-team/seerr:latest
ContainerName=seerr
Network=media.network
UserNS=keep-id
PublishPort=5055:5055
PodmanArgs=--init

Environment=TZ=Pacific/Auckland
Environment=LOG_LEVEL=info
Environment=PORT=5055

Volume=%h/media-stack/config/seerr:/app/config:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Reloading user systemd..."

systemctl --user daemon-reload

echo "Enabling linger..."

loginctl enable-linger "$USER" || true

echo "Starting network..."

systemctl --user start media-network.service || true

echo "Stopping legacy services..."

for service in "${LEGACY_SERVICES[@]}"; do
  systemctl --user stop "$service.service" 2>/dev/null || true
  systemctl --user disable "$service.service" 2>/dev/null || true
done

echo "Restarting services..."

for service in "${SERVICES[@]}"; do
  echo "Restarting $service..."
  systemctl --user restart "$service.service" || systemctl --user start "$service.service"
done

echo ""
echo "Testing NAS write access..."

if touch "$NAS_ROOT/media/movies/.write-test" 2>/dev/null; then
  rm -f "$NAS_ROOT/media/movies/.write-test"
  echo "NAS movies folder writable: OK"
else
  echo "WARNING: Cannot write to $NAS_ROOT/media/movies"
fi

if touch "$NAS_ROOT/downloads/.write-test" 2>/dev/null; then
  rm -f "$NAS_ROOT/downloads/.write-test"
  echo "NAS downloads folder writable: OK"
else
  echo "WARNING: Cannot write to $NAS_ROOT/downloads"
fi

echo ""
echo "Done."
echo ""
echo "Jellyfin:    http://localhost:8096"
echo "Sonarr:      http://localhost:8989"
echo "Radarr:      http://localhost:7878"
echo "Prowlarr:    http://localhost:9696"
echo "Bazarr:      http://localhost:6767"
echo "qBittorrent: http://localhost:8080"
echo "Seerr:       http://localhost:5055"
echo ""
echo "Check Radarr write test:"
echo "podman exec -it radarr touch /movies/test.txt"
