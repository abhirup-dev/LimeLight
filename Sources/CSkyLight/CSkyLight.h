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

// ProcessSerialNumber lives in CoreServices but we reproduce the struct
// here to avoid pulling the deprecated framework into our module.
typedef struct {
    uint32_t highLongOfPSN;
    uint32_t lowLongOfPSN;
} CSPSN;

// SLS notification proc signature — verified against JankyBorders/src/events.c.
typedef void (*SLSNotifyProc)(uint32_t type,
                              void *data,
                              size_t dataLength,
                              void *userInfo,
                              CGSConnectionID cid);

// --- Connection / process discovery --------------------------------------

typedef CGSConnectionID (*SLSMainConnectionIDFn)(void);
typedef int32_t (*SLPSGetFrontProcessFn)(CSPSN *psn);
typedef CGError (*SLSGetConnectionIDForPSNFn)(CGSConnectionID cid,
                                              CSPSN *psn,
                                              CGSConnectionID *out_cid);
typedef CGError (*SLSConnectionGetPIDFn)(CGSConnectionID cid, int32_t *pid);

// --- Window enumeration (SLS connection-filtered) ------------------------

typedef CFArrayRef (*SLSCopyWindowsWithOptionsAndTagsFn)(CGSConnectionID cid,
                                                         uint32_t owner,
                                                         CFArrayRef spaces,
                                                         uint32_t options,
                                                         uint64_t *set_tags,
                                                         uint64_t *clear_tags);
typedef CFTypeRef (*SLSWindowQueryWindowsFn)(CGSConnectionID cid,
                                             CFArrayRef windows,
                                             uint32_t options);
typedef CFTypeRef (*SLSWindowQueryResultCopyWindowsFn)(CFTypeRef query);
typedef int (*SLSWindowIteratorGetCountFn)(CFTypeRef iterator);
typedef bool (*SLSWindowIteratorAdvanceFn)(CFTypeRef iterator);
typedef uint32_t (*SLSWindowIteratorGetParentIDFn)(CFTypeRef iterator);
typedef uint32_t (*SLSWindowIteratorGetWindowIDFn)(CFTypeRef iterator);
typedef uint64_t (*SLSWindowIteratorGetTagsFn)(CFTypeRef iterator);
typedef uint64_t (*SLSWindowIteratorGetAttributesFn)(CFTypeRef iterator);

// --- Space / display ------------------------------------------------------

typedef CFArrayRef (*SLSCopyManagedDisplaysFn)(CGSConnectionID cid);
typedef CFStringRef (*SLSCopyActiveMenuBarDisplayIdentifierFn)(CGSConnectionID cid);
typedef CGSSpaceID (*SLSManagedDisplayGetCurrentSpaceFn)(CGSConnectionID cid,
                                                         CFStringRef display_uuid);

// --- Notification subscription -------------------------------------------

typedef CGError (*SLSRegisterNotifyProcFn)(SLSNotifyProc proc,
                                           uint32_t type,
                                           void *userInfo);

// --- Bounds / owner (defensive accelerators) -----------------------------

typedef CGError (*SLSGetWindowBoundsFn)(CGSConnectionID, CGSWindowID, CGRect *);
typedef CGError (*SLSGetWindowOwnerFn)(CGSConnectionID, CGSWindowID, int32_t *);

#endif // CSKYLIGHT_H
