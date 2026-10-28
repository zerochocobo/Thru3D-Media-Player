'use strict';
// No third-party scripts, metadata requests, favicons, or external fonts.
const BookmarkTools = (() => {
  const sensitive = new Set(['code','state','token','access_token','id_token','refresh_token','password','passwd','session','sessionid','authorization','credential','ticket','nonce','auth']);
  function normalize(raw) {
    const text = String(raw || '').trim();
    if (!text || text.length > 4096 || /[\x00-\x20\x7f]/.test(text)) return null;
    try {
      const url = new URL(text.includes('://') ? text : `https://${text}`);
      if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) return null;
      for (const key of url.searchParams.keys()) if (sensitive.has(key.toLowerCase())) return null;
      url.hash = '';
      return url.href.length <= 4096 ? url.href : null;
    } catch (_) { return null; }
  }
  function prepare(items, existing) {
    const known = new Set(existing.map(item => normalize(item.url)));
    const additions = []; let duplicate = 0, invalid = 0;
    for (const item of items) {
      const url = normalize(item.url);
      if (!url) { invalid++; continue; }
      if (known.has(url)) { duplicate++; continue; }
      known.add(url); additions.push({url, title: String(item.title || new URL(url).hostname).trim().slice(0, 512)});
    }
    return {additions, duplicate, invalid};
  }
  function lines(text) { return text.split(/\r?\n/).map(url => url.trim()).filter(Boolean).map(url => ({url})); }
  function escape(text) { return String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  function html(items) {
    return '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<meta charset="utf-8">\n<title>Thru3D Bookmarks</title>\n<h1>Thru3D Bookmarks</h1>\n<dl><p>\n' +
      items.filter(item => normalize(item.url)).map(item => `<dt><a href="${escape(item.url)}">${escape(item.title || item.url)}</a>`).join('\n') + '\n</dl><p>\n';
  }
  function feedback(items, labels) {
    const clean = value => String(value || '').replace(/[\r\n\t]+/g, ' ').trim();
    return labels.heading + '\n' + labels.issue + ': \n\n' + items.filter(item => normalize(item.url)).map((item, index) => {
      const at = Number(item.at), date = new Date(at);
      return `${index + 1}. ${clean(item.title) || item.url}\n${item.url}` +
        (at > 0 && Number.isFinite(date.getTime()) ? `\n${labels.visited}: ${date.toISOString()}` : '');
    }).join('\n\n');
  }
  return {normalize, prepare, lines, html, feedback};
})();
if (typeof module !== 'undefined') module.exports = BookmarkTools;

if (typeof document !== 'undefined') (async () => {
  const $ = id => document.getElementById(id);
  const storage = {get(key) { try { return sessionStorage.getItem(key); } catch (_) { return null; } }, set(key, value) { try { sessionStorage.setItem(key, value); } catch (_) {} }};
  const resolve = value => /^ja/i.test(value) ? 'ja' : /^zh/i.test(value) ? (/hant|tw|hk|mo/i.test(value) ? 'zh_Hant' : 'zh') : 'en';
  let language = storage.get('bookmark-language') || resolve(navigator.language);
  let catalog = {}, token = storage.get('bookmark-token') || '', bookmarks = [], history = [], revision = '', historyRevision = '', mode = 'bookmarks', selection = new Set();
  let previous = '', editRevision = '', importRevision = '', deleteRevision = '', deleteMode = 'bookmarks', clearingHistory = false, importItems = [], deleting = [], busy = false, refreshing = false, epoch = 0, toastTimer;
  const t = key => catalog[language]?.[key] || key;
  const format = (key, ...args) => { let n = 0; return t(key).replace(/%d/g, () => args[n++]); };
  const errorKeys = {invalid_address:'Invalid address', bookmark_exists:'Bookmark already exists', bookmark_missing:'Bookmark no longer exists', bookmark_limit:'Bookmark limit reached', conflict:'Bookmarks changed. Refresh and try again.', history_conflict:'History changed. Review and try again.', storage_failed:'Unable to save changes', expired:'Sharing has ended. Reopen it in your headset.', unauthorized:'Enter the code shown in your headset', rate:'Too many attempts. Wait one minute.', offline:'Connection lost. Check Wi-Fi or reopen sharing.', file:'Choose an HTML, JSON or text bookmark file', empty:'No new bookmarks', large:'Up to 1,000 bookmarks at a time'};
  function message(error) { return t(errorKeys[error.message] || 'Unable to save changes'); }
  function setMessage(id, key) { $(id).dataset.t = key; $(id).textContent = t(key); }
  function toast(text) { clearTimeout(toastTimer); $('toast').textContent = text; $('toast').hidden = false; toastTimer = setTimeout(() => $('toast').hidden = true, 6000); }
  function localize() {
    document.documentElement.lang = language === 'zh_Hant' ? 'zh-Hant' : language === 'zh' ? 'zh-Hans' : language;
    document.title = `Thru3D · ${t('Browser library')}`; $('language').value = language;
    document.querySelectorAll('[data-t]').forEach(el => el.textContent = t(el.dataset.t));
    document.querySelectorAll('[data-placeholder]').forEach(el => { el.placeholder = t(el.dataset.placeholder); el.setAttribute('aria-label', el.placeholder); });
    document.querySelectorAll('.icon.close').forEach(el => el.setAttribute('aria-label', t('Close')));
    document.querySelector('.tabs').setAttribute('aria-label', t('Browser library'));
    $('edit-title').textContent = t(previous ? 'Edit bookmark' : 'Add bookmark');
    render(); renderPreview();
  }
  async function request(path, data, authenticated = true) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 9000);
    try {
      const response = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json', ...(authenticated ? {Authorization:`Bearer ${token}`} : {})}, body:JSON.stringify(data), signal:controller.signal, cache:'no-store'});
      if (response.status === 401) { if (authenticated) unpair(); throw Error('unauthorized'); }
      if (response.status === 429) throw Error('rate');
      if (response.status === 410) { unpair(); throw Error('expired'); }
      const result = await response.json();
      if (!response.ok || result.error) throw Error(result.error || 'storage_failed');
      return result;
    } catch (error) {
      if (error instanceof TypeError || error.name === 'AbortError') throw Error('offline');
      throw error;
    } finally { clearTimeout(timer); }
  }
  function accept(result) {
    if (!Array.isArray(result.bookmarks) || !Array.isArray(result.history) || typeof result.revision !== 'string' || typeof result.history_revision !== 'string') throw Error('storage_failed');
    bookmarks = result.bookmarks; history = result.history; revision = result.revision; historyRevision = result.history_revision;
    selection = new Set([...selection].filter(url => entries().some(item => item.url === url)));
    render();
  }
  function unpair() {
    token = ''; storage.set('bookmark-token', ''); bookmarks = []; history = []; selection.clear(); revision = ''; historyRevision = ''; $('copy-text').value = '';
    $('workspace').hidden = true; $('pair').hidden = false;
    document.querySelectorAll('dialog[open]').forEach(el => el.close()); $('code').value = ''; $('pair-form').hidden = true; render();
  }
  async function refresh(report = false) {
    if (!token || busy || refreshing) return;
    refreshing = true;
    const started = epoch;
    try {
      const result = await request('/api', {action:'list'});
      if (!token || started !== epoch) return;
      if (result.revision !== revision || result.history_revision !== historyRevision) accept(result);
      $('workspace').hidden = false; $('pair').hidden = true; setMessage('connection', 'Connected to your headset');
      if (report) toast(t('Up to date'));
    } catch (error) { setMessage('connection', errorKeys[error.message] || 'Unable to save changes'); if (!token) { $('retry').hidden = false; setMessage('pair-message', errorKeys[error.message] || 'Unable to save changes'); } if (report) toast(message(error)); }
    finally { refreshing = false; }
  }
  async function connect() {
    $('retry').hidden = true; setMessage('pair-title', 'Your next stop, in VR.'); setMessage('pair-message', 'Connecting…');
    try {
      const result = await request('/pair', {}, false);
      token = result.token; storage.set('bookmark-token', token); await refresh();
    } catch (error) {
      setMessage('pair-message', errorKeys[error.message] || 'Unable to save changes');
      $('pair-form').hidden = error.message !== 'unauthorized';
      $('retry').hidden = error.message === 'unauthorized';
      if (!$('pair-form').hidden) $('code').focus();
    }
  }
  function entries() { return mode === 'history' ? history : bookmarks; }
  function visible() { const query = $('search').value.trim().toLocaleLowerCase(); return entries().filter(item => `${item.title} ${item.url}`.toLocaleLowerCase().includes(query)); }
  function selectedEntries() { return entries().filter(item => selection.has(item.url)); }
  function switchMode(value) {
    if (busy) return;
    mode = value; selection.clear(); $('search').value = ''; render();
  }
  function visitTime(item) {
    const at = Number(item.at), date = new Date(at);
    if (!(at > 0) || !Number.isFinite(date.getTime())) return '';
    return new Intl.DateTimeFormat(language === 'zh_Hant' ? 'zh-TW' : language, {dateStyle:'medium',timeStyle:'short'}).format(date);
  }
  function render() {
    const visits = mode === 'history', list = entries();
    $('workspace').classList.toggle('history-mode', visits);
    $('tab-bookmarks').setAttribute('aria-pressed', String(!visits)); $('tab-history').setAttribute('aria-pressed', String(visits));
    $('bookmark-tools').hidden = visits; $('history-tools').hidden = !visits; $('clear-history').disabled = !history.length;
    setMessage('list-title', visits ? 'Browsing history' : 'Bookmarks');
    $('search').dataset.placeholder = visits ? 'Search browsing history' : 'Search bookmarks';
    $('search').placeholder = t($('search').dataset.placeholder); $('search').setAttribute('aria-label', $('search').placeholder);
    $('count').textContent = list.length;
    const items = visible(); $('cards').replaceChildren();
    for (const item of items) {
      const card = document.createElement('article'); card.className = 'card' + (selection.has(item.url) ? ' selected' : '');
      const check = document.createElement('input'); check.type = 'checkbox'; check.checked = selection.has(item.url); check.setAttribute('aria-label', `${t('Select')}: ${item.title || item.url}`);
      check.addEventListener('change', () => { check.checked ? selection.add(item.url) : selection.delete(item.url); card.classList.toggle('selected', check.checked); renderSelection(); });
      const icon = document.createElement('span'); icon.className = 'monogram'; icon.setAttribute('aria-hidden','true'); icon.textContent = (new URL(item.url).hostname.replace(/^www\./,'')[0] || '✦').toUpperCase();
      const text = document.createElement('div'); text.className = 'card-text';
      const title = document.createElement('strong'); title.textContent = item.title || item.url; title.title = title.textContent;
      const url = document.createElement('small'); url.textContent = item.url; url.title = item.url;
      text.append(title,url); card.append(check,icon,text);
      if (visits) {
        const time = document.createElement('small'); time.className = 'visit-time'; time.textContent = visitTime(item); text.append(time);
        const actions = document.createElement('div'); actions.className = 'card-actions';
        const copy = document.createElement('button'); copy.className = 'copy-link'; copy.textContent = t('Copy link'); copy.addEventListener('click', () => copyText(item.url));
        const feedback = document.createElement('button'); feedback.className = 'feedback'; feedback.textContent = t('Prepare feedback'); feedback.addEventListener('click', () => prepareFeedback([item]));
        actions.append(copy,feedback); card.append(actions);
      } else {
        const edit = document.createElement('button'); edit.textContent = '✎'; edit.className = 'edit'; edit.title = t('Edit bookmark'); edit.setAttribute('aria-label', `${t('Edit')}: ${item.title || item.url}`); edit.addEventListener('click', () => openEditor(item)); card.append(edit);
      }
      $('cards').append(card);
    }
    $('empty').hidden = visits || bookmarks.length !== 0; $('no-results').hidden = !!items.length || (!visits && !bookmarks.length);
    $('export').disabled = !bookmarks.length; renderSelection();
  }
  function renderSelection() {
    const items = visible(), selected = items.filter(item => selection.has(item.url)).length;
    $('all').checked = items.length > 0 && selected === items.length; $('all').indeterminate = selected > 0 && selected < items.length; $('all').disabled = !items.length;
    $('selected').textContent = selection.size ? format('%d selected', selection.size) : ''; $('delete-selected').hidden = !selection.size;
    $('copy-selected').hidden = !selection.size || mode !== 'history'; $('feedback-selected').hidden = !selection.size || mode !== 'history';
  }
  function open(dialog) { dialog.querySelector('.dialog-error').textContent = ''; dialog.showModal(); }
  function openEditor(item = {}) { previous = item.url || ''; editRevision = revision; $('url').value = previous; $('name').value = item.title || ''; $('edit-title').textContent = t(previous ? 'Edit bookmark' : 'Add bookmark'); open($('editor')); }
  async function mutate(data, dialog) {
    if (busy) return false;
    busy = true; epoch++; dialog.querySelectorAll('button').forEach(el => el.disabled = true);
    try {
      accept(await request('/api', data)); dialog.close(); toast(t('Saved to your headset')); return true;
    } catch (error) {
      dialog.querySelector('.dialog-error').textContent = message(error);
      if (error.message === 'conflict' || error.message === 'history_conflict') {
        // Keep drafts. Fetch the current revision; require an explicit second save after review.
        try { accept(await request('/api', {action:'list'})); editRevision = revision; importRevision = revision; deleteRevision = deleteMode === 'history' ? historyRevision : revision; renderPreview(); } catch (_) {}
      }
      return false;
    } finally { busy = false; dialog.querySelectorAll('button').forEach(el => el.disabled = false); renderPreview(); }
  }
  function renderPreview() {
    const preview = BookmarkTools.prepare(importItems, bookmarks);
    $('import-summary').textContent = importItems.length ? format('%d new · %d duplicates · %d invalid', preview.additions.length, preview.duplicate, preview.invalid) : t('HTML, JSON or text · Up to 1,000 bookmarks');
    $('preview-list').replaceChildren();
    preview.additions.slice(0, 50).forEach(item => { const row = document.createElement('li'); row.textContent = item.title + ' · ' + item.url; $('preview-list').append(row); });
    $('import-save').disabled = busy || !preview.additions.length || preview.additions.length + bookmarks.length > 1000;
    if (preview.additions.length + bookmarks.length > 1000) $('importer').querySelector('.dialog-error').textContent = t('Bookmark limit reached');
    return preview.additions;
  }
  function openImport() { importRevision = revision; importItems = []; $('links').value = ''; renderPreview(); open($('importer')); }
  function prepareFeedback(items) {
    setMessage('copy-title', 'Prepare feedback'); setMessage('copy-hint', 'Add a short description before copying');
    $('copy-text').value = BookmarkTools.feedback(items, {heading:t('Thru3D website feedback'),issue:t('Issue'),visited:t('Visited')});
    open($('copy-dialog'));
  }
  async function copyText(text, fromDialog = false) {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); toast(t('Copied')); return; } catch (_) {}
    }
    // Plain LAN HTTP cannot use the modern Clipboard API in many browsers.
    const input = document.createElement('textarea'); input.className = 'clipboard-buffer'; input.value = text; input.setAttribute('aria-hidden', 'true');
    const focused = document.activeElement; (document.querySelector('dialog[open]') || document.body).append(input);
    input.focus(); input.select(); input.setSelectionRange(0, text.length);
    let copied = false;
    try { copied = document.execCommand('copy'); } catch (_) {}
    input.remove(); if (focused?.isConnected) focused.focus();
    if (copied) { toast(t('Copied')); return; }
    if (!fromDialog) { setMessage('copy-title', 'Copy links'); $('copy-text').value = text; open($('copy-dialog')); }
    setMessage('copy-hint', 'Select and copy the text'); $('copy-text').focus(); $('copy-text').select(); $('copy-text').setSelectionRange(0, $('copy-text').value.length);
  }
  function confirmDeletion(clear = false) {
    deleting = [...selection]; deleteMode = mode; clearingHistory = clear; deleteRevision = mode === 'history' ? historyRevision : revision;
    setMessage('delete-title', clear ? 'Clear browsing history?' : mode === 'history' ? 'Delete history entries?' : 'Delete bookmarks?');
    $('delete-summary').textContent = clear ? t('All browsing history') : format('Delete %d items?', deleting.length);
    $('delete-note').hidden = mode !== 'history'; open($('confirmation'));
  }
  $('tab-bookmarks').addEventListener('click', () => switchMode('bookmarks'));
  $('tab-history').addEventListener('click', () => switchMode('history'));
  $('language').addEventListener('change', () => { language = $('language').value; storage.set('bookmark-language', language); $('toast').hidden = true; localize(); });
  $('pair-form').addEventListener('submit', async event => {
    event.preventDefault(); const button = event.currentTarget.querySelector('button'); button.disabled = true;
    try { const result = await request('/pair', {code:$('code').value.trim()}, false); token = result.token; storage.set('bookmark-token', token); await refresh(true); }
    catch (error) { toast(message(error)); } finally { button.disabled = false; }
  });
  $('add').addEventListener('click', () => openEditor());
  $('bulk').addEventListener('click', openImport);
  $('import').addEventListener('click', () => { openImport(); $('file').click(); });
  $('pick-file').addEventListener('click', () => $('file').click());
  $('preview').addEventListener('click', () => { importItems = BookmarkTools.lines($('links').value); renderPreview(); });
  $('links').addEventListener('input', () => { importItems = BookmarkTools.lines($('links').value); renderPreview(); });
  $('file').addEventListener('change', async () => {
    const file = $('file').files[0]; if (!file) return;
    try {
      if (file.size > 2 * 1024 * 1024) throw Error('large');
      const text = await file.text();
      if (/\.html?$/i.test(file.name)) {
        // The fragment is never attached: imported markup cannot run or replace our UI.
        const template = document.createElement('template'); template.innerHTML = text;
        importItems = [...template.content.querySelectorAll('a[href]')].map(a => ({url:a.getAttribute('href'), title:a.textContent}));
      } else if (/\.json$/i.test(file.name)) {
        const parsed = JSON.parse(text); importItems = Array.isArray(parsed) ? parsed : parsed.bookmarks;
        if (!Array.isArray(importItems) || !importItems.every(item => item && typeof item.url === 'string')) throw Error('file');
      } else if (/\.txt$/i.test(file.name)) importItems = BookmarkTools.lines(text);
      else throw Error('file');
      if (importItems.length > 1000) { importItems = []; throw Error('large'); }
      $('links').value = ''; $('importer').querySelector('.dialog-error').textContent = ''; renderPreview();
    } catch (error) { importItems = []; renderPreview(); $('importer').querySelector('.dialog-error').textContent = message(error); }
    finally { $('file').value = ''; }
  });
  $('import-save').addEventListener('click', () => { const items = renderPreview(); if (items.length) mutate({action:'import_bookmarks', items, revision:importRevision}, $('importer')); });
  $('edit-form').addEventListener('submit', event => { event.preventDefault(); mutate({action:'save_bookmark',previous, url:$('url').value.trim(),title:$('name').value.trim(),revision:editRevision}, $('editor')); });
  $('search').addEventListener('input', render);
  $('all').addEventListener('change', () => { visible().forEach(item => $('all').checked ? selection.add(item.url) : selection.delete(item.url)); render(); });
  $('copy-selected').addEventListener('click', () => copyText(selectedEntries().map(item => item.url).join('\n')));
  $('feedback-selected').addEventListener('click', () => prepareFeedback(selectedEntries()));
  $('copy-text-button').addEventListener('click', () => copyText($('copy-text').value, true));
  $('delete-selected').addEventListener('click', () => confirmDeletion());
  $('clear-history').addEventListener('click', () => confirmDeletion(true));
  $('delete-confirm').addEventListener('click', () => mutate({action:clearingHistory ? 'clear_history' : 'remove',collection:deleteMode,urls:deleting,[deleteMode === 'history' ? 'history_revision' : 'revision']:deleteRevision}, $('confirmation')));
  document.querySelectorAll('.close').forEach(button => button.addEventListener('click', () => { if (!busy) button.closest('dialog').close(); }));
  document.querySelectorAll('dialog').forEach(dialog => dialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); }));
  $('refresh').addEventListener('click', () => refresh(true));
  $('retry').addEventListener('click', connect);
  $('disconnect').addEventListener('click', () => { if (!busy) open($('access-confirmation')); });
  $('access-confirm').addEventListener('click', async () => {
    if (busy) return;
    busy = true; epoch++; $('disconnect').disabled = true; $('access-confirm').disabled = true;
    try { await request('/api', {action:'stop_share'}); unpair(); setMessage('pair-title', 'Remote access closed'); setMessage('pair-message', 'All devices are disconnected. Reopen access in your headset.'); $('retry').hidden = true; }
    catch (error) { $('access-confirmation').querySelector('.dialog-error').textContent = message(error); }
    finally { busy = false; $('disconnect').disabled = false; $('access-confirm').disabled = false; }
  });
  $('export').addEventListener('click', () => {
    const url = URL.createObjectURL(new Blob([BookmarkTools.html(bookmarks)], {type:'text/html;charset=utf-8'}));
    const a = document.createElement('a'); a.href = url; a.download = 'Thru3D-bookmarks.html'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  try { const response = await fetch('/translations.json', {cache:'no-store'}); catalog = await response.json(); } catch (_) {}
  localize(); if (token) await refresh(true); if (!token) await connect();
  setInterval(() => { if (!document.hidden && !document.querySelector('dialog[open]')) refresh(); }, 3000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
})();
