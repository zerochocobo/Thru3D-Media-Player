package org.vrpassthroughplayer.miracast;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** MPEG-TS assembly adapted from MiracastReceiver (MIT; see third_party/miracast/NOTICE.txt). */
public final class WfdTransport {
    public enum AudioCodec { AAC_ADTS, LPCM }
    public interface Listener {
        void video(byte[] annexB, long ptsUs);
        void audio(AudioCodec codec, byte[] payload, long ptsUs);
        void discontinuity(boolean video);
    }
    private final Listener listener;
    private int pmtPid = -1, videoPid = -1, audioPid = -1;
    private AudioCodec audioCodec;
    private long ssrc = -1;
    private int sequence = -1;
    private long cycles, baseSequence = -1, lastArrival, lastTimestamp;
    private double jitter;
    public long packets, rejected, lost;
    private final Pes video, audio;
    public WfdTransport(Listener listener) {
        this.listener = listener;
        video = new Pes(true, 2 * 1024 * 1024);
        audio = new Pes(false, 128 * 1024);
    }
    private static int u(byte[] b, int p) { return b[p] & 255; }
    private static int word(byte[] b, int p) { return (u(b,p) << 8) | u(b,p+1); }
    public synchronized void rtp(byte[] b, int offset, int length) {
        if (offset < 0 || length < 12 || offset > b.length - length) { rejected++; return; }
        int end = offset + length;
        int flags = u(b,offset);
        if ((flags >>> 6) != 2 || (u(b,offset+1) & 127) != 33) { rejected++; return; }
        int payload = offset + 12 + (flags & 15) * 4;
        if (payload > end) { rejected++; return; }
        if ((flags & 16) != 0) {
            if (payload > end - 4) { rejected++; return; }
            payload += 4 + word(b,payload+2) * 4;
        }
        if ((flags & 32) != 0) {
            int padding = u(b,end-1);
            if (padding == 0 || padding > end - payload) { rejected++; return; }
            end -= padding;
        }
        if (payload >= end || (end-payload) % 188 != 0) { rejected++; return; }
        long source = ((long)word(b,offset+8) << 16) | word(b,offset+10);
        if (ssrc >= 0 && source != ssrc) { rejected++; return; }
        int seq = word(b,offset+2);
        int delta = sequence < 0 ? 1 : (seq - sequence) & 65535;
        if (delta == 0 || delta > 32768) { rejected++; return; } // duplicate/late packet, not 65535 losses
        if (delta > 1) { lost += delta-1; video.discard(true); audio.discard(true); }
        if (sequence >= 0 && seq < sequence) cycles += 65536;
        if (baseSequence < 0) baseSequence = seq;
        long stamp = ((long)word(b,offset+4)<<16)|word(b,offset+6);
        long arrival = System.nanoTime()/1_000_000L*90;
        if (packets > 0) { long difference = (arrival-lastArrival)-(int)(stamp-lastTimestamp); jitter += (Math.abs(difference)-jitter)/16.0; }
        lastArrival=arrival;lastTimestamp=stamp;
        ssrc = source; sequence = seq; packets++;
        ts(b,payload,end-payload);
    }
    public synchronized long[] reception() {
        return new long[]{ssrc, packets, lost, sequence < 0 ? 0 : cycles+sequence, baseSequence < 0 ? 0 : cycles+sequence-baseSequence+1, (long)jitter};
    }
    public void ts(byte[] b, int offset, int length) {
        if (offset < 0 || length < 0 || offset > b.length-length || length % 188 != 0) { rejected++; return; }
        for (int pos=offset; pos<offset+length; pos+=188) packet(b,pos);
    }
    private void packet(byte[] b, int start) {
        if (u(b,start) != 0x47) { rejected++; video.discard(true); audio.discard(true); return; }
        int pid = word(b,start+1) & 8191;
        Pes pes = pid == videoPid ? video : pid == audioPid ? audio : null;
        int flags = u(b,start+3), control = (flags >>> 4) & 3;
        if ((u(b,start+1) & 128) != 0 || (flags & 192) != 0) {
            rejected++; if (pes != null) pes.discard(true); return; // TEI or scrambled/protected data
        }
        if (control == 0) { rejected++; return; }
        int payload = start+4;
        if (control == 3 || control == 2) {
            int size = u(b,payload);
            if (payload + 1 + size > start+188) { rejected++; if (pes != null) pes.discard(true); return; }
            if (size > 0 && (u(b,payload+1) & 128) != 0 && pes != null) { pes.discard(true); pes.continuity=-1; }
            payload += 1+size;
        }
        if (control == 2 || payload >= start+188) return;
        boolean first = (u(b,start+1) & 64) != 0;
        if (pid == 0 || pid == pmtPid) {
            if (!first) return; // only complete PSI sections are accepted; retry at the next repeated table
            int section = payload + 1 + u(b,payload);
            if (section > start+188-12) { rejected++; return; }
            int sectionEnd = section + 3 + (word(b,section+1) & 4095);
            if (sectionEnd > start+188 || sectionEnd < section+12 || !crc(b,section,sectionEnd)) { rejected++; return; }
            if (pid == 0 && u(b,section) == 0 && pmtPid < 0) {
                for (int p=section+8; p+4<=sectionEnd-4; p+=4) {
                    if (word(b,p) != 0) { pmtPid=word(b,p+2)&8191; break; }
                }
            } else if (pid == pmtPid && u(b,section) == 2) {
                int p = section+12+(word(b,section+10)&4095);
                while (p+5<=sectionEnd-4) {
                    int type=u(b,p), streamPid=word(b,p+1)&8191;
                    int next=p+5+(word(b,p+3)&4095);
                    if (next>sectionEnd-4) { rejected++; return; }
                    if (type==0x1b && videoPid<0) videoPid=streamPid;
                    if ((type==0x0f || type==0x83) && audioPid<0) {
                        audioPid=streamPid; audioCodec=type==0x83 ? AudioCodec.LPCM : AudioCodec.AAC_ADTS;
                    }
                    p=next;
                }
            }
        } else if (pes != null) {
            int count = flags & 15;
            if (pes.continuity == count) return;
            if (pes.continuity >= 0 && count != ((pes.continuity+1)&15)) pes.discard(true);
            pes.continuity=count;
            pes.packet(b,payload,start+188,first);
        }
    }
    private static boolean crc(byte[] b, int start, int end) {
        int crc=-1;
        for (int p=start;p<end;p++) {
            crc ^= u(b,p)<<24;
            for (int bit=0;bit<8;bit++) crc=(crc<<1)^((crc<0)?0x04c11db7:0);
        }
        return crc==0;
    }
    public void flush() { video.flush(); audio.flush(); }
    private final class Pes {
        final boolean isVideo;
        final int limit;
        final ByteArrayOutputStream data=new ByteArrayOutputStream();
        int continuity=-1, expected;
        boolean pending;
        long pts;
        Pes(boolean video, int limit) { this.isVideo=video; this.limit=limit; }
        void discard(boolean notify) {
            data.reset(); pending=false; expected=0;
            if (notify) listener.discontinuity(isVideo);
        }
        void packet(byte[] b, int pos, int end, boolean first) {
            if (first) {
                flush();
                if (pos>end-9 || u(b,pos)!=0 || u(b,pos+1)!=0 || u(b,pos+2)!=1) { rejected++; return; }
                int packetLength=word(b,pos+4), headerLength=u(b,pos+8);
                int headerEnd=pos+9+headerLength;
                if (headerEnd>end || (packetLength>0 && packetLength<3+headerLength)) { rejected++; return; }
                pts=0;
                if ((u(b,pos+7)&128)!=0) {
                    if (headerLength<5 || pos+14>end || (u(b,pos+9)&1)==0 || (u(b,pos+11)&1)==0 || (u(b,pos+13)&1)==0) { rejected++; return; }
                    long ticks=((long)(u(b,pos+9)&14)<<29) | ((long)u(b,pos+10)<<22)
                        | ((long)(u(b,pos+11)&254)<<14) | (u(b,pos+12)<<7) | ((u(b,pos+13)&254)>>>1);
                    pts=ticks*1000/90;
                }
                expected=packetLength>0 ? packetLength-3-headerLength : 0;
                pending=true; pos=headerEnd;
            }
            if (!pending) return;
            int size=end-pos;
            if (expected>0) size=Math.min(size,expected-data.size());
            if (size<0 || size>limit-data.size()) { rejected++; discard(true); return; }
            data.write(b,pos,size);
            if (expected>0 && data.size()==expected) flush();
        }
        void flush() {
            if (!pending || data.size()==0) { discard(false); return; }
            if (expected>0 && data.size()!=expected) { rejected++; discard(true); return; }
            byte[] unit=data.toByteArray(); long timestamp=pts;
            discard(false);
            if (isVideo) listener.video(unit,timestamp); else listener.audio(audioCodec,unit,timestamp);
        }
    }
}
