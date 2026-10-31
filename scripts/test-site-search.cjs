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
async function run(failure = null) {
  const ids = Object.fromEntries(['doc-search', 'search', 'kind', 'search-status', 'search-results', 'document-list'].map(id => [id, new Element()]));
  ids.kind.value = 'guide'; // Same selected option as the generated no-script manual.
  const documents = JSON.parse(fs.readFileSync('build/site/manual/search-index.json', 'utf8'));
  assert.ok(documents.some(item => item.kind === 'reference'));
  assert.ok(documents.some(item => item.kind === 'audit'));
  documents.push({title: '<img src=x onerror=alert(1)>', url: 'safe.html', kind: 'guide', text: '<script>hostile needle</script>'});
  ids['document-list'].children = documents.map(item => { const row = new Element(); row.dataset.kind = item.kind; return row; });
  const source = fs.readFileSync('docs/site/manual/search.js', 'utf8');
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  vm.runInNewContext(source, { document: { getElementById: id => ids[id], createElement: () => new Element() }, fetch: async () => {
    await pending;
    if (failure === 'network') throw new Error('offline');
    return { ok: failure !== 'http', json: async () => { if (failure === 'json') throw new Error('invalid'); return documents; } };
  } });
  // Loading still permits scoped static navigation, never an empty replacement.
  ids.search.value = 'commit'; ids.search.listeners.input();
  assert.equal(ids['document-list'].hidden, false);
  assert.match(ids['search-status'].textContent, /user guides.*Loading/);
  assert.ok(ids['document-list'].children.every(row => row.hidden === (row.dataset.kind !== 'guide')));
  release(); await new Promise(resolve => setImmediate(resolve));
  if (failure) {
    assert.equal(ids['document-list'].hidden, false);
    assert.match(ids['search-status'].textContent, /Search could not load.*Browse/);
    ids.kind.value = 'audit'; ids.kind.listeners.change();
    assert.ok(ids['document-list'].children.every(row => row.hidden === (row.dataset.kind !== 'audit')));
    assert.match(ids['search-status'].textContent, /source audits/);
    ids.kind.value = 'all'; ids.kind.listeners.change();
    assert.ok(ids['document-list'].children.every(row => !row.hidden));
    return;
  }
  ids.search.value = ''; ids.search.listeners.input();
  assert.equal(ids['search-status'].textContent, `${documents.filter(item => item.kind === 'guide').length} user guides.`);
  assert.ok(ids['document-list'].children.every(row => row.hidden === (row.dataset.kind !== 'guide')));
  ids.search.value = 'staging'; ids.search.listeners.input();
  assert.equal(ids['document-list'].hidden, true);
  assert.ok(ids['search-results'].children.some(row => row.children[0].href === 'GETTING-STARTED.html'));
  for (const scope of ['reference', 'audit', 'all']) {
    ids.search.value = 'git'; ids.kind.value = scope; ids.kind.listeners.change();
    assert.ok(ids['search-results'].children.length > 0);
    for (const row of ids['search-results'].children) assert.ok(scope === 'all' || documents.find(item => item.url === row.children[0].href).kind === scope);
    ids.search.value = ''; ids.search.listeners.input();
    assert.equal(ids['document-list'].hidden, false);
    assert.ok(ids['document-list'].children.every(row => row.hidden === (scope !== 'all' && row.dataset.kind !== scope)));
  }
  ids.search.value = 'unfindable_xyz_098'; ids.search.listeners.input();
  assert.match(ids['search-status'].textContent, /No matching.*All documents/);
  // Deliberately hostile index text must use textContent, never markup insertion.
  ids.kind.value = 'guide'; ids.search.value = 'hostile'; ids.search.listeners.input();
  const hostile = ids['search-results'].children.find(row => row.children[0].href === 'safe.html');
  assert.ok(hostile);
  assert.equal(hostile.children[0].textContent, '<img src=x onerror=alert(1)>');
  assert.equal(hostile.children[1].textContent, '<script>hostile needle</script>');
  assert.equal(hostile.children[0].children.length, 0);
  assert.equal(hostile.children[1].children.length, 0);
  assert.ok(!source.includes('innerHTML'));
  ids.search.value = 'git'; ids.search.listeners.input();
  for (const row of ids['search-results'].children) {
    assert.equal(typeof row.children[0].textContent, 'string');
    assert.equal(typeof row.children[1].textContent, 'string');
  }
}
(async () => { await run(); for (const failure of ['network', 'http', 'json']) await run(failure); process.stdout.write('Curated scopes, complete search, safe rendering, loading and failure navigation checks passed.\n'); })().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
