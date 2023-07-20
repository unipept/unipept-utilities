/**
 * This script expects a parsed HALog file and will write the resulting information to a MySQL database. The database
 * name is passed as an argument to this script and should already be initialized with the default schema that can
 * be found in the "schema" directory.
 *
 * @author Pieter Verschaffelt
 */

import readline from "readline";
import mysql from "mysql2";

const args = process.argv;

if (args.length !== 5) {
    console.error("This script expects exactly three arguments.");
    console.error("HAProxy log data will be read from stdin.")
    console.error("example: cat /var/log/haproxy.log | halog -u -H | node collect.js <mysql_user> <mysql_password> <database_name>");
    process.exit(1);
}

const mysqlUser = args[2];
const mysqlPassword = args[3];
const databaseName = args[4];

const con = mysql.createConnection({
    user: mysqlUser,
    password: mysqlPassword,
    database: databaseName
});

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

// Some constants to parse the input lines read by this script.
const delimiter = " ";
const totalReqCountCol = 0;
const badReqCountCol = 1;
const avgTimeCol = 3;
const endpointCol = 8;

// A list of strings that the endpoint should contain in order to be kept in the database. If an endpoint does not
// contain a value in this array, it will be refused.
const accepted_endpoints = ["/mpa", "/private_api", "/api"];

let lineIdx = 0;
const lines = [];
rl.on("line",  (line) => {
    if (lineIdx === 0) {
        lineIdx++;
        return;
    }

    lineIdx++;

    lines.push(line);
});

await new Promise((resolve, reject) => {
    rl.on("close", () => {
        resolve();
    });
});

// All done
for (const line of lines) {
    const fields = line.split(delimiter);
    const totalReqCount = Number.parseInt(fields[totalReqCountCol]);
    const badReqCount = Number.parseInt(fields[badReqCountCol]);
    const avgTime = Number.parseFloat(fields[avgTimeCol]);
    const endpoint = fields[endpointCol]
        .replace("https://api.unipept.ugent.be", "")
        .replace("http://api.unipept.ugent.be", "");

    if (accepted_endpoints.some(v => endpoint.includes(v))) {
        con.query(
            `INSERT INTO endpoint_stats (date, endpoint, req_successful, req_error, avg_duration)
         VALUES (CURDATE(), ?, ?, ?, ?);`,
            [endpoint, totalReqCount - badReqCount, badReqCount, avgTime],
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

con.end();
