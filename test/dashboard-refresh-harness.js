// test/dashboard-refresh-harness.js — drives dashboard/index.html's own SPA
// refresh tick (loadStamp -> conditional loadData -> applyData) against a
// scripted sequence of simulated stamp.js/data.js responses, with no real
// network or timers. Exercises exactly what agent-ops#1300's review found
// untested: whether a tick fetches data.js when (and only when) it must, and
// what happens to the tab's own comparison fingerprint when a fetch fails.
//
// dashboard-render-harness.js deliberately stays a tree-building stub only
// ("chasing [pointer/focus-driven behaviour] would grow this stub into a
// second browser") — this is a second, narrower stub for the same reason:
// growing that one to also fire click/onload/onerror events would blur what
// each one is for. This one never renders and asserts nothing about the DOM.
//
// Usage: node test/dashboard-refresh-harness.js <base-fixture.json> <scenario.json>
//
// <base-fixture.json> is a full DASHBOARD_DATA object (like the fixtures
// under test/fixtures/dashboard-data, but with plain literal timestamps —
// nothing here renders relative time, so no token resolution is needed) and
// must include the Publisher's own `fingerprint` field (issue #1288). It is
// used both as window.DASHBOARD_DATA at page load and as the base a tick's
// "dataOverrides" (below) is merged onto.
//
// <scenario.json>:
//   {
//     "initialStamp": {"generated_at": "...", "fingerprint": "..."} | null,
//     "ticks": [
//       {
//         "stamp": {"generated_at": "...", "fingerprint": "..."} | null,
//         // "null" stamp simulates the stamp.js fetch itself failing.
//         "dataOverrides": {...} | null   // OMIT this key entirely when the
//         // tick must not fetch data.js at all (the harness throws if a
//         // fetch happens anyway); include it — an object merged onto the
//         // base fixture, or null to simulate a failed data.js fetch — when
//         // it must.
//       },
//       ...
//     ]
//   }
//
// Prints one JSON line per tick to stdout:
//   {"tick": 0, "stampFetched": true, "dataFetched": false}
// test/dashboard-refresh.test.sh asserts against these lines with jq.

"use strict";
var fs = require("fs");
var path = require("path");
var vm = require("vm");

var PAGE = path.join(__dirname, "..", "dashboard", "index.html");
var basePath = process.argv[2];
var scenarioPath = process.argv[3];
if (!basePath || !scenarioPath) {
  console.error("usage: node dashboard-refresh-harness.js <base-fixture.json> <scenario.json>");
  process.exit(2);
}
var baseData = JSON.parse(fs.readFileSync(basePath, "utf8"));
var scenario = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));

// ---------- extract the page's own inline script ----------
var html = fs.readFileSync(PAGE, "utf8");
var m = /<script>([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.error("no inline <script> found in " + PAGE); process.exit(1); }
var pageScript = m[1];

// ---------- DOM stub: tree-building, plus the bits a refresh tick needs ----
function Node(tag) {
  this.tagName = tag; this.attributes = {}; this.className = "";
  this.children = []; this.parentNode = null; this.checked = false; this.style = {};
  this._listeners = {};
}
Node.prototype.setAttribute = function (n, v) { this.attributes[n] = String(v); if (n === "id") REGISTRY[v] = this; };
Node.prototype.getAttribute = function (n) { return Object.prototype.hasOwnProperty.call(this.attributes, n) ? this.attributes[n] : null; };
Node.prototype.removeAttribute = function (n) { delete this.attributes[n]; };
Node.prototype.appendChild = function (c) { this.children.push(c); c.parentNode = this; return c; };
Node.prototype.removeChild = function (c) { var i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; };
Node.prototype.replaceChild = function (nc, oc) { var i = this.children.indexOf(oc); if (i >= 0) { this.children[i] = nc; oc.parentNode = null; nc.parentNode = this; } return oc; };
// Real enough to matter here, unlike dashboard-render-harness.js's no-op:
// loadScript's <script src> injection is driven entirely by the head's own
// appendChild (overridden below), but schedule()'s "change" listener and
// tick()'s own registration on #refreshbtn's "click" need a real store so
// this driver can fire tick() the same way a human clicking the button would.
Node.prototype.addEventListener = function (type, cb) {
  (this._listeners[type] = this._listeners[type] || []).push(cb);
};
Node.prototype.removeEventListener = function () {};
Node.prototype.querySelector = function () { return null; };
Node.prototype.closest = function () { return null; };
Node.prototype.contains = function () { return false; };
Node.prototype.getBoundingClientRect = function () { return { top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0 }; };
Object.defineProperty(Node.prototype, "textContent", {
  get: function () { return this.children.map(function (c) { return c._text != null ? c._text : (c.textContent || ""); }).join(""); },
  set: function (v) { this.children = [textNode(v)]; }
});
Object.defineProperty(Node.prototype, "innerHTML", {
  get: function () { return ""; },
  set: function (v) { this.children = v ? [textNode(v)] : []; }
});
function textNode(s) { var n = new Node("#text"); n._text = String(s); return n; }

var REGISTRY = Object.create(null);
["app", "title", "nodename", "livestate", "freshness", "ghfreshness", "autorefresh", "refreshbtn"].forEach(function (id) {
  var n = new Node(id === "autorefresh" ? "input" : id === "refreshbtn" ? "button" : "div");
  n.attributes.id = id;
  REGISTRY[id] = n;
});
REGISTRY.autorefresh.checked = true;

var documentStub = {
  body: new Node("body"),
  head: new Node("head"),
  documentElement: new Node("html"),
  getElementById: function (id) { return REGISTRY[id] || null; },
  createElement: function (tag) { return new Node(tag); },
  createTextNode: function (s) { return textNode(s); },
  querySelector: function () { return null; },
  addEventListener: function () {},
  removeEventListener: function () {}
};

// ---------- the fetch interceptor ----------
// loadScript() (dashboard/index.html) injects a <script src="…?_=…"> into
// document.head and relies on the browser firing onload/onerror once it
// resolves. There is no browser here, so this stands in for the network:
// every append is answered synchronously and deterministically from the
// current tick's own scenario entry, never from a real fetch.
var currentTick = -1;
var fetchLog = [];  // {tick, file}

documentStub.head.appendChild = function (s) {
  var file = /(^|\/)stamp\.js(\?|$)/.test(s.src) ? "stamp"
    : /(^|\/)data\.js(\?|$)/.test(s.src) ? "data" : null;
  if (!file) throw new Error("unexpected script src fetched: " + s.src);
  fetchLog.push({ tick: currentTick, file: file });
  var spec = scenario.ticks[currentTick];
  if (file === "stamp") {
    if (spec.stamp === null) { s.onerror(); return; }
    windowStub.DASHBOARD_STAMP = spec.stamp;
    s.onload();
    return;
  }
  // file === "data"
  if (!Object.prototype.hasOwnProperty.call(spec, "dataOverrides")) {
    throw new Error(
      "tick " + currentTick + " fetched data.js, but the scenario named no " +
      "dataOverrides for it — either the page fetched when it should have " +
      "skipped, or the scenario is missing an expected fetch"
    );
  }
  if (spec.dataOverrides === null) { s.onerror(); return; }
  windowStub.DASHBOARD_DATA = Object.assign({}, baseData, spec.dataOverrides);
  s.onload();
};

var windowStub = {
  document: documentStub, DASHBOARD_DATA: baseData,
  DASHBOARD_STAMP: scenario.initialStamp === undefined ? null : scenario.initialStamp,
  scrollY: 0, scrollTo: function () {}, pageXOffset: 0, pageYOffset: 0, innerHeight: 900,
  setInterval: function () { return 0; }, clearInterval: function () {},
  localStorage: { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} }
};

// ---------- run the page's own script once, to page-load state ----------
var sandbox = {
  window: windowStub, document: documentStub, console: console, Date: Date, JSON: JSON, Math: Math,
  setInterval: function () { return 0; }, clearInterval: function () {},
  setTimeout: function () { return 0; }, clearTimeout: function () {}
};
vm.createContext(sandbox);
vm.runInContext(pageScript, sandbox, { filename: "dashboard/index.html (inline script)" });

// ---------- drive the scripted ticks ----------
// tick() itself is a closure-local var in the page's IIFE, unreachable from
// here directly — exactly as in a real browser, where nothing outside the
// page can call it either. The page's own code already exposes the one hook
// a user has: document.getElementById("refreshbtn").addEventListener("click",
// tick). Firing that the same way a click would is more faithful than
// reaching past the closure, and needs no export the page doesn't already
// have for its own "Refresh now" button.
var clickListeners = REGISTRY.refreshbtn._listeners.click || [];
if (clickListeners.length !== 1) {
  throw new Error("expected exactly one click listener on #refreshbtn, found " + clickListeners.length);
}
var tick = clickListeners[0];

scenario.ticks.forEach(function (_, i) {
  currentTick = i;
  var before = fetchLog.length;
  tick();
  var thisTick = fetchLog.slice(before);
  process.stdout.write(JSON.stringify({
    tick: i,
    stampFetched: thisTick.some(function (f) { return f.file === "stamp"; }),
    dataFetched: thisTick.some(function (f) { return f.file === "data"; })
  }) + "\n");
});
