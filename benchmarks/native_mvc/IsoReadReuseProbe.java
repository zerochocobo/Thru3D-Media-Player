import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import com.sun.net.httpserver.HttpServer;
import org.vrpassthroughplayer.plugin.*;

public class IsoReadReuseProbe {
    public static void main(String[] args) throws Exception {
        if (args.length < 6) throw new IllegalArgumentException(
            "ISO OUTPUT_DIRECTORY PREFLIGHT_BINARY MULTICLIP_BINARY WINDOW_SECONDS TARGET...");
        Path media = Path.of(args[0]); long size = Files.size(media);
        Path output = Path.of(args[1]); Files.createDirectories(output);
        // Diagnostic host RAM only. The production source's independent cache
        // budgets are verified in IsoReadCacheTest. Never copy the input ISO.
        var originCache = Collections.synchronizedMap(new LinkedHashMap<Long, byte[]>(4096, .75f, true) {
            protected boolean removeEldestEntry(Map.Entry<Long, byte[]> entry) { return size() > 4096; }
        });
        boolean playbackPassed = true;
        for (boolean optimized : List.of(false, true)) {
            var requests = Collections.synchronizedList(new ArrayList<String>());
            var sent = new AtomicLong();
            var origin = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            var workers = Executors.newCachedThreadPool(r -> {var t = new Thread(r); t.setDaemon(true); return t;});
            origin.setExecutor(workers);
            origin.createContext("/origin", exchange -> {
                try {
                    String value = exchange.getRequestHeaders().getFirst("Range");
                    var parts = value.substring(6).split("-", -1);
                    long start = Long.parseLong(parts[0]);
                    long end = parts[1].isEmpty() ? size-1 : Math.min(Long.parseLong(parts[1]), size-1);
                    requests.add(start+"-"+end); Thread.sleep(10);
                    exchange.getResponseHeaders().add("Content-Type", "application/octet-stream");
                    exchange.getResponseHeaders().add("Content-Range", "bytes "+start+"-"+end+"/"+size);
                    exchange.sendResponseHeaders(206, end-start+1);
                    try (var file = new RandomAccessFile(media.toFile(), "r"); var body = exchange.getResponseBody()) {
                        long offset = start;
                        while (offset <= end) {
                            long key = offset/65536; byte[] buffer = originCache.get(key);
                            if (buffer == null) {
                                buffer = new byte[(int)Math.min(65536, size-key*65536)];
                                file.seek(key*65536); file.readFully(buffer); originCache.put(key, buffer);
                            }
                            int at = (int)(offset%65536); int n = (int)Math.min(buffer.length-at, end-offset+1);
                            body.write(buffer, at, n); sent.addAndGet(n); offset += n;
                        }
                    }
                } catch (Exception ignored) {} finally { exchange.close(); }
            });
            origin.start(); String mode = optimized ? "optimized" : "baseline";
            try (var local = new LocalStreamServer()) {
                var source = HttpRangeStreamSource.Companion.remote(URI.create("http://127.0.0.1:"+origin.getAddress().getPort()+"/origin"));
                StreamSource selected = optimized ? source : new StreamSource() {
                    public long getSize() { return source.getSize(); }
                    public StreamSource.Reader open() { return source.open(); }
                    public void close() { source.close(); }
                };
                String url = local.publish(selected, "movie.iso");
                for (String phase : List.of("preflight", "playback")) {
                    int before = requests.size(); long bytesBefore = sent.get(); long begin = System.nanoTime();
                    long consumedBefore = local.progress(url).getBytes();
                    var command = new ArrayList<String>();
                    if (phase.equals("preflight")) command.addAll(List.of(args[2], url));
                    else {
                        command.addAll(List.of(args[3], url, args[4]));
                        command.addAll(Arrays.asList(args).subList(5, args.length));
                    }
                    var process = new ProcessBuilder(command).redirectOutput(output.resolve(mode+"-"+phase+".jsonl").toFile())
                        .redirectError(output.resolve(mode+"-"+phase+".log").toFile()).start();
                    if (!process.waitFor(600, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new AssertionError("timeout "+mode+" "+phase); }
                    if (process.exitValue()!=0 && phase.equals("preflight")) throw new AssertionError("probe failed "+mode+" "+phase+" "+process.exitValue());
                    if (process.exitValue()!=0) playbackPassed = false;
                    String report = mode+" "+phase+" upstream_requests="+(requests.size()-before)+
                        " origin_written_bytes="+(sent.get()-bytesBefore)+
                        " upstream_read_bytes="+(local.progress(url).getBytes()-consumedBefore)+
                        " seconds="+(System.nanoTime()-begin)/1e9+
                        " exit="+process.exitValue()+" cache="+local.isoCacheStats(url);
                    Files.writeString(output.resolve(mode+"-"+phase+"-report.txt"), report+"\n");
                    synchronized(requests) { Files.write(output.resolve(mode+"-"+phase+"-ranges.txt"), requests.subList(before, requests.size())); }
                    System.out.println(report);
                    if (phase.equals("preflight")) local.finishIsoPreflight(url);
                }
            } finally { origin.stop(0); workers.shutdownNow(); }
        }
        if (!playbackPassed) throw new AssertionError("Playback failed; both modes' reports have been preserved");
    }
}
