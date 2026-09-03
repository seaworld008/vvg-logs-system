import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const dashboardPath = new URL(
  "../docker-compose/grafana/dashboards/vvg-log-search.json",
  import.meta.url,
);
const panelPath = new URL(
  "../docker-compose/grafana/panel-templates/vvg-message-filter-panel.json",
  import.meta.url,
);

const readJson = async (path) => JSON.parse(await readFile(path, "utf8"));
const dashboard = await readJson(dashboardPath);
const panelTemplate = await readJson(panelPath);

assert.equal(panelTemplate.type, "marcusolsson-dynamictext-panel");
assert.equal(panelTemplate.pluginVersion, "6.3.0");
assert.equal(panelTemplate.options.renderMode, "allRows");
assert.equal(panelTemplate.options.wrap, false);
assert.match(panelTemplate.options.content, /data-action="add"/);
assert.match(panelTemplate.options.content, /data-action="apply"/);
assert.match(panelTemplate.options.content, /data-action="reset"/);
assert.match(panelTemplate.options.content, /vvg-filter-rows/);
assert.match(panelTemplate.options.styles, /grid-template-columns/);
assert.match(panelTemplate.options.styles, /grid-template-columns: 72px/);
assert.match(panelTemplate.options.styles, /max-width: 720px/);
assert.match(panelTemplate.options.afterRender, /row\.append\(remove, operator, input\)/);
assert.match(panelTemplate.options.afterRender, /const nextRefreshExpression = \(expression\) =>/);
assert.match(panelTemplate.options.afterRender, /current === expression \? "\(" \+ expression \+ "\)"/);
assert.match(panelTemplate.options.afterRender, /const refreshSlidingRangeInPlace = \(\) =>/);
assert.match(panelTemplate.options.afterRender, /range\.from\.add\(delta, "milliseconds"\)/);
assert.match(panelTemplate.options.afterRender, /range\.to\.add\(delta, "milliseconds"\)/);
assert.equal(
  (panelTemplate.options.afterRender.match(/refreshSlidingRangeInPlace\(\)/g) || []).length,
  2,
);
assert.equal((panelTemplate.options.afterRender.match(/context\.grafana\.refresh\(\)/g) || []).length, 2);

const updateCode = panelTemplate.options.afterRender;
const startMarker = "// VVG_BUILDER_START";
const endMarker = "// VVG_BUILDER_END";
const start = updateCode.indexOf(startMarker);
const end = updateCode.indexOf(endMarker);
assert.ok(start >= 0 && end > start, "panel update code must expose the tested builder");

const builderSource = updateCode.slice(start + startMarker.length, end);
const buildVvgMessageFilter = vm.runInNewContext(
  `${builderSource}\nbuildVvgMessageFilter;`,
  Object.create(null),
);

assert.equal(buildVvgMessageFilter("AND", [], "*"), "*");
assert.equal(
  buildVvgMessageFilter("AND", [{ operator: "include", value: "湖南非税" }], "*"),
  '_msg:"湖南非税"',
);
assert.equal(
  buildVvgMessageFilter("AND", [{ operator: "exclude", value: "调试日志" }], "*"),
  '-_msg:"调试日志"',
);
assert.equal(
  buildVvgMessageFilter(
    "AND",
    [
      { operator: "include", value: "退款申请" },
      { operator: "exclude", value: "调试日志" },
    ],
    "*",
  ),
  '_msg:"退款申请" -_msg:"调试日志"',
);
assert.equal(
  buildVvgMessageFilter(
    "OR",
    [
      { operator: "include", value: "湖南非税" },
      { operator: "exclude", value: "调试日志" },
    ],
    "*",
  ),
  '(_msg:"湖南非税" OR -_msg:"调试日志")',
);
assert.equal(
  buildVvgMessageFilter(
    "AND",
    [{ operator: "include", value: '路径 C:\\\\logs\\\n"quoted"\0' }],
    "*",
  ),
  '_msg:"路径 C:\\\\\\\\logs\\\\ \\\"quoted\\\""',
);
assert.equal(
  buildVvgMessageFilter("AND", [{ operator: "include", value: "湖南非税" }], "level:=error"),
  '(_msg:"湖南非税") (level:=error)',
);
assert.throws(
  () => buildVvgMessageFilter("AND", Array.from({ length: 21 }, () => ({ operator: "include", value: "x" })), "*"),
  /最多支持 20 个 message 条件/,
);
assert.throws(
  () => buildVvgMessageFilter("AND", [{ operator: "include", value: "x" }], "* | stats count\(\)"),
  /高级过滤只允许 LogsQL 过滤条件/,
);

assert.equal(dashboard.version, 14);
const dashboardPanel = dashboard.panels.find(({ id }) => id === panelTemplate.id);
assert.ok(dashboardPanel, "dashboard must embed the message filter panel");
assert.deepEqual(dashboardPanel.options, panelTemplate.options);
assert.equal(dashboard.panels.some(({ id }) => id === 6), false);
assert.deepEqual(dashboard.panels.find(({ id }) => id === 1).gridPos, {
  h: 4,
  w: 5,
  x: 19,
  y: 8,
});
assert.deepEqual(dashboard.panels.find(({ id }) => id === 2).gridPos, {
  h: 4,
  w: 5,
  x: 19,
  y: 12,
});
assert.deepEqual(dashboard.panels.find(({ id }) => id === 3).gridPos, {
  h: 8,
  w: 19,
  x: 0,
  y: 8,
});

const trendPanel = dashboard.panels.find(({ id }) => id === 3);
const trendTarget = trendPanel.targets.find(({ refId }) => refId === "A");
assert.equal(trendPanel.maxDataPoints, 100);
assert.deepEqual(trendPanel.options.legend, {
  calcs: ["sum"],
  displayMode: "list",
  placement: "bottom",
  showLegend: true,
});
assert.equal(trendPanel.fieldConfig.defaults.custom.axisSoftMin, 0);
assert.equal(trendPanel.fieldConfig.defaults.custom.barWidthFactor, 0.8);
assert.equal(trendPanel.fieldConfig.defaults.custom.drawStyle, "bars");
assert.equal(trendPanel.fieldConfig.defaults.custom.fillOpacity, 80);
assert.equal(trendPanel.fieldConfig.defaults.custom.showPoints, "never");
assert.deepEqual(trendPanel.fieldConfig.defaults.custom.stacking, {
  group: "A",
  mode: "normal",
});
assert.deepEqual(trendPanel.transformations, [
  {
    id: "renameByRegex",
    options: {
      regex: '^\\{"level":"([^"]+)"\\}$',
      renamePattern: "$1",
    },
  },
]);
assert.equal(
  trendTarget.expr,
  "namespace:=$namespace container:=$service pod:=$pod level:=$level _msg:$message ${message_filter_expr:raw}",
);
assert.equal(trendTarget.queryType, "hits");
assert.equal(trendTarget.supportingQueryType, "logsVolume");
assert.deepEqual(trendTarget.fields, ["level"]);
assert.equal(trendTarget.step, "$__interval");
assert.doesNotMatch(trendTarget.expr, /\|\s*stats/);

for (const [name, defaultValue] of [
  ["message_filter_expr", "*"],
  ["message_filter_state", "eyJ2IjoxLCJsb2dpYyI6IkFORCIsImNvbmRpdGlvbnMiOltdLCJhZHZhbmNlZCI6IioifQ"],
]) {
  const variable = dashboard.templating.list.find((item) => item.name === name);
  assert.ok(variable, `dashboard variable ${name} is required`);
  assert.equal(variable.type, "textbox");
  assert.equal(variable.hide, 2);
  assert.equal(variable.query, defaultValue);
  assert.equal(variable.current.value, defaultValue);
}

for (const [name, label] of [
  ["cluster", "集群"],
  ["service", "服务"],
  ["message", "message"],
]) {
  assert.equal(dashboard.templating.list.find((item) => item.name === name).label, label);
}

const targets = dashboard.panels.flatMap((item) => item.targets ?? []);
const filteredTargets = targets.filter(({ expr }) => expr?.includes("_msg:$message"));
assert.equal(filteredTargets.length, 4);
for (const { expr } of filteredTargets) {
  assert.match(expr, /_msg:\$message \$\{message_filter_expr:raw\}/);
}

console.log("PASS: VVG message filter and Explore-style Logs volume validate");
