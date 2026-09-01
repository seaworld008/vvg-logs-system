ARG GRAFANA_VERSION=13.2.0-ubuntu
FROM grafana/grafana:${GRAFANA_VERSION}

ARG VICTORIALOGS_PLUGIN_VERSION=0.31.0

ENV GF_PATHS_PLUGINS=/var/lib/grafana-plugins

USER root
RUN mkdir -p "${GF_PATHS_PLUGINS}" && \
    chown -R grafana:0 "${GF_PATHS_PLUGINS}"

USER grafana
RUN grafana cli --pluginsDir "${GF_PATHS_PLUGINS}" \
    plugins install victoriametrics-logs-datasource "${VICTORIALOGS_PLUGIN_VERSION}"
