# AutoMQ monitoring assets

`grafana/automq-cluster.json` is derived from AutoMQ `1.7.4` at
`docker/telemetry/grafana/provisioning/dashboards/User/cluster.json`.
The repository copy fixes the UID to `automq-cluster-overview` and keeps the
Prometheus datasource variable named `datasource`.

`alert-rules.yml` keeps the official AutoMQ metric names and adds Vector
producer/consumer and shared-host resource gates. The dashboard and rules are
owned by the Jinling Cloud SaaS log system and must be imported into that
project's Nightingale business group after confirming its VictoriaMetrics
datasource. Do not place them in a generic infrastructure group, and do not put
notification tokens or real contact details in Git.

Import `nightingale/automq-cluster.json` into the Jinling Cloud SaaS business
group. This is the production Nightingale dashboard and uses only native
Nightingale v9 panel types. It keeps the official cluster queries, then adds
Broker queues and latency, KRaft, JVM, object-storage/WAL/cache, Vector lag and
buffer, host resources and vmagent health. Every panel has a human-readable
name and description. Do not use the Grafana compatibility importer for the
final Nightingale copy: the official overview intentionally leaves six stat
titles empty and its transformed table panels lose important labels after
conversion.

The repository-level `docs/images/automq-dashboard-overview.png` is a sanitized
layout preview with example values. Never replace it with a live production
screenshot or runtime data.

The bundled vmagent scrape configuration labels the local node-exporter target
with `automq_host="true"`, so host resource alerts do not match other nodes. It
also scrapes VictoriaLogs and vmagent itself. Set
`VICTORIALOGS_METRICS_TARGET` to the reachable `host:port` of the production
VictoriaLogs instance before rendering runtime configuration.

The AutoMQ Cloud documentation describes separate Cluster, Broker, Topic and
Group dashboards, but those templates are distributed through the AutoMQ Cloud
workflow rather than the open-source `1.7.4` repository. Community Kafka
dashboards generally expect JMX Exporter metric names and cannot be imported
unchanged against AutoMQ's `kafka_*` and `kafka_stream_*` metrics. The native
dashboard therefore stays pinned to AutoMQ's own metric contract instead of
pretending a visually richer but incompatible community dashboard works.
