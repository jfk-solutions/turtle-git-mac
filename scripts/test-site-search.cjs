// Exercise the real search script with a minimal DOM and static fetch responses.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
class Element {
  constructor() { this.children = []; this.listeners = {}; this.value = ''; this.hidden = false; this.dataset = {}; }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  replaceChildren() { this.children = []; }
  append(...children) { this.children.push(...children); }
}
async function run(fail = false) {
  const ids = Object.fromEntries(['doc-search', 'search', 'kind', 'search-status', 'search-results', 'document-list'].map(id => [id, new Element()]));
  ids.kind.value = 'all';
  ids['document-list'].children = ['guide', 'audit'].map(kind => { const row = new Element(); row.dataset.kind = kind; return row; });
  const source = fs.readFileSync('docs/site/manual/search.js', 'utf8');
  const documents = JSON.parse(fs.readFileSync('build/site/manual/search-index.json', 'utf8'));
  vm.runInNewContext(source, { document: { getElementById: id => ids[id], createElement: () => new Element() }, fetch: async () => ({ ok: !fail, json: async () => documents }) });
  await new Promise(resolve => setImmediate(resolve));
  if (fail) {
    ids.search.value = 'commit'; ids.search.listeners.input();
    assert.equal(ids['document-list'].hidden, false);
    assert.match(ids['search-status'].textContent, /Browse/);
    return;
  }
  assert.equal(ids['search-status'].textContent, `${documents.length} documents.`);
  ids.search.value = 'staging'; ids.search.listeners.input();
  assert.equal(ids['document-list'].hidden, true);
  assert.ok(ids['search-results'].children.some(row => row.children[0].href === 'GETTING-STARTED.html'));
  ids.kind.value = 'guide'; ids.kind.listeners.change();
  for (const row of ids['search-results'].children) assert.equal(documents.find(item => item.url === row.children[0].href).kind, 'guide');
  ids.search.value = 'unfindable_xyz_098'; ids.search.listeners.input();
  assert.match(ids['search-status'].textContent, /No matching/);
  ids.search.value = ''; ids.search.listeners.input();
  assert.equal(ids['document-list'].hidden, false);
  assert.equal(ids['document-list'].children[1].hidden, true);
  ids.search.value = '<script>'; ids.search.listeners.input();
  for (const row of ids['search-results'].children) assert.equal(typeof row.children[1].textContent, 'string');
}
(async () => { await run(); await run(true); process.stdout.write('Search, filtering, no-match and load-failure checks passed.\n'); })().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
