// Run against WebBookmarkPreview's production HTTP server (never a headset or real library).
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
(async () => {
  const base = process.env.BOOKMARK_PREVIEW_URL || 'http://127.0.0.1:18791';
  assert.equal(new URL(base).hostname, '127.0.0.1');
  const output = path.resolve('build/output/bookmark-remote/web'); await fs.mkdir(output, {recursive:true});
  const browser = await chromium.launch({headless:true, channel:'msedge'});
  const context = await browser.newContext({viewport:{width:1280,height:900},locale:'en-US'});
  const page = await context.newPage(), errors = [], outside = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (!request.url().startsWith(base) && !request.url().startsWith('blob:')) outside.push(request.url()); });
  let checks = 0, stopRequests = 0;
  page.on('request', request => { if (request.url() === base + '/api' && request.postDataJSON()?.action === 'stop_share') stopRequests++; });
  const check = (ok, label) => { assert.ok(ok, label); checks++; };
  try {
    if (process.env.BOOKMARK_PREVIEW_CODE) {
      const code = process.env.BOOKMARK_PREVIEW_CODE;
      await page.goto(base); await page.locator('#pair-form').waitFor({state:'visible'});
      check(await page.locator('#workspace').isHidden(), 'Secure session shows no bookmarks before pairing');
      check(await page.locator('#code').getAttribute('maxlength') === '4', 'Four-letter input');
      for (const lang of ['zh','zh_Hant','ja','en']) {
        await page.locator('#language').selectOption(lang); await page.setViewportSize({width:390,height:844});
        await page.screenshot({path:path.join(output,`${lang}-pair.png`),fullPage:true});
      }
      await page.locator('#code').fill(code === 'ZZZZ' ? 'AAAA' : 'ZZZZ'); await page.locator('#pair-form button').click();
      await page.locator('#toast').filter({hasText:'Enter the code'}).waitFor(); checks++;
      await page.locator('#code').fill(code.toLowerCase()); await page.locator('#pair-form button').click(); await page.locator('#workspace').waitFor({state:'visible'}); checks++;
      await page.reload(); await page.locator('#workspace').waitFor({state:'visible'});
      check(await page.locator('#pair-form').isHidden(), 'Refresh retains this session without another code');
      await page.locator('#disconnect').click(); await page.locator('#access-confirmation').waitFor({state:'visible'});
      check(stopRequests === 0, 'Secure session also requires a second confirmation');
      await page.locator('#access-confirm').click(); await page.locator('#pair-title').filter({hasText:'Remote access closed'}).waitFor(); checks++;
      check(errors.length === 0 && outside.length === 0, 'Pairing stays local and has no browser exceptions');
      await fs.writeFile(path.join(output,'pairing-verification.json'),JSON.stringify({checks,errors,outside},null,2));
      console.log(`Bookmark pairing E2E: ${checks} checks passed; 4 localized screenshots`); return;
    }
    await page.goto(base); await page.locator('#workspace').waitFor({state:'visible'});
    check(await page.locator('#pair-form').isHidden(), 'No code required by default');
    for (const lang of ['zh','zh_Hant','ja','en']) {
      await page.locator('#language').selectOption(lang);
      for (const width of [390,1280]) {
        await page.setViewportSize({width,height:900});
        check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `No horizontal overflow ${lang}/${width}`);
        await page.screenshot({path:path.join(output,`${lang}-${width}.png`),fullPage:true});
      }
    }
    await page.locator('#add').click(); await page.locator('#url').fill('file:///secret'); await page.locator('#edit-form .primary').click();
    await page.locator('#editor .dialog-error').filter({hasText:'Invalid address'}).waitFor(); checks++;
    await page.locator('#url').fill('https://example.com/remote'); await page.locator('#name').fill('<img src=x onerror=alert(1)>');
    await page.locator('#edit-form .primary').click(); await page.locator('#editor').waitFor({state:'hidden'});
    check(await page.locator('.card').count() === 5 && await page.locator('#cards img').count() === 0, 'Saved text is literal, not markup');
    const secondContext = await browser.newContext({viewport:{width:390,height:844},locale:'zh-CN'});
    const second = await secondContext.newPage(); await second.goto(base); await second.locator('#workspace').waitFor({state:'visible'});
    await second.locator('#language').selectOption('en');
    await second.locator('.card').filter({hasText:'https://example.com/remote'}).locator('.edit').click();
    await second.locator('#name').fill('Second draft');
    await page.locator('.card').filter({hasText:'https://example.com/remote'}).locator('.edit').click();
    await page.locator('#name').fill('First change'); await page.locator('#edit-form .primary').click(); await page.locator('#editor').waitFor({state:'hidden'});
    await second.locator('#edit-form .primary').click(); await second.locator('#editor .dialog-error').filter({hasText:'Bookmarks changed'}).waitFor();
    check(await second.locator('#name').inputValue() === 'Second draft', 'Conflict preserves draft and does not overwrite');
    await second.locator('#editor .close').last().click();
    await page.locator('#bulk').click(); await page.locator('#links').fill('https://example.com/remote\nhttps://bulk.example/one\nhttps://bulk.example/two\nfile:///private');
    check((await page.locator('#import-summary').textContent()).includes('2 new · 1 duplicates · 1 invalid'), 'Preview counts before save');
    await page.locator('#import-save').click(); await page.locator('#importer').waitFor({state:'hidden'});
    check(await page.locator('.card').count() === 7, 'Bulk commit added only new valid items');
    await page.locator('#bulk').click();
    await page.locator('#file').setInputFiles({name:'bookmarks.html',mimeType:'text/html',buffer:Buffer.from('<a href="https://import.example/">日本語 &amp; 中文</a><script>window.importExecuted=true</script><img src="https://external.invalid/test">')});
    await page.locator('#preview-list li').filter({hasText:'日本語 & 中文'}).waitFor();
    check(await page.evaluate(() => !window.importExecuted), 'Import markup stays inert');
    await page.locator('#import-save').click(); await page.locator('#importer').waitFor({state:'hidden'});
    check(await page.locator('.card').count() === 8, 'HTML import round trip');
    await page.locator('#search').fill('bulk.example'); await page.locator('#all').check();
    await page.locator('#delete-selected').click(); await page.locator('#confirmation').waitFor({state:'visible'});
    await page.locator('#delete-confirm').click(); await page.locator('#confirmation').waitFor({state:'hidden'});
    await page.locator('#search').fill(''); check(await page.locator('.card').count() === 6, 'Filtered batch delete leaves other bookmarks');
    const downloadEvent = page.waitForEvent('download'); await page.locator('#export').click(); const download = await downloadEvent;
    await download.saveAs(path.join(output,'fixture-export.html'));
    check((await fs.readFile(path.join(output,'fixture-export.html'),'utf8')).includes('日本語 &amp; 中文'), 'Portable HTML export preserves Unicode');
    await second.locator('#refresh').click(); await second.waitForFunction(() => document.querySelectorAll('.card').length === 6);
    check(await second.locator('.card').count() === 6, 'Second browser receives live updates');
    await page.locator('#tab-history').click();
    check(await page.locator('.card').count() === 3 && await page.locator('#bookmark-tools').isHidden(), 'History has its own list and management tools');
    check((await page.locator('.visit-time').first().textContent()).length > 0, 'Visit time is visible');
    for (const lang of ['zh','zh_Hant','ja','en']) {
      await page.locator('#language').selectOption(lang);
      for (const width of [390,1280]) {
        await page.setViewportSize({width,height:900});
        check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `History fits ${lang}/${width}`);
        const close = await page.locator('#disconnect').boundingBox();
        check(close.width >= 300 && close.height >= 80, 'Close access button is large on every layout');
        await page.screenshot({path:path.join(output,`${lang}-history-${width}.png`),fullPage:true});
      }
    }
    // Exercise plain-HTTP copy and denied-copy fallback without modifying the developer's clipboard.
    await page.evaluate(() => {
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined});
      window.testCopies = []; document.execCommand = command => { if (command === 'copy') window.testCopies.push(document.activeElement.value); return true; };
    });
    await page.locator('.card').filter({hasText:'https://session.example/clip'}).locator('.copy-link').click();
    check(await page.evaluate(() => window.testCopies.at(-1)) === 'https://session.example/clip', 'Single-copy preserves the exact URL');
    await page.locator('#search').fill('video.example'); await page.locator('#all').check(); await page.locator('#copy-selected').click();
    check((await page.evaluate(() => window.testCopies.at(-1))).split('\n').length === 2, 'Filtered batch copy contains only selected URLs');
    await page.locator('#feedback-selected').click(); await page.locator('#copy-dialog').waitFor({state:'visible'});
    const report = await page.locator('#copy-text').inputValue();
    check(report.includes('Playback sample') && report.includes('第二个网页') && report.includes('Visited:') && !report.includes('session.example'), 'Feedback contains selected titles, page URLs and times');
    await page.locator('#copy-text').fill(report.replace('Issue: ', 'Issue: Black screen after pressing Play.'));
    await page.locator('#copy-text-button').click();
    check((await page.evaluate(() => window.testCopies.at(-1))).includes('Black screen after pressing Play.'), 'User can add symptoms before copying feedback');
    await page.locator('#copy-dialog .close').last().click();
    await page.evaluate(() => { document.execCommand = () => false; });
    await page.locator('.card .copy-link').first().click(); await page.locator('#copy-dialog').waitFor({state:'visible'});
    check(await page.locator('#copy-hint').textContent() === 'Select and copy the text', 'Denied copy offers manual selection');
    check(await page.locator('#copy-text').evaluate(el => el.selectionStart === 0 && el.selectionEnd === el.value.length), 'Full address selected for manual copy');
    await page.locator('#copy-dialog .close').last().click();
    await page.locator('#delete-selected').click(); await page.locator('#delete-confirm').click(); await page.locator('#confirmation').waitFor({state:'hidden'});
    await page.locator('#search').fill(''); check(await page.locator('.card').count() === 1, 'Filtered history deletion retains the unselected visit');
    await page.locator('#tab-bookmarks').click(); check(await page.locator('.card').count() === 6, 'Deleting history preserves bookmarks');
    await page.locator('#tab-history').click(); await page.locator('#clear-history').click();
    check(await page.locator('#delete-note').isVisible(), 'Clear confirmation explains website logins are kept');
    await page.locator('#delete-confirm').click(); await page.locator('#confirmation').waitFor({state:'hidden'});
    check(await page.locator('#no-results').isVisible() && await page.locator('#clear-history').isDisabled(), 'Clear history reaches the empty state');
    await second.locator('#tab-history').click(); await second.locator('#refresh').click();
    await second.waitForFunction(() => document.querySelectorAll('.card').length === 0); checks++;
    await page.locator('#disconnect').click(); await page.locator('#access-confirmation').waitFor({state:'visible'});
    check(stopRequests === 0 && await page.locator('#workspace').isVisible(), 'First tap only opens a confirmation');
    await page.locator('#access-confirmation .close').click();
    check(stopRequests === 0 && await page.locator('#workspace').isVisible(), 'Cancel keeps every device connected');
    await page.locator('#disconnect').click(); await page.keyboard.press('Escape');
    check(await page.locator('#access-confirmation').isHidden() && stopRequests === 0, 'Escape also cancels closure');
    await page.locator('#disconnect').click();
    for (const lang of ['zh','zh_Hant','ja','en']) {
      // Change the language before reopening: the modal keeps focus inside itself.
      await page.locator('#access-confirmation .close').click(); await page.locator('#language').selectOption(lang); await page.locator('#disconnect').click();
      await page.setViewportSize({width:390,height:844}); await page.screenshot({path:path.join(output,`${lang}-close-confirm.png`),fullPage:true});
    }
    await page.locator('#access-confirm').click(); await page.locator('#pair-title').filter({hasText:'Remote access closed'}).waitFor();
    check(stopRequests === 1, 'Only explicit confirmation sends one stop request');
    check(await page.locator('#workspace').isHidden() && (await page.locator('#pair-message').textContent()).includes('All devices are disconnected'), 'Closing removes management UI and explicitly disconnects everyone');
    await secondContext.close();
    check(errors.length === 0, `No browser exceptions: ${errors}`); check(outside.length === 0, `No external requests: ${outside}`);
    await fs.writeFile(path.join(output,'verification.json'),JSON.stringify({checks,errors,outside},null,2));
    console.log(`Bookmark browser E2E: ${checks} checks passed; 16 responsive screenshots`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
