# VVG Production Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将生产验证过的 Grafana 查询体验、VictoriaLogs 指标驱动调优和 Vector 低延迟可靠采集基线沉淀到仓库，并用自动校验防止回归。

**Architecture:** 保持 Vector、VictoriaLogs、Grafana 三层职责不变。通过固定版本、自定义 Grafana 镜像、参数化 Compose、持久磁盘缓冲和证据驱动的查询限制提升可靠性；通过 Bash 校验脚本和 GitHub Actions 统一验证静态配置与运行时配置。

**Tech Stack:** Docker Compose v2、Grafana 13.2.0、VictoriaLogs v1.52.0、Vector 0.58.0、Bash、GitHub Actions、Markdown。

---

### Task 1: Add repository guardrails

**Files:**
- Create: `scripts/validate-configs.sh`
- Create: `.github/workflows/validate.yml`

**Step 1: Write the failing static checks**

Create a Bash script with `set -euo pipefail` and helpers that fail when:

```bash
grep -R "GF_INSTALL_PLUGINS" docker-compose/grafana
grep -R -E "grafana-(piechart|worldmap)-panel" docker-compose/grafana
grep -R -E "drop_newest|rewrite_timestamp" docker-compose k8s-deployment
grep -R -E "GRAFANA_ADMIN_PASSWORD=.+[^>]$" docker-compose/grafana/env.example
```

Require these repository invariants:

```text
GF_EXPLORE_DEFAULTTIMEOFFSET=15m
victorialogs-ds
maxLines: 2000
search.maxConcurrentRequests
glob_minimum_cooldown_ms: 5000
timeout_secs: 1
when_full: block
```

Add `--static` and `--runtime` modes. Runtime mode must run `docker compose config --quiet` for all three Compose projects and run `vector validate` against the Docker Vector configuration.

**Step 2: Run the static checks and prove they fail**

Run:

```bash
bash scripts/validate-configs.sh --static
```

Expected: non-zero exit with Grafana runtime plugin installation, legacy plugins, missing 15-minute default, real-looking password example, and Docker Vector baseline drift.

**Step 3: Add the CI workflow**

Use an Ubuntu runner, check out the repository, run static validation, then runtime validation. Pin third-party actions to reviewed immutable revisions before merge.

**Step 4: Commit the guardrails**

```bash
git add scripts/validate-configs.sh .github/workflows/validate.yml
git commit -m "test: add VVG configuration guardrails"
```

### Task 2: Harden the Grafana deployment baseline

**Files:**
- Create: `docker-compose/grafana/Dockerfile`
- Modify: `docker-compose/grafana/docker-compose.yml`
- Modify: `docker-compose/grafana/env.example`
- Modify: `docker-compose/grafana/datasources/victorialogs.yaml`
- Modify: `docker-compose/grafana/README.md`

**Step 1: Add the build-time plugin image**

Build from `grafana/grafana:13.2.0-ubuntu` and install exactly `victoriametrics-logs-datasource 0.31.0` during image build:

```dockerfile
ARG GRAFANA_VERSION=13.2.0-ubuntu
FROM grafana/grafana:${GRAFANA_VERSION}
ARG VICTORIALOGS_PLUGIN_VERSION=0.31.0
RUN grafana cli --pluginsDir /var/lib/grafana/plugins \
    plugins install victoriametrics-logs-datasource "${VICTORIALOGS_PLUGIN_VERSION}"
```

Do not install plugins when the container starts.

**Step 2: Update Compose lifecycle and query defaults**

Remove the obsolete top-level Compose version. Use a prebuilt `GRAFANA_IMAGE`, add `stop_grace_period: 1m`, mount provisioning read-only, and configure:

```yaml
- GF_EXPLORE_DEFAULTTIMEOFFSET=15m
- VICTORIALOGS_URL=${VICTORIALOGS_URL}
```

Keep user `472`, add a 120-second health start period, and do not include Angular or unsigned-plugin exceptions.

**Step 3: Make the data source immutable and bounded**

Provision:

```yaml
uid: victorialogs-ds
url: ${VICTORIALOGS_URL}
editable: false
jsonData:
  maxLines: 2000
  timeout: 60
```

Remove the hard-coded tenant header from the generic single-tenant baseline.

**Step 4: Replace secrets and pin versions in the example**

Use non-secret placeholders and explicit versions/image names. Never include a working password.

**Step 5: Validate the Grafana changes**

Run:

```bash
bash scripts/validate-configs.sh --static
docker compose --env-file docker-compose/grafana/env.example \
  -f docker-compose/grafana/docker-compose.yml config --quiet
```

Expected: Grafana-specific checks and Compose expansion pass.

**Step 6: Commit**

```bash
git add docker-compose/grafana
git commit -m "feat: harden Grafana query and upgrade baseline"
```

### Task 3: Make VictoriaLogs query tuning evidence-driven

**Files:**
- Modify: `docker-compose/victorialogs/docker-compose.yml`
- Modify: `docker-compose/victorialogs/env.example`
- Modify: `docker-compose/victorialogs/README.md`

**Step 1: Parameterize verified query controls**

Add these flags through `.env` values:

```text
--search.maxConcurrentRequests=4
--search.maxQueueDuration=1m
--defaultParallelReaders=1
--search.maxQueryDuration=2m
--search.logSlowQueryDuration=8s
```

Add explicit CPU and memory limits matching the documented production sizing, while making every limit overrideable.

**Step 2: Correct the tuning documentation**

Remove the unconditional concurrency 16 example. Document the metrics gate:

```text
vl_concurrent_select_capacity
vl_concurrent_select_current
vl_concurrent_select_limit_reached_total
vl_concurrent_select_limit_timeout_total
vl_slow_queries_total
```

Only increase concurrency when limit/timeout counters grow and CPU/memory still have headroom.

**Step 3: Validate and commit**

```bash
docker compose --env-file docker-compose/victorialogs/env.example \
  -f docker-compose/victorialogs/docker-compose.yml config --quiet
bash scripts/validate-configs.sh --static
git add docker-compose/victorialogs
git commit -m "feat: add evidence-driven VictoriaLogs query controls"
```

### Task 4: Align Docker Vector with the low-latency Kubernetes baseline

**Files:**
- Modify: `docker-compose/vector/docker-compose.yml`
- Modify: `docker-compose/vector/vector.yaml`
- Modify: `docker-compose/vector/env.example`
- Modify: `docker-compose/vector/README.md`

**Step 1: Update file discovery and rotation behavior**

For every file source, add the appropriate verified options:

```yaml
exclude:
  - "**/*.gz"
  - "**/*.tmp"
glob_minimum_cooldown_ms: 5000
oldest_first: false
max_read_bytes: 65536
rotate_wait_secs: 300
```

Confirm every key against Vector 0.58 documentation before editing.

**Step 2: Reduce bounded latency**

Use `timeout_ms: 3000` for Java multiline and `batch.timeout_secs: 1`. Keep the 10 GiB disk buffer, `when_full: block`, gzip, and request concurrency 4.

**Step 3: Remove duplicate stdout output**

Remove the default console sink. Add `vector tap` examples to the README for temporary debugging without duplicating every business log into Docker's json-file logs.

**Step 4: Validate Vector configuration**

Run:

```bash
docker run --rm \
  -e VLS_ENDPOINT=http://victorialogs.example:9428 \
  -e HOSTNAME=validation-node \
  -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
  -v "$PWD/docker-compose/vector/vector.yaml:/etc/vector/vector.yaml:ro" \
  timberio/vector:0.58.0-alpine \
  validate --no-environment /etc/vector/vector.yaml
```

Expected: `Validated` with exit code 0.

**Step 5: Commit**

```bash
git add docker-compose/vector
git commit -m "feat: align Docker Vector with low-latency collection"
```

### Task 5: Add the Grafana query and upgrade runbook

**Files:**
- Create: `docs/grafana-victorialogs-query-performance-runbook.md`
- Modify: `docs/troubleshooting.md`
- Modify: `README.md`
- Modify: `k8s-deployment/README.md`

**Step 1: Document the evidence-first query diagnosis**

Cover:

- default 15-minute range and stale Explore URL overrides;
- `499/context canceled` as a browser cancellation, not a backend timeout;
- invalid LogsQL caused by bare pipe values and smart quotes;
- direct 15-minute and 60-minute query timing;
- VictoriaLogs concurrency counters and the decision not to increase from 4 without saturation.

**Step 2: Document the safe Grafana upgrade path**

Include build-time/offline plugin delivery, exact image/plugin versions, consistent SQLite backup, isolated data-copy migration test, single-service recreation, public endpoint validation, and database-backed rollback requirements.

**Step 3: Update repository navigation and baselines**

Show all three verified versions in the root README and cross-link both operational runbooks from troubleshooting and deployment documents.

**Step 4: Commit**

```bash
git add README.md docs k8s-deployment/README.md
git commit -m "docs: add Grafana query and upgrade operations"
```

### Task 6: Run the delivery gate and merge the PR

**Files:**
- Modify as needed based on validation findings.

**Step 1: Run complete validation**

```bash
bash scripts/validate-configs.sh --static
bash scripts/validate-configs.sh --runtime
git diff --check origin/main...HEAD
git status --short
```

Expected: all checks exit 0 and the worktree contains no uncommitted files.

**Step 2: Review the branch diff**

Check for secrets, unrelated changes, unpinned versions, unsupported flags, and documentation/config drift.

**Step 3: Push and create the PR**

```bash
git push -u origin codex/vvg-production-hardening
gh pr create --base main --head codex/vvg-production-hardening \
  --title "Harden VVG production logging baseline" \
  --body-file PR_BODY.md
```

Do not commit `PR_BODY.md`; remove it after PR creation.

**Step 4: Wait for required checks and merge**

```bash
gh pr checks --watch
gh pr merge --merge --delete-branch
git fetch origin
git log -1 --oneline origin/main
```

Expected: PR merged, required checks successful, and `origin/main` contains the merge commit.
