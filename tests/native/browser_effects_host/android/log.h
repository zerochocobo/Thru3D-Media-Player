#pragma once
#include <cstdarg>
#include <cstdio>
enum { ANDROID_LOG_INFO=4, ANDROID_LOG_WARN=5, ANDROID_LOG_ERROR=6 };
inline int __android_log_print(int,const char*,const char* format,...) { va_list a;va_start(a,format);int r=vfprintf(stderr,format,a);va_end(a);return r; }
