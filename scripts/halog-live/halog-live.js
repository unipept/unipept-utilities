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


