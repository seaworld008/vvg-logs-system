# ADR-003: 按服务与部署平台组织日志配置

## Status

Accepted

## Date

2026-09-04

## Context

历史 `clickhouse-gateway/` 按端到端方案再次嵌套 ClickHouse、Vector和 Grafana目录，
同时仓库顶层已经存在 `docker-compose/grafana/`、`k8s-deployment/` 等服务入口。新用户
容易把这些目录理解为重复服务，无法判断应该启动哪套 Grafana或 Vector。

仓库又必须长期保留 VVG/Gateway 的直写与 AutoMQ缓冲路线，不能通过删除完整配置来
换取表面简洁。

## Decision

按部署平台和服务归位，按日志用途与路线区分配置：

```text
docker-compose/{automq,clickhouse,grafana,victorialogs,vector}/
k8s-deployment/vector/{vvg,gateway}/
```

- ClickHouse只有 `docker-compose/clickhouse/` 一个服务入口；
- Grafana只有 `docker-compose/grafana/` 一个服务入口，Gateway使用可选 route override；
- Kubernetes Vector全部位于 `k8s-deployment/vector/`，每种日志分别提供 direct与
  AutoMQ production YAML；
- 直写清单是解析和字段源，AutoMQ清单由生成器派生并由 CI检查字节级一致性；
- `docs/log-pipeline-selection.md` 是所有路线的唯一总索引；
- 删除旧 `clickhouse-gateway/` 目录，并在 Release说明中提供路径迁移表。

## Consequences

- 用户只需先选择服务或 Kubernetes Vector，再选择日志与发送路线；
- VVG-only 用户不会因为 Gateway datasource和插件缺失而启动失败；
- Gateway用户通过同一个 Grafana Compose叠加明确的 override，而不是启动第二个
  Grafana；
- 路径发生一次不向后兼容的移动，需要同步脚本、运行手册和外部自动化；
- 历史 ADR和 Git记录保留旧决策背景，但活动文档只引用新路径。

## Alternatives Considered

### 保留 `clickhouse-gateway/` 总目录

端到端文件聚合在一起，但复制了服务层级并造成“应启动哪个 Grafana”的歧义，不采用。

### 为四条路线复制四套完整服务目录

初次浏览直观，但解析、Dashboard、插件和 Compose会快速漂移，校验成本最高，不采用。

### 只保留当前生产 AutoMQ路线

目录最少，但失去小规模直写最佳实践和快速回滚入口，不符合仓库复用目标，不采用。
