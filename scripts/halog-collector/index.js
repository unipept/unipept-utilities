/**
 * This script expects a parsed HALog file and will write the resulting information to a sqlite-database. The first 
 * argument to this file is the location of an SQLite-database to which the parsed information will be written.
 * 
 * @author Pieter Verschaffelt
 */

const readline = require("readline");
const betterSqlite = require("better-sqlite3");
const fs = require("fs");

const args = process.argv;

if (args.length !== 3) {
    console.error("This script expects exactly one argument.");
    console.error("HAProxy log data will be read from stdin.")
    console.error("example: halog -u -H /var/log/haproxy.log | node collect.js <database_file.sqlite>");
    process.exit(1);
}

const databasePath = args[2];

let db;
if (fs.existsSync(databasePath)) {
    db = betterSqlite(databasePath);
} else {
    // If the file does not exist yet, we need to initialize this database first.
    db = betterSqlite(databasePath);
    const dbSchema = fs.readFileSync("./schema/default_schema.sql", "utf-8");
    db.exec(dbSchema);
}

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

// Some constants to parse the input lines read by this script.
const delimiter = "\t";
const totalReqCountCol = 0;
const badReqCountCol = 1;
const avgTimeCol = 3;
const endpointCol = 8;

const insertStmt = db.prepare(
    `
    INSERT INTO endpoint_stats (date, endpoint, req_successful, req_error, avg_duration)
    VALUES (date(), ?, ?, ?, ?);
    `
);
  
rl.on("line", (line) => {
    const fields = line.split(delimiter);
    const totalReqCount = Number.parseInt(fields[totalReqCountCol]);
    const badReqCount = Number.parseInt(fields[badReqCountCol]);
    const avgTime = Number.parseFloat(fields[avgTimeCol]);
    const endpoint = fields[endpointCol];

    insertStmt.run(endpoint, totalReqCount - badReqCount, badReqCount, avgTime);
});

rl.on("close", () => {
    // All done
    process.exit(0);
});
