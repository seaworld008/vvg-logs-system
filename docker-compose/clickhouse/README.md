# ClickHouse Docker Compose

本目录是仓库中唯一的 ClickHouse 服务部署入口。当前 schema用于 Gateway 结构化访问
日志；Vector采集和 Grafana展示配置分别归入统一的 Kubernetes Vector 与 Grafana
服务目录，不在这里复制部署文件。

验证基线：ClickHouse `26.8.2.7-alpine`。生产操作前阅读
[Vector/ClickHouse/Grafana 运行手册](../../docs/vector-clickhouse-gateway-runbook.md)。

## 目录

```text
docker-compose/clickhouse/
  docker-compose.yml
  config/observability.xml
  initdb/001-gateway-schema.sql
  README.md
```

关联配置：

- Gateway 直写 Vector：`k8s-deployment/vector/gateway/direct-containerd.yaml`
- Gateway AutoMQ producer：`k8s-deployment/vector/gateway/automq-containerd-production.yaml`
- Grafana可选路线：`docker-compose/grafana/routes/gateway-clickhouse/`
- 四条链路选型：`docs/log-pipeline-selection.md`

## 部署前替换

- 私库 `registry.example.com/observability/...`；
- `CHANGE_ME_BEFORE_DEPLOY` 初始写入密码；
- 数据、日志目录和资源边界。

真实密码、地址和服务器清单不得提交到 Git。生产单文件 Compose若包含实际密码必须
设为 `0600`，并留在目标机的受限目录。

## 镜像交付

在受控机器拉取精确 LTS patch、记录 RepoDigest并推入私库。生产启动禁止在线拉取：

```bash
docker pull clickhouse/clickhouse-server:26.8.2.7-alpine
docker image inspect clickhouse/clickhouse-server:26.8.2.7-alpine \
  --format 'id={{.Id}} digests={{json .RepoDigests}} size={{.Size}}'

docker tag clickhouse/clickhouse-server:26.8.2.7-alpine \
  registry.example.com/observability/clickhouse/clickhouse-server:26.8.2.7-alpine
docker push \
  registry.example.com/observability/clickhouse/clickhouse-server:26.8.2.7-alpine
```

无法出网时使用 `docker save | gzip`、SHA-256、内网传输和 `docker load`；私库确认
可拉取后删除中转包。

## 启动

```bash
cd docker-compose/clickhouse
install -d -m 0750 data logs
chmod 0600 docker-compose.yml
docker compose -f docker-compose.yml config --quiet
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

`001-gateway-schema.sql` 只在空数据目录首次初始化时执行。已有数据库升级必须先停止
写入并创建一致性数据副本；不得把新版本直接指向唯一生产目录。

## 长期运行边界

- 月分区、紧凑主键、30 天 Gateway 业务 TTL；
- query/trace/part system log 7 天 TTL；
- 认证健康检查、120 秒优雅停止、3 CPU/8 GiB和 PID边界；
- `pull_policy: never`，正式启动不联网；
- 已有业务表的分区、ORDER BY、TTL、MV和 projection不随镜像升级修改。

## 验证

```bash
bash scripts/validate-clickhouse-gateway.sh --static
bash scripts/validate-clickhouse-gateway.sh --runtime
```

运行时还要验证最新写入延迟、异步插入失败、parts/mutation、历史查询、Vector buffer、
容器重启和 OOM。仅容器 Running或 HTTP 200不足以证明链路正常。
