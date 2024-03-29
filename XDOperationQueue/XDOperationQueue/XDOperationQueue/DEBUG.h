//
//  DEBUG.h
//  XDOperationQueue
//
//  Created by su xinde on 15/11/21.
//  Copyright © 2015年 com.su. All rights reserved.
//


/* KEEP THIS FILE SHORT! */
#ifndef __SYSTEM_DEBUG_PCH__
#define __SYSTEM_DEBUG_PCH__
#if !__ASSEMBLER__
extern int __debug_build__;

#define BREAKPOINT_FUNCTION(prototype) \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Wlanguage-extension-token\"") \
__attribute__((noinline, visibility("hidden"))) \
prototype { asm(""); } \
_Pragma("clang diagnostic pop")

#ifdef ANDROID
#include <android/log.h>
#define __ANDROID_COMPATIBLE_LOG_ASSERT_FN__ __android_log_assert
#define __ANDROID_COMPATIBLE_LOG_FN__ __android_log_print
#else
#include <stdio.h>
#define __ANDROID_COMPATIBLE_LOG_ASSERT_FN__ (cond, tag, format, ...) printf(format, ##__VA_ARGS__)
#define __ANDROID_COMPATIBLE_LOG_FN__(ignore1, ignore2, format, ...) printf(format, ##__VA_ARGS__)
#endif

#define RELEASE_LOG(format, ...)                                 \
__ANDROID_COMPATIBLE_LOG_FN__(5 /* ANDROID_LOG_WARN */, __PROJECT__, format, ##__VA_ARGS__)

#if defined(ENABLE_LOGGING) || !defined(NDEBUG) || NDEBUG == 0

// Needed for Xcode's clang indexer to avoid showing spurious errors
#if !defined(__SHORT_FILE__)
#define __SHORT_FILE__ __FILE__
#endif

#ifdef SHORT_DEBUG
#define DEBUG_LOG(format, ...) \
__ANDROID_COMPATIBLE_LOG_FN__(4 /* ANDROID_LOG_INFO */, __PROJECT__, format, ##__VA_ARGS__)
#else
#define DEBUG_LOG__(file, line, format, ...) \
__ANDROID_COMPATIBLE_LOG_FN__(4 /* ANDROID_LOG_INFO */, __PROJECT__, file ":" #line " %s: " format, __FUNCTION__, ##__VA_ARGS__)
#define DEBUG_LOG_(file, line, format, ...) DEBUG_LOG__(file, line, format, ##__VA_ARGS__)
#define DEBUG_LOG(format, ...) DEBUG_LOG_(__SHORT_FILE__, __LINE__, format, ##__VA_ARGS__)
#endif

#if defined(__i386__) || defined(__x86_64__)
#define _DEBUG_BREAKPT() __asm__ volatile("int $0x03")
#elif defined(__thumb__)
#define _DEBUG_BREAKPT() __asm__ volatile(".inst 0xde01")
#elif defined(__arm__) && !defined(__thumb__)
#define _DEBUG_BREAKPT() __asm__ volatile(".inst 0xe7f001f0")
#else
#define _DEBUG_BREAKPT() __builtin_trap()
#endif

#define DEBUG_BREAK() {                                                 \
__ANDROID_COMPATIBLE_LOG_FN__(6 /* ANDROID_LOG_ERROR */,              \
__PROJECT__,                            \
"DEBUG_BREAK: Hit breakpoint at %s:%d", \
__FILE__, __LINE__);                    \
_DEBUG_BREAKPT();                                                     \
}

// Timing utility functions.  Defined in call_trace/tictoc.c.
#ifdef __cplusplus
extern "C" {
#endif
    extern void __tic() __attribute__((no_instrument_function, visibility("default")));
    extern float __toc(const char *desc) __attribute__((no_instrument_function, visibility("default")));
#ifdef __cplusplus
}
#endif

// Avoid the residual hassle of tic/toc with the following TIC/TOC macros:
#define __TIC __tic()
#define __TOC__(file, line) __toc(file ":" #line)
#define __TOC_(file, line) __TOC__(file, line)
#define __TOC __TOC_(__SHORT_FILE__, __LINE__)
// Break in the debugger if a particular section runs too slowly with TOC_BREAK(max_milliseconds):
#define __TOC_BREAK(max_milliseconds) if (TOC > max_milliseconds) { DEBUG_BREAK(); }

#else // !NDEBUG

#define DEBUG_LOG(...)
#define DEBUG_BREAK()

#endif // NDEBUG

#endif // !__ASSEMBLER__
#endif // __SYSTEM_DEBUG_PCH__

