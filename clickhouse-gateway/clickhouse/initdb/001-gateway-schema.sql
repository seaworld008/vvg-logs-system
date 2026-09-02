CREATE DATABASE IF NOT EXISTS gateway_logs;

CREATE TABLE IF NOT EXISTS gateway_logs.gateway_access
(
    timestamp DateTime64(3, 'Asia/Shanghai') CODEC(DoubleDelta, ZSTD(1)),
    createdtime DateTime64(3, 'Asia/Shanghai') CODEC(DoubleDelta, ZSTD(1)),
    server_ip String CODEC(ZSTD(1)),
    domain LowCardinality(String),
    request_method LowCardinality(String),
    status UInt16,
    business_code Int32 DEFAULT 0,
    top_path LowCardinality(String),
    path String CODEC(ZSTD(1)),
    query String CODEC(ZSTD(1)),
    protocol LowCardinality(String),
    referer String CODEC(ZSTD(1)),
    upstreamhost LowCardinality(String),
    responsetime Float32,
    upstreamtime Float32,
    duration Float32,
    request_length UInt32,
    response_length UInt32,
    client_ip String,
    client_latitude Nullable(Float32),
    client_longitude Nullable(Float32),
    remote_user String,
    remote_ip String,
    xff String CODEC(ZSTD(1)),
    client_city LowCardinality(String),
    client_region LowCardinality(String),
    client_country LowCardinality(String),
    http_user_agent String CODEC(ZSTD(1)),
    client_browser_family LowCardinality(String),
    client_browser_major LowCardinality(String),
    client_os_family LowCardinality(String),
    client_os_major LowCardinality(String),
    client_device_brand LowCardinality(String),
    client_device_model LowCardinality(String),
    trace_id String,
    version LowCardinality(String),
    app_id String,
    platform_id UInt32 DEFAULT 0,
    tenant_id UInt32 DEFAULT 0,
    user_id UInt64 DEFAULT 0,
    user_type UInt8 DEFAULT 0,
    INDEX idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_app_id app_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_user_id user_id TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
PRIMARY KEY (timestamp, domain, status, top_path)
ORDER BY (timestamp, domain, status, top_path, upstreamhost, path)
TTL toDateTime(timestamp) + INTERVAL 30 DAY DELETE
SETTINGS index_granularity = 8192;
