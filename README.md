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
| Subgen | http://localhost:9000 | Whisper subtitle generation for Bazarr |
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

Caddy exposes friendly local HTTPS hostnames:

- https://jellyfin.home.arpa
- https://sonarr.home.arpa
- https://radarr.home.arpa
- https://prowlarr.home.arpa
- https://bazarr.home.arpa
- https://subgen.home.arpa
- https://qbittorrent.home.arpa
- https://seerr.home.arpa
- https://grafana.home.arpa
- https://prometheus.home.arpa

## Requirements

- Linux host with user-level systemd
- Podman with Quadlet support
- NVIDIA driver and `nvidia-container-toolkit` with a generated CDI spec for Subgen GPU support
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

## Local HTTPS

Caddy uses its internal CA for `.home.arpa` HTTPS. After running `./setup-caddy.sh`, install Caddy's root certificate on each client that will browse the local sites:

```text
~/media-stack/config/caddy/data/caddy/pki/authorities/local/root.crt
```

The certificate must be trusted by each client OS or browser. HTTP requests to the `.home.arpa` names are redirected to HTTPS by Caddy.

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
192.168.0.10 jellyfin.home.arpa sonarr.home.arpa radarr.home.arpa prowlarr.home.arpa bazarr.home.arpa subgen.home.arpa qbittorrent.home.arpa seerr.home.arpa grafana.home.arpa prometheus.home.arpa
```

Replace `192.168.0.10` with the media host IP.

## Operations

Check service status:

```bash
systemctl --user status jellyfin.service
systemctl --user status sonarr.service
systemctl --user status radarr.service
systemctl --user status subgen.service
```

Restart a service:

```bash
systemctl --user restart jellyfin.service
```

View logs:

```bash
journalctl --user -u jellyfin.service -f
journalctl --user -u subgen.service -f
```

List containers:

```bash
podman ps
```

Test media path write access from Radarr:

```bash
podman exec -it radarr touch /movies/test.txt
```

## Subgen Notes

Subgen is installed from `mccloud/subgen:latest`, listens on port `9000`, and is configured with `TRANSCRIBE_DEVICE=cuda` for NVIDIA GPU transcription. The service mounts `/mnt/nas/media/movies` as `/movies` and `/mnt/nas/media/tv` as `/tv`, matching Bazarr's container paths.

In Bazarr, enable the Whisper provider and set the Docker Endpoint to:

```text
http://subgen:9000
```

Enable "Pass Video Name" in Bazarr's Whisper provider settings so Subgen can inspect the source video when it needs to compensate for audio stream offsets.

GPU access depends on a working host NVIDIA stack. Verify the host first with `nvidia-smi`, then verify Podman CDI access with:

```bash
podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
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
- Caddy uses local HTTPS with its internal CA. Trust `~/media-stack/config/caddy/data/caddy/pki/authorities/local/root.crt` on each client to avoid browser warnings.
