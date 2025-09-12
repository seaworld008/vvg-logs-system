# Vector K8S 部署配置

本目录包含用于在 Kubernetes 环境中收集 Java 微服务多行日志的 Vector 配置文件。

## 配置文件说明

### 1. vector-k8s-docker-cri.yaml
适用于使用 **Docker** 作为容器运行时的 K8S 集群。

### 2. vector-k8s-containerd-cri.yaml
适用于使用 **Containerd** 作为容器运行时的 K8S 集群。

## 主要特性

- ✅ 支持 Java 应用多行日志收集（支持 Log4j、Logback 等格式）
- ✅ 使用 Loki API 发送日志到 VictoriaLogs（与 docker-compose 配置保持一致）
- ✅ 自动合并 K8S 分片日志（auto_partial_merge）
- ✅ 提取 K8S 元数据（namespace、pod、container、node）
- ✅ 内存缓冲优化，避免日志丢失
- ✅ 支持 gzip 压缩，减少网络带宽占用

## 部署步骤

### 1. 修改 VictoriaLogs 地址

编辑对应的 YAML 文件，修改 VictoriaLogs 的地址：

```yaml
# 方式1：如果 VictoriaLogs 部署在集群内
- name: VLS_ENDPOINT
  value: "http://victorialogs.logging.svc.cluster.local:9428"

# 方式2：如果使用外部 VictoriaLogs（推荐）
- name: VLS_ENDPOINT
  value: "http://172.18.151.163:9428"  # 替换为您的 VictoriaLogs IP

# 方式3：修改文件底部的 ExternalName Service
spec:
  type: ExternalName
  externalName: 172.18.151.163  # 替换为您的 VictoriaLogs IP
```

### 2. 部署 Vector

根据您的容器运行时选择相应的配置文件：

```bash
# Docker CRI
kubectl apply -f vector-k8s-docker-cri.yaml

# Containerd CRI
kubectl apply -f vector-k8s-containerd-cri.yaml
```

### 3. 验证部署

```bash
# 检查 DaemonSet 状态
kubectl get daemonset -n logging

# 查看 Vector Pod
kubectl get pods -n logging

# 查看 Vector 日志
kubectl logs -n logging -l app=vector --tail=50

# 访问 Vector API
kubectl port-forward -n logging svc/vector-api 8686:8686
curl http://localhost:8686/health
```

## 配置说明

### Java 多行日志配置

配置文件中已包含 Java 应用的多行日志匹配规则：

```yaml
multiline:
  # 匹配日期时间格式：2025-06-25 12:34:56,789 或 2025-06-25T12:34:56.789
  start_pattern: '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{3})?'
  condition_pattern: '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{3})?'
  mode: halt_before
  timeout_ms: 4000  # 4秒超时，确保日志及时刷新
```

支持的 Java 日志格式示例：
- `2025-06-25 12:34:56,789 INFO [main] com.example.App - Application started`
- `2025-06-25T12:34:56.789 ERROR [thread-1] - Exception occurred`
- 多行异常堆栈信息会自动合并为一条日志

### 日志过滤

默认配置只收集带有 `app.kubernetes.io/component=java` 标签的 Pod 日志。

如需收集所有日志，删除或注释以下行：
```yaml
extra_label_selector: "app.kubernetes.io/component=java"
```

如需自定义过滤条件，可修改为：
```yaml
extra_label_selector: "app=myapp,env=production"
```

### 资源限制

默认资源配置（可根据实际负载调整）：
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"
    cpu: "1000m"
```

## 与 Docker Compose 配置的一致性

K8S 配置与 docker-compose 配置保持一致：
- 使用相同的 **Loki sink** 类型
- 相同的日志处理逻辑（保存到 `_msg` 字段）
- 相同的批处理设置（1MB batch size）
- 相同的多行日志匹配规则
- 相同的 VictoriaLogs 接入路径 `/insert/loki/api/v1/push`

## 监控和调试

### 查看 Vector 指标

```bash
# 端口转发
kubectl port-forward -n logging svc/vector-api 8686:8686

# 查看指标
curl http://localhost:8686/metrics

# 查看健康状态
curl http://localhost:8686/health
```

### 查看处理的日志（调试）

配置中包含 console sink，可在 Vector Pod 日志中看到处理后的日志：
```bash
kubectl logs -n logging -l app=vector --tail=100 | grep "_msg"
```

生产环境建议删除 console sink 以节省资源。

### 查询 VictoriaLogs

```bash
# 查询最近的日志
curl -X POST "http://172.18.151.163:9428/select/logsql/query" \
  -d 'query=service:java | tail 100'

# 查询特定 namespace 的日志
curl -X POST "http://172.18.151.163:9428/select/logsql/query" \
  -d 'query=namespace:default AND pod:*'
```

## 常见问题

### 1. 日志没有发送到 VictoriaLogs
- 检查 VLS_ENDPOINT 配置是否正确
- 检查网络连通性：`kubectl exec -n logging <vector-pod> -- curl http://your-victorialogs:9428/health`
- 查看 Vector Pod 日志中的错误信息

### 2. 多行日志没有正确合并
- 检查日志格式是否匹配正则表达式
- 调整 timeout_ms 参数（默认 4000ms）
- 确认容器运行时类型选择正确（Docker vs Containerd）

### 3. 内存占用过高
- 减少 buffer.max_events 值（默认 50000）
- 调整 batch.max_bytes 值（默认 1MB）
- 考虑使用 disk buffer 替代 memory buffer

### 4. 如何判断使用哪个配置文件
```bash
# 检查节点的容器运行时
kubectl get nodes -o wide | grep VERSION

# 或者检查具体节点
kubectl describe node <node-name> | grep "Container Runtime"
```
- 如果显示 `docker://`，使用 `vector-k8s-docker-cri.yaml`
- 如果显示 `containerd://`，使用 `vector-k8s-containerd-cri.yaml`

## 更新配置

修改配置后，更新 ConfigMap 并重启 DaemonSet：
```bash
# 更新配置
kubectl apply -f vector-k8s-docker-cri.yaml

# 重启 DaemonSet
kubectl rollout restart daemonset/vector -n logging

# 查看更新状态
kubectl rollout status daemonset/vector -n logging
```