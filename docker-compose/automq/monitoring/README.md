# AutoMQ monitoring assets

`grafana/automq-cluster.json` is derived from AutoMQ `1.7.4` at
`docker/telemetry/grafana/provisioning/dashboards/User/cluster.json`.
The repository copy fixes the UID to `automq-cluster-overview` and keeps the
Prometheus datasource variable named `datasource`.

`alert-rules.yml` keeps the official AutoMQ metric names and adds Vector
producer/consumer and shared-host resource gates. Import the rules into the
existing Nightingale business group after confirming its VictoriaMetrics
datasource. Do not put notification tokens or real contact details in Git.

The bundled vmagent scrape configuration labels the local node-exporter target
with `automq_host="true"`, so host resource alerts do not match other nodes.
