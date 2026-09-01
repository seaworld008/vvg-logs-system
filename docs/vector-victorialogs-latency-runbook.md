# Vector -> VictoriaLogs 延迟、批量涌入与升级运行手册

> 基线版本：Vector `0.58.0`、VictoriaLogs `v1.52.0`
> 最后验证：2026-09-01
> 适用场景：Kubernetes `kubernetes_logs` -> Loki API -> VictoriaLogs 单节点

本文来自一次真实的生产排查：Grafana 中某些服务几十秒到数分钟没有日志，随后一次出现大量旧日志。排查时必须把“源文件读取延迟”“Vector 转换/缓冲”“VictoriaLogs 写入”和“Grafana 查询展示”分层验证，不能只看最终柱状图。

## 1. 典型症状

- Grafana Logs volume 长时间接近零，随后出现尖峰。
- 日志记录的 `_time` 很新，但 `_msg` 中 Java 行首时间早几十分钟甚至数小时。
- Vector 日志包含：
  - `Failed to annotate event with pod metadata`
  - `VRL condition execution failed: expected string, got null`
- VictoriaLogs 写入 P99 很低、磁盘不忙、写入错误为零。
- 节点上存在大量 `0.log.<timestamp>.gz`，高流量容器很快轮转。

双时间戳是关键证据。例如 `_time=11:43`，Java 行首时间为 `10:04`，说明日志不是 Grafana 展示不连续，而是旧事件被晚读并改写成了新时间。

## 2. 已验证的故障机制

### 2.1 显式排除覆盖 Vector 默认值

`kubernetes_logs.exclude_paths_glob_patterns` 的默认值会排除 `**/*.gz` 和 `**/*.tmp`。一旦用户显式配置该字段，默认列表会被整体替换；如果没有重新加入这两个模式，Vector 会发现压缩轮转文件。

### 2.2 文件发现周期大于轮转周期

`kubernetes_logs.glob_minimum_cooldown_ms` 默认是 60 秒。高流量容器可能在 60 秒内写满一个日志文件并被压缩，Vector 尚未发现活跃 `.log`，下一轮只看到 `.gz` 或旧文件，于是日志成批出现。

### 2.3 默认优先清理最旧文件

`oldest_first: true` 会先排空旧文件。在已经存在积压时，当前活跃文件容易被旧文件阻塞。低延迟采集应使用 `oldest_first: false`，并通过 `max_read_bytes` 在多个活跃文件间公平调度。

### 2.4 强制类型转换导致丢日志

Pod 删除后，旧版本 Vector 可能无法补齐 `.kubernetes.container_name`。`string!(...)` 会在字段为空时抛错并拒绝事件。Vector `0.58.0` 增加了从日志路径恢复 Pod、namespace 和 container 元数据的回退逻辑，但过滤和多行条件仍应使用空值安全表达式。

### 2.5 时间改写掩盖真实延迟

`out_of_order_action: rewrite_timestamp` 会把晚到事件改写成最新时间。VictoriaLogs 支持历史/乱序写入，应使用 `accept` 保留真实时间；否则 Grafana 会把积压显示成当前尖峰。

### 2.6 后端不是默认嫌疑人

只有在 VictoriaLogs 出现写入错误、写入延迟升高、CPU/磁盘饱和或 Vector 持续重试时，才把后端列为根因。若 VictoriaLogs 写入延迟为毫秒级且错误为零，应回到源文件、checkpoint 和 Vector 组件逐层排查。

## 3. 只读排查顺序

### 3.1 记录版本、拓扑和资源

```bash
kubectl version --short
kubectl get nodes -o wide
kubectl -n logging get daemonset,pod -o wide
kubectl -n logging top pod
kubectl -n logging get daemonset vector -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

确认是否同时存在多个 Vector DaemonSet。若多个实例共享同一个宿主机 `data_dir` 和相同 source ID，checkpoint 可能互相干扰；每个 Vector 实例必须使用独立目录。

### 3.2 搜索采集端错误

```bash
for pod in $(kubectl -n logging get pod -l app=vector -o name); do
  echo "=== ${pod} ==="
  kubectl -n logging logs "${pod}" --since=2h 2>&1 \
    | grep -E 'Failed to annotate|VRL condition execution failed|buffer.*(full|drop)|request.*(fail|error)|ERROR' \
    | tail -50
done
```

不要只统计日志行数。Vector 会抑制重复告警，一条 `suppressed N times` 可能代表数万次失败。

### 3.3 检查 checkpoint 和轮转文件

```bash
for pod in $(kubectl -n logging get pod -l app=vector -o name); do
  echo "=== ${pod} ==="
  kubectl -n logging exec "${pod}" -- sh -c '
    du -sh /var/lib/vector
    stat -c "checkpoint_mtime=%y size=%s" \
      /var/lib/vector/k8s_logs/checkpoints.json
    echo "gz_files=$(find -L /var/log/pods -type f -name "*.gz" 2>/dev/null | wc -l)"
    find -L /var/log/pods -type f -name "*.gz" \
      -exec stat -c "%Y %s %n" {} \; 2>/dev/null | sort -n | tail -10
  '
done
```

只查看路径、大小和时间，不输出业务日志正文。

### 3.4 查看 CCE/Kubelet 轮转阈值

```bash
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "=== ${node} ==="
  kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" \
    | jq '.kubeletconfig | {containerLogMaxSize,containerLogMaxFiles}'
done
```

CCE 常见默认值是 `50Mi` 和 `20`。若一个容器约一分钟轮转一次，通常表示它约一分钟写入了 50 MiB 原始 stdout。把阈值提高到 200 MiB 不会提高 Vector 吞吐，只会把单容器理论保留上限从约 1 GiB 放大到约 4 GiB；优先修复采集发现和读取能力。

### 3.5 排除 VictoriaLogs 写入瓶颈

```bash
curl -fsS http://VICTORIALOGS_HOST:9428/health
curl -fsS http://VICTORIALOGS_HOST:9428/metrics \
  | grep -E '^(vl_rows_ingested_total|vl_http_request_errors_total|vl_rows_dropped_total)'

docker stats --no-stream victorialogs
df -h /path/to/victoria-logs-data
iostat -x 1 5
```

同时检查 VictoriaLogs 容器日志中的 `panic`、`corrupt`、`insert error` 和持续慢写入。查询慢不等于写入慢，两者必须分开报告。

### 3.6 比对存储时间与 Java 时间

```bash
curl -fsSG 'http://VICTORIALOGS_HOST:9428/select/logsql/query' \
  --data-urlencode 'query=container:="SERVICE_NAME"' \
  --data-urlencode 'start=START_RFC3339' \
  --data-urlencode 'end=END_RFC3339' \
  --data-urlencode 'limit=100' \
  | jq -r 'select(._time != null and ._msg != null)
    | [._time,
       (try (._msg | capture("(?<ts>20[0-9]{2}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?)").ts)
        catch "NO_TS")]
    | @tsv'
```

只输出时间对，不输出完整业务日志。优化后，`_time` 与 Java 时间应在正常应用缓冲范围内一致。

## 4. 推荐配置

仓库中的 `k8s-deployment/vector-k8s-containerd-cri.yaml` 与 Docker CRI 模板已经包含以下基线：

| 配置 | 推荐值 | 原因 |
|---|---:|---|
| `glob_minimum_cooldown_ms` | `5000` | 在快速压缩前发现活跃日志文件 |
| `oldest_first` | `false` | 避免旧积压饿死当前日志 |
| `max_read_bytes` | `65536` | 提高单次读取吞吐，同时保留文件间公平性 |
| `rotate_wait_secs` | `300` | 给已打开的轮转文件留出读取窗口 |
| `delay_deletion_ms` | `300000` | Pod 删除后暂留元数据 |
| 显式排除 | `**/*.gz`, `**/*.tmp` | 保留被覆盖的 Vector 默认安全项 |
| 多行收束 | `3000ms` | 保留 Java 堆栈完整性 |
| batch timeout | `1s` | 降低低流量服务的额外等待 |
| buffer | `disk`, `1GiB`, `block` | 后端短时维护期间不主动丢新日志 |
| `out_of_order_action` | `accept` | 保留真实事件时间 |

低频 Java 日志的正常可见延迟上限通常约为多行收束 3 秒加批次 1 秒。连续日志遇到下一条首行时会更早释放。

## 5. 版本兼容门禁

- Vector `0.55.0` 修复了 `0.50.0` 引入的 file/kubernetes_logs 高 CPU 回归。
- Vector `0.57.0` 起默认禁止环境变量插值。本仓库只为 Downward API 节点名和非秘密 endpoint 显式启用 `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true`。
- Vector `0.58.0` 在 Pod 已删除时可从日志路径恢复基础 Kubernetes 元数据。
- VictoriaLogs `v1.52.0` 使用 distroless 基础镜像，容器内没有 `sh`、`wget` 或 `curl`。不要使用容器内 `CMD-SHELL wget` 健康检查，应从宿主机、监控系统或独立探针访问 `/health`。
- VictoriaLogs 单节点可从 `v1.50.0` 直接升级到 `v1.52.0`；集群版必须按官方更新说明处理 `v1.51.1` 中间步骤。

## 6. 私有仓库镜像流程

生产环境先把官方镜像镜像到私有仓库，再修改 K8S/Compose。不要使用漂移的 `latest`。

```bash
VECTOR_VERSION='0.58.0-alpine'
VL_VERSION='v1.52.0'
PRIVATE_REGISTRY='registry.example.com/observability'

docker pull "timberio/vector:${VECTOR_VERSION}"
docker pull "victoriametrics/victoria-logs:${VL_VERSION}"

docker run --rm "timberio/vector:${VECTOR_VERSION}" --version
docker run --rm "victoriametrics/victoria-logs:${VL_VERSION}" -version

docker tag "timberio/vector:${VECTOR_VERSION}" \
  "${PRIVATE_REGISTRY}/timberio/vector:${VECTOR_VERSION}"
docker tag "victoriametrics/victoria-logs:${VL_VERSION}" \
  "${PRIVATE_REGISTRY}/victoriametrics/victoria-logs:${VL_VERSION}"

docker push "${PRIVATE_REGISTRY}/timberio/vector:${VECTOR_VERSION}"
docker push "${PRIVATE_REGISTRY}/victoriametrics/victoria-logs:${VL_VERSION}"
```

若生产主机无法访问 Docker Hub，可在有代理的受控工作机拉取后使用 `docker save`，通过内网传输，在登录了私有仓库的主机 `docker load`、打标签并推送。完成后删除临时 tar。私库凭据只保存在 Docker credential store 或 K8S Secret，不写入仓库和命令记录。

升级前用临时 Pod 在每个节点验证私库 tag 能被 `imagePullSecrets` 拉取并实际执行 `vector --version`，验证完成立即删除临时 Pod。

对仍在使用 Docker 19/20 的集群，在应用 DaemonSet 之前逐节点完成三项检查：

1. `docker info --format 'root={{.DockerRootDir}}'` 与容器日志链接指向一致，现有 runtime 挂载不会被误删。
2. 目标镜像已经存在本地，并记录源拉取节点的 `RepoDigests` 和所有节点的镜像 `.Id`。
3. 每个工作节点到 VictoriaLogs `/health` 的内网访问成功。

Docker 19 默认可能报告 `docker manifest inspect is only supported on a Docker cli with experimental cli features enabled`。不要为了这个检查临时改 Docker 全局配置；用受控拉取的 `RepoDigests` 与加载后的镜像 `.Id` 建立证据链。通过 `docker save/load` 加载的镜像可能没有 `RepoDigests`，这不等于镜像内容不一致。

## 7. 安全升级流程

### 7.1 备份 Vector

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/vector-maint-${STAMP}"
SOURCE_MANIFEST="/path/to/vector-k8s-runtime-cri.yaml"
install -d -m 700 "${BACKUP}"

cp -a "${SOURCE_MANIFEST}" "${BACKUP}/source.before.yaml"
kubectl -n logging get configmap vector-config -o yaml \
  > "${BACKUP}/vector-config.yaml"
kubectl -n logging get daemonset vector -o yaml \
  > "${BACKUP}/vector-daemonset.yaml"
kubectl -n logging get pods -l app=vector -o wide \
  > "${BACKUP}/pods.before.txt"
curl -fsS http://VICTORIALOGS_HOST:9428/metrics \
  > "${BACKUP}/victorialogs.metrics.before.txt"
```

同时备份实际用于部署的源清单，不要只保留 `kubectl get` 导出的运行时对象。前者更适合直接回滚，后者用于审计现场差异。

### 7.2 离线校验

```bash
kubectl apply --dry-run=server \
  -f k8s-deployment/vector-k8s-containerd-cri.yaml

docker run --rm \
  -e VECTOR_SELF_NODE_NAME=validation-node \
  -e VLS_ENDPOINT=http://victorialogs.example:9428 \
  -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
  -v "$PWD/vector.yaml:/etc/vector/vector.yaml:ro" \
  timberio/vector:0.58.0-alpine \
  validate --no-environment /etc/vector/vector.yaml
```

从 ConfigMap 提取 `vector.yaml` 后执行第二条命令。校验必须包含 VRL transforms，不能只做 YAML 语法检查。

目标镜像无法直接在所有节点拉取时，先在一个能拉取的节点完成上述验证，再将已验证镜像传递至其他节点。所有节点的镜像 `.Id` 一致后才开始滚动，避免在更新中途发现镜像不可用。

### 7.3 滚动 Vector

```bash
kubectl apply -f k8s-deployment/vector-k8s-containerd-cri.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
kubectl -n logging get pods -l app=vector -o wide
```

保持 `maxUnavailable: 1`。每个新 Pod 必须 Ready、版本正确、无重启且没有 VRL、metadata、buffer drop 错误，才允许继续下一节点。

对从镜像包加载的节点，Kubelet 可能显示 `docker://sha256:...` 而不是 `docker-pullable://...@sha256:...`。验收时同时比较源节点拉取摘要、各节点镜像 `.Id`、Pod 内 `vector --version` 和 `vector validate`，不能只依赖一种 image ID 展示形式。

### 7.4 备份并升级 VictoriaLogs

先备份 Compose、容器 inspect、metrics，并为当前分区创建临时快照：

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/path/to/victorialogs/backup-${STAMP}"
install -d -m 700 "${BACKUP}"
cp -a docker-compose.yml "${BACKUP}/"
docker inspect victorialogs > "${BACKUP}/victorialogs.inspect.json"
curl -fsS http://127.0.0.1:9428/metrics > "${BACKUP}/metrics.before.txt"
curl -fsS 'http://127.0.0.1:9428/internal/partition/snapshot/create?partition_prefix=YYYYMMDD' \
  > "${BACKUP}/snapshot.json"
```

Compose 必须包含：

```yaml
stop_signal: SIGINT
stop_grace_period: 2m
```

然后执行：

```bash
docker compose config
docker compose stop -t 120 victorialogs
docker compose up -d --no-deps --force-recreate victorialogs
curl -fsS http://127.0.0.1:9428/health
```

Vector 的磁盘缓冲应吸收 VictoriaLogs 的短暂停机。恢复后确认 buffer 不再增长、写入计数持续增加，再删除本次创建的临时快照。

## 8. 强制验收

升级完成至少观察 15 分钟：

1. DaemonSet `desired=ready=updated`，Pod 无重启。
2. `vector validate` 在每个 Pod 内通过。
3. 最近 5 分钟以下错误均为零：metadata、VRL、buffer drop、request failed。
4. VictoriaLogs `/health` 为 `200`，`vl_rows_ingested_total` 持续增加。
5. `vl_http_request_errors_total` 和 `vl_rows_dropped_total` 没有非零增长。
6. 升级前历史时间窗仍能查询。
7. 最新日志 `_time` 与 Java 行首时间在正常应用缓冲范围内一致。
8. 查询近期 `_msg` 中包含换行的记录，只输出行数和长度，确认 Java 多行未被拆散。
9. Vector CPU 在追赶积压后回落，磁盘 buffer 稳定或下降。

服务本身低流量时，Grafana 没有日志是正常现象。验收要选择持续产生日志的服务，不能把业务静默误判为采集故障。

不要只在滚动完成时看一次状态。以 1 分钟间隔连续观察至少 15 分钟，每次记录 DaemonSet `desired/ready/updated/available`、Pod 总重启数、Vector 发送/VRL/缓冲严重错误数，以及 VictoriaLogs 的写入、丢弃和 HTTP 错误计数。验收快照与升级前基线一起放入本次带时间戳的回滚目录。

## 9. 回滚

Vector 回滚首选使用升级前的源清单：

```bash
kubectl apply -f /root/vector-maint-TIMESTAMP/source.before.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
```

若源清单不可用，再使用导出的 ConfigMap 和 DaemonSet：

```bash
kubectl apply -f /root/vector-maint-TIMESTAMP/vector-config.yaml
kubectl apply -f /root/vector-maint-TIMESTAMP/vector-daemonset.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
```

VictoriaLogs 回滚前先阅读目标版本的存储兼容说明。恢复旧 Compose 和精确旧镜像 tag，优雅停止当前容器后重建；不要删除或覆盖数据目录。只有确认数据损坏时才使用分区备份恢复，不能把“容器启动失败”直接等同于“数据需要回滚”。

## 10. 不应采用的捷径

- 不通过扩大日志轮转文件掩盖 Vector 发现周期问题。
- 不使用 `rewrite_timestamp` 美化 Grafana 曲线。
- 不使用 `string!` 读取可能缺失的 Kubernetes 元数据。
- 不在高价值日志链路使用 `memory + drop_newest` 作为容错方案。
- 不直接把官方 tag 写进生产模板却跳过私库镜像和节点拉取验证。
- 不因 VictoriaLogs 查询慢就判定写入慢。
- 不在升级时同时修改应用日志级别；日志量治理必须单独评估业务影响。
