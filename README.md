# Media Stack

Podman Quadlet setup scripts for a home media stack, optional reverse proxy, and observability services.

The scripts write user-level systemd Quadlet units under `~/.config/containers/systemd` and keep application state under `~/media-stack/config`. Media and download data are expected under `/mnt/nas`.

## Services

Media services:

| Service | URL | Purpose |
| --- | --- | --- |
| Jellyfin | http://localhost:8096 | Media server |
| Sonarr | http://localhost:8989 | TV library management |
| Radarr | http://localhost:7878 | Movie library management |
| Prowlarr | http://localhost:9696 | Indexer management |
| Bazarr | http://localhost:6767 | Subtitle management |
| qBittorrent | http://localhost:8080 | Download client |
| Seerr | http://localhost:5055 | Media requests |

Observability services:

| Service | URL | Notes |
| --- | --- | --- |
| Prometheus | http://localhost:9090 | Metrics storage |
| Grafana | http://localhost:3000 | Default login: `admin` / `admin` |
| Node Exporter | http://localhost:9100/metrics | Host metrics |
| SNMP Exporter | http://localhost:9116 | NAS SNMP metrics |
| Blackbox Exporter | http://localhost:9115 | HTTP reachability probes |
| Media Exporter | http://localhost:9797/metrics | Radarr and Sonarr library metrics |

Caddy exposes friendly local hostnames:

- http://jellyfin.home.arpa
- http://sonarr.home.arpa
- http://radarr.home.arpa
- http://prowlarr.home.arpa
- http://bazarr.home.arpa
- http://qbittorrent.home.arpa
- http://seerr.home.arpa
- http://grafana.home.arpa
- http://prometheus.home.arpa

## Requirements

- Linux host with user-level systemd
- Podman with Quadlet support
- `systemctl --user` available for the target user
- NAS mounted at `/mnt/nas`
- Write access to:
  - `/mnt/nas/media`
  - `/mnt/nas/downloads`
  - `~/media-stack/config`

The scripts use `TZ=Pacific/Auckland`, `PUID=1000`, and `PGID=0` for most LinuxServer containers. Adjust the scripts before running them if your user, group, timezone, NAS mount, or LAN layout differs.

## Install

Run the media stack first:

```bash
./setup-media-stack.sh
```

Then install observability if wanted:

```bash
./setup-observability.sh
```

Then install Caddy if you want the `.home.arpa` reverse-proxy hostnames:

```bash
./setup-caddy.sh
```

Each script reloads user systemd, enables linger for the current user, starts the shared `media` Podman network, and restarts the services it manages.

## Storage Layout

The media stack expects this NAS layout:

```text
/mnt/nas
|-- downloads
|   |-- complete
|   |   |-- movies
|   |   `-- tv
|   `-- incomplete
`-- media
    |-- books
    |-- movies
    |-- music
    `-- tv
```

Generated service config lives in:

```text
~/media-stack/config
```

That directory is intentionally ignored by git because it contains runtime state, logs, databases, API keys, and application settings.

## DNS

For Caddy hostnames to work, point the `.home.arpa` names at the media host. Common options are:

- Add DNS overrides in your router or local DNS server.
- Add entries to `/etc/hosts` on client machines.

Example:

```text
192.168.0.10 jellyfin.home.arpa sonarr.home.arpa radarr.home.arpa prowlarr.home.arpa bazarr.home.arpa qbittorrent.home.arpa seerr.home.arpa grafana.home.arpa prometheus.home.arpa
```

Replace `192.168.0.10` with the media host IP.

## Operations

Check service status:

```bash
systemctl --user status jellyfin.service
systemctl --user status sonarr.service
systemctl --user status radarr.service
```

Restart a service:

```bash
systemctl --user restart jellyfin.service
```

View logs:

```bash
journalctl --user -u jellyfin.service -f
```

List containers:

```bash
podman ps
```

Test media path write access from Radarr:

```bash
podman exec -it radarr touch /movies/test.txt
```

## Observability Notes

Prometheus is configured to scrape:

- Prometheus itself
- Node Exporter
- Media Exporter
- SNMP Exporter for a Synology target at `192.168.0.148`
- Blackbox HTTP probes for the media services

SNMP uses the community name `media_monitor`. Update `setup-observability.sh` before running it if your NAS IP, SNMP version, or community string differs.

The custom Media Exporter reads Radarr and Sonarr API keys from their generated `config.xml` files and publishes library and queue metrics on port `9797`.

## Notes

- `setup-media-stack.sh` stops and disables the legacy `jellyseerr.service` if present.
- If `~/media-stack/config/jellyseerr` exists and `~/media-stack/config/seerr` is empty, the media setup copies Jellyseerr config into Seerr.
- Caddy has `auto_https off` and serves plain HTTP by default.
