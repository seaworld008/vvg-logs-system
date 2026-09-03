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
group. This is a native Nightingale dashboard. Do not use the Grafana
compatibility importer for the final Nightingale copy because transformed table
panels are downgraded to the unsupported `unknown` type.

The bundled vmagent scrape configuration labels the local node-exporter target
with `automq_host="true"`, so host resource alerts do not match other nodes.
