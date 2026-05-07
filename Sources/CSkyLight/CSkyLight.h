#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// Type-only declarations for private SkyLight / SLS APIs.
// We do NOT link SkyLight at build time — symbols are resolved via dlopen+dlsym
// at runtime so the daemon degrades gracefully if Apple renames a symbol.

typedef int CGSConnectionID;
typedef uint32_t CGSWindowID;
typedef uint64_t CGSSpaceID;

// Function prototypes are exposed only as typedefs so dlsym callers can cast.
typedef CGSConnectionID (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSGetWindowBoundsFn)(CGSConnectionID, CGSWindowID, CGRect *);
typedef CGError (*SLSGetWindowOwnerFn)(CGSConnectionID, CGSWindowID, int32_t *);

#endif // CSKYLIGHT_H
