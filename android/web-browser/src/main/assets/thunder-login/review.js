/* Official review page bridge. The native delegate is bound to one login
 * session; ordinary browser tabs never receive credentials or a bridge. */
(() => {
  'use strict';
  if (location.href !== 'https://i.xunlei.com/xlcaptcha/android.html' || window.top !== window) return;
  const port = browser.runtime.connectNative('thunder_login');
  let finished = false;
  let timer;
  port.onDisconnect.addListener(() => { finished = true; clearInterval(timer); });
  port.onMessage.addListener(message => {
    if (finished || message.type !== 'review' || !message.review || timer) return;
    const page = window.wrappedJSObject;
    const sendMessage = (name, raw, callback) => {
      if (finished) return;
      if (name === 'nativeGetUserDeviceInfo' && callback === 'reviewCb' && typeof page.reviewCb === 'function') {
        page.reviewCb(cloneInto(message.review, window));
      } else if (name === 'nativeRecvOperationResult' && typeof raw === 'string' && raw.length < 16384) {
        try {
          const value = JSON.parse(raw);
          if (value.roCommand === 'android_review' && String(value.roErrorCode) === '0' &&
              typeof value.roData?.creditkey === 'string' && value.roData.creditkey.length > 0 && value.roData.creditkey.length <= 8192) {
            port.postMessage({type: 'verified', credit_key: value.roData.creditkey});
            finished = true;
          }
        } catch (_) { /* Invalid page results cannot complete a login. */ }
      }
    };
    page.XLJSWebViewBridge = cloneInto({sendMessage}, window, {cloneFunctions: true});
    let ticks = 0;
    timer = setInterval(() => {
      if (finished || ++ticks > 100) { clearInterval(timer); return; }
      if (typeof page.reviewCb === 'function') {
        clearInterval(timer);
        page.reviewCb(cloneInto(message.review, window));
      }
    }, 50);
  });
  port.postMessage({type: 'ready'});
})();
