# Gateway Vector Kubernetes 配置

本目录集中管理 Gateway 日志的全部 Kubernetes Vector production清单。两条路线共享
同一解析、GeoIP、字段、checkpoint和 DaemonSet身份，只改变结构化事件的发送目标。

| 路线 | 文件 | 适用场景 |
| --- | --- | --- |
| 直写 ClickHouse | `direct-containerd.yaml` | 小到中等规模、组件最少 |
| 写入 AutoMQ | `automq-containerd-production.yaml` | 中大规模、突发或需要集中缓冲 |

两份文件不能同时应用。AutoMQ文件由直写文件生成，禁止分别修改解析和字段逻辑：

```bash
python3 scripts/render-automq-example-manifests.py
python3 scripts/render-automq-example-manifests.py --check
```

## 共同替换项

- `registry.example.com/observability/...` 私库镜像；`quay.io/curl`辅助镜像也必须保持
  当前精确 digest并先镜像到私库；
- Gateway容器日志 glob；
- `REPLACE_LOGICAL_GATEWAY_ID`；
- ClickHouse内网 endpoint；
- 目标 namespace和 selector。

原始日志可能超过 9000 行。两条路线都在 multiline和 VRL前固定
`max_line_bytes: 16777216`，然后完成 JSON解析、GeoIP和脱敏。解析失败只输出有限技术
诊断，不写原始 header/body。

## Secret

直写路线创建：

```bash
kubectl -n logging create secret generic vector-clickhouse-auth \
  --from-file=username=/secure/path/clickhouse-username \
  --from-file=password=/secure/path/clickhouse-password \
  --dry-run=client -o yaml | kubectl apply -f -
```

AutoMQ路线创建 `automq-gateway-producer` 和
`automq-gateway-clickhouse-fallback`，完整命令见
[链路选型指南](../../../docs/log-pipeline-selection.md)。实际值不得进入 YAML、Git或终端
聊天记录。

## 部署

直写：

```bash
kubectl apply --dry-run=server -f \
  k8s-deployment/vector/gateway/direct-containerd.yaml
kubectl apply -f k8s-deployment/vector/gateway/direct-containerd.yaml
```

AutoMQ：

```bash
kubectl apply --dry-run=server -f \
  k8s-deployment/vector/gateway/automq-containerd-production.yaml
kubectl apply -f \
  k8s-deployment/vector/gateway/automq-containerd-production.yaml
```

两条路线最后都执行：

```bash
kubectl -n logging rollout status \
  daemonset/vector-clickhouse-gateway --timeout=600s
```

已有直写环境切到 AutoMQ前必须执行 shadow对账、故障恢复和压测门禁，不能只运行
`kubectl apply`。详见 [AutoMQ运行手册](../../../docs/automq-log-buffer-runbook.md)。
