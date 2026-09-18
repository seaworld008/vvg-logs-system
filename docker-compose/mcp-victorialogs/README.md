# VictoriaLogs MCP 部署与客户端配置指南

本目录提供官方 `mcp-victorialogs` 与官方 `vmauth` 的只读 MCP 接入层，是独立 Compose 项目，不会重建 Grafana、VictoriaLogs 或 Vector。本文按“准备 -> 生成凭据 -> 部署 -> 验收 -> 配置客户端”编排，适用于 Codex、Claude、Cursor 和其他支持 Streamable HTTP 的 MCP 客户端。

## 1. 工作原理

```text
MCP 客户端 -- HTTPS/HTTP + 外部 Bearer Token --> vmauth:8427
                                             (唯一对外入口)
vmauth -- 内部 Bearer Token --> mcp-victorialogs:8081
mcp-victorialogs --> VictoriaLogs /select/logsql/*
```

- 客户端只访问 `/mcp`；MCP 容器不发布宿主机端口。
- `vmauth` 覆盖 `AccountID`、`ProjectID`，不信任工具参数中的租户。
- 只允许 `query`、`hits`、`field_names`、`field_values`、`stats_query`；禁止写入、管理、flags、metrics 和 `stats_query_range`。
- 日志最多 500 行，字段值最多 100 个，后端超时最多 20 秒，MCP 到后端并发固定为 1。
- 外部客户端 Token 与 MCP 到 `vmauth` 的内部 Token 必须不同；不要设置 `MCP_PASSTHROUGH_HEADERS`。

## 2. 固定版本与目录

`env.example` 固定官方 Linux AMD64 镜像：`mcp-victorialogs v1.9.0`、`vmauth v1.151.0`。生产应先复制到受控私库，再在 `.env` 中保留 digest；禁止 `latest` 或运行时在线拉取。

建议目标机目录（凭据不入 Git）：

```text
/data/vvg-mcp/
├── docker-compose.yml
├── .env                         # 0600
├── vmauth/auth.yml              # 0600；容器读取时可为 0640:65534
├── secrets/client-bearer-token  # 0600
└── backups/
```

```bash
sudo install -d -m 0700 /data/vvg-mcp/{vmauth,secrets,backups}
sudo cp docker-compose.yml /data/vvg-mcp/
sudo cp env.example /data/vvg-mcp/.env
sudo cp vmauth/auth.example.yml /data/vvg-mcp/vmauth/
cd /data/vvg-mcp
```

## 3. 生成并渲染 Token

必须生成两个独立随机 Token，不能复用 Grafana、SSH 或 VictoriaLogs 凭据：

```bash
CLIENT_TOKEN="$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=')"
PROXY_TOKEN="$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=')"
test "$CLIENT_TOKEN" != "$PROXY_TOKEN"
printf '%s\n' "$CLIENT_TOKEN" | sudo tee secrets/client-bearer-token >/dev/null
sudo chmod 600 secrets/client-bearer-token
```

将 `PROXY_TOKEN` 写入 `.env`，将 `CLIENT_TOKEN` 写入 `vmauth/auth.yml` 的 `vvg-mcp-client` 用户。推荐在受限终端中渲染模板，避免 Token 出现在命令历史：

```bash
read -rsp '内部 vmauth Token: ' PROXY_TOKEN; echo
read -rsp '外部客户端 Token: ' CLIENT_TOKEN; echo
export PROXY_TOKEN CLIENT_TOKEN
export VICTORIALOGS_URL='http://victorialogs:9428'
export VL_ACCOUNT_ID=0 VL_PROJECT_ID=0
python3 - <<'PY'
from pathlib import Path
import os
p = Path('vmauth/auth.example.yml')
s = p.read_text()
for k, v in {
 '__MCP_CLIENT_BEARER_TOKEN__': os.environ['CLIENT_TOKEN'],
 '__VL_PROXY_BEARER_TOKEN__': os.environ['PROXY_TOKEN'],
 '__VL_ACCOUNT_ID__': os.environ['VL_ACCOUNT_ID'],
 '__VL_PROJECT_ID__': os.environ['VL_PROJECT_ID'],
 '__VICTORIALOGS_URL__': os.environ['VICTORIALOGS_URL'],
}.items():
 s = s.replace(k, v)
Path('vmauth/auth.yml').write_text(s)
PY
chmod 600 .env vmauth/auth.yml
```

`.env` 至少包含：

```dotenv
MCP_BIND_ADDRESS=10.0.0.10
MCP_PORT=8081
MCP_VICTORIALOGS_IMAGE=registry.example.com/observability/mcp-victorialogs:v1.9.0@sha256:...
VMAUTH_IMAGE=registry.example.com/observability/vmauth:v1.151.0@sha256:...
VL_PROXY_BEARER_TOKEN=内部Token
VL_DEFAULT_TENANT_ID=0:0
```

## 4. 校验、启动与验收

```bash
docker compose --env-file .env config --quiet
docker run --rm -v "$PWD/vmauth/auth.yml:/etc/vmauth/auth.yml:ro" \
  "$VMAUTH_IMAGE" -auth.config=/etc/vmauth/auth.yml -dryRun
docker compose --env-file .env up -d
docker compose ps
curl -fsS http://127.0.0.1:${MCP_PORT}/health/readiness
```

未带 Token 必须拒绝，带正确外部 Token 必须完成 MCP 初始化并列出 5 个工具；再执行一次最近 15 分钟真实查询，确认最多 500 行。同步检查容器 healthy、重启次数为 0、OOM 为 false，以及 VictoriaLogs/Grafana 原有健康状态。生产入口应使用 HTTPS 反向代理，直接 `http://HOST:8081/mcp` 仅用于内网验证。

更新 `auth.yml` 后原子替换并只重建 vmauth（bind mount 可能仍指向旧 inode）：

```bash
docker compose up -d --no-deps --force-recreate vmauth
```

## 5. Codex 配置

Codex CLI、IDE 扩展和 ChatGPT 桌面应用共享 `~/.codex/config.toml`。优先使用 CLI：

```bash
codex mcp add vvg-logs --url https://logs.example.com/mcp \
  --bearer-token "$CLIENT_TOKEN"
codex mcp list
```

若版本没有 `--bearer-token` 参数，编辑：

```toml
[mcp_servers.vvg-logs]
url = "https://logs.example.com/mcp"
bearer_token = "REPLACE_WITH_CLIENT_TOKEN"
```

重启后在 TUI 输入 `/mcp`。桌面应用也可在“设置 -> MCP 服务器 -> 添加服务器”选择 Streamable HTTP，填写 URL 和 Bearer Token。

## 6. Claude 配置

### Claude Code

```bash
claude mcp add --transport http vvg-logs https://logs.example.com/mcp \
  --header "Authorization: Bearer $CLIENT_TOKEN"
claude mcp list
```

重启后用 `/mcp` 检查连接。

### Claude Desktop

部分版本只接受 stdio，可用 `mcp-remote` 桥接：

```json
{
  "mcpServers": {
    "vvg-logs": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://logs.example.com/mcp", "--header", "Authorization:\${VVG_MCP_AUTH}"],
      "env": {"VVG_MCP_AUTH": "Bearer REPLACE_WITH_CLIENT_TOKEN"}
    }
  }
}
```

将其放入 `claude_desktop_config.json` 后重启。Token 应放在操作系统密钥链或受限启动脚本中，不要进入同步目录。

## 7. Cursor 与其他 JSON 客户端

```json
{
  "mcpServers": {
    "vvg-logs": {
      "url": "https://logs.example.com/mcp",
      "headers": {"Authorization": "Bearer REPLACE_WITH_CLIENT_TOKEN"}
    }
  }
}
```

保存到 Cursor 的 MCP 设置或项目 `.cursor/mcp.json`。只支持 stdio 的客户端使用上一节的 `mcp-remote` 方式。

## 8. 故障排查、轮换与回滚

- **401/403**：误用了内部 `VL_PROXY_BEARER_TOKEN`，或客户端没有发送 `Authorization: Bearer`。
- **无工具**：确认 URL 以 `/mcp` 结尾、传输为 Streamable HTTP，代理未删除 MCP 会话头。
- **超时**：缩小时间、namespace、service 或 pod；20 秒是保护上限，不应直接放宽 vmauth。
- **更新不生效**：原子替换后执行 `--force-recreate vmauth`。
- **不应公网暴露**：`MCP_BIND_ADDRESS` 绑定内网地址，入口启用 HTTPS、访问控制和审计。
- **Token 泄露**：重新生成一对 Token、替换 auth 配置、重建 vmauth，并撤销旧 Token。
- **回滚**：恢复同一份 `.env`、`auth.yml` 和 Compose 展开备份，只重建 vmauth；不要顺带升级或回滚 VictoriaLogs、Vector、Grafana。

凭据、服务器地址、租户和运行日志不得提交 Git、PR、Release 或截图。
