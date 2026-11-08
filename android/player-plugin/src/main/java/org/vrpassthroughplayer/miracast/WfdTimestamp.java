package org.vrpassthroughplayer.miracast;

/** Extend a sender's arbitrary 33-bit MPEG presentation clock across wraps and A/V reordering. */
public final class WfdTimestamp {
    public static final long WRAP_US = (1L << 33) * 1000 / 90;
    private long latest = Long.MIN_VALUE;
    public synchronized long nanoseconds(long rawUs) {
        if (rawUs < 0 || rawUs >= WRAP_US) throw new IllegalArgumentException("Invalid MPEG timestamp");
        if (latest == Long.MIN_VALUE) latest = rawUs;
        long value = rawUs + latest / WRAP_US * WRAP_US;
        if (value < latest - WRAP_US / 2) value += WRAP_US;
        if (value > latest + WRAP_US / 2) value -= WRAP_US;
        latest = Math.max(latest, value);
        return Math.max(0, value) * 1000 + 1;
    }
}
