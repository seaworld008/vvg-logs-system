# 仓库检查与可靠性修复（2026-09-05）

检查基线：`3421a2d`。范围是 Git 中的 Compose、Vector 直写与 AutoMQ 生成链路、
启动/恢复脚本、Grafana 与夜莺资产、MCP 配置边界及 CI。没有连接或修改生产主机，
因此这份检查不能替代 OBS 实测、生产故障演练或真实流量容量测试。

## 本次修复

| 问题 | 影响 | 修复与验证 |
|---|---|---|
| bootstrap 等待包含 Topic 的健康检查 | 空集群中 Topic 尚不存在，创建 Topic 的服务却无法启动 | bootstrap 等待有界的已认证 API 探测，消费者继续等待 bootstrap 完成与 Topic 健康；测试冷启动依赖及 API 延迟/失败 |
| 健康检查只排除负 leader | 仅含摘要、没有实际分区的输出可能被误判 healthy；原 Compose 超时 35 秒小于三次内部探测最多 40 秒 | 要求至少一条分区记录且每条 leader 为非负整数，外层超时改为 45 秒；覆盖空输出、摘要、负 leader 和部分分区失败 |
| watchdog 查询失败使脚本整体退出 | Gateway 查询故障阻断 VVG 恢复；查询未知状态与旧计数组合可能导致误重启 | 使用有界 group state 查询，隔离 group 错误，清除非连续计数；只对连续两次 Empty/0 执行原有优雅重启 |
| watchdog 选服务时未始终限定 project，且执行 `.env` | 其他 project 的同名服务干扰本机判断；配置中的 shell 特殊字符可能被执行 | 所有服务选择限定 `automq` project；只解析必要 group 值，测试跨 project 与命令替换输入 |
| VVG 生成器写死 `add_msg_field` 并清空所有 sink | 现场追加的脱敏/过滤可能被绕过，辅助 sink 丢失 | 继承真实 Loki sink inputs，只替换目标 sink；shadow/production 都做回归验证，拒绝空输入 |
| 远端 consumer 缺少禁止拉取策略 | 与离线启动要求不一致 | 三实例继承 `pull_policy: never` |
| CI 只检查生成清单结构 | 生成的 VRL 或 Vector 配置错误可能通过检查 | 保留结构与防漂移校验，增加四种生产者配置的 Vector 0.58.0 实际编译与 GeoIP SHA-256 校验 |

回归测试位于 `scripts/tests/test_automq_reliability.py`，由现有静态入口自动执行。
测试使用临时目录与 Kafka/Docker 命令替身验证脚本行为，不向真实集群建 Topic、发日志或
重启容器。完整容器编译仍由 `--runtime` / GitHub Actions 验证。

## 其他检查结论与后续优先级

| 范围 | 检查结论 / 下一步 |
|---|---|
| VVG 直写与日志检索 | 本轮静态校验通过；保留 checkpoint、disk/block、乱序时间、稳定 UID、500 行及 15 分钟限制。Grafana 插件升级必须重新做浏览器请求级验证 |
| Gateway / ClickHouse | 保留 180 秒写入超时、异步写入确认、固定 GeoIP、脱敏边界和表结构。没有用镜像升级顺带修改 TTL/主键 |
| MCP | 保留官方组件、独立 Token、固定租户 Header、路径白名单和并发限制。此次未执行真实鉴权/超时穿透测试，不能宣称完成安全认证 |
| 镜像与依赖 | 保留已固定的版本/digest；本轮没有批量升级。当前缺少真实部署副本和插件浏览器验收条件，更新版本应作为独立兼容性任务 |
| 单节点 AutoMQ | 仍有 Broker/KRaft/宿主机单点；对象存储不消除控制面单点。需要高可用时另行规划多节点和故障演练 |
| 本机 VVG 多副本与监控 | 本机 `scale: 3` 仍共享宿主机 state 路径；consumer 当前使用 memory buffer，但应在后续迁移中改为独立目录。远端模板已有独立目录和端口。监控静态 service 名也应改为逐副本发现并按已启用 profile 生成目标，避免漏采和未启用 profile 的持续 down |
| producer 自动恢复 | 现有 liveness 以高水位且队列不下降判断卡住，持续满负荷时可能与真实卡死混淆；需要结合现场发送速率、lag 与负载回放再调整，不能仅凭配置推断安全阈值 |
| 首次启动与对象存储 | 回归证明依赖循环已移除，但不替代真实 OBS 小对象、multipart、重启后消息校验和 90 分钟 shadow 门禁 |

## 验证与部署

```bash
python3 -m pip install -r scripts/requirements-automq.txt
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
bash scripts/validate-configs.sh --static
bash scripts/validate-configs.sh --runtime
git diff --check
```

合并要求：PR 的完整 CI 成功，合并后核对 `main`。实际主机更新仍遵循
[AutoMQ 运行手册](automq-log-buffer-runbook.md)，先备份再展开 Compose，只更新批准的
脚本/配置；合并仓库不代表已部署到生产。回滚采用新的 revert PR 和对应主机配置备份，
不删除 Topic、offset、OBS 对象或生产数据。

依据：[Compose 启动依赖](https://docs.docker.com/compose/how-tos/startup-order/)、
[Kafka consumer group 管理](https://kafka.apache.org/41/operations/basic-kafka-operations/)。
