#include "../../native/rvm/rvm_frame_identity.h"
#include <iostream>
using quest::accepts_rvm_frame;
static_assert(accepts_rvm_frame(-1, -1, 0, 0, false));
static_assert(accepts_rvm_frame(10, 100, 11, 110, false));
static_assert(accepts_rvm_frame(10, 100, 11, 90, false)); // Timestamp discontinuity resets state downstream.
static_assert(!accepts_rvm_frame(10, 100, 10, 100, false));
static_assert(accepts_rvm_frame(10, 100, 10, 100, true));
static_assert(!accepts_rvm_frame(10, 100, 10, 101, true));
static_assert(!accepts_rvm_frame(10, 100, 10, 99, true));
static_assert(!accepts_rvm_frame(10, 100, 9, 100, true));
static_assert(!accepts_rvm_frame(10, 100, 9, 90, false));
static_assert(!accepts_rvm_frame(-1, -1, -1, -1, true));
static_assert(!accepts_rvm_frame(10, 100, 11, -1, true));
int main() { std::cout << "11 RVM frame identity checks passed\n"; }
