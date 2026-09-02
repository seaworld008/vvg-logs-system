# VVG Kibana-Style Message Filter Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 使用签名 Business Text 插件，为生产和测试日志大屏增加动态 message 条件行、包含/不包含、全局 AND/OR、Apply/Reset 和 URL 状态恢复。

**Architecture:** 固定 Business Text 6.3.0，并通过只读、版本化的宿主机插件包与 Grafana 镜像解耦。面板 After Render Code 渲染紧凑行式 UI，只生成经过转义的 LogsQL，并通过两个隐藏 Dashboard 变量把表达式和表单状态同步到 URL；四个 VictoriaLogs 查询继续共享同一过滤表达式。

**Tech Stack:** Grafana 13.2.0、Business Text 6.3.0、VictoriaLogs datasource 0.31.0、Business Text After Render Code、Classic Dashboard JSON、Docker、Chrome CDP。

---

### Task 1: Pin and validate the signed plugin

**Files:**
- Create: `scripts/install-grafana-plugins.sh`
- Modify: `docker-compose/grafana/docker-compose.yml`
- Modify: `docker-compose/grafana/env.example`
- Modify: `docker-compose/grafana/README.md`
- Modify: `scripts/validate-configs.sh`

**Step 1: Add failing checks**

Require `BUSINESS_TEXT_PLUGIN_VERSION=6.3.0`, a versioned `GRAFANA_PLUGINS_DIR`, read-only Compose mount, atomic installer and runtime validation for both fixed plugin versions.

**Step 2: Prove static validation fails**

```bash
bash scripts/validate-configs.sh --static
```

**Step 3: Add the external plugin bundle installer**

Install both plugins into a staged host release directory, generate SHA-256, remove write permissions and atomically publish it. Mount it read-only at `/var/lib/grafana-plugins`; do not add runtime plugin installation.

**Step 4: Verify static checks pass**

Run static validation and `git diff --check`.

### Task 2: Build the filter builder Dashboard

**Files:**
- Modify: `docker-compose/grafana/dashboards/vvg-log-search.json`
- Create: `docker-compose/grafana/panel-templates/vvg-message-filter-panel.json`
- Create: `scripts/validate-vvg-message-filter.mjs`
- Modify: `scripts/validate-configs.sh`

**Step 1: Add hidden state variables**

Add hidden Text box variables `message_filter_expr` with default `*` and `message_filter_state` with an empty URL-safe state.

**Step 2: Add the Business Text panel**

Create a compact full-width panel before the overview row. Configure static logic/advanced/add controls and dynamic operator/value/delete elements. Use built-in Submit as Apply and Reset as Reset.

**Step 3: Implement safe Custom Code**

Initial Code restores state from URL. Add/Delete buttons update elements locally. Apply Code:

1. validates 1-20 non-empty rows;
2. removes NUL/newlines and escapes backslashes/quotes;
3. maps include to `_msg:"value"` and exclude to `-_msg:"value"`;
4. joins with whitespace for AND or ` OR ` inside parentheses for OR;
5. combines the optional advanced filter;
6. updates state/expression variables with `locationService.partial()` and refreshes once.

Reset clears dynamic rows and restores both variables.

**Step 4: Apply the hidden expression to four queries**

Append `${message_filter_expr:raw}` after `_msg:$message` and before stats/sort pipes. Increment Dashboard version.

**Step 5: Add automated validation**

The Node validator loads the panel fragment and Dashboard, tests the pure expression builder with empty, include, exclude, AND, OR, quotes, slashes, newlines and 21-row rejection, and checks that the committed Dashboard embeds the same panel options.

### Task 3: Update guides and rollback procedures

**Files:**
- Modify: `docker-compose/grafana/README.md`
- Modify: `docs/grafana-victorialogs-log-search-dashboard-guide.md`
- Modify: `docs/grafana-victorialogs-query-performance-runbook.md`

Document the UI, Apply/Reset behavior, URL sharing, advanced expression, 20-row limit, plugin build/install, test-derived Dashboard boundary and image+JSON rollback.

### Task 4: Build and verify the candidate image in test

**Step 1: Back up test Grafana**

Back up Compose, `.env`, datasource, Dashboard, active plugin release, plugin inventory and SQLite database with SHA-256.

**Step 2: Build an isolated plugin bundle**

Generate an exactly versioned release directory with both plugins. Verify Grafana version, plugin list/signature, release SHA-256 and image digest before changing the service.

**Step 3: Run an isolated test container**

Use a copied data directory, read-only candidate plugin mount and loopback-only port. Verify migrations, panel plugin registration, datasource registration and no fatal/signature errors.

**Step 4: Recreate only test Grafana**

Apply the environment-derived Dashboard (`测试 ACK`, `jwxt-saastest`) and new plugin release path, then reapply the legacy-host Docker runtime limits.

### Task 5: Browser-test the filter builder in test

Use Chrome to verify:

- default zero conditions and no extra query;
- add/delete condition rows without queries;
- Apply triggers one four-query refresh;
- Reset restores `*`;
- 2, 5, 10 and 20 rows;
- include/exclude and AND/OR counts;
- Chinese, quotes, slash and newline escaping;
- URL copy/reload restores form state;
- valid/invalid advanced filter;
- no overlap at desktop viewport;
- query status/timing, highlight, memory, OOM/restarts and slow-query counters.

### Task 6: Publish the same image and Dashboard to production

Back up production image/config/Dashboard/database, transfer the tested plugin bundle without runtime download, validate SHA-256, run an isolated copy, then recreate only production Grafana. Apply the production-derived Dashboard and repeat the browser/service matrix. Leave the final page with zero conditions.

### Task 7: Deliver through GitHub

Run static and Node validation, full runtime CI, secret scans and `git diff --check`. Commit implementation, push `codex/vvg-multi-message-filters`, create a focused PR, wait for CI, merge to `main`, synchronize local `main` and rerun verification on the merge commit.
