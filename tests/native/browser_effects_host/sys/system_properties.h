#pragma once
#define PROP_VALUE_MAX 92
inline int __system_property_get(const char*,char* out) { out[0]=0;return 0; }
