/* Local Plex library requests. Authentication comes only from this exact request. */
const Thru3DPlex = (() => {
  const address = (value, page) => {
    if (typeof value !== 'string' || value.length > 16384 || typeof page !== 'string' || page.length > 8192 ||
        !/\/(?:library\/parts\/|video\/:\/transcode\/universal\/start\.)/i.test(value)) return null;
    try {
      const u = new URL(value, page), p = new URL(page);
      if (!/^https?:$/.test(u.protocol) || u.origin !== p.origin || u.username || u.password || u.hash ||
          /%|(?:^|\/)\.\.?(?:\/|$)/.test(u.pathname)) return null;
      const direct = u.pathname.match(/^(.*)\/library\/parts\/([0-9]{1,20})\/([0-9]{1,20})\/file(?:\.[a-z0-9]{1,8})?$/i);
      const transcode = u.pathname.match(/^(.*)\/video\/:\/transcode\/universal\/start\.(?:mpd|m3u8|mkv)$/i);
      if (!direct && !transcode) return null;
      const args = new Map();
      for (const [name, value] of u.searchParams) {
        const key = name.toLowerCase();
        if (args.has(key)) return null;
        args.set(key, value);
      }
      if (direct) return {u, args, key:`plex-part:${direct[2]}:${direct[3]}`};
      const path = args.get('path'), media = args.get('mediaindex') ?? '-1', part = args.get('partindex') ?? '-1';
      if (!/^\/library\/metadata\/[0-9]{1,20}$/.test(path || '') || !/^(?:-1|[0-9]{1,3})$/.test(media) ||
          !/^(?:-1|[0-9]{1,3})$/.test(part) || Number(media) > 127 || Number(part) > 127) return null;
      return {u, args, key:`plex:${path.split('/').pop()}:${media}:${part}`};
    } catch (_) { return null; }
  };
  const source = (value, page, headers = {}) => {
    const parsed = address(value, page); if (!parsed) return null;
    const {u, args, key} = parsed;
    const observed = Object.fromEntries(Object.entries(headers || {}).map(([k,v])=>[k.toLowerCase(),v]));
    const query = args.get('x-plex-token'), sent = observed['x-plex-token'];
    const token = query || sent;
    if (!token || typeof token !== 'string' || token.length > 4096 || /[^\x21-\x7e]/.test(token) || query && sent && query !== sent) return null;
    const auth = {'X-Plex-Token':token};
    const client = args.get('x-plex-client-identifier') || observed['x-plex-client-identifier'];
    if (typeof client === 'string' && /^[\x21-\x7e]{1,256}$/.test(client)) auth['X-Plex-Client-Identifier'] = client;
    const offset = args.get('copyts') === '0' ? Number(args.get('offset') || 0) : 0;
    if (!Number.isFinite(offset) || offset < 0 || offset > 1e7) return null;
    return {source:u.href,key,headers:auth,offset,plex:true};
  };
  return {address,source};
})();
