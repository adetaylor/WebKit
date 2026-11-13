/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>

#if ENABLE(THREADING_LIBDISPATCH)

#include <wtf/Compiler.h>
#include <wtf/darwin/DispatchExtras.h>

namespace WebCore {

// Calls job(0) ... job(count - 1) concurrently and returns once they have all finished. They run on the default-priority
// global queue, as WTF::ParallelJobs and ConcurrentWorkQueue::apply run theirs with libdispatch; Swift's
// DispatchQueue.concurrentPerform takes no queue and uses the caller's QoS. Swift imports `job` as a non-escaping closure
// that isn't Sendable: ParallelRows.swift calls this only through a wrapper that takes a @Sendable one.
inline void dispatchParallelRowJobs(size_t count, NOESCAPE void (^job)(size_t))
{
    dispatch_apply(count, globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), job);
}

} // namespace WebCore

#endif // ENABLE(THREADING_LIBDISPATCH)
