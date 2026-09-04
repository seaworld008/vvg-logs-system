# VictoriaLogs monitoring assets

`grafana/victorialogs-v1.52.0.json` is the official VictoriaLogs single-node
dashboard published with VictoriaLogs `v1.52.0`. It is vendored byte-for-byte
from:

```text
https://github.com/VictoriaMetrics/VictoriaLogs/blob/v1.52.0/dashboards/victorialogs.json
```

Expected SHA-256:

```text
07a17ece43627672bdc8335a6e51a881c11ae58f184f51623094e204d84be569
```

The dashboard contains 73 panels covering availability, ingestion, query
latency and concurrency, dropped logs, storage, merges, CPU, memory, disk I/O,
file descriptors and process restarts. Its default range is three hours. The
dashboard expects a Prometheus-compatible datasource and the standard `job`,
`instance` and `version` labels emitted by vmagent.

`nightingale/victorialogs-v1.52.0.json` is the Nightingale v9.1.1 native import
of the same pinned dashboard. It keeps all 73 panels, removes the duplicate
datasource variable created by the compatibility importer, and converts the
single unsupported Grafana table (`Non-default flags`) to a native bar gauge.
No metric query is changed.

Import the native JSON into the Jinling Cloud SaaS business group and select
the existing VictoriaMetrics datasource. The production vmagent must scrape
the VictoriaLogs `/metrics` endpoint under the `victorialogs` job before the
dashboard is imported.

Refresh the pinned copy only when VictoriaLogs itself is upgraded:

```bash
node scripts/vendor-victorialogs-dashboard.mjs
node scripts/vendor-victorialogs-dashboard.mjs --check
```

Do not replace the pinned URL with a branch URL or a Grafana.com download URL.
The Git tag and SHA-256 are the provenance and rollback boundary.
