package org.vrpassthroughplayer.miracast;

import java.nio.ByteBuffer;

/** RFC 3550 receiver reports and generic SDES. No sender/device identifiers are retained. */
public final class WfdRtcp {
    private final WfdTransport transport;
    private final int localSsrc;
    private long previousExpected, previousReceived, lastSr, receivedAt;
    public WfdRtcp(WfdTransport transport,int localSsrc){this.transport=transport;this.localSsrc=localSsrc;}
    private static long uint(byte[] b,int p){return ((long)(b[p]&255)<<24)|((long)(b[p+1]&255)<<16)|((long)(b[p+2]&255)<<8)|(b[p+3]&255);}
    public synchronized void receive(byte[] b,int length,long nowNs){
        if(length<4||length>b.length)return;
        long source=transport.reception()[0];
        for(int p=0;p+4<=length;){
            if((b[p]&0xc0)!=0x80)return;
            int size=((((b[p+2]&255)<<8)|(b[p+3]&255))+1)*4;
            if(size<4||size>length-p)return;
            if((b[p+1]&255)==200&&size>=28&&uint(b,p+4)==source){
                lastSr=((uint(b,p+8)&65535)<<16)|(uint(b,p+12)>>>16);receivedAt=nowNs;
            }
            p+=size;
        }
    }
    public synchronized byte[] report(long nowNs){
        long[] s=transport.reception();if(s[0]<0)return null;
        long expected=s[4]-previousExpected, received=s[1]-previousReceived;
        int fraction=expected<=0?0:(int)Math.max(0,Math.min(255,((expected-received)<<8)/expected));
        previousExpected=s[4];previousReceived=s[1];
        long lost=Math.min(0x7fffff,s[2]);
        ByteBuffer out=ByteBuffer.allocate(52);
        out.put((byte)0x81).put((byte)201).putShort((short)7).putInt(localSsrc).putInt((int)s[0]);
        out.put((byte)fraction).put((byte)(lost>>>16)).put((byte)(lost>>>8)).put((byte)lost);
        out.putInt((int)s[3]).putInt((int)s[5]).putInt((int)lastSr);
        out.putInt(receivedAt==0?0:(int)Math.max(0,Math.min(0xffffffffL,(nowNs-receivedAt)/1_000_000L*65536/1000)));
        out.put((byte)0x81).put((byte)202).putShort((short)4).putInt(localSsrc);
        out.put((byte)1).put((byte)6).put(new byte[]{'T','h','r','u','3','D'}).putInt(0);
        return out.array();
    }
}
