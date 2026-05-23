#!/usr/bin/env bash

set -euo pipefail

SYSTEMD_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/media-stack/config"
OBS_CONFIG_DIR="$CONFIG_DIR/observability"

SERVICES=(
  media-exporter
  node-exporter
  snmp-exporter
  blackbox-exporter
  prometheus
  grafana
)

echo "Creating observability folders..."

mkdir -p "$SYSTEMD_DIR"
mkdir -p "$OBS_CONFIG_DIR"/{prometheus,blackbox,snmp-exporter,media-exporter,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards,grafana/data,prometheus/data}

echo "Ensuring media Quadlet network exists..."

cat > "$SYSTEMD_DIR/media.network" <<'EOF'
[Network]
NetworkName=media
EOF

echo "Writing Prometheus config..."

cat > "$OBS_CONFIG_DIR/prometheus/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: node
    static_configs:
      - targets:
          - node-exporter:9100

  - job_name: media-library
    static_configs:
      - targets:
          - media-exporter:9797

  - job_name: synology-snmp
    metrics_path: /snmp
    params:
      module:
        - synology
      auth:
        - synology_v2
    static_configs:
      - targets:
          - 192.168.0.148
    relabel_configs:
      - source_labels:
          - __address__
        target_label: __param_target
      - source_labels:
          - __param_target
        target_label: instance
      - target_label: __address__
        replacement: snmp-exporter:9116

  - job_name: media-http
    metrics_path: /probe
    params:
      module:
        - http_reachable
    static_configs:
      - targets:
          - http://jellyfin:8096
          - http://sonarr:8989
          - http://radarr:7878
          - http://prowlarr:9696
          - http://bazarr:6767
          - http://qbittorrent:8080
          - http://seerr:5055
    relabel_configs:
      - source_labels:
          - __address__
        target_label: __param_target
      - source_labels:
          - __param_target
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
EOF

echo "Writing SNMP Exporter config..."

cat > "$OBS_CONFIG_DIR/snmp-exporter/snmp.yml" <<'EOF'
auths:
  synology_v2:
    version: 2
    community: media_monitor

modules:
  synology:
    walk:
      - 1.3.6.1.2.1.1.3.0
      - 1.3.6.1.4.1.2021.4.5.0
      - 1.3.6.1.4.1.2021.4.6.0
      - 1.3.6.1.4.1.2021.4.14.0
      - 1.3.6.1.4.1.2021.4.15.0
      - 1.3.6.1.4.1.2021.11.9.0
      - 1.3.6.1.4.1.2021.11.10.0
      - 1.3.6.1.4.1.2021.11.11.0
    metrics:
      - name: synology_uptime_ticks
        oid: 1.3.6.1.2.1.1.3.0
        type: gauge
        help: Synology uptime in hundredths of a second.
      - name: synology_mem_total_real_kilobytes
        oid: 1.3.6.1.4.1.2021.4.5.0
        type: gauge
        help: Synology total physical memory in kilobytes.
      - name: synology_mem_avail_real_kilobytes
        oid: 1.3.6.1.4.1.2021.4.6.0
        type: gauge
        help: Synology available physical memory in kilobytes.
      - name: synology_mem_buffer_kilobytes
        oid: 1.3.6.1.4.1.2021.4.14.0
        type: gauge
        help: Synology buffered memory in kilobytes.
      - name: synology_mem_cached_kilobytes
        oid: 1.3.6.1.4.1.2021.4.15.0
        type: gauge
        help: Synology cached memory in kilobytes.
      - name: synology_cpu_user_percent
        oid: 1.3.6.1.4.1.2021.11.9.0
        type: gauge
        help: Synology CPU user percentage.
      - name: synology_cpu_system_percent
        oid: 1.3.6.1.4.1.2021.11.10.0
        type: gauge
        help: Synology CPU system percentage.
      - name: synology_cpu_idle_percent
        oid: 1.3.6.1.4.1.2021.11.11.0
        type: gauge
        help: Synology CPU idle percentage.
EOF

echo "Writing Blackbox Exporter config..."

cat > "$OBS_CONFIG_DIR/blackbox/blackbox.yml" <<'EOF'
modules:
  http_reachable:
    prober: http
    timeout: 5s
    http:
      valid_http_versions:
        - HTTP/1.1
        - HTTP/2.0
      valid_status_codes:
        - 200
        - 401
        - 403
      follow_redirects: true
      preferred_ip_protocol: ip4
EOF

echo "Writing Media Exporter..."

cat > "$OBS_CONFIG_DIR/media-exporter/media_exporter.py" <<'EOF'
#!/usr/bin/env python3

import json
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RADARR_URL = "http://radarr:7878"
SONARR_URL = "http://sonarr:8989"
RADARR_CONFIG = "/arr-config/radarr/config.xml"
SONARR_CONFIG = "/arr-config/sonarr/config.xml"


def read_api_key(path):
    try:
        return ET.parse(path).findtext("ApiKey", default="").strip()
    except Exception:
        return ""


def request_json(url, api_key):
    req = urllib.request.Request(url, headers={"X-Api-Key": api_key})
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def parse_time(value):
    if not value:
        return 0
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def label(value):
    return str(value or "").replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def metric(name, value, labels=None):
    if labels:
        label_text = ",".join(f'{key}="{label(val)}"' for key, val in labels.items())
        return f"{name}{{{label_text}}} {value}"
    return f"{name} {value}"


def quality(record):
    quality_obj = record.get("quality") or {}
    if isinstance(quality_obj, dict):
        nested = quality_obj.get("quality") or {}
        if isinstance(nested, dict):
            return nested.get("name", "")
    return ""


def collect_radarr(lines):
    api_key = read_api_key(RADARR_CONFIG)
    if not api_key:
        lines.append(metric("media_exporter_scrape_success", 0, {"app": "radarr"}))
        return

    movies = request_json(f"{RADARR_URL}/api/v3/movie", api_key)
    downloaded = sum(1 for item in movies if item.get("hasFile"))
    monitored = sum(1 for item in movies if item.get("monitored"))
    latest = max(movies, key=lambda item: parse_time(item.get("added")), default=None)

    lines.append(metric("media_radarr_movies_total", len(movies)))
    lines.append(metric("media_radarr_movies_downloaded_total", downloaded))
    lines.append(metric("media_radarr_movies_missing_total", len(movies) - downloaded))
    lines.append(metric("media_radarr_movies_monitored_total", monitored))
    if latest:
        lines.append(metric(
            "media_radarr_latest_added_timestamp",
            parse_time(latest.get("added")),
            {"title": latest.get("title"), "year": latest.get("year")},
        ))

    queue = request_json(f"{RADARR_URL}/api/v3/queue?page=1&pageSize=100&sortKey=timeleft&sortDirection=ascending", api_key)
    records = queue.get("records", [])
    lines.append(metric("media_radarr_queue_total", len(records)))
    for item in records:
        movie = item.get("movie") or {}
        lines.append(metric("media_radarr_queue_item", 1, {
            "title": movie.get("title") or item.get("title"),
            "status": item.get("status"),
            "quality": quality(item),
            "protocol": item.get("protocol"),
        }))

    lines.append(metric("media_exporter_scrape_success", 1, {"app": "radarr"}))


def collect_sonarr(lines):
    api_key = read_api_key(SONARR_CONFIG)
    if not api_key:
        lines.append(metric("media_exporter_scrape_success", 0, {"app": "sonarr"}))
        return

    series = request_json(f"{SONARR_URL}/api/v3/series", api_key)
    episodes = 0
    episode_files = 0
    monitored = sum(1 for item in series if item.get("monitored"))
    latest = max(series, key=lambda item: parse_time(item.get("added")), default=None)
    for item in series:
        stats = item.get("statistics") or {}
        episodes += int(stats.get("episodeCount") or stats.get("totalEpisodeCount") or 0)
        episode_files += int(stats.get("episodeFileCount") or 0)

    lines.append(metric("media_sonarr_series_total", len(series)))
    lines.append(metric("media_sonarr_series_monitored_total", monitored))
    lines.append(metric("media_sonarr_episodes_total", episodes))
    lines.append(metric("media_sonarr_episodes_downloaded_total", episode_files))
    lines.append(metric("media_sonarr_episodes_missing_total", max(episodes - episode_files, 0)))
    if latest:
        lines.append(metric(
            "media_sonarr_latest_series_added_timestamp",
            parse_time(latest.get("added")),
            {"series": latest.get("title"), "year": latest.get("year")},
        ))

    queue = request_json(f"{SONARR_URL}/api/v3/queue?page=1&pageSize=100&sortKey=timeleft&sortDirection=ascending", api_key)
    records = queue.get("records", [])
    lines.append(metric("media_sonarr_queue_total", len(records)))
    for item in records:
        series_obj = item.get("series") or {}
        episode_obj = item.get("episode") or {}
        lines.append(metric("media_sonarr_queue_item", 1, {
            "series": series_obj.get("title"),
            "title": item.get("title") or episode_obj.get("title"),
            "status": item.get("status"),
            "quality": quality(item),
            "protocol": item.get("protocol"),
        }))

    lines.append(metric("media_exporter_scrape_success", 1, {"app": "sonarr"}))


def collect():
    lines = [
        "# HELP media_exporter_scrape_success Whether the last app scrape succeeded.",
        "# TYPE media_exporter_scrape_success gauge",
        "# TYPE media_radarr_movies_total gauge",
        "# TYPE media_radarr_movies_downloaded_total gauge",
        "# TYPE media_radarr_movies_missing_total gauge",
        "# TYPE media_radarr_queue_total gauge",
        "# TYPE media_radarr_queue_item gauge",
        "# TYPE media_radarr_latest_added_timestamp gauge",
        "# TYPE media_sonarr_series_total gauge",
        "# TYPE media_sonarr_episodes_total gauge",
        "# TYPE media_sonarr_episodes_downloaded_total gauge",
        "# TYPE media_sonarr_episodes_missing_total gauge",
        "# TYPE media_sonarr_queue_total gauge",
        "# TYPE media_sonarr_queue_item gauge",
        "# TYPE media_sonarr_latest_series_added_timestamp gauge",
    ]
    for app, collector in (("radarr", collect_radarr), ("sonarr", collect_sonarr)):
        try:
            collector(lines)
        except Exception:
            lines.append(metric("media_exporter_scrape_success", 0, {"app": app}))
    lines.append(metric("media_exporter_last_scrape_timestamp", int(time.time())))
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/"):
            self.send_response(404)
            self.end_headers()
            return
        body = collect().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9797), Handler).serve_forever()
EOF

echo "Writing Grafana provisioning..."

cat > "$OBS_CONFIG_DIR/grafana/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    uid: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

cat > "$OBS_CONFIG_DIR/grafana/provisioning/dashboards/media-stack.yml" <<'EOF'
apiVersion: 1

providers:
  - name: Media Stack
    orgId: 1
    folder: Media Stack
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF

cat > "$OBS_CONFIG_DIR/grafana/dashboards/media-stack.json" <<'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "links": [],
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [
            {
              "options": {
                "0": {
                  "color": "red",
                  "index": 0,
                  "text": "Down"
                },
                "1": {
                  "color": "green",
                  "index": 1,
                  "text": "Up"
                }
              },
              "type": "value"
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "probe_success{job=\"media-http\"}",
          "legendFormat": "{{instance}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Media App Reachability",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "id": 2,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "probe_duration_seconds{job=\"media-http\"}",
          "legendFormat": "{{instance}}",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "HTTP Probe Duration",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "id": 3,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "1 - (node_filesystem_avail_bytes{mountpoint=~\"/|/var/mnt/nas|/mnt/nas|/host|/host/mnt/nas\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=~\"/|/var/mnt/nas|/mnt/nas|/host|/host/mnt/nas\",fstype!~\"tmpfs|overlay\"})",
          "legendFormat": "{{mountpoint}}",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "Filesystem Usage",
      "type": "timeseries"
    }
  ],
  "refresh": "15s",
  "schemaVersion": 39,
  "tags": [
    "media-stack"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "Media Stack Overview",
  "uid": "media-stack-overview",
  "version": 1,
  "weekStart": ""
}
EOF

cat > "$OBS_CONFIG_DIR/grafana/dashboards/media-stack-ops.json" <<'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [
            {
              "options": {
                "0": {
                  "color": "red",
                  "index": 0,
                  "text": "Down"
                },
                "1": {
                  "color": "green",
                  "index": 1,
                  "text": "Up"
                }
              },
              "type": "value"
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "gridPos": {
        "h": 5,
        "w": 18,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "probe_success{job=\"media-http\"}",
          "legendFormat": "{{instance}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Media Apps",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.9
              },
              {
                "color": "green",
                "value": 0.99
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 5,
        "w": 6,
        "x": 18,
        "y": 0
      },
      "id": 2,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "avg(probe_success{job=\"media-http\"})",
          "legendFormat": "availability",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Fleet Availability",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 14,
        "x": 0,
        "y": 5
      },
      "id": 3,
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "probe_duration_seconds{job=\"media-http\"}",
          "legendFormat": "{{instance}}",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "App Response Time",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 10,
        "x": 14,
        "y": 5
      },
      "id": 4,
      "options": {
        "cellHeight": "sm",
        "footer": {
          "countRows": false,
          "fields": "",
          "reducer": [
            "sum"
          ],
          "show": false
        },
        "showHeader": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "probe_http_status_code{job=\"media-http\"}",
          "format": "table",
          "instant": true,
          "legendFormat": "{{instance}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "HTTP Status Codes",
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true,
              "job": true
            },
            "indexByName": {},
            "renameByName": {
              "Value": "status"
            }
          }
        }
      ],
      "type": "table"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.7
              },
              {
                "color": "red",
                "value": 0.9
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 6,
        "x": 0,
        "y": 13
      },
      "id": 5,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))",
          "legendFormat": "CPU",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Host CPU",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.75
              },
              {
                "color": "red",
                "value": 0.9
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 6,
        "x": 6,
        "y": 13
      },
      "id": 6,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)",
          "legendFormat": "Memory",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Host Memory",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.75
              },
              {
                "color": "red",
                "value": 0.9
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 6,
        "x": 12,
        "y": 13
      },
      "id": 7,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "max(1 - (node_filesystem_avail_bytes{mountpoint=~\"/mnt/nas|/var/mnt/nas|/host/mnt/nas\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=~\"/mnt/nas|/var/mnt/nas|/host/mnt/nas\",fstype!~\"tmpfs|overlay\"}))",
          "legendFormat": "NAS",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "NAS Capacity",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "decbytes"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 6,
        "x": 18,
        "y": 13
      },
      "id": 8,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "max(node_filesystem_avail_bytes{mountpoint=~\"/mnt/nas|/var/mnt/nas|/host/mnt/nas\",fstype!~\"tmpfs|overlay\"})",
          "legendFormat": "NAS free",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "NAS Free Space",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 21
      },
      "id": 9,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "sum(rate(node_network_receive_bytes_total{device!~\"lo|podman.*|veth.*|br.*|docker.*\"}[5m]))",
          "legendFormat": "receive",
          "range": true,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "sum(rate(node_network_transmit_bytes_total{device!~\"lo|podman.*|veth.*|br.*|docker.*\"}[5m]))",
          "legendFormat": "transmit",
          "range": true,
          "refId": "B"
        }
      ],
      "title": "Network Throughput",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 21
      },
      "id": 10,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "sum(rate(node_disk_read_bytes_total{device!~\"loop.*|ram.*\"}[5m]))",
          "legendFormat": "read",
          "range": true,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "sum(rate(node_disk_written_bytes_total{device!~\"loop.*|ram.*\"}[5m]))",
          "legendFormat": "write",
          "range": true,
          "refId": "B"
        }
      ],
      "title": "Disk IO",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "ops"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 0,
        "y": 29
      },
      "id": 11,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "scrape_samples_scraped",
          "legendFormat": "{{job}}",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "Scrape Samples",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [
            {
              "options": {
                "0": {
                  "color": "red",
                  "index": 0,
                  "text": "Down"
                },
                "1": {
                  "color": "green",
                  "index": 1,
                  "text": "Up"
                }
              },
              "type": "value"
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 12,
        "y": 29
      },
      "id": 12,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "up",
          "legendFormat": "{{job}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Prometheus Targets",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.75
              },
              {
                "color": "red",
                "value": 0.9
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 0,
        "y": 36
      },
      "id": 13,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "max((100 - synology_cpu_idle_percent{job=\"synology-snmp\"}) / 100)",
          "legendFormat": "CPU",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "NAS CPU",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.8
              },
              {
                "color": "red",
                "value": 0.9
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 12,
        "y": 36
      },
      "id": 14,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "max((synology_mem_total_real_kilobytes{job=\"synology-snmp\"} - synology_mem_avail_real_kilobytes{job=\"synology-snmp\"} - synology_mem_buffer_kilobytes{job=\"synology-snmp\"} - synology_mem_cached_kilobytes{job=\"synology-snmp\"}) / synology_mem_total_real_kilobytes{job=\"synology-snmp\"})",
          "legendFormat": "Memory",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "NAS Memory",
      "type": "gauge"
    }
  ],
  "refresh": "15s",
  "schemaVersion": 39,
  "tags": [
    "media-stack",
    "operations"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "Media Stack Operations",
  "uid": "media-stack-ops",
  "version": 1,
  "weekStart": ""
}
EOF

cat > "$OBS_CONFIG_DIR/grafana/dashboards/media-library.json" <<'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 6,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "displayMode": "gradient",
        "legend": {
          "calcs": [],
          "displayMode": "list",
          "placement": "bottom",
          "showLegend": true
        },
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showUnfilled": true,
        "valueMode": "color"
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_movies_downloaded_total",
          "legendFormat": "movies downloaded",
          "range": false,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_movies_missing_total",
          "legendFormat": "movies missing",
          "range": false,
          "refId": "B"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_episodes_downloaded_total",
          "legendFormat": "episodes downloaded",
          "range": false,
          "refId": "C"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_episodes_missing_total",
          "legendFormat": "episodes missing",
          "range": false,
          "refId": "D"
        }
      ],
      "title": "Library Inventory",
      "type": "bargauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 6,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "id": 2,
      "options": {
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_movies_total",
          "legendFormat": "movies",
          "range": false,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_series_total",
          "legendFormat": "tv shows",
          "range": false,
          "refId": "B"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_episodes_total",
          "legendFormat": "episodes",
          "range": false,
          "refId": "C"
        }
      ],
      "title": "Catalog Size",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.8
              },
              {
                "color": "green",
                "value": 0.95
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 6,
        "x": 0,
        "y": 6
      },
      "id": 3,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_movies_downloaded_total / media_radarr_movies_total",
          "legendFormat": "movies",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Movie Completion",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "orange",
                "value": 0.8
              },
              {
                "color": "green",
                "value": 0.95
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 6,
        "x": 6,
        "y": 6
      },
      "id": 4,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_episodes_downloaded_total / media_sonarr_episodes_total",
          "legendFormat": "episodes",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "TV Episode Completion",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 12,
        "y": 6
      },
      "id": 5,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_queue_total",
          "legendFormat": "movie downloads",
          "range": false,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_queue_total",
          "legendFormat": "tv downloads",
          "range": false,
          "refId": "B"
        }
      ],
      "title": "Active Queue",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 0,
        "y": 13
      },
      "id": 6,
      "options": {
        "cellHeight": "sm",
        "footer": {
          "countRows": false,
          "fields": "",
          "reducer": [
            "sum"
          ],
          "show": false
        },
        "showHeader": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_radarr_queue_item",
          "format": "table",
          "instant": true,
          "legendFormat": "{{title}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Movies Downloading",
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true,
              "job": true,
              "instance": true,
              "Value": true
            },
            "indexByName": {},
            "renameByName": {
              "protocol": "source"
            }
          }
        }
      ],
      "type": "table"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 12,
        "y": 13
      },
      "id": 7,
      "options": {
        "cellHeight": "sm",
        "footer": {
          "countRows": false,
          "fields": "",
          "reducer": [
            "sum"
          ],
          "show": false
        },
        "showHeader": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "media_sonarr_queue_item",
          "format": "table",
          "instant": true,
          "legendFormat": "{{series}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "TV Downloading",
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true,
              "job": true,
              "instance": true,
              "Value": true
            },
            "indexByName": {},
            "renameByName": {
              "protocol": "source"
            }
          }
        }
      ],
      "type": "table"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "dateTimeAsIso"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 0,
        "y": 22
      },
      "id": 8,
      "options": {
        "cellHeight": "sm",
        "footer": {
          "countRows": false,
          "fields": "",
          "reducer": [
            "sum"
          ],
          "show": false
        },
        "showHeader": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "topk(1, media_radarr_latest_added_timestamp * 1000)",
          "format": "table",
          "instant": true,
          "legendFormat": "{{title}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Last Movie Added",
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true,
              "job": true,
              "instance": true
            },
            "indexByName": {},
            "renameByName": {
              "Value": "added"
            }
          }
        }
      ],
      "type": "table"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "Prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "dateTimeAsIso"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 7,
        "w": 12,
        "x": 12,
        "y": 22
      },
      "id": 9,
      "options": {
        "cellHeight": "sm",
        "footer": {
          "countRows": false,
          "fields": "",
          "reducer": [
            "sum"
          ],
          "show": false
        },
        "showHeader": true
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "Prometheus"
          },
          "editorMode": "code",
          "expr": "topk(1, media_sonarr_latest_series_added_timestamp * 1000)",
          "format": "table",
          "instant": true,
          "legendFormat": "{{series}}",
          "range": false,
          "refId": "A"
        }
      ],
      "title": "Last TV Show Added",
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true,
              "job": true,
              "instance": true
            },
            "indexByName": {},
            "renameByName": {
              "Value": "added"
            }
          }
        }
      ],
      "type": "table"
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": [
    "media-stack",
    "library"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-24h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "Media Library",
  "uid": "media-library",
  "version": 1,
  "weekStart": ""
}
EOF

echo "Writing Media Exporter Quadlet..."

cat > "$SYSTEMD_DIR/media-exporter.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=docker.io/library/python:3.12-alpine
ContainerName=media-exporter
Network=media.network
PublishPort=9797:9797

Volume=%h/media-stack/config/observability/media-exporter:/app:Z
Volume=%h/media-stack/config/radarr:/arr-config/radarr:ro,z
Volume=%h/media-stack/config/sonarr:/arr-config/sonarr:ro,z

Exec=python /app/media_exporter.py

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Node Exporter Quadlet..."

cat > "$SYSTEMD_DIR/node-exporter.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=quay.io/prometheus/node-exporter:latest
ContainerName=node-exporter
Network=media.network
PublishPort=9100:9100

Volume=/:/host:ro,rslave

Exec=--path.rootfs=/host --collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/containers/.+)($|/)

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing SNMP Exporter Quadlet..."

cat > "$SYSTEMD_DIR/snmp-exporter.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=quay.io/prometheus/snmp-exporter:latest
ContainerName=snmp-exporter
Network=media.network
PublishPort=9116:9116

Volume=%h/media-stack/config/observability/snmp-exporter:/etc/snmp_exporter:Z

Exec=--config.file=/etc/snmp_exporter/snmp.yml

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Blackbox Exporter Quadlet..."

cat > "$SYSTEMD_DIR/blackbox-exporter.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=quay.io/prometheus/blackbox-exporter:latest
ContainerName=blackbox-exporter
Network=media.network
PublishPort=9115:9115

Volume=%h/media-stack/config/observability/blackbox:/config:Z

Exec=--config.file=/config/blackbox.yml

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Prometheus Quadlet..."

cat > "$SYSTEMD_DIR/prometheus.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=docker.io/prom/prometheus:latest
ContainerName=prometheus
Network=media.network
PublishPort=9090:9090
User=0

Volume=%h/media-stack/config/observability/prometheus:/etc/prometheus:Z
Volume=%h/media-stack/config/observability/prometheus/data:/prometheus:Z

Exec=--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=30d --web.enable-lifecycle

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

echo "Writing Grafana Quadlet..."

cat > "$SYSTEMD_DIR/grafana.container" <<'EOF'
[Unit]
After=media-network.service
Requires=media-network.service

[Container]
Image=docker.io/grafana/grafana-oss:latest
ContainerName=grafana
Network=media.network
PublishPort=3000:3000
User=0

Environment=GF_SECURITY_ADMIN_USER=admin
Environment=GF_SECURITY_ADMIN_PASSWORD=admin
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_AUTH_ANONYMOUS_ENABLED=false

Volume=%h/media-stack/config/observability/grafana/data:/var/lib/grafana:Z
Volume=%h/media-stack/config/observability/grafana/provisioning:/etc/grafana/provisioning:Z
Volume=%h/media-stack/config/observability/grafana/dashboards:/var/lib/grafana/dashboards:Z

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

echo "Restarting observability services..."

for service in "${SERVICES[@]}"; do
  echo "Restarting $service..."
  systemctl --user restart "$service.service" || systemctl --user start "$service.service"
done

echo ""
echo "Done."
echo ""
echo "Prometheus:       http://localhost:9090"
echo "Grafana:          http://localhost:3000  admin/admin"
echo "Node Exporter:    http://localhost:9100/metrics"
echo "SNMP Exporter:    http://localhost:9116"
echo "Blackbox Exporter: http://localhost:9115"
