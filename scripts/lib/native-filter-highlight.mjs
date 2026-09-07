// Literal native ad hoc filters only. Query execution remains owned by Grafana.
export function parseNativeHighlightFilters(value) {
  const entries = Array.isArray(value) ? value : [value];
  const filters = [];
  const seen = new Set();
  for (const entry of entries.slice(0, 32)) {
    if (typeof entry !== "string" || entry.length > 4608) continue;
    const first = entry.indexOf("|");
    const second = entry.indexOf("|", first + 1);
    if (first <= 0 || second < 0) continue;
    const key = entry.slice(0, first);
    const operator = entry.slice(first + 1, second);
    const text = entry.slice(second + 1);
    if (key.length > 256 || operator !== "=" || !text || text.length > 4096) continue;
    const identity = JSON.stringify([key, text]);
    if (seen.has(identity)) continue;
    seen.add(identity);
    filters.push({ key, text });
  }
  return filters;
}

export function installNativeFiltersHighlighter(context, host) {
  const doc = host.ownerDocument;
  const win = doc?.defaultView;
  if (!win?.CSS?.highlights || !win.Highlight || !win.MutationObserver) return () => {};
  const scope = doc.querySelector("main");
  if (!scope) return () => {};
  const panelSelector = '[data-testid="data-testid Panel header 日志明细"]';
  const registryName = "vvg-native-filter-match";
  const style = doc.createElement("style");
  style.textContent = "::highlight(vvg-native-filter-match) { background-color: #f2cc0c; color: #111217; text-decoration: underline; }";
  doc.head.appendChild(style);
  let timer;
  let stopped = false;

  const update = () => {
    timer = undefined;
    if (stopped) return;
    win.CSS.highlights.delete(registryName);
    const panel = scope.querySelector(panelSelector);
    const search = context.grafana.locationService.getSearchObject?.() || {};
    const filters = parseNativeHighlightFilters(search["var-Filters"]);
    if (!panel || !filters.length) return;
    const highlight = new win.Highlight();
    let budget = 1000000;
    let rangeCount = 0;
    const fields = [];
    for (const button of panel.querySelectorAll('button[aria-label="Filter for value"]')) {
      // Grafana's native details row: actions, field name, field value.
      // Validate the shape before using it; avoid generated CSS class names.
      const row = button.parentElement?.parentElement?.parentElement;
      if (row?.children.length !== 3) continue;
      const [actions, key, value] = row.children;
      if (!actions.contains(button) || !value.querySelector('button[aria-label="Copy value to clipboard"]')) continue;
      fields.push({ key: key.textContent, value });
    }
    for (const filter of filters) {
      const targets = fields.filter(({ key }) => key === filter.key).map(({ value }) => value);
      if (filter.key === "message" || filter.key === "_msg") {
        targets.push(...panel.querySelectorAll(".log-line-body"));
      }
      for (const target of new Set(targets)) {
        if (budget <= 0 || rangeCount >= 2000) break;
        const walker = doc.createTreeWalker(target, win.NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            return node.parentElement?.closest("button,svg,input,textarea,script,style")
              ? win.NodeFilter.FILTER_REJECT : win.NodeFilter.FILTER_ACCEPT;
          },
        });
        let node;
        let text = "";
        const spans = [];
        while ((node = walker.nextNode()) && text.length < budget) {
          const value = node.textContent.slice(0, budget - text.length);
          spans.push({ node, start: text.length, end: text.length + value.length });
          text += value;
        }
        budget -= text.length;
        let offset = 0;
        while (rangeCount < 2000 && (offset = text.indexOf(filter.text, offset)) !== -1) {
          const end = offset + filter.text.length;
          const left = spans.find((span) => span.start <= offset && span.end > offset);
          const right = spans.find((span) => span.start < end && span.end >= end);
          if (left && right) {
            const range = doc.createRange();
            range.setStart(left.node, offset - left.start);
            range.setEnd(right.node, end - right.start);
            highlight.add(range);
            rangeCount++;
          }
          offset = end;
        }
      }
    }
    if (rangeCount) win.CSS.highlights.set(registryName, highlight);
  };
  const schedule = () => {
    if (!stopped && timer === undefined) timer = win.setTimeout(update, 120);
  };
  const observer = new win.MutationObserver((mutations) => {
    if (!host.isConnected) return;
    const changed = mutations.some(({ target, addedNodes, removedNodes }) => {
      const element = target.nodeType === 1 ? target : target.parentElement;
      return element?.closest(panelSelector) || [...addedNodes, ...removedNodes].some((node) =>
        node.nodeType === 1 && (node.matches?.(panelSelector) || node.querySelector?.(panelSelector)));
    });
    if (changed) schedule();
  });
  observer.observe(scope, { childList: true, subtree: true, characterData: true });
  win.addEventListener("popstate", schedule);
  schedule();
  return () => {
    stopped = true;
    if (timer !== undefined) win.clearTimeout(timer);
    observer.disconnect();
    win.removeEventListener("popstate", schedule);
    win.CSS.highlights.delete(registryName);
    style.remove();
  };
}

export const nativeFilterHighlightScript = [
  parseNativeHighlightFilters.toString(),
  installNativeFiltersHighlighter.toString(),
].join("\n\n");
