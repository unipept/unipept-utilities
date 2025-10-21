/**
 * Use the HAProxy halog utility to parse the HAProxy log file, extract total requests
 * per backend node, and send the totals to Graphite (Carbon plaintext over TCP).
 *
 * Options (all optional):
 * --haproxy-log   Path to HAProxy log file. Default: /var/log/haproxy.log
 * --graphite-host Graphite/Carbon host.      Default: 127.0.0.1
 * --graphite-port Graphite/Carbon TCP port.  Default: 2003
 *
 * Intended usage: run periodically (e.g., every 10 seconds) via a systemd timer.
 * Each run executes: `cat <log> | halog -s -1 -H -srv` and reports cumulative totals per node to Graphite
 * using metric path: halog_live.unipeptapi.<node>.request_count
 *
 * Notes:
 * - Relies on halog being available in PATH.
 * - The metric is cumulative total observed in the provided log file at the time of execution.
 */

import net from 'node:net';
import {execSync} from 'node:child_process';
import fs from 'node:fs';

import yargs from 'yargs';
import {hideBin} from 'yargs/helpers';

function sanitizeForGraphite(segment) {
    // Graphite metric path segments should avoid spaces and special chars
    return String(segment).replace(/[^A-Za-z0-9_\-]/g, '_');
}

// Process a shell command, capture stdout, remove the first header line and the
// trailing status line printed by halog.
function processCommand(command) {
    let lineIdx = 0;
    const lines = [];

    const stdout = execSync(command, {encoding: 'utf-8'});

    for (const line of stdout.split('\n')) {
        if (lineIdx === 0) {
            lineIdx++;
            continue;
        }
        lineIdx++;
        lines.push(line.trimEnd());
    }

    // Remove the last line, which is the status message of the command
    if (lines.length > 0) {
        lines.splice(-1, 1);
    }
    return lines;
}

// Same as processCommand, but feeds the provided input to the process via STDIN
function processCommandWithInput(command, input) {
    let lineIdx = 0;
    const lines = [];

    const stdout = execSync(command, {encoding: 'utf-8', input});

    for (const line of stdout.split('\n')) {
        if (lineIdx === 0) {
            lineIdx++;
            continue;
        }
        lineIdx++;
        const trimmed = line.trimEnd();
        if (trimmed.length === 0) continue;
        lines.push(trimmed);
    }

    // Remove the last line, which is the status message of the command
    if (lines.length > 0) {
        lines.splice(-1, 1);
    }
    return lines;
}

function parseSyslogTimestampToDate(tokens) {
    // ISO-8601/RFC3339 only (e.g., 2025-10-21T10:08:04Z or 2025-10-21T10:08:04+02:00)
    // tokens: an array of whitespace-separated tokens from the start of a log line
    if (!tokens || tokens.length === 0) return null;

    const first = tokens[0];
    // Some syslog configurations might split timezone in a separate token, e.g.:
    //   2025-10-21T10:08:04 +02:00
    const tzSecond = tokens[1];

    // Detect ISO-8601: YYYY-MM-DDTHH:MM:SS[.sss][Z|±HH:MM]
    const isoLike = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:?\d{2})?$/.test(first);
    const tzOnly = tzSecond && /^[+\-]\d{2}:?\d{2}$/.test(tzSecond);

    if (!(isoLike || (/^\d{4}-\d{2}-\d{2}T/.test(first) && tzOnly))) {
        return null; // Not ISO-8601
    }

    let isoStr = first;
    // If timezone is provided as a separate token, append it without space
    if (!/[Zz]$/.test(first) && tzOnly && !/[+\-]\d{2}:?\d{2}$/.test(first)) {
        isoStr = first + tzSecond;
    }

    // Try direct parsing first
    let d = new Date(isoStr);
    if (!Number.isNaN(d.getTime())) return d;

    // If parsing failed, try without fractional seconds by stripping them
    const m = first.match(/^(.*T\d{2}:\d{2}:\d{2})(?:\.\d+)?(.*)$/);
    if (m) {
        const tryStr = (m[1] + (m[2] || '') + (tzOnly ? tzSecond : ''));
        const d2 = new Date(tryStr);
        if (!Number.isNaN(d2.getTime())) return d2;
    }

    return null;
}

function filterRecentLogLines(logPath, windowSeconds = 60) {
    let content;
    try {
        content = fs.readFileSync(logPath, 'utf-8');
    } catch (e) {
        console.error(`Failed to read HAProxy log at ${logPath}`);
        throw e;
    }
    const now = Date.now();
    const cutoff = now - windowSeconds * 1000;

    const out = [];
    for (const line of content.split('\n')) {
        if (!line) continue;
        // Expect ISO-8601 timestamp at the start of the line
        const parts = line.split(/\s+/);
        if (parts.length < 1) continue;
        const dt = parseSyslogTimestampToDate(parts);
        if (!dt) continue;
        if (dt.getTime() >= cutoff) {
            out.push(line);
        }
    }
    return out.join('\n') + (out.length ? '\n' : '');
}

function avgLatencyByNodeFromRecent(logPath) {
    const filtered = filterRecentLogLines(logPath, 60);
    if (!filtered || filtered.trim().length === 0) {
        return {};
    }

    let lines;
    try {
        // Feed filtered lines to halog via stdin
        lines = processCommandWithInput('halog -s -1 -H -srv', filtered);
    } catch (e) {
        console.error('Failed to execute halog for avg latency. Is it installed and in PATH?');
        throw e;
    }

    const stats = new Map();
    const delimiter = ' ';
    const serverNameCol = 0;
    const totReqCountCol = 7;
    const avgTimeCol = 11;

    console.log('Parsed lines:');
    console.log(lines);

    for (const line of lines) {
        if (!line) continue;
        const fields = line.split(delimiter);
        let serverName = fields[serverNameCol];
        if (!serverName) continue;

        const parts = serverName.split('/');
        const node = parts.length > 1 ? parts[1] : serverName;

        const totalReqCount = Number.parseInt(fields[totReqCountCol], 10);
        const avgTime = Number.parseFloat(fields[avgTimeCol]);
        if (!Number.isFinite(totalReqCount) || !Number.isFinite(avgTime)) continue;

        if (!stats.has(node)) {
            stats.set(node, {total: 0, weightedSum: 0});
        }
        const nodeStats = stats.get(node);
        nodeStats.total += totalReqCount;
        nodeStats.weightedSum += avgTime * totalReqCount;
    }

    // Convert to node -> avg
    const result = Object.create(null);
    for (const [node, {total, weightedSum}] of stats.entries()) {
        if (total > 0) {
            result[node] = weightedSum / total;
        }
    }
    return result;
}

function countRequestsByNode(logPath) {
    let lines;
    try {
        // -s -1 is important to ignore the first metadata field printed by rsyslog to the HAProxy log file
        // -H to aggregate; -srv to summarize per server
        lines = processCommand(`cat ${logPath} | halog -s -1 -H -srv`);
    } catch (e) {
        console.error('Failed to execute halog. Is it installed and in PATH?');
        throw e;
    }

    const counts = Object.create(null);
    const delimiter = ' ';
    const serverNameCol = 0;
    const totReqCountCol = 7;

    for (const line of lines) {
        if (!line) continue;
        const fields = line.split(delimiter);
        let serverName = fields[serverNameCol];
        if (!serverName) continue;

        // Expect format like all_handlers/selma -> keep part after '/'
        const parts = serverName.split('/');
        const node = parts.length > 1 ? parts[1] : serverName;

        const totalReqCount = Number.parseInt(fields[totReqCountCol], 10);
        if (!Number.isFinite(totalReqCount)) continue;

        counts[node] = (counts[node] || 0) + totalReqCount;
    }

    return counts;
}

function sendToGraphite(host, port, metrics) {
    return new Promise((resolve, reject) => {
        const client = new net.Socket();
        let resolved = false;

        client.connect(port, host, () => {
            const ts = Math.floor(Date.now() / 1000);
            const lines = [];
            for (const {path, value} of metrics) {
                lines.push(`${path} ${value} ${ts}`);
            }
            const payload = lines.join('\n') + '\n';
            client.write(payload, 'utf8', () => {
                client.end();
            });
        });

        client.on('error', (err) => {
            if (!resolved) {
                resolved = true;
                reject(err);
            }
        });

        client.on('close', () => {
            if (!resolved) {
                resolved = true;
                resolve();
            }
        });
    });
}

async function main() {
    const argv = yargs(hideBin(process.argv))
        .usage('Usage: node $0 [options]')
        .option('haproxy-log', {
            describe: 'Path to HAProxy log file',
        })
        .default('haproxy-log', '/var/log/haproxy.log')
        .option('graphite-host', {
            describe: 'Graphite/Carbon host',
        })
        .default('graphite-host', '127.0.0.1')
        .option('graphite-port', {
            describe: 'Graphite/Carbon TCP port',
        })
        .default('graphite-port', 2003)
        .help('help')
        .alias('help', 'h')
        .argv;

    const haproxyLog = argv.haproxyLog;
    const graphiteHost = argv.graphiteHost;
    const graphitePort = Number.parseInt(argv.graphitePort);

    if (!graphitePort || Number.isNaN(graphitePort)) {
        console.error('Invalid --graphite-port value.');
        process.exit(1);
    }

    const counts = countRequestsByNode(haproxyLog);

    // Prepare metrics in Graphite plaintext format
    const metrics = [];
    for (const [node, total] of Object.entries(counts)) {
        const nodeSafe = sanitizeForGraphite(node);
        const path = `halog_live.unipeptapi.${nodeSafe}.request_count`;
        metrics.push({path, value: total});
    }

    // Compute average response time for the last minute per node
    let avgs = {};
    try {
        avgs = avgLatencyByNodeFromRecent(haproxyLog);
        console.log('Computed avg latency metrics:', avgs);
    } catch (e) {
        // If halog is missing or parsing fails, keep service running and just skip avg metrics this round
        console.error('Failed to compute avg latency metrics:', e.message || e);
        process.exitCode = 1;
    }
    for (const [node, avg] of Object.entries(avgs)) {
        const nodeSafe = sanitizeForGraphite(node);
        const path = `halog_live.unipeptapi.${nodeSafe}.avg_response_time`;
        metrics.push({path, value: avg});
    }

    if (metrics.length === 0) {
        // Nothing to send; exit quietly to be cron/systemd friendly.
        return;
    }

    try {
        await sendToGraphite(graphiteHost, graphitePort, metrics);
    } catch (err) {
        // Log error but do not throw to keep the service resilient
        console.error(`Failed to send metrics to Graphite at ${graphiteHost}:${graphitePort}:`, err.message || err);
        process.exitCode = 1;
    }
}

await main();


