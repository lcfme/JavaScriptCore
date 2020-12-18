/*
 * Copyright (C) 2013-2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"

#import "JavaScriptCore.h"

#if JSC_OBJC_API_ENABLED

#import "APICast.h"
#import "DFGWorklist.h"
#import "JSManagedValueInternal.h"
#import "JSVirtualMachineInternal.h"
#import "JSVirtualMachinePrivate.h"
#import "JSWrapperMap.h"
#import "SigillCrashAnalyzer.h"
#import "SlotVisitorInlines.h"
#import <mutex>
#import <wtf/BlockPtr.h>
#import <wtf/Lock.h>
#import <wtf/RetainPtr.h>

static NSMapTable *globalWrapperCache = 0;

static Lock wrapperCacheMutex;

static void initWrapperCache()
{
    ASSERT(!globalWrapperCache);
    NSPointerFunctionsOptions keyOptions = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality;
    NSPointerFunctionsOptions valueOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality;
    globalWrapperCache = [[NSMapTable alloc] initWithKeyOptions:keyOptions valueOptions:valueOptions capacity:0];
}

static NSMapTable *wrapperCache()
{
    if (!globalWrapperCache)
        initWrapperCache();
    return globalWrapperCache;
}

@interface JSVMWrapperCache : NSObject
+ (void)addWrapper:(JSVirtualMachine *)wrapper forJSContextGroupRef:(JSContextGroupRef)group;
+ (JSVirtualMachine *)wrapperForJSContextGroupRef:(JSContextGroupRef)group;
@end

@implementation JSVMWrapperCache

+ (void)addWrapper:(JSVirtualMachine *)wrapper forJSContextGroupRef:(JSContextGroupRef)group
{
    std::lock_guard<Lock> lock(wrapperCacheMutex);
    NSMapInsert(wrapperCache(), group, (__bridge void*)wrapper);
}

+ (JSVirtualMachine *)wrapperForJSContextGroupRef:(JSContextGroupRef)group
{
    std::lock_guard<Lock> lock(wrapperCacheMutex);
    return (__bridge JSVirtualMachine *)NSMapGet(wrapperCache(), group);
}

@end

@implementation JSVirtualMachine {
    JSContextGroupRef m_group;
    Lock m_externalDataMutex;
    NSMapTable *m_contextCache;
    NSMapTable *m_externalObjectGraph;
    NSMapTable *m_externalRememberedSet;
}

- (instancetype)init
{
    JSContextGroupRef group = JSContextGroupCreate();
    self = [self initWithContextGroupRef:group];
    // The extra JSContextGroupRetain is balanced here.
    JSContextGroupRelease(group);
    return self;
}

- (instancetype)initWithContextGroupRef:(JSContextGroupRef)group
{
    self = [super init];
    if (!self)
        return nil;
    
    m_group = JSContextGroupRetain(group);
    
    NSPointerFunctionsOptions keyOptions = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality;
    NSPointerFunctionsOptions valueOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality;
    m_contextCache = [[NSMapTable alloc] initWithKeyOptions:keyOptions valueOptions:valueOptions capacity:0];
    
    NSPointerFunctionsOptions weakIDOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality;
    NSPointerFunctionsOptions strongIDOptions = NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPersonality;
    m_externalObjectGraph = [[NSMapTable alloc] initWithKeyOptions:weakIDOptions valueOptions:strongIDOptions capacity:0];

    NSPointerFunctionsOptions integerOptions = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality;
    m_externalRememberedSet = [[NSMapTable alloc] initWithKeyOptions:weakIDOptions valueOptions:integerOptions capacity:0];
   
    [JSVMWrapperCache addWrapper:self forJSContextGroupRef:group];
 
    return self;
}

- (void)dealloc
{
    JSContextGroupRelease(m_group);
    [m_contextCache release];
    [m_externalObjectGraph release];
    [m_externalRememberedSet release];
    [super dealloc];
}

static id getInternalObjcObject(id object)
{
    if ([object isKindOfClass:[JSManagedValue class]]) {
        JSValue* value = [static_cast<JSManagedValue *>(object) value];
        if (!value)
            return nil;
        id temp = tryUnwrapObjcObject([value.context JSGlobalContextRef], [value JSValueRef]);
        if (temp)
            return temp;
        return object;
    }
    
    if ([object isKindOfClass:[JSValue class]]) {
        JSValue *value = static_cast<JSValue *>(object);
        object = tryUnwrapObjcObject([value.context JSGlobalContextRef], [value JSValueRef]);
    }

    return object;
}

- (bool)isOldExternalObject:(id)object
{
    JSC::VM* vm = toJS(m_group);
    return vm->heap.collectorSlotVisitor().containsOpaqueRoot((__bridge void*)object);
}

- (void)addExternalRememberedObject:(id)object
{
    auto locker = holdLock(m_externalDataMutex);
    ASSERT([self isOldExternalObject:object]);
    [m_externalRememberedSet setObject:@YES forKey:object];
}

- (void)addManagedReference:(id)object withOwner:(id)owner
{    
    if ([object isKindOfClass:[JSManagedValue class]])
        [object didAddOwner:owner];
        
    object = getInternalObjcObject(object);
    owner = getInternalObjcObject(owner);
    
    if (!object || !owner)
        return;
    
    JSC::JSLockHolder locker(toJS(m_group));
    if ([self isOldExternalObject:owner] && ![self isOldExternalObject:object])
        [self addExternalRememberedObject:owner];
 
    auto externalDataMutexLocker = holdLock(m_externalDataMutex);
    RetainPtr<NSMapTable> ownedObjects = [m_externalObjectGraph objectForKey:owner];
    if (!ownedObjects) {
        NSPointerFunctionsOptions weakIDOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality;
        NSPointerFunctionsOptions integerOptions = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality;
        ownedObjects = adoptNS([[NSMapTable alloc] initWithKeyOptions:weakIDOptions valueOptions:integerOptions capacity:1]);

        [m_externalObjectGraph setObject:ownedObjects.get() forKey:owner];
    }

    size_t count = reinterpret_cast<size_t>(NSMapGet(ownedObjects.get(), (__bridge void*)object));
    NSMapInsert(ownedObjects.get(), (__bridge void*)object, reinterpret_cast<void*>(count + 1));
}

- (void)removeManagedReference:(id)object withOwner:(id)owner
{
    if ([object isKindOfClass:[JSManagedValue class]])
        [object didRemoveOwner:owner];

    object = getInternalObjcObject(object);
    owner = getInternalObjcObject(owner);
    
    if (!object || !owner)
        return;
    
    JSC::JSLockHolder locker(toJS(m_group));
    
    auto externalDataMutexLocker = holdLock(m_externalDataMutex);
    NSMapTable *ownedObjects = [m_externalObjectGraph objectForKey:owner];
    if (!ownedObjects)
        return;
   
    size_t count = reinterpret_cast<size_t>(NSMapGet(ownedObjects, (__bridge void*)object));
    if (count > 1) {
        NSMapInsert(ownedObjects, (__bridge void*)object, reinterpret_cast<void*>(count - 1));
        return;
    }
    
    if (count == 1)
        NSMapRemove(ownedObjects, (__bridge void*)object);

    if (![ownedObjects count]) {
        [m_externalObjectGraph removeObjectForKey:owner];
        [m_externalRememberedSet removeObjectForKey:owner];
    }
}

@end

@implementation JSVirtualMachine(Internal)

JSContextGroupRef getGroupFromVirtualMachine(JSVirtualMachine *virtualMachine)
{
    return virtualMachine->m_group;
}

+ (JSVirtualMachine *)virtualMachineWithContextGroupRef:(JSContextGroupRef)group
{
    JSVirtualMachine *virtualMachine = [JSVMWrapperCache wrapperForJSContextGroupRef:group];
    if (!virtualMachine)
        virtualMachine = [[[JSVirtualMachine alloc] initWithContextGroupRef:group] autorelease];
    return virtualMachine;
}

- (JSContext *)contextForGlobalContextRef:(JSGlobalContextRef)globalContext
{
    return (__bridge JSContext *)NSMapGet(m_contextCache, globalContext);
}

- (void)addContext:(JSContext *)wrapper forGlobalContextRef:(JSGlobalContextRef)globalContext
{
    NSMapInsert(m_contextCache, globalContext, (__bridge void*)wrapper);
}

- (Lock&)externalDataMutex
{
    return m_externalDataMutex;
}

- (NSMapTable *)externalObjectGraph
{
    return m_externalObjectGraph;
}

- (NSMapTable *)externalRememberedSet
{
    return m_externalRememberedSet;
}

- (void)shrinkFootprintWhenIdle
{
    JSC::VM* vm = toJS(m_group);
    JSC::JSLockHolder locker(vm);
    vm->shrinkFootprintWhenIdle();
}

#if ENABLE(DFG_JIT)

+ (NSUInteger)setNumberOfDFGCompilerThreads:(NSUInteger)numberOfThreads
{
    JSC::DFG::Worklist* worklist = JSC::DFG::existingGlobalDFGWorklistOrNull();
    if (worklist)
        return worklist->setNumberOfThreads(numberOfThreads, JSC::Options::priorityDeltaOfDFGCompilerThreads());
    else
        return JSC::DFG::setNumberOfDFGCompilerThreads(numberOfThreads);
}

+ (NSUInteger)setNumberOfFTLCompilerThreads:(NSUInteger)numberOfThreads
{
    JSC::DFG::Worklist* worklist = JSC::DFG::existingGlobalFTLWorklistOrNull();
    if (worklist)
        return worklist->setNumberOfThreads(numberOfThreads, JSC::Options::priorityDeltaOfFTLCompilerThreads());
    else
        return JSC::DFG::setNumberOfFTLCompilerThreads(numberOfThreads);
}

#endif // ENABLE(DFG_JIT)

- (JSContextGroupRef)JSContextGroupRef
{
    return m_group;
}

- (BOOL)isWebThreadAware
{
    JSC::VM* vm = toJS(m_group);
    return vm->apiLock().isWebThreadAware();
}

+ (void)setCrashOnVMCreation:(BOOL)shouldCrash
{
    JSC::VM::setCrashOnVMCreation(shouldCrash);
}

@end

static void scanExternalObjectGraph(JSC::VM& vm, JSC::SlotVisitor& visitor, void* root, bool lockAcquired)
{
    @autoreleasepool {
        JSVirtualMachine *virtualMachine = [JSVMWrapperCache wrapperForJSContextGroupRef:toRef(&vm)];
        if (!virtualMachine)
            return;
        NSMapTable *externalObjectGraph = [virtualMachine externalObjectGraph];
        Lock& externalDataMutex = [virtualMachine externalDataMutex];
        Vector<void*> stack;
        stack.append(root);
        while (!stack.isEmpty()) {
            void* nextRoot = stack.last();
            stack.removeLast();
            if (!visitor.addOpaqueRoot(nextRoot))
                continue;

            auto appendOwnedObjects = [&] {
                NSMapTable *ownedObjects = [externalObjectGraph objectForKey:(__bridge id)nextRoot];
                for (id ownedObject in ownedObjects)
                    stack.append((__bridge void*)ownedObject);
            };

            if (lockAcquired)
                appendOwnedObjects();
            else {
                auto locker = holdLock(externalDataMutex);
                appendOwnedObjects();
            }
        }
    }
}

void scanExternalObjectGraph(JSC::VM& vm, JSC::SlotVisitor& visitor, void* root)
{
    bool lockAcquired = false;
    scanExternalObjectGraph(vm, visitor, root, lockAcquired);
}

void scanExternalRememberedSet(JSC::VM& vm, JSC::SlotVisitor& visitor)
{
    @autoreleasepool {
        JSVirtualMachine *virtualMachine = [JSVMWrapperCache wrapperForJSContextGroupRef:toRef(&vm)];
        if (!virtualMachine)
            return;
        Lock& externalDataMutex = [virtualMachine externalDataMutex];
        auto locker = holdLock(externalDataMutex);
        NSMapTable *externalObjectGraph = [virtualMachine externalObjectGraph];
        NSMapTable *externalRememberedSet = [virtualMachine externalRememberedSet];
        for (id key in externalRememberedSet) {
            NSMapTable *ownedObjects = [externalObjectGraph objectForKey:key];
            bool lockAcquired = true;
            for (id ownedObject in ownedObjects)
                scanExternalObjectGraph(vm, visitor, (__bridge void*)ownedObject, lockAcquired);
        }
        [externalRememberedSet removeAllObjects];
    }
}

#endif // JSC_OBJC_API_ENABLED
