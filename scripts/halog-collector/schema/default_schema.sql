CREATE TABLE endpoint_stats (
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    req_successful INTEGER,
    req_error INTEGER,
    avg_duration REAL
);
