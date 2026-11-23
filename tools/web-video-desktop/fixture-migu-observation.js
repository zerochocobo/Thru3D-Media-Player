/* Keep the passive document observation independent of the regular media report. */
const Thru3DFixtureMiguObservation = (() => {
  let page = '';
  let attempts = 0;
  let posted = 0;
  let failure = '';
  let snapshotRequest = 0;
  let stopProbe;
  const enabled = () => window === window.top &&
    /^https:\/\/www\.miguvideo\.com\/p\/vertical\/(968096380|966398567)$/.test(location.href);

  function current() {
    if (page !== location.href) {
      page = location.href;
      attempts = 0;
      posted = 0;
      failure = '';
      snapshotRequest = 0;
    }
    return enabled();
  }

  function report(send, token, closed) {
    if (!current()) return send(token);
    if (!closed) attempts++;
    try { return send(token); }
    catch (_) { failure = 'build_error'; }
  }

  function sent(ok) {
    if (!current()) return;
    if (ok) posted++;
    else failure = 'post_error';
  }

  function packet(trace, requests, isProtected) {
    const videos = [];
    for (const video of document.querySelectorAll('video')) {
      if (videos.length === 16) break;
      videos.push({
        width: video.videoWidth,
        height: video.videoHeight,
        time: Number.isFinite(video.currentTime) ? video.currentTime : 0,
        duration: Number.isFinite(video.duration) ? video.duration : 0,
        playing: !video.paused && !video.ended,
        protected: isProtected(video),
        blob: video.currentSrc.startsWith('blob:'),
        fixture_migu_visible: Thru3DPlayButton.visible(video),
        fixture_migu_mse_video_codecs: Thru3DFixtureMiguMse.activeVideoCodecs(video),
        fixture_migu_player_event: Thru3DFixtureMiguEvents.snapshot(video, requests),
      });
    }
    return {type: 'fixture_migu_observation', videos, trace, attempts, posted, failure,
      ...(snapshotRequest ? {snapshot_request: snapshotRequest} : {})};
  }

  function receiveSnapshot(request) {
    if (current() && Number.isSafeInteger(request) && request > 0) snapshotRequest = request;
  }

  function sample(port, trace, requests, isProtected) {
    if (current()) port.postMessage(packet(trace, requests, isProtected));
  }

  function startProbe(token, read) {
    if (!current() || typeof token !== 'string' || !/^[a-f0-9]{32}$/.test(token)) return;
    stopProbe?.();
    const route = location.href;
    let remaining = 160;
    let pending = false;
    const tick = () => {
      if (location.href !== route || --remaining < 0) return stop();
      if (pending || document.hidden) return;
      pending = true;
      Promise.resolve().then(() => {
        const [trace, requests, isProtected] = read();
        return browser.runtime.sendNativeMessage('thru3d_video', {...packet(trace, requests, isProtected), token});
      }).catch(() => {}).finally(() => { pending = false; });
    };
    const timer = setInterval(tick, 1500);
    const stop = () => {
      clearInterval(timer);
      window.removeEventListener('pagehide', stop);
    };
    stopProbe = stop;
    window.addEventListener('pagehide', stop, {once: true});
    tick();
  }

  return {report, sent, receiveSnapshot, sample, startProbe};
})();
