#undef NDEBUG
#include <assert.h>
#include <stdio.h>
#include "../../native/mpv/mvc/mvc_recovery.h"

int main(void)
{
    int count = -1;
    const uint8_t zero[] = {6, 1, 0xc0, 0x80};
    const uint8_t two[] = {6, 1, 0x70, 0x80};
    const uint8_t escaped[] = {5, 4, 0, 0, 3, 1, 2, 6, 1, 0x70, 0x80};
    const uint8_t truncated[] = {6, 2, 0x70};
    const uint8_t short_flags[] = {6, 1, 0x08, 0x80};
    const uint8_t empty[] = {0x80};
    const uint8_t bad_escape[] = {5, 4, 0, 0, 3, 4};
    assert(mvc_recovery_sei(zero, sizeof(zero), &count) && count == 0);
    assert(mvc_recovery_sei(two, sizeof(two), &count) && count == 2);
    assert(mvc_recovery_sei(escaped, sizeof(escaped), &count) && count == 2);
    assert(!mvc_recovery_sei(truncated, sizeof(truncated), &count));
    assert(!mvc_recovery_sei(short_flags, sizeof(short_flags), &count));
    assert(!mvc_recovery_sei(bad_escape, sizeof(bad_escape), &count));
    assert(mvc_recovery_sei(empty, sizeof(empty), &count) && count == -1);
    MvcRecovery gate;
    mvc_recovery_reset(&gate);
    assert(!mvc_recovery_allows(&gate, 100));
    mvc_recovery_picture(&gate, 14, 15, 0, 1, 100);
    assert(!gate.ready); /* An intra-looking frame alone is not a recovery point. */
    gate.pending = 2;
    mvc_recovery_picture(&gate, 14, 15, 0, 1, 100);
    assert(!gate.ready && gate.target == 0);
    mvc_recovery_picture(&gate, 15, 15, 0, 0, 90);
    mvc_recovery_picture(&gate, 15, 15, 0, 1, 130);
    assert(!gate.ready);
    mvc_recovery_picture(&gate, 0, 15, 0, 0, 120);
    assert(!gate.ready); /* A non-reference B picture cannot complete recovery. */
    mvc_recovery_picture(&gate, 0, 15, 0, 1, 160);
    assert(gate.ready && !mvc_recovery_allows(&gate, 150));
    assert(mvc_recovery_allows(&gate, 160) && mvc_recovery_allows(&gate, 170));
    mvc_recovery_picture(&gate, 0, 15, 0, 1, 120);
    assert(gate.first_pts == 160); /* Reordered output cannot reopen leading pictures. */
    mvc_recovery_reset(&gate);
    gate.pending = 0;
    mvc_recovery_picture(&gate, 7, 15, 0, 1, 500);
    assert(mvc_recovery_allows(&gate, 500) && !mvc_recovery_allows(&gate, 499));
    mvc_recovery_reset(&gate);
    mvc_recovery_picture(&gate, 0, 15, 1, 1, 900);
    assert(mvc_recovery_allows(&gate, 900));
    mvc_recovery_reset(&gate);
    mvc_recovery_picture(&gate, 0, 15, 1, 1, INT64_MIN);
    assert(!gate.ready);
    puts("MVC recovery parser/gate checks passed");
    return 0;
}
