/*
 * Copyright (C) 2019-2020 Apple Inc. All rights reserved.
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

#pragma once

#include "OptionsList.h"
#include <wtf/PtrTag.h>
#include <wtf/StdLibExtras.h>

namespace JSC {

class ExecutableAllocator;
class FixedVMPoolExecutableAllocator;
class VM;

#if CPU(ARM64) || PLATFORM(WATCHOS)
constexpr size_t PageSize = 16 * KB;
#else
constexpr size_t PageSize = 4 * KB;
#endif

constexpr size_t ConfigSizeToProtect = PageSize;

#if ENABLE(SEPARATED_WX_HEAP)
using JITWriteSeparateHeapsFunction = void (*)(off_t, const void*, size_t);
#endif

struct Config {
    JS_EXPORT_PRIVATE static void disableFreezingForTesting();
    JS_EXPORT_PRIVATE static void enableRestrictedOptions();
    JS_EXPORT_PRIVATE static void permanentlyFreeze();

    static void configureForTesting()
    {
        disableFreezingForTesting();
        enableRestrictedOptions();
    }

    union {
        struct {
            // All the fields in this struct should be chosen such that their
            // initial value is 0 / null / falsy because Config is instantiated
            // as a global singleton.

            bool isPermanentlyFrozen;
            bool disabledFreezingForTesting;
            bool restrictedOptionsEnabled;
            bool jitDisabled;

            // The following HasBeenCalled flags are for auditing call_once initialization functions.
            bool initializeThreadingHasBeenCalled;

            ExecutableAllocator* executableAllocator;
            FixedVMPoolExecutableAllocator* fixedVMPoolExecutableAllocator;
            void* startExecutableMemory;
            void* endExecutableMemory;
            uintptr_t startOfFixedWritableMemoryPool;

#if ENABLE(SEPARATED_WX_HEAP)
            JITWriteSeparateHeapsFunction jitWriteSeparateHeaps;
            bool useFastPermisionsJITCopy;
#endif

            OptionsStorage options;

            void (*shellTimeoutCheckCallback)(VM&);

            WTF::PtrTagLookup ptrTagLookupRecord;
        };
        char ensureSize[ConfigSizeToProtect];
    };
};

extern "C" alignas(PageSize) JS_EXPORT_PRIVATE Config g_jscConfig;

static_assert(sizeof(Config) == ConfigSizeToProtect, "");
static_assert(roundUpToMultipleOf<PageSize>(ConfigSizeToProtect) == ConfigSizeToProtect, "");

} // namespace JSC
