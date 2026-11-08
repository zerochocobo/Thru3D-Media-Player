package org.vrpassthroughplayer.miracast;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** The advertised WFD modes only: AAC-LC 48kHz stereo and 16-bit LPCM 48kHz stereo. */
public final class WfdAudioFrames {
    public interface Listener { void frame(boolean pcm, byte[] bytes, long ptsUs); }
    private final Listener listener;
    private final ByteArrayOutputStream pending = new ByteArrayOutputStream();
    private long nextPts;
    public long rejected, frames;
    public WfdAudioFrames(Listener listener) { this.listener=listener; }
    public void reset() { pending.reset(); nextPts=0; }
    public void pes(WfdTransport.AudioCodec codec, byte[] data, long ptsUs) {
        if (codec==WfdTransport.AudioCodec.LPCM) {
            if (data.length<8 || (data[0]&255)!=0xa0 || (data[3]&255)!=0x11 || (data.length-4)%4!=0) { rejected++; return; }
            byte[] pcm=new byte[data.length-4];
            for(int i=0;i<pcm.length;i+=2) { pcm[i]=data[i+5]; pcm[i+1]=data[i+4]; }
            frames++; listener.frame(true,pcm,ptsUs); return;
        }
        if (codec!=WfdTransport.AudioCodec.AAC_ADTS || data.length>16384-pending.size()) { rejected++; reset(); return; }
        if(pending.size()==0) nextPts=ptsUs;
        pending.write(data,0,data.length);
        byte[] b=pending.toByteArray(); int p=0;
        while(p+7<=b.length) {
            int profile=((b[p+2]&255)>>>6)+1, rate=((b[p+2]&255)>>>2)&15;
            int channels=((b[p+2]&1)<<2)|((b[p+3]&255)>>>6);
            if((b[p]&255)!=255 || (b[p+1]&0xf6)!=0xf0 || profile!=2 || rate!=3 || channels!=2 || (b[p+6]&3)!=0) {
                rejected++; reset(); return;
            }
            int header=(b[p+1]&1)!=0?7:9;
            int length=((b[p+3]&3)<<11)|((b[p+4]&255)<<3)|((b[p+5]&255)>>>5);
            if(length<header) { rejected++; reset(); return; }
            if(p+length>b.length) break;
            frames++; listener.frame(false,Arrays.copyOfRange(b,p+header,p+length),nextPts);
            nextPts+=1024_000_000L/48000; p+=length;
        }
        pending.reset(); pending.write(b,p,b.length-p);
    }
}
