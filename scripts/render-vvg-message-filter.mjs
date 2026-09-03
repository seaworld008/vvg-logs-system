import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dashboardPath = resolve(root, "docker-compose/grafana/dashboards/vvg-log-search.json");
const panelPath = resolve(root, "docker-compose/grafana/panel-templates/vvg-message-filter-panel.json");
const emptyState = "eyJ2IjoxLCJsb2dpYyI6IkFORCIsImNvbmRpdGlvbnMiOltdLCJhZHZhbmNlZCI6IioifQ";

const content = `
<div class="vvg-message-filter">
  <div class="vvg-filter-top">
    <span class="vvg-filter-label">组合方式</span>
    <div class="vvg-logic" role="group" aria-label="message 条件组合方式">
      <button type="button" data-logic="AND" aria-pressed="true">全部满足（AND）</button>
      <button type="button" data-logic="OR" aria-pressed="false">任一满足（OR）</button>
    </div>
    <span class="vvg-filter-summary" aria-live="polite">0 个条件</span>
  </div>
  <div class="vvg-filter-rows" aria-label="message 过滤条件"></div>
  <details class="vvg-filter-advanced">
    <summary>高级 LogsQL（可选）</summary>
    <textarea rows="2" aria-label="高级 LogsQL 过滤表达式" spellcheck="false">*</textarea>
  </details>
  <div class="vvg-filter-actions">
    <button type="button" class="vvg-button vvg-button-secondary" data-action="add">+ 添加条件</button>
    <button type="button" class="vvg-button vvg-button-secondary" data-action="reset">重置</button>
    <button type="button" class="vvg-button vvg-button-primary" data-action="apply">应用过滤</button>
  </div>
</div>
`.trim();

const styles = `
.vvg-message-filter {
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 8px;
  height: 100%;
  min-height: 0;
  overflow: auto;
  padding: 2px 4px 4px;
  color: inherit;
  font-size: 14px;
}
.vvg-message-filter * { box-sizing: border-box; }
.vvg-filter-top {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  min-height: 32px;
}
.vvg-filter-label { font-weight: 600; }
.vvg-filter-summary { color: rgba(204, 204, 220, 0.72); font-size: 12px; }
.vvg-logic {
  display: inline-flex;
  overflow: hidden;
  border: 1px solid rgba(204, 204, 220, 0.22);
  border-radius: 4px;
}
.vvg-logic button,
.vvg-button,
.vvg-condition-row button {
  min-height: 32px;
  border: 0;
  color: inherit;
  cursor: pointer;
  font: inherit;
}
.vvg-logic button {
  padding: 0 12px;
  background: transparent;
  border-right: 1px solid rgba(204, 204, 220, 0.22);
}
.vvg-logic button:last-child { border-right: 0; }
.vvg-logic button[aria-pressed="true"] { background: rgba(50, 116, 217, 0.28); }
.vvg-filter-rows {
  display: flex;
  flex-direction: column;
  gap: 6px;
  max-height: 142px;
  min-height: 0;
  overflow-y: auto;
  padding-right: 3px;
}
.vvg-condition-row {
  display: grid;
  grid-template-columns: 72px minmax(112px, 144px) minmax(180px, 1fr);
  align-items: center;
  gap: 8px;
  width: 100%;
}
.vvg-condition-row select,
.vvg-condition-row input,
.vvg-filter-advanced textarea {
  width: 100%;
  min-width: 0;
  border: 1px solid rgba(204, 204, 220, 0.22);
  border-radius: 4px;
  background: rgba(17, 18, 23, 0.36);
  color: inherit;
  font: inherit;
  outline: none;
}
.vvg-condition-row select,
.vvg-condition-row input { height: 32px; padding: 0 9px; }
.vvg-condition-row select:focus,
.vvg-condition-row input:focus,
.vvg-filter-advanced textarea:focus { border-color: #5794f2; }
.vvg-condition-row button {
  border: 1px solid rgba(224, 47, 68, 0.48);
  border-radius: 4px;
  background: rgba(224, 47, 68, 0.14);
  color: #ff7383;
  padding: 0 10px;
}
.vvg-filter-advanced summary { cursor: pointer; font-weight: 600; line-height: 28px; }
.vvg-filter-advanced textarea { min-height: 56px; padding: 7px 9px; resize: vertical; }
.vvg-filter-actions { display: flex; align-items: center; gap: 6px; min-height: 32px; }
.vvg-button { border-radius: 4px; padding: 0 13px; }
.vvg-button-secondary {
  border: 1px solid rgba(204, 204, 220, 0.22);
  background: rgba(204, 204, 220, 0.08);
}
.vvg-button-primary { background: #3274d9; color: #fff; }
.vvg-button:hover, .vvg-logic button:hover, .vvg-condition-row button:hover { filter: brightness(1.12); }
.vvg-message-filter button:focus-visible,
.vvg-message-filter input:focus-visible,
.vvg-message-filter select:focus-visible,
.vvg-message-filter textarea:focus-visible { outline: 2px solid #5794f2; outline-offset: 1px; }
@media (max-width: 720px) {
  .vvg-condition-row { grid-template-columns: 72px minmax(0, 1fr); }
  .vvg-condition-row input { grid-column: 1 / -1; }
  .vvg-filter-actions { flex-wrap: wrap; }
}
`.trim();

const afterRender = String.raw`
// VVG_BUILDER_START
function buildVvgMessageFilter(logic, conditions, advanced = "*") {
  if (!Array.isArray(conditions)) throw new Error("message 条件格式无效");
  if (conditions.length > 20) throw new Error("最多支持 20 个 message 条件");
  if (logic !== "AND" && logic !== "OR") throw new Error("组合方式必须是 AND 或 OR");

  const filters = conditions.map((condition) => {
    if (condition.operator !== "include" && condition.operator !== "exclude") {
      throw new Error("条件方式必须是包含或不包含");
    }
    const value = String(condition.value ?? "")
      .replace(/\0/g, "")
      .replace(/\r?\n/g, " ")
      .trim();
    if (!value) throw new Error("message 条件内容不能为空");
    const escaped = value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    return (condition.operator === "exclude" ? "-" : "") + '_msg:"' + escaped + '"';
  });

  const advancedFilter = String(advanced || "*").trim() || "*";
  if (/[|\r\n\0]/.test(advancedFilter)) {
    throw new Error("高级过滤只允许 LogsQL 过滤条件，不能包含管道、换行或 NUL");
  }
  const generated =
    filters.length === 0
      ? "*"
      : logic === "OR" && filters.length > 1
        ? "(" + filters.join(" OR ") + ")"
        : filters.join(" ");

  if (advancedFilter === "*") return generated;
  if (generated === "*") return advancedFilter;
  return "(" + generated + ") (" + advancedFilter + ")";
}
// VVG_BUILDER_END

const EMPTY_STATE = "${emptyState}";
const host = context.element.matches && context.element.matches(".vvg-message-filter")
  ? context.element
  : context.element.querySelector(".vvg-message-filter");
if (!host) return;

const rowsHost = host.querySelector(".vvg-filter-rows");
const summary = host.querySelector(".vvg-filter-summary");
const advancedInput = host.querySelector(".vvg-filter-advanced textarea");
const logicButtons = Array.from(host.querySelectorAll("[data-logic]"));

const decodeState = (encoded) => {
  const normalized = String(encoded || EMPTY_STATE).replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
};
const encodeState = (value) => {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};
const cleanCondition = (condition) => ({
  operator: condition.operator === "exclude" ? "exclude" : "include",
  value: String(condition.value ?? "").replace(/\0/g, "").replace(/\r?\n/g, " ").trim(),
});
let state = { v: 1, logic: "AND", conditions: [], advanced: "*" };
try {
  const encoded = context.grafana.replaceVariables("$" + "{message_filter_state:raw}");
  const parsed = decodeState(encoded);
  if (parsed && parsed.v === 1 && Array.isArray(parsed.conditions)) {
    state = {
      v: 1,
      logic: parsed.logic === "OR" ? "OR" : "AND",
      conditions: parsed.conditions.slice(0, 20).map(cleanCondition),
      advanced: String(parsed.advanced || "*"),
    };
  }
} catch (_error) {
  state = decodeState(EMPTY_STATE);
}

const renderLogic = () => {
  logicButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.logic === state.logic));
  });
};
const renderRows = () => {
  rowsHost.replaceChildren();
  state.conditions.forEach((condition, index) => {
    const row = document.createElement("div");
    row.className = "vvg-condition-row";
    row.dataset.rowIndex = String(index);

    const operator = document.createElement("select");
    operator.setAttribute("aria-label", "第 " + (index + 1) + " 条条件方式");
    operator.dataset.field = "operator";
    [["include", "包含"], ["exclude", "不包含"]].forEach((entry) => {
      const option = document.createElement("option");
      option.value = entry[0];
      option.textContent = entry[1];
      operator.append(option);
    });
    operator.value = condition.operator;

    const input = document.createElement("input");
    input.type = "text";
    input.value = condition.value;
    input.placeholder = "输入 message 模糊匹配内容";
    input.setAttribute("aria-label", "第 " + (index + 1) + " 条 message 内容");
    input.dataset.field = "value";

    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "删除";
    remove.dataset.action = "delete";
    remove.setAttribute("aria-label", "删除第 " + (index + 1) + " 条条件");

    row.append(remove, operator, input);
    rowsHost.append(row);
  });
  summary.textContent = state.conditions.length + " 个条件";
};
const render = () => {
  renderLogic();
  renderRows();
  advancedInput.value = state.advanced || "*";
};

const nextRefreshExpression = (expression) => {
  const search = context.grafana.locationService.getSearchObject?.() || {};
  const current = search["var-message_filter_expr"];
  return current === expression ? "(" + expression + ")" : expression;
};

const refreshSlidingRangeInPlace = () => {
  const range = context.grafana.timeRange;
  const rawFrom = range?.raw?.from;
  const rawTo = range?.raw?.to;
  const slidingFrom = /^now(?:[+-]\d+(?:ms|s|m|h|d|w|M|y))?$/;
  const currentTo = /^now(?:[+-]0s)?$/;
  if (
    typeof rawFrom !== "string" ||
    typeof rawTo !== "string" ||
    !slidingFrom.test(rawFrom) ||
    !currentTo.test(rawTo) ||
    typeof range.from?.add !== "function" ||
    typeof range.to?.add !== "function"
  ) {
    return false;
  }

  const delta = Date.now() - range.to.valueOf();
  if (delta > 0) {
    range.from.add(delta, "milliseconds");
    range.to.add(delta, "milliseconds");
  }
  return true;
};

const isRelativeRange = () => {
  const raw = context.grafana.timeRange?.raw || {};
  return [raw.from, raw.to].some((value) => typeof value === "string" && value.includes("now"));
};

const handleClick = (event) => {
  const target = event.target.closest("button");
  if (!target || !host.contains(target)) return;
  if (target.dataset.logic) {
    state.logic = target.dataset.logic === "OR" ? "OR" : "AND";
    renderLogic();
    return;
  }
  if (target.dataset.action === "add") {
    if (state.conditions.length >= 20) {
      context.grafana.notifyError(["message 条件过滤器", "最多支持 20 个 message 条件"]);
      return;
    }
    state.conditions.push({ operator: "include", value: "" });
    renderRows();
    const inputs = rowsHost.querySelectorAll('input[data-field="value"]');
    if (inputs.length) inputs[inputs.length - 1].focus();
    return;
  }
  if (target.dataset.action === "delete") {
    const row = target.closest(".vvg-condition-row");
    state.conditions.splice(Number(row.dataset.rowIndex), 1);
    renderRows();
    return;
  }
  if (target.dataset.action === "reset") {
    state = { v: 1, logic: "AND", conditions: [], advanced: "*" };
    render();
    const refreshedInPlace = refreshSlidingRangeInPlace();
    context.grafana.locationService.partial(
      {
        "var-message_filter_expr": nextRefreshExpression("*"),
        "var-message_filter_state": EMPTY_STATE,
      },
      true,
    );
    if (!refreshedInPlace && isRelativeRange()) context.grafana.refresh();
    context.grafana.notifySuccess(["message 条件过滤器", "过滤条件已重置"]);
    return;
  }
  if (target.dataset.action === "apply") {
    try {
      const expression = buildVvgMessageFilter(state.logic, state.conditions, state.advanced);
      const normalized = {
        v: 1,
        logic: state.logic,
        conditions: state.conditions.map(cleanCondition),
        advanced: String(state.advanced || "*").trim() || "*",
      };
      const refreshedInPlace = refreshSlidingRangeInPlace();
      context.grafana.locationService.partial(
        {
          "var-message_filter_expr": nextRefreshExpression(expression),
          "var-message_filter_state": encodeState(normalized),
        },
        true,
      );
      if (!refreshedInPlace && isRelativeRange()) context.grafana.refresh();
      context.grafana.notifySuccess(["message 条件过滤器", "过滤条件已应用"]);
    } catch (error) {
      context.grafana.notifyError(["message 条件过滤器", error.message]);
    }
  }
};
const handleInput = (event) => {
  if (event.target === advancedInput) {
    state.advanced = event.target.value;
    return;
  }
  const row = event.target.closest(".vvg-condition-row");
  if (!row || !event.target.dataset.field) return;
  const condition = state.conditions[Number(row.dataset.rowIndex)];
  if (event.target.dataset.field === "operator") condition.operator = event.target.value;
  if (event.target.dataset.field === "value") condition.value = event.target.value;
};

host.addEventListener("click", handleClick);
host.addEventListener("input", handleInput);
host.addEventListener("change", handleInput);
render();

return () => {
  host.removeEventListener("click", handleClick);
  host.removeEventListener("input", handleInput);
  host.removeEventListener("change", handleInput);
};
`.trim();

const panel = {
  datasource: { type: "datasource", uid: "grafana" },
  fieldConfig: { defaults: {}, overrides: [] },
  gridPos: { h: 7, w: 24, x: 0, y: 0 },
  id: 8,
  options: {
    afterRender,
    content,
    contentPartials: [],
    defaultContent: content,
    editor: { format: "auto", height: 240, language: "html" },
    editors: ["afterRender", "styles"],
    externalScripts: [],
    externalStyles: [],
    helpers: "",
    renderMode: "allRows",
    styles,
    wrap: false,
  },
  pluginVersion: "6.3.0",
  targets: [{ datasource: { type: "datasource", uid: "grafana" }, refId: "A" }],
  title: "message 多条件过滤",
  type: "marcusolsson-dynamictext-panel",
};

const dashboard = JSON.parse(await readFile(dashboardPath, "utf8"));
dashboard.panels = dashboard.panels.filter(({ id }) => id !== panel.id && id !== 6);
dashboard.panels.unshift(panel);

const compactLayout = new Map([
  [8, { h: 7, w: 24, x: 0, y: 0 }],
  [5, { h: 1, w: 24, x: 0, y: 7 }],
  [1, { h: 4, w: 5, x: 19, y: 8 }],
  [2, { h: 4, w: 5, x: 19, y: 12 }],
  [3, { h: 8, w: 19, x: 0, y: 8 }],
  [7, { h: 1, w: 24, x: 0, y: 16 }],
  [4, { h: 20, w: 24, x: 0, y: 17 }],
]);
dashboard.panels = dashboard.panels.map((item) => ({
  ...item,
  gridPos: compactLayout.get(item.id) ?? item.gridPos,
  title: item.id === 5 ? "日志概览与趋势" : item.title,
}));

const variable = (name, value) => ({
  current: { selected: false, text: value, value },
  hide: 2,
  label: "",
  name,
  options: [],
  query: value,
  skipUrlSync: false,
  type: "textbox",
});
dashboard.templating.list = dashboard.templating.list.filter(
  ({ name }) => name !== "message_filter_expr" && name !== "message_filter_state",
);
dashboard.templating.list.push(variable("message_filter_expr", "*"));
dashboard.templating.list.push(variable("message_filter_state", emptyState));
const compactVariableLabels = new Map([
  ["cluster", "集群"],
  ["service", "服务"],
  ["message", "message"],
]);
dashboard.templating.list = dashboard.templating.list.map((item) => ({
  ...item,
  label: compactVariableLabels.get(item.name) ?? item.label,
}));

const trendPanel = dashboard.panels.find(({ id }) => id === 3);
if (!trendPanel) throw new Error("VVG log volume panel is missing");
trendPanel.maxDataPoints = 100;
trendPanel.options = {
  ...trendPanel.options,
  legend: {
    calcs: ["sum"],
    displayMode: "list",
    placement: "bottom",
    showLegend: true,
  },
};
trendPanel.fieldConfig.defaults.custom = {
  ...trendPanel.fieldConfig.defaults.custom,
  axisSoftMin: 0,
  barWidthFactor: 0.6,
  drawStyle: "bars",
  fillOpacity: 80,
  showPoints: "never",
  stacking: { group: "A", mode: "normal" },
};
trendPanel.transformations = [
  {
    id: "renameByRegex",
    options: {
      regex: '^\\{"level":"([^"]+)"\\}$',
      renamePattern: "$1",
    },
  },
];

const trendTarget = trendPanel.targets?.find(({ refId }) => refId === "A");
if (!trendTarget) throw new Error("VVG log volume query is missing");
Object.assign(trendTarget, {
  expr: "namespace:=$namespace container:=$service pod:=$pod level:=$level _msg:$message ${message_filter_expr:raw}",
  fields: ["level"],
  legendFormat: "{{level}}",
  queryType: "hits",
  step: "$__interval",
  supportingQueryType: "logsVolume",
});

for (const item of dashboard.panels) {
  for (const target of item.targets ?? []) {
    if (!target.expr?.includes("_msg:$message")) continue;
    target.expr = target.expr
      .replace(/ _msg:\$message(?: \$\{message_filter_expr:raw\})?/g, " _msg:$message")
      .replace(" _msg:$message", " _msg:$message ${message_filter_expr:raw}");
  }
}
dashboard.version = 15;

await mkdir(dirname(panelPath), { recursive: true });
await writeFile(panelPath, `${JSON.stringify(panel, null, 2)}\n`, "utf8");
await writeFile(dashboardPath, `${JSON.stringify(dashboard, null, 2)}\n`, "utf8");
console.log("Rendered Business Text message filter and VVG log search dashboard version 15");
