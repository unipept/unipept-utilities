# HALog Live

A small Node.js utility that tails HAProxy activity and exports live metrics to Graphite for real‑time dashboards (e.g., in Grafana).

## What it does

HALog Live is designed to run as a system service on the load‑balancer host. It periodically inspects the HAProxy log file and reports metrics to a Graphite/Carbon backend using the plaintext protocol.

The script currently collects:

- Total request counts per backend node (cumulative values derived from the current log file)
- Average response time per backend node for the last minute (computed from recent log lines only)

Metric naming (Graphite paths):

- halog_live.unipeptapi.<node>.request_count
- halog_live.unipeptapi.<node>.avg_response_time

Notes:

- The script shells out to halog with flags: `-s -1 -H -srv`. The `-s -1` is needed to skip rsyslog’s first metadata field.
- Average response time is computed using only the last ~60 seconds of log lines, parsed by timestamp.
- If no metrics can be computed during a cycle, the script exits quietly (useful for cron/systemd).

## Requirements

- Node.js 18+ (ES modules enabled)
- The `halog` command installed and available in PATH (part of the HAProxy tools)
- Access to the HAProxy log file (default: `/var/log/haproxy.log`)
- A reachable Graphite/Carbon instance (host and TCP port)

## Install dependencies

From this directory (`scripts/halog-live/`):

- npm install

## Usage

- node halog-live.js [options]

Options:

- --haproxy-log        Path to HAProxy log file (default: "/var/log/haproxy.log")
- --graphite-host      Graphite/Carbon host (default: "127.0.0.1")
- --graphite-port      Graphite/Carbon TCP port (default: 2003)
- --help, -h           Show built-in help

## Examples

Run once with defaults (local Graphite, default log path):

- node halog-live.js

Send to a remote Graphite instance and a custom log path:

- node halog-live.js --graphite-host graphite.example.org --graphite-port 2003 --haproxy-log /var/log/haproxy.log

## Scheduling / Service usage

Typical usage is to run this as a system service that fires frequently (e.g., every 10 seconds) to keep live dashboards up to date. Example `systemd` units:

Service unit (`/etc/systemd/system/halog-live.service`):

```
[Unit]
Description=HALog Live metrics exporter
After=network.target

[Service]
Type=oneshot
WorkingDirectory=/opt/unipept-unutilities/scripts/halog-live
ExecStart=/usr/bin/node halog-live.js --haproxy-log /var/log/haproxy.log --graphite-host 127.0.0.1 --graphite-port 2003
User=haproxy
Group=haproxy
```

Timer unit (`/etc/systemd/system/halog-live.timer`):

```
[Unit]
Description=Run HALog Live every 10 seconds

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=halog-live.service

[Install]
WantedBy=timers.target
```

Enable and start:

- systemctl daemon-reload
- systemctl enable --now halog-live.timer

For more information on how this script is configured on our Unipept servers, please see the same guide used for the collector: https://github.com/unipept/unipept/wiki/unipept-api-load-balancer-configuration#logging-and-monitoring-server-status

## Operational notes

- The total request count per node is cumulative for the content of the current log file. If logs rotate, counts will reflect the new file.
- Average response time per node is calculated using a sliding 60‑second window based on timestamps in each log line (expects ISO‑8601/RFC3339 at the start of the line, as produced by our rsyslog configuration).
- The script is resilient: failure to compute a subset of metrics or to connect to Graphite is logged to stderr, but the process exits cleanly for the next run.
