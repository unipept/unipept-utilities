/**
 * This script expects a parsed HALog file and will write the resulting information to a MySQL database. The database
 * name is passed as an argument to this script and should already be initialized with the default schema that can
 * be found in the "schema" directory.
 *
 * @author Pieter Verschaffelt
 */

import mysql from "mysql2";
import { execSync } from "node:child_process";

import yargs from "yargs";
import { hideBin } from "yargs/helpers";

const setupDatabase = function(argv) {
    return mysql.createConnection({
        user: argv.dbUser,
        password: argv.dbPassword,
        database: argv.dbName,
        port: argv.dbPort,
        host: argv.dbHost
    });
}

/**
 * Process a given command (run it through the shell), extract it's output and sanitize it (e.g. remove the header,
 * trailing newlines and the status message at the end of the command's output).
 *
 * @param command The shell command that should be executed.
 * @returns string[] An array of output returned by the given command.
 */
const processCommand = function(command) {
    let lineIdx = 0;
    const lines = [];

    const stdout = execSync(command, { encoding: "utf-8" });

    for (const line of stdout.split("\n")) {
        if (lineIdx === 0) {
            lineIdx++;
            continue;
        }

        lineIdx++;
        lines.push(line.trimEnd());
    }

    // Remove the last line, which is the status message of the command.
    lines.splice(-1, 1);
    return lines;
}

/**
 * This function analyzes the HAProxy logfile (using the halog command) and keeps track of how many times each Unipept
 * API-endpoint has been called (including successful and failed requests) and how long the average call took.
 *
 * @param dbConnection A valid connection to the database in which the summarized results should be kept.
 * @param halogPath The path to the HAProxy log file that should be analyzed.
 */
const processEndpoints = function(dbConnection, halogPath) {
    const lines = processCommand(`cat ${halogPath} | halog -u -H`);

    // Some constants to parse the input lines read by this script.
    const delimiter = " ";
    const totalReqCountCol = 0;
    const badReqCountCol = 1;
    const avgTimeCol = 3;
    const endpointCol = 8;

    // A list of strings that the endpoint should contain in order to be kept in the database. If an endpoint does not
    // contain a value in this array, it will be refused.
    const accepted_endpoints = ["/mpa", "/private_api", "/api"];

    const stats = new Map();

    // All done
    for (const line of lines) {
        const fields = line.split(delimiter);
        const totalReqCount = Number.parseInt(fields[totalReqCountCol]);
        const badReqCount = Number.parseInt(fields[badReqCountCol]);
        const avgTime = Number.parseFloat(fields[avgTimeCol]);
        const endpoint = fields[endpointCol]
            .replace("https://api.unipept.ugent.be", "")
            .replace("http://api.unipept.ugent.be", "")
            .replace("//", "/");

        if (accepted_endpoints.some(v => endpoint.includes(v))) {
            const currentStat = {
                totalReqCount,
                badReqCount,
                avgTime
            }

            if (stats.has(endpoint)) {
                currentStat.totalReqCount += stats.get(endpoint).totalReqCount;
                currentStat.badReqCount += stats.get(endpoint).badReqCount;
                currentStat.avgTime = (
                    currentStat.avgTime * totalReqCount +
                    stats.get(endpoint).avgTime * stats.get(endpoint).totalReqCount
                ) / (currentStat.totalReqCount + stats.get(endpoint).totalReqCount);
            }

            stats.set(endpoint, currentStat);
        }
    }

    // Check if yesterday's data is already present in the database and remove it (we will replace it with the new data).
    dbConnection.query(
        `DROP FROM endpoint_stats WHERE date = SUBDATE(CURDATE(), 1);`
    );

    for (const [endpoint, stat] of stats) {
        dbConnection.query(
            `INSERT INTO endpoint_stats (date, endpoint, req_successful, req_error, avg_duration) VALUES (SUBDATE(CURDATE(), 1), ?, ?, ?, ?);`,
            [endpoint, stat.totalReqCount - stat.badReqCount, stat.badReqCount, stat.avgTime],
            (err, result) => {
                if (err) {
                    console.error("Error while inserting data into MySQL database.");
                    console.error(err);
                    process.exit(3);
                }
            }
        );
    }
}

/**
 * Process the HAProxy log file and keep track of how many times each of the different handling nodes has been called.
 *
 * @param dbConnection The connection with the database that should be filled with the aggregated statistics.
 * @param halogPath HAProxy configuration file containing information about which node handled which requests.
 */
const processNodes = function(dbConnection, halogPath) {
    const lines = processCommand(`cat ${halogPath} | halog -H -srv`);

    // Some constants to parse the input lines read by this script.
    const delimiter = " ";
    const serverNameCol = 0;
    const totReqCountCol = 7;
    const successfulReqCountCol = 8;
    const avgTimeCol = 11;

    const acceptedNodes = [
        "patty",
        "selma",
        "rick",
        "sherlock"
    ]

    const stats = new Map();

    for (const line of lines) {
        const fields = line.split(delimiter);
        let serverName = fields[serverNameCol];

        if (!acceptedNodes.some((n) => serverName.includes(n))) {
            continue;
        }


        serverName = serverName.split("/")[1];

        const totalReqCount = Number.parseInt(fields[totReqCountCol]);
        const successfulReqCount = Number.parseInt(fields[successfulReqCountCol]);
        const badReqCount = totalReqCount - successfulReqCount;
        const avgTime = Number.parseFloat(fields[avgTimeCol]);

        const currentStat = {
            totalReqCount,
            badReqCount,
            avgTime
        }

        if (stats.has(serverName)) {
            currentStat.totalReqCount += stats.get(serverName).totalReqCount;
            currentStat.badReqCount += stats.get(serverName).badReqCount;
            currentStat.avgTime = (
                currentStat.avgTime * totalReqCount +
                stats.get(serverName).avgTime * stats.get(serverName).totalReqCount
            ) / (currentStat.totalReqCount + stats.get(serverName).totalReqCount);
        }

        stats.set(serverName, currentStat);
    }

    // Check if yesterday's data is already present in the database and remove it (we will replace it with the new data).
    dbConnection.query(
        `DROP FROM node_stats WHERE date = SUBDATE(CURDATE(), 1);`
    );

    for (const [serverName, stat] of stats) {
        dbConnection.query(
            `INSERT INTO node_stats (date, node, req_successful, req_error, avg_duration) VALUES (SUBDATE(CURDATE(), 1), ?, ?, ?, ?);`,
            [serverName, stat.totalReqCount - stat.badReqCount, stat.badReqCount, stat.avgTime],
            (err, result) => {
                if (err) {
                    console.error("Error while inserting data into MySQL database.");
                    console.error(err);
                    process.exit(3);
                }
            }
        );
    }
}

/**
 * Process the HAProxy log file and keep track of where the requests originated from (CLI, Desktop app, Browser or other).
 *
 * @param dbConnection A valid connection to the database in which the summarized results should be kept.
 * @param halogPath The path to the HAProxy log file that should be analyzed.
 */
const processSources = function(dbConnection, halogPath) {
    const userAgentCounts = processCommand(`cat ${halogPath} | grep "{" | cut -d "{" -f 2 | cut -d "}" -f 1 | sort | uniq -c`);

    let desktopCounts = 0;
    let cliCounts = 0;
    let webCounts = 0;
    let otherCounts = 0;

    const matchesBrowser = function(userAgent) {
        const tests = [
            /chrome|chromium|crios/i,
            /firefox|fxios/i,
            /safari/i,
            /opr/i,
            /edg/i,
        ];

        return tests.some(t => userAgent.match(t));
    }

    for (const line of userAgentCounts) {
        // Remove both leading and trailing spaces
        const trimmed = line.trim();

        const fields = trimmed.split(" ");
        const counts = Number.parseInt(fields[0]);
        const userAgent = fields.slice(1).join(" ");

        if (userAgent.toLowerCase().includes("unipeptdesktop")) {
            desktopCounts += counts;
        } else if (userAgent.toLowerCase().includes("unipept cli")) {
            cliCounts += counts;
        } else if (matchesBrowser(userAgent)) {
            webCounts += counts;
        } else {
            otherCounts += counts;
        }
    }


    // Check if yesterday's data is already present in the database and remove it (we will replace it with the new data).
    dbConnection.query(
        `DROP FROM source_stats WHERE date = SUBDATE(CURDATE(), 1);`
    );

    for (const [sourceName, counts] of new Map([[ "desktop", desktopCounts ], [ "cli", cliCounts ], [ "web", webCounts ], [ "other", otherCounts ]])) {
        dbConnection.query(
            `INSERT INTO source_stats (date, source, req_total) VALUES (SUBDATE(CURDATE(), 1), ?, ?);`,
            [sourceName, counts],
            (err, result) => {
                if (err) {
                    console.error("Error while inserting data into MySQL database.");
                    console.error(err);
                    process.exit(3);
                }
            }
        );
    }
}


const argv = yargs(hideBin(process.argv))
    .usage('Usage: node $0 <command> [options]')
    .command(
        "endpoints",
        "Collect endpoint statistics and counts (i.e. which API-endpoint is called how many times?).",
        () => {},
        (argv) => {
            const db = setupDatabase(argv);
            processEndpoints(db, argv.haproxyConfig);
            db.end();
        }
    )
    .command(
        "nodes",
        "Collect node statistics and counts (i.e. which server is handling how many requests?).",
        () => {},
        (argv) => {
            const db = setupDatabase(argv);
            processNodes(db, argv.haproxyConfig);
            db.end();
        }
    )
    .command(
        "sources",
        "Collect user agent statistics and count how many times the browser / desktop / cli app was used.",
        () => {},
        (argv) => {
            const db = setupDatabase(argv);
            processSources(db, argv.haproxyConfig);
            db.end();
        }
    )
    .option("db-user", {
        alias: "u",
        describe: "The username that should be used to connect to the MySQL database.",
    })
    .default("db-user", "root")
    .option("db-password", {
        alias: "p",
        describe: "The password that should be used to connect to the MySQL database.",
    })
    .default("db-password", "")
    .option("db-name", {
        describe: "The name of the MySQL database in which the results should be stored."
    })
    .default("db-name", "statistics")
    .option("db-host", {
        describe: "The host of the MySQL database in which the results should be stored. Defaults to \"localhost\""
    })
    .default("db-host", "localhost")
    .option("db-port", {
        describe: "The port of the MySQL database in which the results should be stored. Defaults to 3306."
    })
    .default("db-port", "3306")
    .option("haproxy-config", {
        describe: "The path to the HAProxy log file that should be used to collect endpoint statistics."
    })
    .default("haproxy-config", "/var/log/haproxy.log")
    .help("help")
    .alias("help", "h")
    .argv;
