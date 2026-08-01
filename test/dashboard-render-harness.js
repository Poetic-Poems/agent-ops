// test/dashboard-render-harness.js — runs dashboard/index.html's own inline
// script, unmodified, against a fixture DASHBOARD_DATA and prints a
// serialised dump of the rendered DOM so test/dashboard-render.test.sh can
// grep it. Part of TD-PPagop-26072606.
//
// Usage: node test/dashboard-render-harness.js <fixture.json>
//
// The DOM stub below is deliberately the tree-building subset only
// (createElement/createTextNode/appendChild + a serialiser, per the record):
// every panel the page renders is built by walking DASHBOARD_DATA and
// appending elements — nothing here needs layout, styling or event
// dispatch. Pointer/focus-driven behaviour (the pull-request hover card,
// #96) is out of scope for the same reason: it is not tree-building, and
// chasing it would grow this stub into a second browser.

"use strict";
var fs = require("fs");
var path = require("path");
var vm = require("vm");

var PAGE = path.join(__dirname, "..", "dashboard", "index.html");
var fixturePath = process.argv[2];
if (!fixturePath) { console.error("usage: node dashboard-render-harness.js <fixture.json>"); process.exit(2); }

// ---------- fixture: checked-in JSON, with relative-time tokens ----------
// Timestamps can't be baked into a checked-in fixture (every "3m ago"
// assertion would rot by the time the test ran), so the fixture carries
// tokens instead and this resolves them against one `now` per run:
//   "@now"        -> the current instant
//   "@ago:<N><u>" -> N units (s/m/h/d) before now
var now = Date.now();
function resolveTokens(text) {
  return text
    .replace(/"@now"/g, '"' + new Date(now).toISOString() + '"')
    .replace(/"@ago:(\d+)(s|m|h|d)"/g, function (_, n, u) {
      var ms = { s: 1000, m: 60000, h: 3600000, d: 86400000 }[u] * Number(n);
      return '"' + new Date(now - ms).toISOString() + '"';
    });
}
var data = JSON.parse(resolveTokens(fs.readFileSync(fixturePath, "utf8")));

// ---------- extract the page's own inline script ----------
// The bare `<script>` tag (no `src`) is the page's logic; `<script
// src="data.js">` is the sibling the Publisher writes and is not this.
var html = fs.readFileSync(PAGE, "utf8");
var m = /<script>([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.error("no inline <script> found in " + PAGE); process.exit(1); }
var pageScript = m[1];

// ---------- DOM stub: tree-building operations only ----------
function Node(tag) {
  this.tagName = tag; this.attributes = {}; this.className = "";
  this.children = []; this.parentNode = null; this.checked = false; this.style = {};
}
Node.prototype.setAttribute = function (n, v) { this.attributes[n] = String(v); if (n === "id") REGISTRY[v] = this; };
Node.prototype.getAttribute = function (n) { return Object.prototype.hasOwnProperty.call(this.attributes, n) ? this.attributes[n] : null; };
Node.prototype.removeAttribute = function (n) { delete this.attributes[n]; };
Node.prototype.appendChild = function (c) { this.children.push(c); c.parentNode = this; return c; };
Node.prototype.removeChild = function (c) { var i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; };
Node.prototype.replaceChild = function (nc, oc) { var i = this.children.indexOf(oc); if (i >= 0) { this.children[i] = nc; oc.parentNode = null; nc.parentNode = this; } return oc; };
Node.prototype.addEventListener = function () {};
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
  get: function () { return serialize(this); },
  set: function (v) { this.children = v ? [rawNode(v)] : []; }
});
function textNode(s) { var n = new Node("#text"); n._text = String(s); return n; }
function rawNode(s) { var n = new Node("#raw"); n._text = String(s); return n; }

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
var windowStub = {
  document: documentStub, DASHBOARD_DATA: data, scrollY: 0,
  scrollTo: function () {}, pageXOffset: 0, pageYOffset: 0, innerHeight: 900,
  setInterval: function () { return 0; }, clearInterval: function () {}
};

// ---------- serialiser: enough structure for a grep-based assertion ----------
function serialize(node, indent) {
  indent = indent || "";
  if (node._text != null) return indent + node._text + "\n";
  var attrs = Object.keys(node.attributes).map(function (k) { return ' ' + k + '="' + node.attributes[k] + '"'; }).join("");
  var cls = node.className ? ' class="' + node.className + '"' : "";
  var out = indent + "<" + node.tagName + cls + attrs + ">\n";
  node.children.forEach(function (c) { out += serialize(c, indent + "  "); });
  return out;
}

// ---------- run the page's own script against the fixture ----------
var sandbox = {
  window: windowStub, document: documentStub, console: console, Date: Date, JSON: JSON, Math: Math,
  setInterval: function () { return 0; }, clearInterval: function () {},
  setTimeout: function () { return 0; }, clearTimeout: function () {}
};
vm.createContext(sandbox);
vm.runInContext(pageScript, sandbox, { filename: "dashboard/index.html (inline script)" });

process.stdout.write(serialize(REGISTRY.app));
process.stdout.write(serialize(REGISTRY.livestate));
process.stdout.write(serialize(REGISTRY.nodename));
process.stdout.write(serialize(REGISTRY.freshness));
