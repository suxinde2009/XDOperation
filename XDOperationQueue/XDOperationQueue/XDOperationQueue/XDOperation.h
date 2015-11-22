//
//  XDOperation.h
//  XDOperationQueue
//
//  Created by su xinde on 15/11/21.
//  Copyright © 2015年 com.su. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Foundation/NSObject.h>
#import "DEBUG.h"

@class NSArray, NSSet;

typedef NS_ENUM(NSInteger, XDOperationQueuePriority) {
    XDOperationQueuePriorityVeryLow = -8L,
    XDOperationQueuePriorityLow = -4L,
    XDOperationQueuePriorityNormal = 0,
    XDOperationQueuePriorityHigh = 4,
    XDOperationQueuePriorityVeryHigh = 8
};

enum {
    XDOperationQueueDefaultMaxConcurrentOperationCount = -1
};

FOUNDATION_EXPORT NSString * const NSInvocationOperationVoidResultException;
FOUNDATION_EXPORT NSString * const NSInvocationOperationCancelledException;
CF_EXPORT void CFSortIndexes(CFIndex *indexBuffer, CFIndex count, CFOptionFlags opts, CFComparisonResult (^cmp)(CFIndex, CFIndex));

@interface XDOperation : NSObject

- (id)init;
- (void)start;
- (void)main;
- (BOOL)isCancelled;
- (void)cancel;
- (BOOL)isExecuting;
- (BOOL)isFinished;
- (BOOL)isConcurrent;
- (BOOL)isReady;
- (void)addDependency:(XDOperation *)op;
- (void)removeDependency:(XDOperation *)op;
- (NSArray *)dependencies;
- (XDOperationQueuePriority)queuePriority;
- (void)setQueuePriority:(XDOperationQueuePriority)p;
#if NS_BLOCKS_AVAILABLE
- (void (^)(void))completionBlock;
- (void)setCompletionBlock:(void (^)(void))block;
#endif
- (void)waitUntilFinished;
- (double)threadPriority;
- (void)setThreadPriority:(double)p;

@end

@interface XDBlockOperation : XDOperation

#if NS_BLOCKS_AVAILABLE
+ (id)blockOperationWithBlock:(void (^)(void))block;
- (void)addExecutionBlock:(void (^)(void))block;
- (NSArray *)executionBlocks;
#endif

@end

@interface XDInvocationOperation : XDOperation

- (id)initWithTarget:(id)target selector:(SEL)sel object:(id)arg;
- (id)initWithInvocation:(NSInvocation *)inv;
- (NSInvocation *)invocation;
- (id)result;

@end

@interface XDOperationQueue : NSObject

+ (id)currentQueue;
+ (id)mainQueue;
- (void)addOperation:(XDOperation *)op;
- (void)addOperations:(NSArray *)ops waitUntilFinished:(BOOL)wait;
#if NS_BLOCKS_AVAILABLE
- (void)addOperationWithBlock:(void (^)(void))block;
#endif
- (NSArray *)operations;
- (NSUInteger)operationCount;
- (NSInteger)maxConcurrentOperationCount;
- (void)setMaxConcurrentOperationCount:(NSInteger)cnt;
- (void)setSuspended:(BOOL)b;
- (BOOL)isSuspended;
- (void)setName:(NSString *)n;
- (NSString *)name;
- (void)cancelAllOperations;
- (void)waitUntilAllOperationsAreFinished;

@end
