/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#include <atomic>
#include <utility>
#include <wtf/SwiftBridging.h>

namespace WebKit {

// A request that keeps the GPU process's rendering resources, which are freed a while after the last request ends. With the
// CG renderer in Swift, ScopedRenderingResourcesRequest.swift frees them.
class SWIFT_PRIVATE_FILEID("WebKit/ScopedRenderingResourcesRequest.swift") ScopedRenderingResourcesRequest {
public:
    ScopedRenderingResourcesRequest() = default;
    ScopedRenderingResourcesRequest(ScopedRenderingResourcesRequest&& other)
        : m_requested(std::exchange(other.m_requested, false))
    {
    }
    ~ScopedRenderingResourcesRequest()
    {
        reset();
    }
    ScopedRenderingResourcesRequest& operator=(ScopedRenderingResourcesRequest&& other)
    {
        if (this != &other) {
            reset();
            m_requested = std::exchange(other.m_requested, false);
        }
        return *this;
    }
    bool isRequested() const { return m_requested; }
    void reset()
    {
        if (!std::exchange(m_requested, false))
            return;
        ASSERT(s_requests);
        --s_requests;
        if (!s_requests)
            scheduleFreeRenderingResources();
    }
    static ScopedRenderingResourcesRequest acquire()
    {
        return { DidRequest };
    }
private:
#if PLATFORM(COCOA)
    static void scheduleFreeRenderingResources();
    static void freeRenderingResources();
    // Purges the Metal devices, catching the Objective-C exceptions they may throw.
    static void purgeDevices();
#else
    static void scheduleFreeRenderingResources() { }
    static void freeRenderingResources() { }
#endif
    enum RequestState { DidRequest };
    ScopedRenderingResourcesRequest(RequestState)
        : m_requested(true)
    {
        ++s_requests;
    }
    static inline std::atomic<unsigned> s_requests;
    bool m_requested { false };
    friend bool hasOutstandingRenderingResourceUsage();
};

inline bool hasOutstandingRenderingResourceUsage()
{
    return ScopedRenderingResourcesRequest::s_requests;
}

}
