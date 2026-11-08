package org.vrpassthroughplayer.miracast;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * WFD sink M1-M7 control session. Flow/capability reference: weekdayjast/MiracastReceiver,
 * commit 17cac2ac6e22b4fcd35676af86dc5b839109ca1c (MIT, see third_party/miracast).
 * Adapted for explicit CSeq/state matching, bounded framing, no Activity/UI coupling,
 * no subnet scanning and no content-protection negotiation.
 */
public final class WfdRtspSession implements AutoCloseable {
    public interface Listener {
        void audioFormat(String codec);
        void playing(int remoteRtpPort, int remoteRtcpPort);
        void stopped();
    }
    /** Control verbs/status only; never passes URLs, headers or media to diagnostics. */
    public interface Trace { void control(boolean incoming, String method, int status); }
    private final Socket socket;
    private final Listener listener;
    private final int localPort;
    private final Trace trace;
    private final Map<Integer, String> pending = new java.util.concurrent.ConcurrentHashMap<>();
    private int nextCseq, remoteRtp, remoteRtcp;
    private volatile String presentation = "", session = "";
    private boolean optionsSent, setupSent;
    private volatile boolean playing;
    private volatile boolean closed;
    public WfdRtspSession(Socket socket, int localRtpPort, Listener listener) throws IOException {
        this(socket, localRtpPort, listener, null);
    }
    public WfdRtspSession(Socket socket, int localRtpPort, Listener listener, Trace trace) throws IOException {
        if (localRtpPort < 1024 || localRtpPort > 65534 || (localRtpPort & 1) != 0)
            throw new IllegalArgumentException("RTP requires an even local port and its reserved RTCP pair");
        this.socket = socket; this.localPort = localRtpPort; this.listener = listener;
        this.trace = trace;
        socket.setSoTimeout(15000);
    }
    public void run() throws IOException {
        try {
            while (!closed) {
                Message message = read(socket.getInputStream());
                if (message == null) break;
                String verb = message.first.split(" ", 2)[0];
                int status = message.first.matches("RTSP/1\\.0 [0-9]{3}(?: .*)?") ? Integer.parseInt(message.first.substring(9, 12)) : 0;
                control(true, verb, status);
                if (message.first.startsWith("RTSP/1.0 ")) response(message);
                else request(message);
            }
        } finally { close(); listener.stopped(); }
    }
    private void request(Message m) throws IOException {
        String[] first = m.first.split(" ", -1);
        if (first.length != 3 || !"RTSP/1.0".equals(first[2])) throw new IOException("Malformed RTSP request");
        int seq = m.sequence();
        switch (first[0]) {
            case "OPTIONS":
                reply(seq, 200, "OK", "Public: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER\r\n", "");
                if (!optionsSent) { optionsSent = true; send("OPTIONS", "*", "Require: org.wfa.wfd1.0\r\n"); }
                break;
            case "GET_PARAMETER":
                if (!optionsSent) throw new IOException("Capabilities requested before OPTIONS");
                StringBuilder body = new StringBuilder();
                for (String key : m.parameters().keySet()) {
                    String value = capability(key);
                    if (value != null) body.append(key).append(": ").append(value).append("\r\n");
                }
                reply(seq, 200, "OK", "", body.toString());
                break;
            case "SET_PARAMETER":
                if (!optionsSent) throw new IOException("Parameters before OPTIONS");
                Map<String, String> p = m.parameters();
                if (p.containsKey("wfd_video_formats")) validateVideo(p.get("wfd_video_formats"));
                String protection = p.get("wfd_content_protection");
                if (protection != null && !"none".equalsIgnoreCase(protection)) {
                    reply(seq, 406, "Not Acceptable", "", "");
                    throw new IOException("Protected WFD session unsupported");
                }
                if (p.containsKey("wfd_presentation_url")) {
                    String url = p.get("wfd_presentation_url").split(" +")[0];
                    try {
                        URI uri = new URI(url);
                        if (!"rtsp".equalsIgnoreCase(uri.getScheme()) || uri.getUserInfo() != null
                            || uri.getHost() == null || !uri.getHost().equals(socket.getInetAddress().getHostAddress())
                            || url.length() > 1024 || url.indexOf('\r') >= 0 || url.indexOf('\n') >= 0)
                            throw new URISyntaxException("", "Unbound presentation address");
                    } catch (URISyntaxException error) { throw new IOException("Unbound WFD presentation URL", error); }
                    presentation = url;
                }
                String audio = p.get("wfd_audio_codecs");
                if (audio != null) {
                    if (audio.equalsIgnoreCase("none")) listener.audioFormat("none");
                    else if (audio.matches("(?i)AAC +00000001 +[0-9a-f]{2}")) listener.audioFormat("AAC");
                    else if (audio.matches("(?i)LPCM +00000002 +[0-9a-f]{2}")) listener.audioFormat("LPCM");
                    else throw new IOException("Unadvertised audio format");
                }
                String trigger = p.get("wfd_trigger_method");
                if (trigger != null && !trigger.equals("SETUP") && !trigger.equals("TEARDOWN")) {
                    reply(seq, 501, "Not Implemented", "", ""); break;
                }
                reply(seq, 200, "OK", "", "");
                if ("TEARDOWN".equals(trigger)) { closed = true; break; }
                if ("SETUP".equals(trigger) && !setupSent) {
                    if (presentation.isEmpty()) throw new IOException("SETUP without a bound presentation URL");
                    setupSent = true;
                    send("SETUP", presentation, "Transport: RTP/AVP/UDP;unicast;client_port=" + localPort + "-" + (localPort + 1) + "\r\n");
                }
                break;
            case "TEARDOWN": reply(seq, 200, "OK", "", ""); closed = true; break;
            default: reply(seq, 405, "Method Not Allowed", "", "");
        }
    }
    private String capability(String key) {
        switch (key) {
            case "wfd_video_formats": return "28 00 03 10 000000A1 00000000 00000000 00 0000 0000 00 none none";
            case "wfd_audio_codecs": return "LPCM 00000002 00, AAC 00000001 00";
            // M3's second value is the secondary RTP stream, NOT the RTCP port.
            // Android WifiDisplaySource rejects a non-zero secondary port. RTCP is paired in M6.
            case "wfd_client_rtp_ports": return "RTP/AVP/UDP;unicast " + localPort + " 0 mode=play";
            case "wfd_content_protection": case "wfd_display_edid": case "wfd_uibc_capability":
            case "wfd_3d_video_formats": case "wfd_standby_resume_capability": return "none";
            case "wfd_coupled_sink": return "00 none";
            case "wfd_connector_type": return "05";
            default: return null;
        }
    }
    public static void validateVideo(String value) throws IOException {
        String[] fields = value.trim().split(" +");
        try {
            if (fields.length != 13) throw new NumberFormatException();
            int profile = Integer.parseInt(fields[2], 16), level = Integer.parseInt(fields[3], 16);
            long cea = Long.parseLong(fields[4], 16), vesa = Long.parseLong(fields[5], 16), hh = Long.parseLong(fields[6], 16);
            if ((profile != 1 && profile != 2) || level < 1 || level > 16 || (level & (level - 1)) != 0
                || cea == 0 || (cea & ~0xa1L) != 0 || vesa != 0 || hh != 0) throw new NumberFormatException();
        } catch (NumberFormatException error) { throw new IOException("Unadvertised video format", error); }
    }
    private void response(Message m) throws IOException {
        int seq = m.sequence();
        String method = pending.remove(seq);
        if (method == null) throw new IOException("Unmatched RTSP response CSeq");
        if (!m.first.matches("RTSP/1\\.0 200(?: .*)?")) {
            if (method.equals("SET_PARAMETER")) return; // optional IDR request; wait for the sender's next GOP
            throw new IOException("WFD request rejected");
        }
        if (method.equals("SETUP")) {
            String value = m.headers.get("session");
            session = value == null ? "" : value.split(";", 2)[0].trim();
            if (!session.matches("[A-Za-z0-9._-]{1,128}")) throw new IOException("Missing or invalid RTSP session");
            String transport = m.headers.get("transport");
            String profile = transport == null ? "" : transport.split(";", 2)[0].trim().toUpperCase(Locale.ROOT);
            if ((!profile.equals("RTP/AVP/UDP") && !profile.equals("RTP/AVP"))
                || transport.toLowerCase(Locale.ROOT).matches(".*;\\s*multicast\\s*(?:;.*)?"))
                throw new IOException("Non-UDP RTP transport selected");
            java.util.regex.Matcher ports = java.util.regex.Pattern.compile("(?:^|;)\\s*server_port\\s*=\\s*(\\d+)(?:-(\\d+))?\\s*(?:;|$)", java.util.regex.Pattern.CASE_INSENSITIVE).matcher(transport);
            if (ports.find()) {
                remoteRtp = port(ports.group(1));
                remoteRtcp = ports.group(2) == null ? 0 : port(ports.group(2));
            }
            send("PLAY", presentation, "Session: " + session + "\r\n");
        } else if (method.equals("PLAY")) {
            if (session.isEmpty() || playing) throw new IOException("Invalid PLAY state");
            playing = true; socket.setSoTimeout(90000);
            listener.playing(remoteRtp, remoteRtcp);
        }
    }
    private static int port(String value) throws IOException {
        try { int n = Integer.parseInt(value); if (n > 0 && n < 65536) return n; }
        catch (NumberFormatException ignored) { }
        throw new IOException("Invalid server port");
    }
    private synchronized void send(String method, String uri, String headers) throws IOException {
        if (pending.size() >= 4) throw new IOException("Too many pending WFD requests");
        int seq = ++nextCseq; pending.put(seq, method);
        write(method + " " + uri + " RTSP/1.0\r\nCSeq: " + seq + "\r\n" + headers + "\r\n");
        control(false, method, 0);
    }
    public synchronized void requestKeyFrame() throws IOException {
        if (!playing || closed || pending.size() >= 4) return;
        int seq = ++nextCseq; pending.put(seq, "SET_PARAMETER");
        String body = "wfd_idr_request\r\n";
        write("SET_PARAMETER " + presentation + " RTSP/1.0\r\nCSeq: " + seq + "\r\nSession: " + session
            + "\r\nContent-Type: text/parameters\r\nContent-Length: " + body.length() + "\r\n\r\n" + body);
        control(false, "SET_PARAMETER", 0);
    }
    private void reply(int seq, int status, String reason, String headers, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        write("RTSP/1.0 " + status + " " + reason + "\r\nCSeq: " + seq + "\r\n" + headers
            + (bytes.length > 0 ? "Content-Type: text/parameters\r\n" : "")
            + "Content-Length: " + bytes.length + "\r\n\r\n" + body);
        control(false, "", status);
    }
    private void control(boolean incoming, String method, int status) {
        if (trace == null) return;
        String safe = Arrays.asList("OPTIONS", "GET_PARAMETER", "SET_PARAMETER", "SETUP", "PLAY", "TEARDOWN", "PAUSE").contains(method) ? method : "response";
        try { trace.control(incoming, safe, status); } catch (RuntimeException ignored) { }
    }
    private synchronized void write(String text) throws IOException {
        if (closed) throw new IOException("Session closed");
        socket.getOutputStream().write(text.getBytes(StandardCharsets.UTF_8)); socket.getOutputStream().flush();
    }
    @Override public void close() { closed = true; try { socket.close(); } catch (IOException ignored) { } }

    public static final class Message {
        public final String first, body;
        public final Map<String, String> headers;
        Message(String first, Map<String, String> headers, String body) { this.first = first; this.headers = headers; this.body = body; }
        public int sequence() throws IOException {
            String value = headers.get("cseq");
            if (value == null || !value.matches("[0-9]{1,10}")) throw new IOException("Missing/invalid CSeq");
            try { return Integer.parseInt(value); } catch (NumberFormatException error) { throw new IOException("CSeq overflow", error); }
        }
        public Map<String, String> parameters() throws IOException {
            Map<String, String> result = new LinkedHashMap<>();
            for (String line : body.split("\r\n")) {
                if (line.isEmpty()) continue;
                int colon = line.indexOf(':');
                String key = (colon < 0 ? line : line.substring(0, colon)).trim().toLowerCase(Locale.ROOT);
                if (!key.matches("[a-z0-9_]{1,64}") || result.containsKey(key)) throw new IOException("Invalid/duplicate WFD parameter");
                result.put(key, colon < 0 ? "" : line.substring(colon + 1).trim());
            }
            return result;
        }
    }
    public static Message read(InputStream input) throws IOException {
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        int tail = 0;
        while (tail != 0x0d0a0d0a) {
            int b = input.read();
            if (b < 0) { if (header.size() == 0) return null; throw new EOFException("Truncated RTSP header"); }
            header.write(b); tail = (tail << 8) | b;
            if (header.size() > 16384) throw new IOException("RTSP header exceeds limit");
        }
        String[] lines = new String(header.toByteArray(), StandardCharsets.US_ASCII).split("\r\n");
        Map<String, String> fields = new LinkedHashMap<>();
        for (int i = 1; i < lines.length; ++i) {
            int colon = lines[i].indexOf(':');
            if (colon <= 0) throw new IOException("Invalid RTSP header");
            String key = lines[i].substring(0, colon).toLowerCase(Locale.ROOT);
            if (!key.matches("[a-z0-9-]+") || fields.put(key, lines[i].substring(colon + 1).trim()) != null)
                throw new IOException("Duplicate/invalid RTSP header");
        }
        int length = 0;
        if (fields.containsKey("content-length")) {
            String value = fields.get("content-length");
            if (!value.matches("[0-9]{1,5}")) throw new IOException("Invalid Content-Length");
            length = Integer.parseInt(value);
            if (length > 16384) throw new IOException("RTSP body exceeds limit");
        }
        byte[] body = new byte[length];
        int position = 0;
        while (position < length) {
            int count = input.read(body, position, length - position);
            if (count < 0) throw new EOFException("Truncated RTSP body");
            position += count;
        }
        return new Message(lines[0], fields, new String(body, StandardCharsets.UTF_8));
    }
}
