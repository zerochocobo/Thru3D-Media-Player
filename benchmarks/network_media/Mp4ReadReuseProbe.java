import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import com.sun.net.httpserver.HttpServer;
import org.vrpassthroughplayer.plugin.*;

class Mp4ReadReuseProbe {
    public static void main(String[] args) throws Exception {
        if (args.length < 5) throw new IllegalArgumentException("MP4 OUTPUT BASELINE_HASH_DIRECTORY SECONDS TARGET_SECONDS...");
        int seconds = Integer.parseInt(args[3]);
        if (seconds < 1 || seconds > 60) throw new IllegalArgumentException("Sample budget");
        List<Integer> targets = Arrays.stream(args).skip(4).map(Integer::parseInt).toList();
        if (targets.size() > 16 || targets.stream().anyMatch(t -> t < 0)) throw new IllegalArgumentException("Target budget");
        Path baseline = Path.of(args[2]);
        Path media = Path.of(args[0]); long size = Files.size(media);
        Path output = Path.of(args[1]); Files.createDirectories(output);
        var originCache = Collections.synchronizedMap(new LinkedHashMap<Long, byte[]>(4096, .75f, true) { protected boolean removeEldestEntry(Map.Entry<Long, byte[]> e) { return size() > 4096; } });
        for (boolean enabled : List.of(true)) {
            for (int start : targets) {
                AtomicInteger requests = new AtomicInteger(); AtomicLong sent = new AtomicLong();
                int blocksBefore = originCache.size();
                var origin = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
                var workers = Executors.newCachedThreadPool(r -> {var t = new Thread(r); t.setDaemon(true); return t;});
                origin.setExecutor(workers);
                origin.createContext("/file", exchange -> {
                    requests.incrementAndGet();
                    try {
                        String value = exchange.getRequestHeaders().getFirst("Range");
                        var parts = value.substring(6).split("-", -1);
                        long begin = Long.parseLong(parts[0]);
                        long end = parts[1].isEmpty() ? size - 1 : Math.min(Long.parseLong(parts[1]), size - 1);
                        Thread.sleep(30);
                        exchange.getResponseHeaders().add("Content-Type", "video/mp4");
                        exchange.getResponseHeaders().add("Content-Range", "bytes " + begin + "-" + end + "/" + size);
                        exchange.sendResponseHeaders(206, end-begin+1);
                        try (var file = new RandomAccessFile(media.toFile(), "r"); var body = exchange.getResponseBody()) {
                            long offset = begin;
                            while (offset <= end) {
                                long block = offset / 65536;
                                byte[] buffer = originCache.computeIfAbsent(block, key -> {

                                    try {
                                        if (file.getFilePointer() != key * 65536) file.seek(key * 65536);
                                        byte[] valueBytes = new byte[(int)Math.min(65536, size-key*65536)];
                                        file.readFully(valueBytes); return valueBytes;
                                    } catch (IOException e) { throw new UncheckedIOException(e); }
                                });
                                int at = (int)(offset % 65536);
                                int n = (int)Math.min(buffer.length-at, end-offset+1);
                                body.write(buffer, at, n); sent.addAndGet(n); offset += n;
                            }
                        }
                    } catch (Exception ignored) {} finally { exchange.close(); }
                });
                origin.start();
                String label = (enabled ? "packet" : "baseline") + "-" + start;
                try (var local = new LocalStreamServer()) {
                    var source = HttpRangeStreamSource.Companion.remote(URI.create("http://127.0.0.1:" + origin.getAddress().getPort() + "/file"));
                    String url = local.publish(source, "sample.mp4");
                    var decision = Mp4InterleavePolicy.INSTANCE.inspectHttp(url, () -> false);
                    if (!decision.getRegionCache() || decision.getSequential()) throw new AssertionError("not the distributed audio case: " + decision);

                    if (!local.enableInterleaveCache(url, decision.getAudioChunks())) throw new AssertionError("activation failed");
                    int before = requests.get(); long bytesBefore = sent.get(); long begin = System.nanoTime();
                    var command = new ArrayList<>(List.of("ffmpeg", "-v", "error", "-nostdin", "-ss", ""+start, "-i", url,
                        "-map", "0:v:0", "-map", "0:a:0", "-t", Integer.toString(seconds), "-c", "copy", "-progress", "pipe:1",
                        "-y", "-f", "streamhash", "-hash", "sha256", output.resolve(label+"-streamhash.txt").toString()));

                    var process = new ProcessBuilder(command).redirectOutput(output.resolve(label+"-progress.txt").toFile())
                        .redirectError(output.resolve(label+"-stderr.txt").toFile()).start();
                    boolean completed = process.waitFor(180, TimeUnit.SECONDS);
                    if (!completed) process.destroyForcibly();
                    int exit = completed ? process.exitValue() : -1;
                    String report = label + " upstream_requests=" + (requests.get()-before) + " upstream_written_bytes=" + (sent.get()-bytesBefore) +
                        " seconds=" + (System.nanoTime()-begin)/1e9 + " exit=" + exit +
                        " origin_RAM_blocks_added=" + (originCache.size()-blocksBefore) + " cache=" + local.interleaveCacheStats(url);
                    System.out.println(report);
                    Files.writeString(output.resolve(label+"-report.txt"), report+"\n");
                    if (exit != 0) throw new AssertionError("ffmpeg failed or timed out " + label);
                } finally { origin.stop(0); workers.shutdownNow(); }
            }
        }
        for (int start : targets) {
            String a = Files.readString(baseline.resolve("baseline-"+start+"-streamhash.txt"));
            String b = Files.readString(output.resolve("packet-"+start+"-streamhash.txt"));
            if (!a.equals(b) || a.lines().count()!=2) throw new AssertionError("AV hashes differ at " + start);
        }
        System.out.println("All sampled positions preserve both compressed AV stream hashes; this is not paced native playback.");
    }
}
