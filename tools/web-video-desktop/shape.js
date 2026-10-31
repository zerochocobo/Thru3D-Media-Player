/* Inspect normalization inputs as booleans/counts only; never retain the response. */
const originalNormalize = Thru3DBilibili.normalize;
const originalView = Thru3DBilibili.view;
Thru3DBilibili.view = (raw, requested) => {
  const result = originalView(raw, requested), v=raw?.data?.View;
  normalizedShapes.push({view: true, accepted:!!result, bvid:result?.bvid, code:raw?.code, has_view:!!v, pages:v?.pages?.length,
    bvid_matches:requested.bvid===v?.bvid, aid_matches:requested.aid===String(v?.aid)});
  if(normalizedShapes.length>8)normalizedShapes.shift();
  return result;
};
Thru3DBilibili.normalize = (raw, identity) => {
  const result = originalNormalize(raw, identity), d = raw?.data;
  const address = value => {
    try {
      const u = new URL(value);
      return {https: u.protocol === 'https:', host: /(?:^|\.)bilivideo\.(com|cn)$/.test(u.hostname) ? 'bilivideo' : 'other',
        port: Number(u.port || 443), cdn_domain: u.hostname.split('.').slice(-2).join('.'), prefix: u.pathname.startsWith('/v1/resource/') ? 'v1/resource' : 'other',
        cid_file: /\/\d+-[^/]+\.m4s$/.test(u.pathname), cid_matches: new RegExp('/' + identity.cid + '-').test(u.pathname),
        cid_directory: u.pathname.split('/').slice(0,-1).includes(identity.cid),
        path_shape: u.pathname.split('/').filter(Boolean).map(p => p === 'upgcxcode' ? p : /^\d+$/.test(p) ? 'digits:' + p.length :
          /^[a-f0-9]+\.m4s$/i.test(p) ? 'hex:' + (p.length - 4) + '.m4s' : 'mixed:' + p.length + (p.endsWith('.m4s') ? '.m4s' : '')),
        accepted: !!Thru3DBilibili.address(value, identity.cid)};
    } catch (_) {return {invalid: true};}
  };
  const shape = {accepted: !!result, code: Number(raw?.code), quality: Number(d?.quality),
    duration: Number(d?.timelength) / 1000, preview: !!(d?.is_preview || d?.is_trial),
    drm: !!(d?.has_drm || d?.drm_tech_type), dash: !!d?.dash};
  for (const key of ['video', 'audio']) shape[key] = (d?.dash?.[key] || []).slice(0, 16).map(t => ({
    id: Number(t.id), codec: /^(avc1|hev1|hvc1|av01|mp4a)\.[a-z0-9.]+$/i.test(t.codecs || '') ? t.codecs : 'other',
    width: Number(t.width || 0), height: Number(t.height || 0),
    addresses: [t.baseUrl || t.base_url, ...(t.backupUrl || t.backup_url || [])].slice(0, 9).map(address)}));
  normalizedShapes.push(shape); if (normalizedShapes.length > 4) normalizedShapes.shift();
  return result;
};
