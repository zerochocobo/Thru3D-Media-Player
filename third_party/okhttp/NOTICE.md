# Cancellable cloud media transport

- OkHttp 4.12.0: `com.squareup.okhttp3:okhttp:4.12.0`.
- Transitive Okio JVM 3.6.0: `com.squareup.okio:okio-jvm:3.6.0`.
- Both use Apache-2.0. License files are unmodified upstream copies from
  https://github.com/square/okhttp/tree/parent-4.12.0 and
  https://github.com/square/okio/tree/parent-3.6.0.
- `PUBLIC_SUFFIX_NOTICE.txt` is copied unchanged from
  `okhttp3/internal/publicsuffix/NOTICE` in the Maven OkHttp jar. That original
  resource and database remain in the dependency.

`CancellableMediaConnection` adapts media requests to the existing
`HttpURLConnection` factory interface. `Call.cancel()` closes a stalled socket
before response cleanup. Redirects, Range validation, provider headers and
retries remain in `CloudStreamSource`. HTTP/1.1 and no idle pooled connections
preserve the player's explicit CDN body ownership. It adds no disk cache.

The real HTTP stall tests use this production connection implementation. The
JDK's default `HttpURLConnection` can block inside `disconnect()` while another
thread reads a stalled body, so it cannot provide the cancellation contract
required by shared cloud playback. Synthetic CDN tests continue to enforce one
active origin and zero connection-limit rejections.
