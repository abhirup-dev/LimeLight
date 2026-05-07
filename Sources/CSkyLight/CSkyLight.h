#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// Private SkyLight / SLS API declarations.
// These symbols ship in /System/Library/PrivateFrameworks/SkyLight.framework
// and are not part of any public SDK. Consumers must link -framework SkyLight
// from /System/Library/PrivateFrameworks at link time.
//
// Surface kept intentionally small for now — the BorderEngine and WindowTracker
// epics will extend this with the symbols they actually need.

#ifdef __cplusplus
extern "C" {
#endif

typedef int CGSConnectionID;

extern CGSConnectionID SLSMainConnectionID(void);

// Active-window query. Returns the window ID currently considered "key" for the
// front process by the WindowServer. Useful for focus tracking before AX events.
extern CGError SLSGetActiveWindow(CGSConnectionID cid, uint32_t *outWindowID);

// Window list / introspection.
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(
    CGSConnectionID cid,
    uint32_t owner,
    CFArrayRef spaces,
    uint32_t options,
    uint64_t *setTags,
    uint64_t *clearTags
);

// Frame/owner queries used by border attachment.
extern CGError SLSGetWindowBounds(CGSConnectionID cid, uint32_t windowID, CGRect *outBounds);
extern CGError SLSGetWindowOwner(CGSConnectionID cid, uint32_t windowID, int32_t *outPid);

#ifdef __cplusplus
}
#endif

#endif // CSKYLIGHT_H
