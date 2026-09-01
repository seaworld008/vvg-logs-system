ARG GRAFANA_VERSION=13.2.0-ubuntu
FROM grafana/grafana:${GRAFANA_VERSION}

ARG VICTORIALOGS_PLUGIN_VERSION=0.31.0

RUN grafana cli --pluginsDir /var/lib/grafana/plugins \
    plugins install victoriametrics-logs-datasource "${VICTORIALOGS_PLUGIN_VERSION}"
