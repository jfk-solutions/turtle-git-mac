'use strict';
(() => {
  const form = document.getElementById('doc-search');
  const input = document.getElementById('search');
  const kind = document.getElementById('kind');
  const status = document.getElementById('search-status');
  const results = document.getElementById('search-results');
  const list = document.getElementById('document-list');
  let catalog = null;
  let failed = false;
  function render() {
    const words = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    for (const row of list.children) row.hidden = kind.value !== 'all' && row.dataset.kind !== kind.value;
    list.hidden = words.length > 0 && catalog !== null;
    results.hidden = !list.hidden;
    results.replaceChildren();
    if (!catalog) {
      status.textContent = failed ? 'Search could not load. Browse the document links below.' : 'Loading local search index…';
      return;
    }
    const matches = catalog.filter(item => (kind.value === 'all' || item.kind === kind.value) && words.every(word => item.haystack.includes(word)));
    if (!words.length) { status.textContent = `${matches.length} documents.`; return; }
    matches.sort((a, b) => words.filter(word => b.title.toLocaleLowerCase().includes(word)).length - words.filter(word => a.title.toLocaleLowerCase().includes(word)).length || a.title.localeCompare(b.title));
    for (const item of matches) {
      const row = document.createElement('li');
      const link = document.createElement('a'); link.href = item.url; link.textContent = item.title;
      const snippet = document.createElement('p');
      const position = item.text.toLocaleLowerCase().indexOf(words[0]);
      const start = Math.max(0, position - 60);
      snippet.textContent = (start ? '…' : '') + item.text.slice(start, start + 240) + (start + 240 < item.text.length ? '…' : '');
      row.append(link, snippet); results.append(row);
    }
    status.textContent = matches.length ? `${matches.length} matching documents.` : 'No matching documents. Try fewer words.';
  }
  form.addEventListener('submit', event => { event.preventDefault(); render(); });
  input.addEventListener('input', render); kind.addEventListener('change', render);
  fetch('search-index.json').then(response => { if (!response.ok) throw new Error('index'); return response.json(); }).then(items => {
    catalog = items.map(item => ({ ...item, haystack: (item.title + '\n' + item.text).toLocaleLowerCase() })); render();
  }).catch(() => { failed = true; render(); });
})();
