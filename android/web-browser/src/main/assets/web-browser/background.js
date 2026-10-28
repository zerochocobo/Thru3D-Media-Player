/* Privileged extension background only; no page/content-script message listener. */
"use strict";
const connect = () => {
  const port = browser.runtime.connectNative("thru3d_cookies");
  port.onMessage.addListener(async (message) => {
    const groups = [["youtube.com"], ["bilibili.com"], ["douyin.com", "iesdouyin.com"],
      ["weibo.com", "weibo.cn"], ["iqiyi.com"], ["mgtv.com"], ["qq.com"], ["youku.com"],
      ["vimeo.com"], ["dailymotion.com", "dai.ly"], ["twitch.tv"], ["tubitv.com"],
      ["redbull.com", "redbull.tv"], ["astalavr.com"],
      ["tiktok.com"], ["instagram.com"], ["facebook.com", "fb.watch"],
      ["twitter.com", "x.com"], ["reddit.com", "redd.it"], ["streamable.com"],
      ["ted.com"], ["archive.org"], ["rumble.com"], ["odysee.com"],
      ["nicovideo.jp", "nico.ms"], ["naver.com"], ["kakao.com"]];
    const domains = message?.domains;
    if (!/^[a-f0-9-]{36}$/.test(message?.request || "") || !Array.isArray(domains) ||
        !groups.some(group => JSON.stringify(group) === JSON.stringify(domains))) return;
    const reply = { request: message.request, ok: false, cookies: [] };
    try {
      const cookies = (await Promise.all(domains.map(domain => browser.cookies.getAll({ domain })))).flat();
      if (cookies.length > 256) throw new Error("limit");
      reply.cookies = cookies.filter(c => !c.partitionKey && !c.firstPartyDomain).map(({ name, value, domain, path, secure, httpOnly, hostOnly, expirationDate }) =>
        ({ name, value, domain, path, secure, httpOnly, hostOnly, expirationDate }));
      reply.ok = JSON.stringify(reply).length <= 256 * 1024;
      if (!reply.ok) reply.cookies = [];
    } catch (_) { reply.cookies = []; }
    try { port.postMessage(reply); } catch (_) { /* Native window closed. */ }
  });
  port.onDisconnect.addListener(() => setTimeout(connect, 1000));
};
connect();
