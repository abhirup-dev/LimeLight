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

// SLS notification proc signature — verified against JankyBorders/src/events.c.
// `type` is one of the EVENT_* class IDs (806/807/808/815/816/1325/1326/1401/1508).
// `data` carries the affected CGSWindowID (or pid for app events) inline.
// `dataLength` is the size of `data` in bytes.
// `userInfo` is the opaque pointer we passed to SLSRegisterNotifyProc.
typedef void (*SLSNotifyProc)(uint32_t type,
                              void *data,
                              size_t dataLength,
                              void *userInfo,
                              CGSConnectionID cid);

// Function prototypes are exposed only as typedefs so dlsym callers can cast.
typedef CGSConnectionID (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSRegisterNotifyProcFn)(SLSNotifyProc proc,
                                           uint32_t type,
                                           void *userInfo);
typedef CGError (*SLSGetWindowBoundsFn)(CGSConnectionID, CGSWindowID, CGRect *);
typedef CGError (*SLSGetWindowOwnerFn)(CGSConnectionID, CGSWindowID, int32_t *);
typedef CGError (*SLSConnectionGetPIDFn)(CGSConnectionID, int32_t *);

#endif // CSKYLIGHT_H
