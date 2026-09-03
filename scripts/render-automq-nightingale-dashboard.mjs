import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const output = resolve(root, "docker-compose/automq/monitoring/nightingale/automq-cluster.json");
const datasource = { cate: "prometheus", value: "${datasource}" };

const thresholds = (warning = null) => ({
  mode: "absolute",
  style: "line",
  steps: [
    { color: "#73BF69", value: null, type: "base" },
    ...(warning === null ? [] : [{ color: "#F2495C", value: warning }]),
  ],
});

const options = (unit = "none", warning = null) => ({
  valueMappings: [],
  thresholds: thresholds(warning),
  standardOptions: { util: unit },
  legend: { displayMode: "list", placement: "bottom" },
  tooltip: { mode: "all", sort: "desc" },
});

const target = (refId, expr, legend) => ({ refId, expr, legend });

const panel = (id, type, name, layout, targets, unit = "none", warning = null) => ({
  version: "3.4.0",
  id,
  type,
  name,
  links: [],
  layout: { ...layout, i: id },
  targets,
  options: options(unit, warning),
  custom: type === "stat"
    ? { version: "3.4.0", textMode: "value", calc: "lastNotNull", colorMode: "value" }
    : type === "barGauge"
      ? { version: "3.4.0", calc: "lastNotNull" }
      : {
          version: "3.4.0",
          drawStyle: "lines",
          lineInterpolation: "linear",
          fillOpacity: 0.2,
          stack: "off",
        },
  maxPerRow: 4,
  datasourceCate: "prometheus",
  datasourceValue: "${datasource}",
});

const stat = (id, name, layout, expr, legend, unit = "none", warning = null) =>
  panel(id, "stat", name, layout, [target("A", expr, legend)], unit, warning);
const timeseries = (id, name, layout, targets, unit = "none") =>
  panel(id, "timeseries", name, layout, targets, unit);
const barGauge = (id, name, layout, targets) =>
  panel(id, "barGauge", name, layout, targets);

const dashboard = {
  name: "AutoMQ Production Cluster",
  tags: "automq production logs",
  note: "AutoMQ log buffer health, throughput, lag and recovery signals.",
  ident: "automq-production-cluster",
  uuid: 1788455364871000,
  configs: {
    version: "3.4.0",
    links: [],
    var: [
      {
        type: "query",
        name: "cluster_id",
        label: "Cluster",
        allOption: false,
        multi: false,
        reg: "",
        hide: false,
        definition: "label_values(kafka_broker_active_count,job)",
        datasource,
      },
      {
        type: "datasource",
        name: "datasource",
        label: "Data Source",
        definition: "prometheus",
        hide: false,
      },
    ],
    panels: [
      stat("automq-controller", "Active Controller", { h: 6, w: 4, x: 0, y: 0 },
        'sum(kafka_controller_active_count{job="$cluster_id"})', "controller"),
      stat("automq-broker", "Active Broker", { h: 6, w: 4, x: 4, y: 0 },
        'sum(kafka_broker_active_count{job="$cluster_id"})', "broker"),
      stat("automq-fenced", "Fenced Broker", { h: 6, w: 4, x: 8, y: 0 },
        'sum(kafka_broker_fenced_count{job="$cluster_id"}) or vector(0)', "fenced", "none", 1),
      stat("automq-topics", "Topics", { h: 6, w: 4, x: 12, y: 0 },
        'sum(kafka_topic_count{job="$cluster_id"})', "topics"),
      stat("automq-partitions", "Partitions", { h: 6, w: 4, x: 16, y: 0 },
        'sum(kafka_partition_total_count{job="$cluster_id"})', "partitions"),
      stat("automq-size", "Stored Log Bytes", { h: 6, w: 4, x: 20, y: 0 },
        'sum(max by(topic,partition) (kafka_log_size{job="$cluster_id"}))', "bytes", "bytesIEC"),
      timeseries("automq-network", "Broker Bytes In / Out", { h: 10, w: 12, x: 0, y: 6 }, [
        target("A", 'sum(rate(kafka_broker_network_io_bytes_total{job="$cluster_id",direction="in"}[$__rate_interval]))', "in"),
        target("B", 'sum(rate(kafka_broker_network_io_bytes_total{job="$cluster_id",direction="out"}[$__rate_interval]))', "out"),
      ], "bytesSIps"),
      timeseries("automq-requests", "Produce / Fetch Requests", { h: 10, w: 12, x: 12, y: 6 }, [
        target("A", 'sum(rate(kafka_request_count_total{job="$cluster_id",type="Produce"}[$__rate_interval]))', "produce"),
        target("B", 'sum(rate(kafka_request_count_total{job="$cluster_id",type="Fetch"}[$__rate_interval]))', "fetch"),
        target("C", 'sum(rate(kafka_request_error_count_total{job="$cluster_id",error!="NONE"}[$__rate_interval])) or vector(0)', "errors"),
      ], "reqps"),
      timeseries("automq-latency", "Kafka Request P99", { h: 10, w: 12, x: 0, y: 16 }, [
        target("A", 'max(kafka_request_time_99p_milliseconds{job="$cluster_id",type="Produce"})', "produce"),
        target("B", 'max(kafka_request_time_99p_milliseconds{job="$cluster_id",type="Fetch"})', "fetch"),
      ], "ms"),
      timeseries("automq-topic-rate", "Topic Message Rate", { h: 10, w: 12, x: 12, y: 16 }, [
        target("A", 'sum by(topic) (rate(kafka_message_count_total{job="$cluster_id",direction="in"}[$__rate_interval]))', "{{topic}} in"),
      ], "mps"),
      timeseries("automq-consumer-lag", "Vector Consumer Lag", { h: 10, w: 12, x: 0, y: 26 }, [
        target("A", 'sum by(consumer_group,topic) (clamp_min(vector_kafka_consumer_lag{partition_id!="-1"},0))', "{{consumer_group}} / {{topic}}"),
      ]),
      timeseries("automq-producer-buffer", "Vector Producer Disk Buffer", { h: 10, w: 12, x: 12, y: 26 }, [
        target("A", 'sum by(component_id,host) (vector_buffer_size_bytes{component_type="kafka",component_id=~"automq(_lane_[ab])?"})', "{{host}} / {{component_id}}"),
      ], "bytesIEC"),
      barGauge("automq-groups", "Consumer Group State", { h: 9, w: 12, x: 0, y: 36 }, [
        target("A", 'sum(kafka_group_count{job="$cluster_id"})', "total"),
        target("B", 'sum(kafka_group_stable_count{job="$cluster_id"})', "stable"),
        target("C", 'sum(kafka_group_empty_count{job="$cluster_id"})', "empty"),
        target("D", 'sum(kafka_group_dead_count{job="$cluster_id"})', "dead"),
      ]),
      timeseries("automq-s3", "Object Storage Operations", { h: 9, w: 12, x: 12, y: 36 }, [
        target("A", 'sum by(operation_name,status) (rate(kafka_stream_operation_latency_count{operation_type="S3Request"}[$__rate_interval]))', "{{operation_name}} / {{status}}"),
      ], "reqps"),
    ],
  },
};

const rendered = `${JSON.stringify(dashboard, null, 2)}\n`;
if (process.argv.includes("--check")) {
  if (readFileSync(output, "utf8") !== rendered) {
    throw new Error("Nightingale AutoMQ dashboard is not freshly rendered");
  }
} else {
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, rendered, "utf8");
  console.log(`Rendered ${dashboard.configs.panels.length} Nightingale AutoMQ panels`);
}
