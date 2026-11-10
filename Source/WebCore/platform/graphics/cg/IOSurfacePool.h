/*
 * Copyright (C) 2013, 2014 Apple Inc. All rights reserved.
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
#if HAVE(IOSURFACE)

#include <WebCore/IOSurface.h>
#include <WebCore/IntSize.h>
#include <WebCore/IntSizeHash.h>
#include <wtf/Deque.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {

class ColorSpace;

// A facade over IOSurfacePoolCore (IOSurface.swift), which holds the pool and implements it, for callers in C++.
class SWIFT_PRIVATE_FILEID("WebCore/IOSurface.swift") IOSurfacePool : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<IOSurfacePool> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(IOSurfacePool, WEBCORE_EXPORT);
    WTF_MAKE_NONCOPYABLE(IOSurfacePool);
    friend class LazyNeverDestroyed<IOSurfacePool>;
    friend class IOSurface;
    friend class ImageBufferSurface;

public:
    WEBCORE_EXPORT static IOSurfacePool& sharedPoolSingleton();
    WEBCORE_EXPORT static Ref<IOSurfacePool> create();

    WEBCORE_EXPORT ~IOSurfacePool();

    WEBCORE_EXPORT std::unique_ptr<IOSurface> takeSurface(IntSize, const ColorSpace&, IOSurface::Format, UseLosslessCompression);
    WEBCORE_EXPORT void addSurface(std::unique_ptr<IOSurface>&&);

    WEBCORE_EXPORT void discardAllSurfaces();

    WEBCORE_EXPORT void setPoolSize(size_t);

private:
    IOSurfacePool();

    // A +1 reference to the IOSurfacePoolCore.
    const uintptr_t m_swiftState;
};

}
#endif // HAVE(IOSURFACE)
