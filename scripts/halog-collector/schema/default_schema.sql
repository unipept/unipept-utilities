CREATE DATABASE IF NOT EXISTS load_balancer_stats;

USE load_balancer_stats;

CREATE TABLE endpoint_stats (
    id INTEGER NOT NULL AUTO_INCREMENT,
    date TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    req_successful INTEGER,
    req_error INTEGER,
    avg_duration REAL,
    PRIMARY KEY (id)
);

CREATE TABLE node_stats (
    id INTEGER NOT NULL AUTO_INCREMENT,
    date TEXT NOT NULL,
    node TEXT NOT NULL,
    req_successful INTEGER,
    req_error INTEGER,
    avg_duration REAL,
    PRIMARY KEY (id)
);

CREATE TABLE source_stats (
    id INTEGER NOT NULL AUTO_INCREMENT,
    date TEXT NOT NULL,
    source TEXT NOT NULL,
    req_total INTEGER,
    PRIMARY KEY (id)
);
