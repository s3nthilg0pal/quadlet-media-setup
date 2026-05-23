#!/usr/bin/env bash

set -euo pipefail

SYSTEMD_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/media-stack/config"
CADDY_CONFIG_DIR="$CONFIG_DIR/caddy"

SERVICES=(
  caddy
)

echo "Creating Caddy folders..."

mkdir -p "$SYSTEMD_DIR"
mkdir -p "$CADDY_CONFIG_DIR"/{data,config,sites}

echo "Ensuring media Quadlet network exists..."

cat > "$SYSTEMD_DIR/media.network" <<'EOF'
[Network]
NetworkName=media
EOF

echo "Writing Caddy config..."

cat > "$CADDY_CONFIG_DIR/Caddyfile" <<'EOF'
{
	local_certs
}

import /etc/caddy/sites/*.caddy
EOF

cat > "$CADDY_CONFIG_DIR/sites/media.caddy" <<'EOF'
jellyfin.home.arpa {
	reverse_proxy jellyfin:8096
}

sonarr.home.arpa {
	reverse_proxy sonarr:8989
}

radarr.home.arpa {
	reverse_proxy radarr:7878
}

prowlarr.home.arpa {
	reverse_proxy prowlarr:9696
}

bazarr.home.arpa {
	reverse_proxy bazarr:6767
}

subgen.home.arpa {
	reverse_proxy subgen:9000
}

qbittorrent.home.arpa {
	reverse_proxy qbittorrent:8080
}

seerr.home.arpa {
	reverse_proxy seerr:5055
}
EOF

cat > "$CADDY_CONFIG_DIR/sites/observability.caddy" <<'EOF'
grafana.home.arpa {
	reverse_proxy grafana:3000
}

prometheus.home.arpa {
	reverse_proxy prometheus:9090
}
EOF

echo "Writing Caddy Quadlet..."

cat > "$SYSTEMD_DIR/caddy.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=caddy
Network=media.network
PublishPort=80:80
PublishPort=443:443
PublishPort=443:443/udp

Volume=%h/media-stack/config/caddy/Caddyfile:/etc/caddy/Caddyfile:Z
Volume=%h/media-stack/config/caddy/sites:/etc/caddy/sites:Z
Volume=%h/media-stack/config/caddy/data:/data:Z
Volume=%h/media-stack/config/caddy/config:/config:Z

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

echo "Restarting Caddy..."

for service in "${SERVICES[@]}"; do
  echo "Restarting $service..."
  systemctl --user restart "$service.service" || systemctl --user start "$service.service"
done

echo ""
echo "Done."
echo ""
echo "Caddy:"
echo "  https://jellyfin.home.arpa"
echo "  https://sonarr.home.arpa"
echo "  https://radarr.home.arpa"
echo "  https://prowlarr.home.arpa"
echo "  https://bazarr.home.arpa"
echo "  https://subgen.home.arpa"
echo "  https://qbittorrent.home.arpa"
echo "  https://seerr.home.arpa"
echo "  https://grafana.home.arpa"
echo "  https://prometheus.home.arpa"
echo ""
echo "Trust Caddy's local root CA on each client to avoid browser warnings:"
echo "  ~/media-stack/config/caddy/data/caddy/pki/authorities/local/root.crt"
