const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '../static/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function page() {
  const nodes = new Map();
  const element = key => {
    if (!nodes.has(key)) nodes.set(key, {
      innerHTML: '', style: {setProperty() {}}, addEventListener() {},
      classList: {toggle() {}, remove() {}, add() {}, contains() { return false; }},
      setAttribute() {}, querySelectorAll: () => [], querySelector: () => null,
    });
    return nodes.get(key);
  };
  const ctx = vm.createContext({
    document: {querySelector: element, querySelectorAll: () => [], addEventListener() {}, body: element('body')},
    window: {addEventListener() {}}, location: {search: ''}, URLSearchParams,
    ResizeObserver: class { observe() {} }, clearTimeout, requestAnimationFrame() {},
    fetch: () => new Promise(() => {}), // No daemon or startup polling in unit tests.
  });
  const run = s => vm.runInContext(s, ctx);
  run(script);
  run("LOCALE = 'en'");
  return {ctx, run, element};
}

test('observed usage, hidden agent, and old daemon without usage fields', async () => {
  const {ctx, run, element} = page();
  const day = new Date().toISOString().slice(0, 10);
  const hour = Math.floor(Date.now() / 3600000) * 3600;
  const data = {days: [day], hourly: [{ts: hour, ag: 42}], antigravity_daily: {[day]: 42},
    claude_daily: {}, codex_daily: {}, cost_daily: {}};
  ctx.fetch = async () => ({json: async () => data});
  const render = () => run('Promise.all([loadUsage(), loadCurve(), loadToday()])');
  await render();
  assert.match(element('#usagelegend').innerHTML, /Antigravity/);
  assert.match(element('#usagesvg').innerHTML, /fill="url\(#ug-antigravity\)"/);
  assert.match(element('#curvelegend').innerHTML, /Antigravity[^<]*<b[^>]*>42/);
  assert.match(element('#today').innerHTML, />42<\/b>/);
  run('settings = {show_antigravity: false}');
  await render();
  assert.doesNotMatch(element('#usagelegend').innerHTML, /Antigravity/);
  assert.equal(element('#today').innerHTML, '');
  run('settings = {}');
  delete data.antigravity_daily;
  delete data.hourly[0].ag;
  await render();
  assert.doesNotMatch(element('#curvelegend').innerHTML, /Antigravity/);
  assert.doesNotMatch(element('#usagelegend').innerHTML, /Antigravity/);
});

test('cost scope follows visibility, independently of Antigravity observations', async () => {
  const {ctx, run, element} = page();
  const day = '2026-01-02';
  const data = {days:[day], hourly:[], claude_daily:{}, codex_daily:{[day]:20},
    cost_7d:0, cost_30d:0, cost_daily:{[day]:0}, antigravity_daily:{}};
  ctx.fetch = async () => ({json: async () => data});
  const render = () => run('Promise.all([loadUsage(), loadToday()])');
  for (const sample of [undefined, {}, {[day]:3}]) {
    data.antigravity_daily = sample;
    await render();
    for (const id of ['#cost', '#today']) {
      assert.match(element(id).innerHTML, /Claude \/ Codex subtotal/);
      assert.match(element(id).innerHTML, /\$0/);
    }
  }
  run('settings = {show_claude:false}');
  data.codex_cost_7d = data.codex_cost_30d = 7;
  data.costs_by_agent_daily = {codex:{[day]:5}};
  await render();
  assert.match(element('#cost').innerHTML, /Codex subtotal.*\$7/);
  assert.match(element('#today').innerHTML, /Codex subtotal.*\$5/);
  delete data.costs_by_agent_daily;
  await render();
  assert.match(element('#today').innerHTML, /Cost unknown/);
  run('settings.show_codex = false');
  await render();
  for (const id of ['#cost', '#today']) {
    assert.match(element(id).innerHTML, /Cost unknown/);
    assert.doesNotMatch(element(id).innerHTML, /\$0/);
  }
  run('settings = {show_antigravity:false}');
  await render();
  for (const id of ['#cost', '#today']) assert.doesNotMatch(element(id).innerHTML, /subtotal|Cost unknown/);
});

test('quota shows actual remaining amounts, including zero, without a percentage', () => {
  const {run} = page();
  const card = run("quotaCardInner('Antigravity', {ok:true, remaining_amounts:[{label:'Credits', remaining:0}]})");
  assert.match(card, /Credits/);
  assert.match(card, /Remaining 0/);
  assert.doesNotMatch(card, /0%/);
  assert.match(card, /\/brand\/antigravity-tray@2x\.png/);
});

test('both quota response formats respect visibility and do not invent quota pages', () => {
  const {ctx, run, element} = page();
  const account = {ok:true, windows:[{id:'model', label:'Model quota', used_percent:17}]};
  for (const data of [{antigravity:account}, {agents:[{id:'antigravity', accounts:[account]}]}]) {
    ctx.payload = data;
    run("settings = {}; renderQuotaFlat($('#qc-flat'), payload)");
    assert.match(element('#qc-flat').innerHTML, /Antigravity/);
    assert.match(element('#qc-flat').innerHTML, /17%/);
    run("settings.show_antigravity = false; renderQuotaFlat($('#qc-flat'), payload)");
    assert.doesNotMatch(element('#qc-flat').innerHTML, /17%|Antigravity/);
  }
  run("settings = {}; renderQuotaFlat($('#qc-flat'), {})");
  assert.doesNotMatch(element('#qc-flat').innerHTML, /Antigravity/);
});

test('server-side filtered search and source-specific session actions', async () => {
  const {ctx, run, element} = page();
  assert.match(html, /data-f="antigravity"/);
  const session = {id:'session', tool:'antigravity', source:'antigravity_app', account_id:'app',
    title:'Review', project:'Project', mtime:0};
  let url;
  ctx.fetch = async u => { url = u; return {json: async () => ({sessions:[session]})}; };
  await run("filter = 'antigravity'; query = 'review'; loadSessions()");
  assert.equal(url, '/api/sessions?q=review&tool=antigravity');
  assert.match(element('#slist').innerHTML, /Review/);
  assert.doesNotMatch(element('#slist').innerHTML, /data-act="(?:resume|copy)"/);
  Object.assign(session, {source:'antigravity_cli', account_id:'cli'});
  await run('loadSessions()');
  assert.match(element('#slist').innerHTML, /data-act="resume"/);
  assert.match(element('#slist').innerHTML, /data-act="copy"/);
  run('settings = {}; renderAgentSettings()');
  for (const key of ['show_antigravity', 'menubar_antigravity', 'color_antigravity'])
    assert.ok(element('#setbody').innerHTML.includes(key));
});
