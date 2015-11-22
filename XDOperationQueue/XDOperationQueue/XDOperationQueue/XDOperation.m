//
//  XDOperation.m
//  XDOperationQueue
//
//  Created by su xinde on 15/11/21.
//  Copyright © 2015年 com.su. All rights reserved.
//

#import "XDOperation.h"
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSLock.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSKeyValueObserving.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSThread.h>
#import <Foundation/NSInvocation.h>
#import <Foundation/NSException.h>
#import <Foundation/NSMethodSignature.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#import <libkern/OSAtomic.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>

enum __XDOperationState {
    XDOperationStateReady,
    XDOperationStateNotReady,
    XDOperationStateExecuting = 0x10,
    XDOperationStateFinished = 0xF4
};

typedef NSUInteger _XDOperationState;


@class _XDOperationInternal;
@interface XDOperation() {
    _XDOperationInternal *_internal;
}

@property (nonatomic, readonly) _XDOperationInternal* _internal;

@end

@interface _XDOperationQueueInternal : NSObject {
    @package
    dispatch_queue_t _schedule_queue;
    NSString *_name;
}

@end

@interface _XDOperationInternal : NSObject {
    @package
    XDOperationQueue *_queue;
    
    //THIS OPERATION IS NOT RETAINED.
    XDOperation *_operation;
    NSMutableArray *_dependencies;
    NSMutableSet *_inverse_dependencies;
    NSRecursiveLock *_dependencyLock;
    BOOL _hasExecuted;
    _XDOperationState _state;
    BOOL _cancelled;
    pthread_mutex_t _waitlock;
    pthread_cond_t _waitcondition;
    void (^_completionBlock)(void);
    double _threadPriority;
    XDOperationQueuePriority _queuePriority;
    int _waiting_deps;
    NSInteger _effectivePriorityValue;
}

@property (readonly) NSArray *depedencies;

- (id)initWithOperation:(XDOperation *)operation;

@end

static volatile int32_t _XDOperationQueueID = 0;

@interface XDOperationQueue() {
    BOOL _suspended;
    NSString *_name;
    NSInteger _maxConcurrentOperationCount;
    pthread_mutex_t _queuelock;
    pthread_mutexattr_t _mta;
    
    NSMutableArray *_pendingOperations;
    NSMutableArray *_operations;
    NSMutableArray *_operationsToStart;
    
    _XDOperationQueueInternal *_internal;
    
    BOOL _isMainQueue;
}


- (void)_removeFinishedOperation:(_XDOperationInternal *)opi;
- (void)_queueSchedulerRun;

@end


static pthread_mutex_t _XDOperationLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

@implementation _XDOperationInternal

@synthesize depedencies=_dependencies;

- (id)initWithOperation:(XDOperation *)operation
{
    self = [super init];
    if (self)
    {
        _completionBlock = nil;
        _operation = operation;
        _dependencies = [[NSMutableArray alloc] initWithCapacity:2];
        _inverse_dependencies = [[NSMutableSet alloc] initWithCapacity:2];
        _dependencyLock = [[NSRecursiveLock alloc] init];
        _hasExecuted = NO;
        _state = XDOperationStateReady; //every operation starts ready until you add a depedency to make it not ready
        _cancelled = NO;
        _completionBlock = NULL;
        _threadPriority = 0.5;
        _queuePriority = XDOperationQueuePriorityNormal;
        _waiting_deps = 0;
        _effectivePriorityValue = 0;
        _queue = nil;
    }
    return self;
}

- (void)dealloc
{
    if (_state ==XDOperationStateExecuting)
    {
        DEBUG_BREAK();
    }
    [_inverse_dependencies release];
    _inverse_dependencies = nil;
    [_dependencies release];
    _dependencies = nil;
    [_dependencyLock release];
    _dependencyLock = nil;
    _operation = nil;
    [super dealloc];
}

- (BOOL)isReady
{
    //If the operation already started, it's not ready anymore. it will never be ready again.
    if (_state >= XDOperationStateExecuting || _cancelled)
    {
        return YES;
    }
    
    if (_waiting_deps >0)
    {
        return NO;
    }
    
    BOOL isReady = YES;
    
    //shouldn't need this but just in case someone didn't add dependencies currectly.
    [_dependencyLock lock];
    for (XDOperation *oper in _dependencies)
    {
        //if any of dependent operations are not cancelled and not finished then we cannot continue
        if ([oper isCancelled] == NO && [oper isFinished] == NO)
        {
            isReady = NO;
            break;
        }
    }
    [_dependencyLock unlock];
    return isReady;
}

- (BOOL)isExecuting
{
    return _state == XDOperationStateExecuting;
}

- (BOOL)isFinished
{
    return _state == XDOperationStateFinished;
}

- (BOOL)isCancelled
{
    return _cancelled;
}

- (void)cancel
{
    [_operation retain];
    if (!_cancelled)
    {
        BOOL sendReadyChanged = NO;
        [_operation willChangeValueForKey:@"isCancelled"];
        if (_state == XDOperationStateNotReady)
        {
            [_operation didChangeValueForKey:@"isReady"];
            sendReadyChanged = YES;
            //This will cause us to get ran so we can quickly return in our start method.
            _state = XDOperationStateReady;
        }
        _cancelled = YES;
        if (sendReadyChanged)
        {
            [_operation didChangeValueForKey:@"isReady"];
        }
        [_operation didChangeValueForKey:@"isCancelled"];
    }
    [_operation release];
}

- (double)threadPriority
{
    //TODO.. ignoring this.
    return _threadPriority;
}

- (void)setThreadPriority:(double)threadPriority
{
    //TODO.. ignoring this.
    _threadPriority = threadPriority;
}

- (void)addDependency:(XDOperation *)operation
{
    [_operation willChangeValueForKey:@"depedencies"];
    [_operation willChangeValueForKey:@"isReady"];
    [_dependencyLock lock];
    if ([_dependencies indexOfObjectIdenticalTo:operation] == NSNotFound)
    {
        [_dependencies addObject:operation];
        
        if (![operation isCancelled] && ![operation isFinished])
        {
            [operation._internal->_dependencyLock lock];
            //this operation will prevent us from being ready right now so we need to add our selves to their inverse depdencies so they can retain us until they finish.
            [operation._internal->_inverse_dependencies addObject:self];
            [operation._internal->_dependencyLock unlock];
            _waiting_deps++;
            _state = XDOperationStateNotReady;
        }
    }
    [_dependencyLock unlock];
    [_operation didChangeValueForKey:@"isReady"];
    [_operation didChangeValueForKey:@"depedencies"];
}

- (void)removeDependency:(XDOperation *)operation
{
    [_operation willChangeValueForKey:@"depedencies"];
    [_operation willChangeValueForKey:@"isReady"];
    [_dependencyLock lock];
    [_dependencies removeObjectIdenticalTo:operation];
    [_dependencyLock unlock];
    [operation._internal->_dependencyLock lock];
    if ([operation._internal->_inverse_dependencies member:self])
    {
        [operation._internal->_inverse_dependencies removeObject:self];
        _waiting_deps--;
    }
    [operation._internal->_dependencyLock unlock];
    [_operation didChangeValueForKey:@"isReady"];
    [_operation didChangeValueForKey:@"depedencies"];
}

- (void)start
{
    @autoreleasepool {
        [_operation retain];
        if ([_operation isExecuting])
        {
            [NSException raise:NSInvalidArgumentException format:@"Operation is already executing."];
            DEBUG_BREAK();
            [_operation release];
            return;
        }
        
        if (![_operation isReady])
        {
            [NSException raise:NSInvalidArgumentException format:@"Operation is not ready"];
            [_operation release];
            return;
        }
        
        if (_state != XDOperationStateExecuting)
        {
            [_operation willChangeValueForKey:@"isExecuting"];
            _state = XDOperationStateExecuting;
            [_operation didChangeValueForKey:@"isExecuting"];
        }
        
        //TODO.. set thread priority
        [_operation main];
        
        [_operation willChangeValueForKey:@"isFinished"];
        if (_state == XDOperationStateExecuting)
        {
            [_operation willChangeValueForKey:@"isExecuting"];
            _state = XDOperationStateFinished;
            [_operation didChangeValueForKey:@"isExecuting"];
        }
        else
        {
            //coming from unknown mode.. don't fire off KVO for isExecuting. It's possible the operation also unset it's own executing flag.
            _state = XDOperationStateFinished;
        }
        [_operation didChangeValueForKey:@"isFinished"];
        [_operation release];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == _operation)
    {
        [_operation retain]; //retain because our actions may cause it to go away.
        if ([keyPath isEqualToString:@"isFinished"])
        {
            if (![_operation isFinished])
            {
                //not acutally finished. why did you call me?
                [_operation release];
                return;
            }
            
            for (_XDOperationInternal *_opi in _inverse_dependencies)
            {
                if (_opi->_waiting_deps >= 2)
                {
                    _opi->_waiting_deps--;
                }
                else {
                    //if we are are going to remove the last depedency, lets do it after
                    //we are done so the is ready fires after we really have gone away overselves.
                    
                    //Magic number. just bigger then the quantom in the OS to force it happen in a second.
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,0), ^{
                        if (_opi->_state != XDOperationStateNotReady)
                            return;
                        //lets trigger off an isReady for them
                        
                        [_opi->_operation willChangeValueForKey:@"isReady"];
                        pthread_mutex_lock(&_XDOperationLock);
                        //in canceled situtations, it doesn't matter if this operation is waiting.
                        if (!_opi->_cancelled && _opi->_waiting_deps > 0) {
                            _opi->_waiting_deps--;
                        }
                        pthread_mutex_unlock(&_XDOperationLock);
                        [_opi->_operation didChangeValueForKey:@"isReady"];
                    });
                }
            }
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                pthread_mutex_lock(&_XDOperationLock);
                [_inverse_dependencies removeAllObjects];
                pthread_mutex_unlock(&_XDOperationLock);
            });
            
            //Let any one know that is doing a waitUntilFinished on us.
            pthread_mutex_lock(&_waitlock);
            _state = XDOperationStateFinished; // we are finished
            pthread_cond_broadcast(&_waitcondition);
            pthread_mutex_unlock(&_waitlock);
            
            
            pthread_mutex_lock(&_XDOperationLock);
            void (^block)(void) =[[_operation completionBlock] retain];
            pthread_mutex_unlock(&_XDOperationLock);
            if (block)
            {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    block();
                    [block release];
                });
            }
            dispatch_time_t val = dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_MSEC);
            [_queue retain];
            dispatch_after(val, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
                [_queue _removeFinishedOperation:self];
                [_queue release];
                //TODO: make call to remove this operation from the dispatch queue and re-run the queue scheduler.
            });
            
        }
        else if ([keyPath isEqualToString:@"isExecuting"])
        {
            pthread_mutex_lock(&_XDOperationLock);
            if (_state <= XDOperationStateExecuting && [_operation isExecuting])
            {
                _state = XDOperationStateExecuting;
            }
            pthread_mutex_unlock(&_XDOperationLock);
        }
        else if ([keyPath isEqualToString:@"isReady"])
        {
            pthread_mutex_lock(&_XDOperationLock);
            if (_state < XDOperationStateExecuting)
            {
                if ([_operation isReady])
                {
                    _state = XDOperationStateReady;
                    
                    [_queue _queueSchedulerRun];
                }
                else
                {
                    _state = XDOperationStateNotReady;
                }
            }
            pthread_mutex_unlock(&_XDOperationLock);
        }
        [_operation release];
    }
}

- (void (^)(void))completionBlock
{
    return _completionBlock;
}

- (void)setCompletionBlock:(void (^)(void))block
{
    [_operation willChangeValueForKey:@"completionBlock"];
    pthread_mutex_lock(&_XDOperationLock);
    if (block != _completionBlock)
    {
        Block_release(_completionBlock);
        _completionBlock = Block_copy(block);
    }
    pthread_mutex_unlock(&_XDOperationLock);
    [_operation didChangeValueForKey:@"completionBlock"];
}

- (XDOperationQueuePriority)queuePriority
{
    return _queuePriority;
}

- (void)setQueuePriority:(XDOperationQueuePriority)priority
{
    //CLAMPS!
    if (priority <= XDOperationQueuePriorityVeryLow)
    {
        _queuePriority = XDOperationQueuePriorityVeryLow;
    }
    else if (priority <= XDOperationQueuePriorityLow)
    {
        _queuePriority = XDOperationQueuePriorityLow;
    }
    else if (priority < XDOperationQueuePriorityHigh)
    {
        _queuePriority = XDOperationQueuePriorityNormal;
    }
    else if (priority < XDOperationQueuePriorityVeryHigh)
    {
        _queuePriority = XDOperationQueuePriorityHigh;
    }
    else
    {
        _queuePriority = XDOperationQueuePriorityVeryHigh;
    }
}

- (NSArray *)dependencies
{
    return [NSArray arrayWithArray:_dependencies];
}

- (void)waitUntilFinished
{
    if (_operation)
    {
        pthread_mutex_lock(&_waitlock);
        
        // Ensures thread actually waits
        while (![_operation isFinished])
        {
            pthread_cond_wait(&_waitcondition, &_waitlock);
        }
        
        pthread_mutex_unlock(&_waitlock);
        return;
    }
}

@end

static NSString const *XDOperationQueueKey = @"XDOperationQueue";

@implementation XDOperation

@synthesize _internal=_internal;

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    if ([key isEqualToString:@"isExecuting"] || [key isEqualToString:@"isReady"] || [key isEqualToString:@"isFinished"])
    {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _internal = [[_XDOperationInternal alloc] initWithOperation:self];
        
        [self addObserver:_internal
               forKeyPath:@"isExecuting"
                  options:(NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew)
                  context:NULL];
        [self addObserver:_internal
               forKeyPath:@"isReady"
                  options:(NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew)
                  context:NULL];
        [self addObserver:_internal
               forKeyPath:@"isFinished"
                  options:(NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew)
                  context:NULL];
        
    }
    return self;
}

- (void)dealloc {
    if (_internal->_state == XDOperationStateExecuting)
    {
        DEBUG_BREAK();
    }
    [self removeObserver:_internal forKeyPath:@"isExecuting"];
    [self removeObserver:_internal forKeyPath:@"isReady"];
    [self removeObserver:_internal forKeyPath:@"isFinished"];
    _internal->_operation = nil;
    [_internal release];
    _internal = nil;
    [super dealloc];
}

/** KVO wrapped state properties property */

- (BOOL)isExecuting
{
    return [_internal isExecuting];
}

- (BOOL)isReady
{
    return [_internal isReady];
}

- (BOOL)isFinished
{
    return [_internal isFinished];
}

- (BOOL)isCancelled
{
    return [_internal isCancelled];
}

- (BOOL)isConcurrent
{
    //legacy. left around for 10.5 users.
    return NO;
}

/** depedencies */

- (void)addDependency:(XDOperation *)operation
{
    [_internal addDependency:operation];
}

- (void)removeDependency:(XDOperation *)operation
{
    [_internal removeDependency:operation];
}

- (NSArray *)dependencies
{
    return [_internal dependencies];
}

/** methods */

- (void)start
{
    [_internal start];
}

- (void)main
{
    // no-op base
}

- (void)cancel
{
    [_internal cancel];
}

- (void)waitUntilFinished
{
    [_internal waitUntilFinished];
}


/** completions */

- (void(^)(void))completionBlock
{
    return [_internal completionBlock];
}

- (void)setCompletionBlock:(void(^)(void))block
{
    [_internal setCompletionBlock:block];
}

/** priorities */

- (XDOperationQueuePriority)queuePriority
{
    return [_internal queuePriority];
}

- (void)setQueuePriority:(XDOperationQueuePriority)priority
{
    [_internal setQueuePriority:priority];
}

- (double)threadPriority
{
    return [_internal threadPriority];
}

- (void)setThreadPriority:(double)priority
{
    [_internal setThreadPriority:priority];
}

@end


@implementation _XDOperationQueueInternal

- (id)initWithName:(NSString *)name
{
    self = [super init];
    if (self)
    {
        _name = [name retain];
        _schedule_queue = dispatch_queue_create([_name UTF8String], DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    dispatch_release(_schedule_queue);
    _schedule_queue = NULL;
    [_name release];
    _name = nil;
    [super dealloc];
}

@end


@implementation XDOperationQueue

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@"operations"] ||
        [key isEqualToString:@"operationCount"] ||
        [key isEqualToString:@"maxConcurrentOperationCount"] ||
        [key isEqualToString:@"suspended"] ||
        [key isEqualToString:@"name"])
    {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}


+ (XDOperationQueue *)queueForThread:(NSThread *)thread
{
    NSMutableDictionary *threadDictionary = [thread threadDictionary];
    XDOperationQueue *queue = [threadDictionary objectForKey:XDOperationQueueKey];
    
    //Should not automagically create a new operation queue unless it's the mainQueue
    if (!queue && [thread isMainThread])
    {
        queue = [[XDOperationQueue alloc] init];
        if (queue)
        {
            //main queue is special. it runs it's ops on the main thread
            [threadDictionary setObject:queue forKey:XDOperationQueueKey];
            queue->_isMainQueue = YES;
            [queue setMaxConcurrentOperationCount:1];
            [queue setName:@"Main Operation Queue"];
        }
        [queue release];
    }
    return queue;
}

/** specifics */
+ (XDOperationQueue *)currentQueue
{
    return [self queueForThread:[NSThread currentThread]];
}

+ (XDOperationQueue *)mainQueue
{
    return [self queueForThread:[NSThread mainThread]];
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _name = [[NSString alloc] initWithFormat:@"XDOperationQueue %d",OSAtomicIncrement32(&_XDOperationQueueID)];
        _internal = [[_XDOperationQueueInternal alloc] initWithName:_name];
        pthread_mutexattr_init(&_mta);
        pthread_mutexattr_settype(&_mta, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_queuelock, &_mta);
        _suspended = NO;
        _pendingOperations = [[NSMutableArray alloc] initWithCapacity:5];
        _operationsToStart = [[NSMutableArray alloc] initWithCapacity:5];
        _operations = [[NSMutableArray alloc] initWithCapacity:5];
        _maxConcurrentOperationCount = XDOperationQueueDefaultMaxConcurrentOperationCount;
        _isMainQueue = NO;
    }
    return self;
}

- (void)dealloc
{
    pthread_mutex_lock(&_XDOperationLock);
    for (XDOperation *op in _pendingOperations)
    {
        op._internal->_queue = nil;
    }
    for (XDOperation *op in _operations)
    {
        op._internal->_queue = nil;
    }
    pthread_mutex_unlock(&_XDOperationLock);
    [_pendingOperations release];
    _pendingOperations = nil;
    [_operationsToStart release];
    _operationsToStart = nil;
    [_operations release];
    _operations = nil;
    [_name release];
    _name = nil;
    [_internal release];
    _internal = nil;
    pthread_mutex_destroy(&_queuelock);
    pthread_mutexattr_destroy(&_mta);
    [super dealloc];
}

- (NSString *)description
{
    pthread_mutex_lock(&_queuelock);
    NSString *desc = [NSString stringWithFormat:@"<XDOperationQueue name:\"%@\" executing:%u pending:%u >",_name,[_operations count],[_pendingOperations count]];
    pthread_mutex_unlock(&_queuelock);
    return desc;
}

/** manage */
- (void)addOperation:(XDOperation *)op
{
    if (op == nil)
    {
        return;
    }
    
    [op retain];
    pthread_mutex_lock(&_queuelock);
    if ([_pendingOperations indexOfObjectIdenticalTo:op] != NSNotFound)
    {
        pthread_mutex_unlock(&_queuelock);
        [op autorelease]; //Auto releasing so we can put the op in the log message but still raise from here.
        [NSException raise:NSInvalidArgumentException format:@"operation %@ is already in the queue", op];
        return;
    }
    pthread_mutex_unlock(&_queuelock);
    
    if (op._internal->_state >= XDOperationStateExecuting)
    {
        [op autorelease]; //Auto releasing so we can put the op in the log message but still raise from here.
        [NSException raise:NSInvalidArgumentException format:@"operation %@ has already started running", op];
        return;
    }
    
    if (op._internal->_queue != nil)
    {
        NSLog(@"operation %@ is already scheduled in another queue", op);
        XDOperationQueue *otherQueue = op._internal->_queue;
        //TODO.. if we can't aquire a lock, defer until later.
        pthread_mutex_lock(&(otherQueue->_queuelock));
        [otherQueue willChangeValueForKey:@"operationCount"];
        [otherQueue willChangeValueForKey:@"operations"];
        [otherQueue->_operations removeObjectIdenticalTo:op];
        [otherQueue->_pendingOperations removeObjectIdenticalTo:op];
        [otherQueue didChangeValueForKey:@"operations"];
        [otherQueue didChangeValueForKey:@"operationCount"];
        pthread_mutex_unlock(&(otherQueue->_queuelock));
    }
    
    op._internal->_queue = self;
    pthread_mutex_lock(&_queuelock);
    [self willChangeValueForKey:@"operationCount"];
    [self willChangeValueForKey:@"operations"];
    [_pendingOperations addObject:op];
    [self didChangeValueForKey:@"operations"];
    [self didChangeValueForKey:@"operationCount"];
    pthread_mutex_unlock(&_queuelock);
    [op release];
    
    if ([op isReady] && !_suspended)
    {
        [self _queueSchedulerRun];
    }
}

- (void)addOperations:(NSArray *)ops waitUntilFinished:(BOOL)wait
{
    for (XDOperation *op in ops)
    {
        [self addOperation:op];
    }
    if (wait)
    {
        for (XDOperation *op in ops)
        {
            [op waitUntilFinished];
        }
    }
}

- (void)addOperationWithBlock:(void (^)(void))block
{
    if (block == nil)
    {
        [NSException raise:NSInvalidArgumentException format:@"Cannot add nil block to operation queue"];
        return;
    }
    
    [self addOperation:[XDBlockOperation blockOperationWithBlock:block]];
}

- (NSArray *)operations
{
    pthread_mutex_lock(&_queuelock);
    NSMutableArray *operations = [NSMutableArray arrayWithArray:_operations];
    [operations addObjectsFromArray:_pendingOperations];
    pthread_mutex_unlock(&_queuelock);
    return operations;
}

- (NSUInteger)operationCount
{
    pthread_mutex_lock(&_queuelock);
    NSUInteger count = [_operations count] + [_pendingOperations count];
    pthread_mutex_unlock(&_queuelock);
    return count;
}

- (void)cancelAllOperations
{
    [self.operations makeObjectsPerformSelector:@selector(cancel) withObject:nil];
}

/*
 From what I can tell from the docs, this waits until the currently queued operations
 have finished at the time it's called. If someone adds from other threads after this call
 you ignore it.
 */
- (void)waitUntilAllOperationsAreFinished
{
    [self retain];
    for (XDOperation *operation in [self operations])
    {
        [operation waitUntilFinished];
    }
    [self release];
}

/** limits */

- (NSInteger)maxConcurrentOperationCount
{
    return _maxConcurrentOperationCount;
}

- (void)setMaxConcurrentOperationCount:(NSInteger)count
{
    [self willChangeValueForKey:@"maxConcurrentOperationCount"];
    if (_maxConcurrentOperationCount > count)
    {
        [self _queueSchedulerRun];
    }
    _maxConcurrentOperationCount = count;
    [self didChangeValueForKey:@"maxConcurrentOperationCount"];
}

/** suspending */
- (void)setSuspended:(BOOL)suspended
{
    if (_suspended != suspended)
    {
        [self willChangeValueForKey:@"suspended"];
        _suspended = suspended;
        if (!_suspended)
        {
            [self _queueSchedulerRun];
        }
        [self didChangeValueForKey:@"suspended"];
    }
}

- (BOOL)isSuspended
{
    return _suspended;
}

/** naming */
- (void)setName:(NSString *)name
{
    [self willChangeValueForKey:@"name"];
    if (![_name isEqual:name])
    {
        [_name release];
        _name = [name copy];
    }
    [self didChangeValueForKey:@"name"];
}

- (NSString *)name
{
    return [[_name retain] autorelease];
}


/** internal magic */

- (void)_removeFinishedOperation:(_XDOperationInternal *)opi
{
    if (opi->_state != XDOperationStateFinished)
    {
        return;
    }
    //just incase some takes an operation out of being finished after we queue up doing this.
    
    pthread_mutex_lock(&_queuelock);
    [self willChangeValueForKey:@"operationCount"];
    [self willChangeValueForKey:@"operations"];
    [_operations removeObjectIdenticalTo:opi->_operation];
    [self didChangeValueForKey:@"operations"];
    [self didChangeValueForKey:@"operationCount"];
    pthread_mutex_unlock(&_queuelock);
    [self _queueSchedulerRun];
}

//called when things need to happen.

- (void)_queueSchedulerRun
{
    [self retain];
    dispatch_async(_internal->_schedule_queue, ^{
        [self _schedulerRun];
        [self release];
    });
}

static NSComparisonResult compareOperationEffectivePriorities(id obj1, id obj2, void *context)
{
    XDOperation *op1 = (XDOperation *)obj1;
    XDOperation *op2 = (XDOperation *)obj2;
    NSArray *pendingOperations = (NSArray *)context;
    NSUInteger weightFactor = [pendingOperations count];
    NSInteger weight1 = op1._internal->_effectivePriorityValue + op1._internal->_queuePriority * weightFactor;
    NSInteger weight2 = op2._internal->_effectivePriorityValue + op2._internal->_queuePriority * weightFactor;
    if (weight1 < weight2)
    {
        return NSOrderedDescending;
    }
    else if (weight1 > weight2)
    {
        return NSOrderedAscending;
    }
    else
    {
        return NSOrderedSame;
    }
}

- (void)_sortPendingOperations {
    // _pendingOperations is assumed to be locked already
    const NSUInteger kMaxCount = 512;
    NSUInteger count = [_pendingOperations count];
    if (count <= 1) {
        return;
    }
    if (count > kMaxCount) {
        [_pendingOperations sortUsingFunction:&compareOperationEffectivePriorities context:_pendingOperations];
        return;
    }
    [_pendingOperations _mutate];
    NSRange range = NSMakeRange(0, count);
    id objs[kMaxCount];
    CFIndex indexes[kMaxCount];
    [_pendingOperations getObjects:objs range:range];
    id *pobjs = objs;
    CFSortIndexes(indexes, count, 0, ^(CFIndex i1, CFIndex i2) {
        return (CFComparisonResult)compareOperationEffectivePriorities(pobjs[i1], pobjs[i2], _pendingOperations);
    });
    assert(sizeof(id) == sizeof(CFIndex));
    for (int i = 0; i < count; i++) {
        indexes[i] = (CFIndex)objs[indexes[i]]; // re-use indexes allocation
    }
    [_pendingOperations replaceObjectsInRange:range withObjects:(id *)indexes count:count];
    return;
}

- (void)_schedulerRun {
    pthread_mutex_lock(&_queuelock);
    if (_suspended)
    {
        pthread_mutex_unlock(&_queuelock);
        return;
    }
    
    NSInteger operationsToAdd = NSIntegerMax;
    if (_maxConcurrentOperationCount != XDOperationQueueDefaultMaxConcurrentOperationCount)
    {
        operationsToAdd = _maxConcurrentOperationCount - [_operations count];
    }
    
    if (operationsToAdd > 0)
    {
        [self _sortPendingOperations];
        for (XDOperation *op in _pendingOperations)
        {
            if (operationsToAdd > 0 && op._internal->_state == XDOperationStateReady)
            {
                operationsToAdd--;
                [_operationsToStart addObject:op];
            }
            else if (operationsToAdd <= 0)
            {
                if (op._internal->_state == XDOperationStateReady)
                {
                    op._internal->_effectivePriorityValue++;
                }
            }
        }
        
        for (XDOperation *op in _operationsToStart)
        {
            [_pendingOperations removeObjectIdenticalTo:op];
            [_operations addObject:op];
            void (^start)(void) = ^{
                XDOperation *o = [op retain];
                NSMutableDictionary *threadDictionary = [[NSThread currentThread] threadDictionary];
                XDOperationQueue *previousValue = [threadDictionary objectForKey:XDOperationQueueKey];
                [threadDictionary setObject:self forKey:XDOperationQueueKey];
                //Lets get to work.
                [o start];
                //if the operation is not finished then they must have subclassed and replaced start. Finish will come later.
                //if the operation is finished, but KVO didn't fire to let the internal know, lets make sure we catch this to remove the operation
                if ([o isFinished] && o._internal->_state != XDOperationStateFinished)
                {
                    [o._internal observeValueForKeyPath:@"isFinished" ofObject:o change:nil context:nil];
                }
                
                if (!previousValue)
                {
                    [threadDictionary removeObjectForKey:XDOperationQueueKey];
                }
                else
                {
                    [threadDictionary setObject:previousValue forKey:XDOperationQueueKey];
                }
                [op release];
            };
            
            if (_isMainQueue)
            {
                dispatch_async(dispatch_get_main_queue(), start);
            }
            else
            {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), start);
            }
        }
        [_operationsToStart removeAllObjects];
    }
    
    pthread_mutex_unlock(&_queuelock);
}
@end

@implementation XDInvocationOperation {
    NSInvocation *_inv;
}

- (id)initWithTarget:(id)target selector:(SEL)sel object:(id)arg
{
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (sig != nil)
    {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        if ([sig numberOfArguments] > 2)
        {
            [inv setArgument:&arg atIndex:2];
        }
        return [self initWithInvocation:inv];
    }
    else
    {
        DEBUG_LOG("Invalid method signature for selector %s", sel_getName(sel));
        [self release];
        return nil;
    }
}

- (id)initWithInvocation:(NSInvocation *)inv
{
    self = [super init];
    if (self)
    {
        _inv = [inv retain];
        [inv retainArguments];
    }
    return self;
}

- (void)dealloc
{
    [_inv release];
    _inv = nil;
    [super dealloc];
}

- (NSInvocation *)invocation
{
    return (NSInvocation *)_inv;
}

- (void)main
{
    [(NSInvocation *)_inv invoke];
}

- (id)result
{
    id result = nil;
    [(NSInvocation *)_inv getReturnValue:&result];
    return result;
}

@end

@implementation XDBlockOperation {
    dispatch_block_t _block;
    NSMutableArray *_blocks;
}

- (id)initWithBlock:(void (^)(void))block
{
    if (block == NULL)
    {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"block is nil"];
        return nil;
    }
    
    self = [super init];
    if (self)
    {
        _block = Block_copy(block);
    }
    return self;
}

- (void)dealloc
{
    [_blocks release];
    _blocks = NULL;
    
    if (_block != NULL)
    {
        Block_release(_block);
    }
    
    [super dealloc];
}

+ (id)blockOperationWithBlock:(void (^)(void))block
{
    return [[[self alloc] initWithBlock:block] autorelease];
}

- (void)addExecutionBlock:(void (^)(void))block
{
    if (block == NULL)
    {
        [NSException raise:NSInvalidArgumentException format:@"block is nil"];
        return;
    }
    
    void (^item)() = Block_copy(block);
    @synchronized(self)
    {
        if (_blocks == nil)
        {
            _blocks = [[NSMutableArray alloc] init];
        }
        [_blocks addObject:item];
    }
    Block_release(item);
}

- (NSArray *)executionBlocks
{
    NSMutableArray *blocks = [[NSMutableArray alloc] init];
    @synchronized(self)
    {
        if (_block != nil)
        {
            [blocks addObject:_block];
        }
        if (_blocks != nil)
        {
            [blocks addObjectsFromArray:_blocks];
        }
    }
    
    return [blocks autorelease];
}

- (void)main
{
    dispatch_block_t block = NULL;
    
    @synchronized(self)
    {
        if (_block != NULL)
        {
            block = Block_copy(_block);
        }
    }
    
    if (block != NULL)
    {
        block();
        Block_release(block);
    }
    
    NSUInteger count = 0;
    dispatch_block_t *blocks = NULL;
    
    @synchronized(self)
    {
        count = [_blocks count];
        if (count > 0)
        {
            blocks = malloc(sizeof(dispatch_block_t) * count);
            if (blocks != NULL)
            {
                [_blocks getObjects:(id *)blocks range:NSMakeRange(0, count)];
                for (NSUInteger i = 0; i < count; i++)
                {
                    blocks[i] = Block_copy(blocks[i]);
                }
            }
        }
    }
    
    if (blocks != NULL)
    {
        for (NSUInteger i = 0; i < count; i++)
        {
            blocks[i]();
            Block_release(blocks[i]);
        }
        
        free(blocks);
    }
}

@end