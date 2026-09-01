# Vector Kubernetes 部署

本目录提供 Docker CRI 和 Containerd CRI 两套 DaemonSet 模板，用于收集 Java 标准输出日志并写入 VictoriaLogs。

当前基线：Vector `0.58.0`。生产部署必须先阅读 [延迟排查与升级运行手册](../docs/vector-victorialogs-latency-runbook.md)。

Grafana 查询卡顿和 VictoriaLogs 查询并发调优属于展示/存储层问题，使用 [Grafana/VictoriaLogs 查询性能与升级运行手册](../docs/grafana-victorialogs-query-performance-runbook.md)，不要通过修改 DaemonSet 掩盖前端取消或错误 LogsQL。

## 配置选择

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion
```

- `containerd://...`：使用 `vector-k8s-containerd-cri.yaml`
- `docker://...`：使用 `vector-k8s-docker-cri.yaml`

两个模板的采集、转换、缓冲和滚动策略一致，仅宿主机 runtime 挂载不同。

## 生产前必改

### VictoriaLogs endpoint

修改 DaemonSet 中的 `VLS_ENDPOINT`：

```yaml
- name: VLS_ENDPOINT
  value: "http://victorialogs.logging.svc.cluster.local:9428"
```

如果 VictoriaLogs 在集群外，使用内网地址并先从工作节点验证可达性。

### 私有镜像

先按运行手册把 `timberio/vector:0.58.0-alpine` 镜像到私有仓库，再替换：

```yaml
image: registry.example.com/observability/timberio/vector:0.58.0-alpine
imagePullSecrets:
  - name: registry-secret
```

不要使用 `latest` 或未验证的浮动 tag。升级前在每个节点用临时 Pod 验证私库拉取和 `vector --version`，验证后删除临时 Pod。

### 过滤范围

模板默认排除 `kube-system`、`monitoring`、`logging` namespace，以及常见 sidecar。按实际 namespace 和标签调整：

```yaml
extra_label_selector: 'app!=fluentd,app!=vector,app!=vector-log'
extra_field_selector: 'metadata.namespace!=kube-system,metadata.namespace!=monitoring,metadata.namespace!=logging'
```

这些 selector 是“排除条件”，不会自动保证只收集 Java。需要严格白名单时，应使用稳定的业务标签或 namespace 设计并先做覆盖率检查。

## 关键设计

### 快速轮转文件

```yaml
glob_minimum_cooldown_ms: 5000
oldest_first: false
max_read_bytes: 65536
rotate_wait_secs: 300
exclude_paths_glob_patterns:
  - "**/*.gz"
  - "**/*.tmp"
```

显式设置 `exclude_paths_glob_patterns` 会覆盖 Vector 默认排除项，因此 `.gz` 和 `.tmp` 不能省略。高流量容器在默认 60 秒发现周期内可能已经轮转并压缩，最终表现为日志延迟后批量出现。

这里的 5 秒属于 `kubernetes_logs` 在快速 CRI 轮转场景的实测基线。Docker Compose 使用普通 `file` source，其 Vector 0.58 默认发现周期已是 1 秒；两者不要机械地写成同一个值。

### Java 多行日志

处理分两层：

1. `auto_partial_merge` 合并 runtime 因单行长度限制拆分的 CRI 片段。
2. `reduce` 按 Pod 和 container 合并 Java 异常堆栈。

```yaml
group_by:
  - kubernetes.pod_name
  - kubernetes.container_name
starts_when: |
  match(string(.message) ?? "", r'^(\d{4}-\d{2}-\d{2}(?:T|\s)\d{2}:\d{2}:\d{2}|\b(INFO|WARN|DEBUG|ERROR|FATAL|TRACE)\b)')
expire_after_ms: 3000
```

不要把 `expire_after_ms` 直接降为几百毫秒，否则较慢输出的堆栈可能被拆开。低频日志的正常可见延迟约为 3 秒收束加 1 秒批次。

### 空字段安全

Pod 删除后元数据可能暂时不完整。不要对 `.kubernetes.*` 使用 `string!`：

```vrl
message = string(.message) ?? ""
container_name = string(.kubernetes.container_name) ?? ""
```

Vector 0.58 能从日志路径回退恢复基础 Pod 元数据，但转换层仍需防御可空字段。

### 时间戳和缓冲

```yaml
out_of_order_action: accept
batch:
  timeout_secs: 1
buffer:
  type: disk
  max_size: 1073741824
  when_full: block
```

VictoriaLogs 支持历史事件。`rewrite_timestamp` 会把旧日志伪装成新日志，掩盖真实积压。持久磁盘缓冲可吸收 VictoriaLogs 的短时重启；`memory + drop_newest` 会主动丢日志。

## 离线验证

```bash
kubectl apply --dry-run=server -f vector-k8s-containerd-cri.yaml
```

还必须提取 ConfigMap 中的 `vector.yaml`，使用目标镜像编译 VRL 和完整拓扑：

```bash
docker run --rm \
  -e VECTOR_SELF_NODE_NAME=validation-node \
  -e VLS_ENDPOINT=http://victorialogs.example:9428 \
  -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
  -v "$PWD/vector.yaml:/etc/vector/vector.yaml:ro" \
  timberio/vector:0.58.0-alpine \
  validate --no-environment /etc/vector/vector.yaml
```

Vector 0.57+ 默认关闭环境变量插值。模板仅为受控的节点名和 endpoint 显式开启插值，不要把秘密放进普通环境变量。

## 部署与滚动

先导出当前对象：

```bash
kubectl -n logging get configmap vector-config -o yaml > vector-config.before.yaml
kubectl -n logging get daemonset vector -o yaml > vector-daemonset.before.yaml
```

部署：

```bash
kubectl apply -f vector-k8s-containerd-cri.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
```

模板固定 `maxUnavailable: 1` 和 120 秒退出宽限期。不要一次删除所有 Vector Pod。

## 验收

```bash
kubectl -n logging get pods -l app=vector -o wide
kubectl -n logging top pod -l app=vector

for pod in $(kubectl -n logging get pod -l app=vector -o name); do
  kubectl -n logging exec "${pod}" -- vector --version
  kubectl -n logging exec "${pod}" -- \
    vector validate --no-environment /etc/vector/vector.yaml
  kubectl -n logging logs "${pod}" --since=5m 2>&1 \
    | grep -E 'Failed to annotate|VRL condition execution failed|buffer.*(full|drop)|request.*(fail|error)|ERROR' \
    || true
done
```

最终还要验证：

- VictoriaLogs `/health` 为 `200`，写入计数持续增加且写入错误为零。
- 升级前历史时间窗仍可查询。
- 最新 `_time` 与 Java 行首时间一致。
- 近期仍存在包含换行的 `_msg`，证明 Java 多行未被拆散。
- 磁盘 buffer 在后端恢复后稳定或下降。

仅 Pod Running 或本地配置校验通过，不能作为端到端验收。

## 回滚

```bash
kubectl apply -f vector-config.before.yaml
kubectl apply -f vector-daemonset.before.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
```

回滚后重复完整验收。不要删除 `/var/lib/vector` checkpoint 或 buffer 来“解决”积压，这会破坏恢复位置或丢失尚未发送的事件。
