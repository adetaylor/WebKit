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

#import "config.h"
#import "IOSurfacePool.h"

#if HAVE(IOSURFACE)

#import "ColorSpace.h"
#import "ColorSpaceCG.h"
#import <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(IOSurfacePool);

IOSurfacePool::IOSurfacePool()
    : m_swiftState(IOSurface::createPoolSwiftState())
{
}

IOSurfacePool::~IOSurfacePool()
{
    IOSurface::destroyPoolSwiftState(m_swiftState);
}

IOSurfacePool& IOSurfacePool::sharedPoolSingleton()
{
    static LazyNeverDestroyed<IOSurfacePool> pool;
    static std::once_flag s_onceFlag;
    std::call_once(s_onceFlag, [] {
        pool.construct();
    });
    return pool;
}

Ref<IOSurfacePool> IOSurfacePool::create()
{
    return adoptRef(*new IOSurfacePool);
}

std::unique_ptr<IOSurface> IOSurfacePool::takeSurface(IntSize size, const ColorSpace& colorSpace, IOSurface::Format format, UseLosslessCompression useLosslessCompression)
{
    return IOSurface::adoptSwiftState(IOSurface::takePoolSurface(m_swiftState, size, protect(colorSpace.platformColorSpace()).get(), format, useLosslessCompression));
}

void IOSurfacePool::addSurface(std::unique_ptr<IOSurface>&& surface)
{
    auto facade = WTF::move(surface);
    if (!facade)
        return;
    IOSurface::addPoolSurface(m_swiftState, facade->releaseSwiftState());
}

void IOSurfacePool::setPoolSize(size_t poolSizeInBytes)
{
    IOSurface::setPoolSize(m_swiftState, poolSizeInBytes);
}

void IOSurfacePool::discardAllSurfaces()
{
    IOSurface::discardAllPoolSurfaces(m_swiftState);
}

}
#endif // HAVE(IOSURFACE)
