import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const output = resolve(root, "docker-compose/automq/monitoring/nightingale/automq-cluster.json");
const datasource = { cate: "prometheus", value: "${datasource}" };

const thresholdSteps = (warning = null, critical = null) => ({
  mode: "absolute",
  style: "line",
  steps: [
    { color: "#73BF69", value: null, type: "base" },
    ...(warning === null ? [] : [{ color: "#FADE2A", value: warning }]),
    ...(critical === null ? [] : [{ color: "#F2495C", value: critical }]),
  ],
});

const options = (unit = "none", warning = null, critical = null) => ({
  valueMappings: [],
  thresholds: thresholdSteps(warning, critical),
  standardOptions: { unit },
  legend: { displayMode: "table", placement: "bottom" },
  tooltip: { mode: "all", sort: "desc" },
});

const target = (refId, expr, legend, instant = false) => ({ refId, expr, legend, instant });

const panel = (id, type, name, description, layout, targets, unit = "none", warning = null, critical = null) => ({
  version: "3.4.0",
  id,
  type,
  name,
  description,
  links: [],
  layout: { ...layout, i: id },
  targets,
  options: options(unit, warning, critical),
  custom: type === "stat"
    ? { version: "3.4.0", textMode: "valueAndName", calc: "lastNotNull", colorMode: "value", textSize: {} }
    : type === "barGauge"
      ? { version: "3.4.0", calc: "lastNotNull", displayMode: "basic", orientation: "horizontal", textSize: {} }
      : {
          version: "3.4.0",
          drawStyle: "lines",
          lineInterpolation: "linear",
          lineWidth: 2,
          fillOpacity: 0.18,
          gradientMode: "none",
          showPoints: "never",
          scaleDistribution: { type: "linear" },
          stack: "off",
        },
  overrides: [],
  transformationsNG: [],
  maxPerRow: 4,
  datasourceCate: "prometheus",
  datasourceValue: "${datasource}",
});

const row = (id, name, y) => ({
  version: "3.4.0",
  id,
  type: "row",
  name,
  collapsed: true,
  layout: { h: 1, w: 24, x: 0, y, i: id, isResizable: false },
  targets: [],
  options: {},
  custom: {},
  overrides: [],
  transformationsNG: [],
});

const stat = (id, name, description, layout, expr, legend, unit = "none", warning = null, critical = null) =>
  panel(id, "stat", name, description, layout, [target("A", expr, legend, true)], unit, warning, critical);
const availabilityStat = (id, name, description, layout, expr, legend) => {
  const result = stat(id, name, description, layout, expr, legend);
  result.options.thresholds.steps = [
    { color: "#F2495C", value: null, type: "base" },
    { color: "#73BF69", value: 1 },
  ];
  return result;
};
const timeseries = (id, name, description, layout, targets, unit = "none", warning = null, critical = null) =>
  panel(id, "timeseries", name, description, layout, targets, unit, warning, critical);
const barGauge = (id, name, description, layout, targets, unit = "none") =>
  panel(id, "barGauge", name, description, layout, targets, unit);

const dashboard = {
  name: "AutoMQ 生产集群监控（官方指标增强版）",
  tags: "automq production kafka victorialogs vector",
  note: "基于 AutoMQ 1.7.4 官方 Cluster Overview 与 Prometheus 指标语义，补齐夜莺原生标题、说明、Broker/请求/KRaft/JVM/S3/WAL/Vector 链路监控。单节点部署不是高可用架构。",
  ident: "automq-production-cluster",
  uuid: 1788455364871001,
  configs: {
    version: "3.4.0",
    links: [
      {
        title: "AutoMQ 1.7.4 官方监控源",
        url: "https://github.com/AutoMQ/automq/blob/1.7.4/docker/telemetry/grafana/provisioning/dashboards/User/cluster.json",
        targetBlank: true,
      },
      {
        title: "AutoMQ 指标说明",
        url: "https://docs.automq.com/automq/observability/metrics",
        targetBlank: true,
      },
    ],
    var: [
      {
        type: "datasource",
        name: "datasource",
        label: "数据源",
        definition: "prometheus",
        hide: false,
      },
      {
        type: "query",
        name: "cluster_id",
        label: "AutoMQ 集群",
        allOption: false,
        multi: false,
        reg: "",
        hide: false,
        definition: "label_values(kafka_broker_active_count,job)",
        datasource,
      },
    ],
    panels: [
      row("row-health", "一、集群健康与容量", 0),
      availabilityStat("automq-controller", "活动 Controller", "KRaft 当前活动 Controller 数量。单节点基线应为 1；为 0 时集群无法完成控制面操作。", { h: 5, w: 3, x: 0, y: 1 }, 'sum(kafka_controller_active_count{job="$cluster_id"})', "Controller"),
      availabilityStat("automq-broker", "活动 Broker", "当前可提供 Kafka 读写服务的 Broker 数量。现网单节点基线应为 1。", { h: 5, w: 3, x: 3, y: 1 }, 'sum(kafka_broker_active_count{job="$cluster_id"})', "Broker"),
      stat("automq-fenced", "被隔离 Broker", "被 Controller 隔离、不能承担读写的 Broker 数量。正常值为 0。", { h: 5, w: 3, x: 6, y: 1 }, 'sum(kafka_broker_fenced_count{job="$cluster_id"}) or vector(0)', "Fenced", "none", null, 1),
      stat("automq-offline", "离线分区", "没有可用 Leader 的分区数量。正常值为 0；大于 0 会直接影响生产或消费。", { h: 5, w: 3, x: 9, y: 1 }, 'sum(kafka_partition_offline_count{job="$cluster_id"}) or vector(0)', "Offline", "none", null, 1),
      stat("automq-topics", "Topic 数", "AutoMQ 中当前 Topic 总数，包含系统内部 Topic。", { h: 5, w: 3, x: 12, y: 1 }, 'max(kafka_topic_count{job="$cluster_id"})', "Topics"),
      stat("automq-partitions", "分区总数", "所有 Topic 的分区总数。现网业务 Topic 之外还包含 Kafka/AutoMQ 系统分区。", { h: 5, w: 3, x: 15, y: 1 }, 'max(kafka_partition_total_count{job="$cluster_id"})', "Partitions"),
      stat("automq-size", "逻辑日志量", "按 Topic/Partition 去重后的 Kafka 逻辑日志大小，不等于 OBS 实际计费容量。", { h: 5, w: 3, x: 18, y: 1 }, 'sum(max by(topic,partition) (kafka_log_size{job="$cluster_id"}))', "Stored", "bytesIEC"),
      stat("automq-errors", "错误请求/秒", "Kafka 非 NONE 错误响应速率。短时认证探测可能产生少量错误，持续增长必须按 error 标签定位。", { h: 5, w: 3, x: 21, y: 1 }, 'sum(rate(kafka_request_error_count_total{job="$cluster_id",error!="NONE"}[$__rate_interval])) or vector(0)', "Errors/s", "reqps", 0.01, 1),

      row("row-traffic", "二、流量、请求与 Broker 压力", 6),
      timeseries("automq-network", "Broker 网络吞吐", "Broker 接收与发送字节速率；入站主要是 producer，出站主要是 consumer。", { h: 9, w: 12, x: 0, y: 7 }, [
        target("A", 'sum(rate(kafka_broker_network_io_bytes_total{job="$cluster_id",direction="in"}[$__rate_interval]))', "写入"),
        target("B", 'sum(rate(kafka_broker_network_io_bytes_total{job="$cluster_id",direction="out"}[$__rate_interval]))', "读取"),
      ], "bytesSecIEC"),
      timeseries("automq-topic-rate", "各 Topic 消息写入速率", "按 Topic 展示进入 Broker 的消息速率，用于识别 VVG 与 Gateway 流量变化。", { h: 9, w: 12, x: 12, y: 7 }, [
        target("A", 'sum by(topic) (rate(kafka_message_count_total{job="$cluster_id",direction="in"}[$__rate_interval]))', "{{topic}}"),
      ], "mps"),
      timeseries("automq-requests", "Produce / Fetch 请求速率", "Broker 每秒处理的生产与拉取请求。请求数和消息数不同，一个请求可包含多个消息。", { h: 9, w: 8, x: 0, y: 16 }, [
        target("A", 'sum(rate(kafka_request_count_total{job="$cluster_id",type="Produce"}[$__rate_interval]))', "Produce"),
        target("B", 'sum(rate(kafka_request_count_total{job="$cluster_id",type="Fetch"}[$__rate_interval]))', "Fetch"),
      ], "reqps"),
      timeseries("automq-latency", "Kafka 请求 P99 延迟", "Produce/Fetch 请求端到端处理时间的第 99 百分位；持续升高时结合队列、线程空闲率和 S3 延迟判断。", { h: 9, w: 8, x: 8, y: 16 }, [
        target("A", 'max(kafka_request_time_99p_milliseconds{job="$cluster_id",type="Produce"})', "Produce P99"),
        target("B", 'max(kafka_request_time_99p_milliseconds{job="$cluster_id",type="Fetch"})', "Fetch P99"),
      ], "ms"),
      timeseries("automq-request-errors", "Kafka 错误响应明细", "按 Kafka error 标签拆分非成功响应，便于区分认证、Leader、超时和消息过大等错误。", { h: 9, w: 8, x: 16, y: 16 }, [
        target("A", 'sum by(error,type) (rate(kafka_request_error_count_total{job="$cluster_id",error!="NONE"}[$__rate_interval]))', "{{type}} / {{error}}"),
      ], "reqps"),
      timeseries("automq-queues", "请求与响应队列", "Broker 网络线程与 I/O 线程之间的等待队列。持续堆积通常表示线程或下游存储处理不及。", { h: 9, w: 8, x: 0, y: 25 }, [
        target("A", 'max by(type) (kafka_request_queue_size{job="$cluster_id"})', "请求 {{type}}"),
        target("B", 'max by(type) (kafka_response_queue_size{job="$cluster_id"})', "响应 {{type}}"),
      ]),
      timeseries("automq-purgatory", "延迟请求等待数", "等待副本确认或数据可用的 Produce/Fetch 请求数量。持续上升要检查 Broker、Leader 与对象存储。", { h: 9, w: 8, x: 8, y: 25 }, [
        target("A", 'sum by(type) (kafka_purgatory_size{job="$cluster_id"})', "{{type}}"),
      ]),
      timeseries("automq-thread-idle", "网络 / I/O 线程空闲率", "线程空闲率越低表示 Broker 越忙。长期接近 0 时请求延迟和队列通常会同步升高。", { h: 9, w: 8, x: 16, y: 25 }, [
        target("A", 'min(kafka_network_threads_idle_rate{job="$cluster_id"})', "Network"),
        target("B", 'min(kafka_io_threads_idle_rate_1m{job="$cluster_id"})', "I/O"),
      ], "percentUnit"),

      row("row-delivery", "三、生产者、消费者与积压", 34),
      timeseries("automq-consumer-lag", "Vector Consumer Lag", "Kafka 最新 offset 与 Vector consumer 已提交 offset 的差值。正式 VVG/Gateway 组应在流量稳定后回落到低位。", { h: 10, w: 12, x: 0, y: 35 }, [
        target("A", 'sum by(consumer_group,topic) (clamp_min(vector_kafka_consumer_lag{partition_id!="-1"},0))', "{{consumer_group}} / {{topic}}"),
      ]),
      timeseries("automq-producer-buffer", "Vector Producer 磁盘缓冲", "CCE producer 尚未可靠写入 AutoMQ 的本地磁盘队列。Broker 故障时会增长，恢复后必须持续下降。", { h: 10, w: 12, x: 12, y: 35 }, [
        target("A", 'sum by(component_id,host) (vector_buffer_size_bytes{component_type="kafka",component_id=~"automq(_lane_[ab])?"})', "{{host}} / {{component_id}}"),
      ], "bytesIEC"),
      barGauge("automq-groups", "Consumer Group 状态", "stable 为正常工作组；preparing/completing_rebalance 持续非零表示频繁再均衡；empty/dead 多为历史组。", { h: 9, w: 8, x: 0, y: 45 }, [
        target("A", 'sum(kafka_group_count{job="$cluster_id"})', "总数", true),
        target("B", 'sum(kafka_group_stable_count{job="$cluster_id"})', "稳定", true),
        target("C", 'sum(kafka_group_preparing_rebalance_count{job="$cluster_id"})', "准备再均衡", true),
        target("D", 'sum(kafka_group_completing_rebalance_count{job="$cluster_id"})', "完成再均衡", true),
        target("E", 'sum(kafka_group_empty_count{job="$cluster_id"})', "空组", true),
        target("F", 'sum(kafka_group_dead_count{job="$cluster_id"})', "已删除", true),
      ]),
      timeseries("automq-vector-throughput", "Vector Kafka 收发事件速率", "各 producer/consumer Kafka 组件接收与发送事件速率，用来定位积压发生在入 Kafka 还是出 Kafka。", { h: 9, w: 8, x: 8, y: 45 }, [
        target("A", 'sum by(host,component_id) (rate(vector_component_received_events_total{component_type="kafka"}[$__rate_interval]))', "收到 {{host}} / {{component_id}}"),
        target("B", 'sum by(host,component_id) (rate(vector_component_sent_events_total{component_type="kafka"}[$__rate_interval]))', "发出 {{host}} / {{component_id}}"),
      ], "mps"),
      timeseries("automq-vector-errors", "Vector 交付错误与丢弃", "Vector 组件错误和主动丢弃事件速率。生产链路持续非零必须结合 component_id 与 error_type 排查。", { h: 9, w: 8, x: 16, y: 45 }, [
        target("A", 'sum by(host,component_id,error_type) (rate(vector_component_errors_total[$__rate_interval]))', "错误 {{host}} / {{component_id}} / {{error_type}}"),
        target("B", 'sum by(host,component_id) (rate(vector_component_discarded_events_total[$__rate_interval]))', "丢弃 {{host}} / {{component_id}}"),
      ], "mps"),

      row("row-storage", "四、S3 / OBS、WAL 与缓存", 54),
      timeseries("automq-s3-ops", "对象存储请求速率", "AutoMQ 到对象存储的 S3Request 操作速率，按操作名和状态拆分。非成功状态持续出现需要检查 OBS 网络、权限与限流。", { h: 9, w: 12, x: 0, y: 55 }, [
        target("A", 'sum by(operation_name,status) (rate(kafka_stream_operation_latency_count{job="$cluster_id",operation_type="S3Request"}[$__rate_interval]))', "{{operation_name}} / {{status}}"),
      ], "reqps"),
      timeseries("automq-s3-latency", "对象存储操作 P99 延迟", "S3Request 操作第 99 百分位延迟。延迟升高会传导到 WAL 上传、冷读和 Kafka 请求尾延迟。", { h: 9, w: 12, x: 12, y: 55 }, [
        target("A", 'max by(operation_name,status) (kafka_stream_operation_latency_99p_nanoseconds{job="$cluster_id",operation_type="S3Request"}) / 1000000', "{{operation_name}} / {{status}}"),
      ], "ms"),
      timeseries("automq-s3-throughput", "对象存储上传 / 下载吞吐", "AutoMQ 向 OBS 上传和从 OBS 冷读的字节速率。", { h: 9, w: 8, x: 0, y: 64 }, [
        target("A", 'sum(rate(kafka_stream_upload_size_bytes_total{job="$cluster_id"}[$__rate_interval]))', "上传"),
        target("B", 'sum(rate(kafka_stream_download_size_bytes_total{job="$cluster_id"}[$__rate_interval]))', "下载"),
      ], "bytesSecIEC"),
      timeseries("automq-wal", "WAL 待上传字节", "本地 WAL 中等待上传到对象存储的数据。短暂波动正常，持续上升表示上传能力或对象存储异常。", { h: 9, w: 8, x: 8, y: 64 }, [
        target("A", 'sum(kafka_stream_wal_pending_upload_bytes{job="$cluster_id"})', "待上传"),
      ], "bytesIEC"),
      timeseries("automq-cache", "AutoMQ 内存与缓存", "流缓冲、WAL cache 与 block cache 的实际占用，用于核对 6 GiB cgroup 内的 Tiny 内存基线。", { h: 9, w: 8, x: 16, y: 64 }, [
        target("A", 'sum(kafka_stream_buffer_allocated_memory_size_bytes{job="$cluster_id"})', "流缓冲"),
        target("B", 'sum(kafka_stream_delta_wal_cache_size_bytes{job="$cluster_id"})', "WAL cache"),
        target("C", 'sum(kafka_stream_block_cache_size_bytes{job="$cluster_id"})', "Block cache"),
      ], "bytesIEC"),
      timeseries("automq-s3-objects", "S3 对象数量", "按对象状态统计 AutoMQ 管理的 S3 对象数量，用于观察对象增长和 compaction 是否异常。", { h: 9, w: 8, x: 0, y: 73 }, [
        target("A", 'sum by(state) (kafka_stream_s3_object_count{job="$cluster_id"})', "{{state}}"),
      ]),
      timeseries("automq-s3-object-size", "S3 对象容量", "按对象状态统计 AutoMQ 管理的 S3 对象总大小；这是对象层视角，与 Kafka 逻辑日志量口径不同。", { h: 9, w: 8, x: 8, y: 73 }, [
        target("A", 'sum by(state) (kafka_stream_s3_object_size_bytes{job="$cluster_id"})', "{{state}}"),
      ], "bytesIEC"),
      timeseries("automq-backpressure", "AutoMQ 背压与慢 Broker", "背压状态或 slow broker 数量非零表示写入/读取路径正在被限流或节点响应异常。", { h: 9, w: 8, x: 16, y: 73 }, [
        target("A", 'max(kafka_stream_back_pressure_state{job="$cluster_id"})', "背压状态"),
        target("B", 'max(kafka_stream_slow_broker_count{job="$cluster_id"})', "慢 Broker"),
      ]),

      row("row-runtime", "五、KRaft、JVM、宿主机与采集器", 82),
      timeseries("automq-kraft", "KRaft Leader / Epoch / High Watermark", "KRaft 控制面 Leader、epoch 和高水位。Leader 为 -1 或高水位长时间不推进表示元数据仲裁异常。", { h: 9, w: 8, x: 0, y: 83 }, [
        target("A", 'max(kafka_server_kraft_current_leader{job="$cluster_id"})', "Leader"),
        target("B", 'max(kafka_server_kraft_current_epoch{job="$cluster_id"})', "Epoch"),
        target("C", 'max(kafka_server_kraft_high_watermark{job="$cluster_id"})', "High watermark"),
      ]),
      timeseries("automq-kraft-latency", "KRaft 提交延迟", "控制面 Raft 日志提交平均值与最大值。单节点仍需关注磁盘或线程阻塞造成的尖峰。", { h: 9, w: 8, x: 8, y: 83 }, [
        target("A", 'max(kafka_server_kraft_commit_latency_avg_milliseconds{job="$cluster_id"})', "平均"),
        target("B", 'max(kafka_server_kraft_commit_latency_max_milliseconds{job="$cluster_id"})', "最大"),
      ], "ms"),
      timeseries("automq-event-queue", "Controller 事件队列 P99", "控制器事件排队和处理第 99 百分位耗时；排队高而处理低通常是线程繁忙，二者都高需查资源与存储。", { h: 9, w: 8, x: 16, y: 83 }, [
        target("A", 'max(kafka_event_queue_time_99p_milliseconds{job="$cluster_id"})', "排队"),
        target("B", 'max(kafka_event_queue_processing_time_99p_milliseconds{job="$cluster_id"})', "处理"),
      ], "ms"),
      timeseries("automq-jvm-memory", "JVM 内存使用", "JVM 各内存池使用量。显式 Heap/Direct 之外还需为 native、线程栈、ZGC 和网络缓冲保留空间。", { h: 9, w: 8, x: 0, y: 92 }, [
        target("A", 'sum by(area,type) (jvm_memory_used_bytes{job="$cluster_id"})', "{{area}} / {{type}}"),
      ], "bytesIEC"),
      timeseries("automq-jvm-cpu-gc", "JVM CPU 与 GC", "进程 CPU 利用率和平均 GC 停顿。GC 持续升高时结合内存占用与宿主机压力判断。", { h: 9, w: 8, x: 8, y: 92 }, [
        target("A", 'max(jvm_cpu_recent_utilization_ratio{job="$cluster_id"})', "CPU"),
        target("B", 'sum(rate(jvm_gc_duration_seconds_sum{job="$cluster_id"}[$__rate_interval])) / clamp_min(sum(rate(jvm_gc_duration_seconds_count{job="$cluster_id"}[$__rate_interval])),1)', "平均 GC 秒"),
      ]),
      timeseries("automq-host", "AutoMQ 宿主机 CPU / 内存使用率", "只匹配 automq_host=true 的 node-exporter，避免把其他节点资源混入。", { h: 9, w: 8, x: 16, y: 92 }, [
        target("A", '1 - avg(rate(node_cpu_seconds_total{automq_host="true",mode="idle"}[$__rate_interval]))', "CPU"),
        target("B", '1 - (node_memory_MemAvailable_bytes{automq_host="true"} / node_memory_MemTotal_bytes{automq_host="true"})', "内存"),
      ], "percentUnit", 0.8, 0.9),
      timeseries("automq-vmagent-health", "vmagent 抓取与 Remote Write 健康", "抓取失败或 Remote Write 待发送数据持续增长时，夜莺看到的曲线可能滞后，不能误判为被监控服务无流量。", { h: 9, w: 12, x: 0, y: 101 }, [
        target("A", 'sum by(job) (rate(vm_promscrape_scrapes_failed_total{job="automq-vmagent"}[$__rate_interval]))', "抓取失败 {{job}}"),
        target("B", 'sum(vmagent_remotewrite_pending_data_bytes{job="automq-vmagent"})', "Remote Write 待发送字节"),
      ]),
      timeseries("automq-jvm-threads", "JVM 线程数", "AutoMQ JVM 当前平台线程数。持续单向增长可能表示线程泄漏或连接/任务堆积。", { h: 9, w: 12, x: 12, y: 101 }, [
        target("A", 'max(jvm_thread_count{job="$cluster_id"})', "Threads"),
      ]),
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
