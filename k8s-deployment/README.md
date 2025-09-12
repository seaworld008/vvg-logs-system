# Vector K8S 部署配置

本目录包含用于在 Kubernetes 环境中收集 Java 应用多行日志并发送到 VictoriaLogs 的 Vector 配置文件。

## 配置文件说明

### 1. vector-k8s-docker-cri.yaml
适用于使用 **Docker** 作为容器运行时的 K8S 集群。

### 2. vector-k8s-containerd-cri.yaml
适用于使用 **Containerd** 作为容器运行时的 K8S 集群。

## 主要特性

- ✅ **官方最佳实践**：使用 `kubernetes_logs` 源，支持自动多行日志合并
- ✅ **简化配置**：基于 Vector 官方推荐，配置简洁易维护
- ✅ **VictoriaLogs 集成**：使用 Loki API 发送日志，包含 `_msg` 字段
- ✅ **K8S 元数据**：自动提取 namespace、pod、container 等信息
- ✅ **健康检查过滤**：自动过滤 `/actuator/health` 等健康检查日志
- ✅ **高可用性**：内存缓冲、批处理、重试机制
- ✅ **资源优化**：合理的资源限制和性能配置

## 部署步骤

### 1. 修改 VictoriaLogs 地址

编辑配置文件中的 VictoriaLogs 端点地址：

```yaml
sinks:
  victorialogs:
    endpoint: "http://172.18.151.163:9428"  # 替换为您的 VictoriaLogs IP
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
# 检查 Pod 状态
kubectl get pods -n logging -l app=vector

# 查看 Vector 日志
kubectl logs -n logging -l app=vector --tail=50

# 检查是否有错误
kubectl logs -n logging -l app=vector | grep -i error
```

## 核心配置说明

### 日志源配置

使用官方推荐的 `kubernetes_logs` 源：

```yaml
sources:
  k8s_logs:
    type: "kubernetes_logs"
    # 自动处理多行日志合并（官方最佳实践）
    auto_partial_merge: true
    # 过滤系统组件日志，只收集应用日志
    extra_label_selector: "app!=fluentd,app!=vector"
```

### 日志处理流程

```yaml
transforms:
  # 1. 过滤健康检查日志
  filter_java_logs:
    type: filter
    condition: |
      !contains(string!(.message), "/actuator/health") && 
      !contains(string!(.message), "/health")
  
  # 2. 添加 VictoriaLogs 所需的 _msg 字段
  add_msg_field:
    type: remap
    source: |
      ._msg = .message
```

### VictoriaLogs 输出配置

```yaml
sinks:
  victorialogs:
    type: loki
    endpoint: "http://172.18.151.163:9428"
    path: /insert/loki/api/v1/push
    labels:
      job: "java-app"
      namespace: "{{ kubernetes.pod_namespace }}"
      pod: "{{ kubernetes.pod_name }}"
      container: "{{ kubernetes.container_name }}"
    # 性能优化配置
    batch:
      max_bytes: 102400      # 100KB 批大小
      timeout_secs: 5        # 5秒批超时
    buffer:
      type: memory
      max_events: 1000       # 内存缓冲1000条
    healthcheck: false       # 禁用健康检查避免400错误
```

## 如何判断使用哪个配置文件

```bash
# 检查节点的容器运行时
kubectl get nodes -o wide

# 或者检查具体节点
kubectl describe node <node-name> | grep "Container Runtime"
```

- 如果显示 `docker://`，使用 `vector-k8s-docker-cri.yaml`
- 如果显示 `containerd://`，使用 `vector-k8s-containerd-cri.yaml`

## 监控和验证

### 检查日志收集

```bash
# 查看 Vector 处理的日志数量
kubectl logs -n logging -l app=vector | grep "Events received"

# 检查发送到 VictoriaLogs 的状态  
kubectl logs -n logging -l app=vector | grep victorialogs
```

### 查询 VictoriaLogs

在 VictoriaLogs Web 界面中查询：
- **日志查询**: `job="java-app"`
- **按 namespace 过滤**: `namespace="your-namespace"`
- **按 pod 过滤**: `pod=~"your-app-.*"`

## 常见问题

### 1. Pod 启动报错 "VECTOR_SELF_NODE_NAME env var is not set"
**解决方案**: 确保配置文件中包含以下环境变量：
```yaml
env:
- name: VECTOR_SELF_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
```

### 2. 日志中出现 "missing _msg field" 错误  
**解决方案**: 配置文件已包含 `add_msg_field` transform，确保部署的是最新版本。

### 3. Pod 出现端口冲突 "Address in use (os error 98)"
**原因**: 节点上已经运行了其他 Vector 实例（如 Docker 版本）
**解决方案**: 停止节点上的其他 Vector 服务，或修改端口配置

### 4. 400 Bad Request 错误
**解决方案**: 配置中已设置 `healthcheck: false` 来避免此问题

### 5. 小文件警告 "file too small to fingerprint"  
**说明**: 这是正常警告，不影响功能，可忽略

## 更新配置

```bash
# 更新配置
kubectl apply -f vector-k8s-docker-cri.yaml

# 重启 Pod（可选，ConfigMap 会自动重载）
kubectl delete pods -n logging -l app=vector
```

## 资源配置

默认资源限制：
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"  
    cpu: "1000m"
```

根据集群规模和日志量可适当调整。

## 支持的日志格式

Vector 会自动处理以下格式的 Java 多行日志：
- Spring Boot 默认格式
- Log4j/Log4j2 格式  
- Logback 格式
- 自定义格式（只要有时间戳开头）

异常堆栈会自动合并为单条日志记录。