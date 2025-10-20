# HALog Collector

A Node.js CLI for collecting and processing HAProxy log data and storing aggregated metrics in MySQL.

## What it does

The HALog Collector is designed to run periodically (e.g., daily) to process logs from an HAProxy load balancer.
It aggregates usage statistics and stores them in a MySQL database for historical tracking and monitoring.

Collected data can be used for:

- Historical usage analysis
- Service monitoring (e.g., Grafana)
- API endpoint usage tracking
- Server/node load distribution monitoring
- Client/source breakdown (browser, desktop app, CLI, other)

## Requirements

- Node.js 18+ (ES modules enabled)
- A working MySQL/MariaDB instance the script can connect to
- The `halog` command available on the host (part of the HAProxy tools)
- Access to the HAProxy log file (default: `/var/log/haproxy.log`)

## Database schema

Initialize the target database with the provided schema before running the collector:

- File: `schema/default_schema.sql`

This schema creates the tables used by the collector:

- `endpoint_stats(date, endpoint, req_successful, req_error, avg_duration)`
- `node_stats(date, node, req_successful, req_error, avg_duration)`
- `source_stats(date, source, req_total)`

Each run for a specific date replaces existing rows for that date (the script deletes by date first, then inserts),
allowing safe re-runs.

## Install dependencies

From this directory (`scripts/halog-collector/`):

- npm install

## Usage

- node collect.js <command> [options]

Commands:

- endpoints — Aggregate stats per API endpoint (total requests, errors, average duration)
- nodes — Aggregate stats per backend/handling node (total requests, errors, average duration)
- sources — Aggregate request counts by client source (browser, desktop app, CLI, other)

Global options:

- --db-user, -u         MySQL username (default: "root")
- --db-password, -p     MySQL password (default: "")
- --db-name             Target database name (default: "statistics")
- --db-host             Database host (default: "localhost")
- --db-port             Database port (default: "3306")
- --haproxy-config      Path to the HAProxy log file (default: "/var/log/haproxy.log")
- --days-ago            How many days ago the provided log file represents (default: 1)
- --help, -h            Show built-in help

Notes:

- days-ago controls the `date` column written into the tables (using `SUBDATE(CURDATE(), days-ago)`). For example,
  when you process yesterday's log, use `--days-ago 1` (the default). For a log from two days ago, use `--days-ago 2`.
- The script shells out to `halog` and some standard utilities for parsing; ensure `halog` is installed and that the
  log format matches what `halog` expects. The script calls `halog` with `-s -1` to skip rsyslog's first metadata field.

## Examples

Process yesterday's endpoint stats using defaults (local MySQL, root/no password, default DB/schema and log path):

- node collect.js endpoints

Process node stats from a specific log path into a remote DB:

- node collect.js nodes --haproxy-config /var/log/haproxy.log.1 --days-ago 1 --db-host db.example.org --db-user stats --db-password secret --db-name statistics

Process source stats for a log from two days ago:

- node collect.js sources --days-ago 2

## Scheduling

Typical usage is to schedule a daily run (after log rotation) for each command you want to collect, e.g. with a
`systemd` timer. For more information on how this script is configured on our Unipept Servers, please see 
[this guide](https://github.com/unipept/unipept/wiki/unipept-api-load-balancer-configuration#logging-and-monitoring-server-status).


