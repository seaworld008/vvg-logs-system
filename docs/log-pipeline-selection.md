# 日志链路选型与 Kubernetes 快速启用指南

本仓库同时维护直写和 AutoMQ 缓冲两类生产方案。Git 保留所有经过校验的通用配置，
目标服务器只保留当前启用链路的主文件；旧现场文件进入权限受限、带 SHA-256 的归档。

## 1. 选择入口

| 日志 | 适用规模 | 链路 | Kubernetes 主文件 |
| --- | --- | --- | --- |
| VVG 应用原始日志 | 小到中等 | Vector -> VictoriaLogs | `k8s-deployment/vector/vvg/direct-containerd.yaml` |
| Gateway 结构化日志 | 小到中等 | Vector -> ClickHouse | `k8s-deployment/vector/gateway/direct-containerd.yaml` |
| VVG 应用原始日志 | 中大规模或需要集中缓冲 | Vector -> AutoMQ -> Vector consumer -> VictoriaLogs | `k8s-deployment/vector/vvg/automq-containerd-production.yaml` |
| Gateway 结构化日志 | 中大规模或需要集中缓冲 | Vector -> AutoMQ -> Vector consumer -> ClickHouse | `k8s-deployment/vector/gateway/automq-containerd-production.yaml` |

同一条日志只能选择一个 production producer 清单。直写与 AutoMQ 清单复用同一
DaemonSet、ConfigMap 和 checkpoint hostPath，不能同时应用；切换使用滚动更新，不删除
checkpoint 或仍有数据的 disk buffer。

仓库提供的是脱敏通用配置。`registry.example.com`、`*.example.internal`、Gateway 日志
glob 和逻辑网关标识必须先替换；实际密码、Token、内网地址和服务器清单不得提交回 Git。

## 2. 目录约定

```text
k8s-deployment/vector/
  vvg/
    direct-containerd.yaml                       # VVG 直写 VictoriaLogs
    direct-docker.yaml                           # 旧 Docker CRI 的 VVG 直写兼容模板
    automq-containerd-production.yaml            # VVG 写 AutoMQ，生成文件
  gateway/
    direct-containerd.yaml                       # Gateway 直写 ClickHouse
    automq-containerd-production.yaml            # Gateway 写 AutoMQ，生成文件
    geoip/NOTICE.md
docker-compose/automq/
  docker-compose.yml                             # Broker、consumer、vmagent
  config/vector-vvg-consumer.yaml                # AutoMQ -> VictoriaLogs
  config/vector-gateway-consumer.yaml            # AutoMQ -> ClickHouse
docker-compose/clickhouse/                        # 唯一 ClickHouse 服务
docker-compose/grafana/
  dashboards/vvg-log-search.json                 # 默认 VVG Dashboard
  routes/gateway-clickhouse/                     # 同一 Grafana 的可选 Gateway 配置
scripts/
  render-automq-vector-manifest.py                # 从真实源清单派生 producer
  render-automq-example-manifests.py              # 生成/核对仓库 production 示例
```

直写 YAML 是解析和字段契约的源。两份 AutoMQ production YAML由生成器派生，不能分别
手改；修改源清单或生成器后必须重新生成并提交。

### 从 v0.4.0 迁移路径

| 旧路径 | 新路径 |
| --- | --- |
| `k8s-deployment/vector-k8s-containerd-cri.yaml` | `k8s-deployment/vector/vvg/direct-containerd.yaml` |
| `k8s-deployment/vector-k8s-docker-cri.yaml` | `k8s-deployment/vector/vvg/direct-docker.yaml` |
| `clickhouse-gateway/clickhouse/` | `docker-compose/clickhouse/` |
| `clickhouse-gateway/vector/vector-k8s-containerd.yaml` | `k8s-deployment/vector/gateway/direct-containerd.yaml` |
| `clickhouse-gateway/vector/geoip/` | `k8s-deployment/vector/gateway/geoip/` |
| `clickhouse-gateway/grafana/` | `docker-compose/grafana/routes/gateway-clickhouse/` |

旧路径不保留副本或软链接。更新外部脚本后再删除本地旧 checkout；不要同时引用新旧
路径部署同一个资源。

## 3. 共同前置检查

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion
kubectl get namespace logging >/dev/null 2>&1 || kubectl create namespace logging
```

1. 把 Vector和清单中的辅助容器精确镜像推入受控私库并记录 digest。
2. 替换清单中的示例私库地址；需要时配置 `imagePullSecrets`。
3. 从每个工作节点验证目标后端或 AutoMQ VPC listener 可达。
4. 导出当前 ConfigMap、DaemonSet、checkpoint 摘要并生成 SHA-256。
5. 使用目标集群的 `kubectl apply --dry-run=server` 校验候选文件。

Docker CRI 只保留 VVG 直写兼容模板。新的 containerd 集群使用表中的 containerd 文件；
不要未经真实运行时验证就把旧 Docker hostPath复制到 AutoMQ 清单。

## 4. VVG 直写 VictoriaLogs

修改 `VLS_ENDPOINT` 和私库镜像后：

```bash
kubectl apply --dry-run=server \
  -f k8s-deployment/vector/vvg/direct-containerd.yaml
kubectl apply -f k8s-deployment/vector/vvg/direct-containerd.yaml
kubectl -n logging rollout status daemonset/vector --timeout=300s
```

该路线保留 Java 多行合并、真实事件时间、每节点 1 GiB disk buffer、`when_full: block`
和 1 秒批次。完整验收见
[Vector/VictoriaLogs 延迟运行手册](vector-victorialogs-latency-runbook.md)。

## 5. Gateway 直写 ClickHouse

先替换私库镜像、ClickHouse endpoint、Gateway 日志 glob和逻辑网关标识，再从受控文件
创建写入 Secret：

```bash
kubectl -n logging create secret generic vector-clickhouse-auth \
  --from-file=username=/secure/path/clickhouse-username \
  --from-file=password=/secure/path/clickhouse-password \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --dry-run=server \
  -f k8s-deployment/vector/gateway/direct-containerd.yaml
kubectl apply -f k8s-deployment/vector/gateway/direct-containerd.yaml
kubectl -n logging rollout status \
  daemonset/vector-clickhouse-gateway --timeout=300s
```

该路线先完成 16 MiB单行读取、多行 JSON解析、GeoIP和脱敏，再通过 1 GiB disk buffer
写 ClickHouse。原始 header/body不会进入诊断文件。

## 6. AutoMQ 共同组件

AutoMQ 路线先部署 Broker、Topic、ACL、consumer和 vmagent，再启动 Kubernetes producer：

```bash
cd docker-compose/automq
cp env.example .env
# 填写固定镜像 digest、对象存储和后端参数；真实值只留在目标机。
bash scripts/render-runtime.sh
docker compose --env-file .env --profile production config --quiet
docker compose --env-file .env up -d automq vmagent
docker compose --env-file .env run --rm automq-bootstrap
```

新部署先启动 production consumer，再应用 producer。已有直写环境必须按
[AutoMQ 主切运行手册](automq-log-buffer-runbook.md)完成 shadow、停 consumer、Broker
重启、3 倍压测和固定时间窗对账；不能把下面的快速命令替代迁移门禁。

## 7. VVG 写入 AutoMQ

替换示例 bootstrap 地址、VictoriaLogs endpoint和私库镜像。producer 密码必须与
AutoMQ 中 `vvg-producer` SCRAM 用户一致：

```bash
kubectl -n logging create secret generic automq-vvg-producer \
  --from-file=password=/secure/path/vvg-producer-password \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --dry-run=server \
  -f k8s-deployment/vector/vvg/automq-containerd-production.yaml
kubectl apply \
  -f k8s-deployment/vector/vvg/automq-containerd-production.yaml
kubectl -n logging rollout status daemonset/vector --timeout=600s
```

VVG 使用 12 partitions、两个确定性 producer lane和总计 10 GiB/节点 disk buffer。
超过 4 MiB的事件直写 VictoriaLogs兜底；超过 16 MiB时保留大小和 SHA-256审计字段后
截取有限正文。常规事件不会同时直写和写入 AutoMQ。

## 8. Gateway 写入 AutoMQ

Gateway producer 需要独立 SCRAM 密码；超过 4 MiB的已脱敏结构化事件需要 ClickHouse
fallback Secret：

```bash
kubectl -n logging create secret generic automq-gateway-producer \
  --from-file=password=/secure/path/gateway-producer-password \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n logging create secret generic automq-gateway-clickhouse-fallback \
  --from-file=username=/secure/path/clickhouse-username \
  --from-file=password=/secure/path/clickhouse-password \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --dry-run=server \
  -f k8s-deployment/vector/gateway/automq-containerd-production.yaml
kubectl apply -f k8s-deployment/vector/gateway/automq-containerd-production.yaml
kubectl -n logging rollout status \
  daemonset/vector-clickhouse-gateway --timeout=600s
```

该清单复用直写路线的完整解析、GeoIP和字段契约，只把不超过 4 MiB的脱敏结构化事件
发送到 `gateway.access.v1`。原始 header/body不得进入 AutoMQ或对象存储。

## 9. 切换与回滚映射

| 当前链路 | 回滚或切换文件 |
| --- | --- |
| VVG AutoMQ -> 直写 | `k8s-deployment/vector/vvg/direct-containerd.yaml` |
| VVG 直写 -> AutoMQ | `k8s-deployment/vector/vvg/automq-containerd-production.yaml` |
| Gateway AutoMQ -> 直写 | `k8s-deployment/vector/gateway/direct-containerd.yaml` |
| Gateway 直写 -> AutoMQ | `k8s-deployment/vector/gateway/automq-containerd-production.yaml` |

AutoMQ 回滚时先恢复直写 producer，再让已进入 Topic 的消息由 production consumer排空；
不得先删除 Topic、对象存储数据或 KRaft metadata。切换后验证后端行数、事件时间、
consumer lag、producer buffer、错误、丢弃、Pod restart和 OOM。

## 10. 生成与校验

```bash
python3 -m pip install -r scripts/requirements-automq.txt
python3 scripts/render-automq-example-manifests.py
python3 scripts/render-automq-example-manifests.py --check
bash scripts/validate-automq.sh --static
bash scripts/validate-configs.sh --static
git diff --check
```

生产环境有自定义 selector、解析、GeoIP、字段或 checkpoint时，不以仓库示例覆盖现场。
先导出当前真实源 manifest，再使用 `render-automq-vector-manifest.py` 派生候选，并执行
运行手册的影子与回滚流程。

## 11. 服务器文件保留策略

- Git：长期保留四条链路的通用 YAML、生成器、文档和校验。
- CCE 管理节点：链路目录顶层只保留当前 production YAML、README和对应 SHA清单。
- 旧直写/影子/候选现场文件：移入 `archive/`，权限 `0700/0600`，生成 SHA-256。
- 凭据和带真实地址的渲染文件：只留在受限目标机，不进入 Git、PR、Release或截图。
- 不删除尚未排空的 Vector buffer、Kafka Topic、OBS对象或 KRaft metadata。
