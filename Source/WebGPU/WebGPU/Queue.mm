/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#import "config.h"
#import "Queue.h"

#import "Buffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Texture.h"
#import <wtf/BlockPtr.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#endif

namespace WebGPU::Metal {

id<MTLBuffer> newBufferAliasingOwner(id<MTLDevice> device, const WebGPU::ByteOwner& owner, uint64_t offset, uint64_t length)
{
    auto bytes = owner.span();
    if (offset > bytes.size() || length > bytes.size() - offset)
        return nil;
    bytes = bytes.subspan(static_cast<size_t>(offset), static_cast<size_t>(length));
    // Metal reads the bytes in place until it destroys the buffer, and only then releases the deallocator, which holds
    // their owner. The buffer is only ever a copy source, so nothing writes to them.
    auto keepOwnerAlive = makeBlockPtr([protectedOwner = Ref { owner }](void*, NSUInteger) { });
    return [device newBufferWithBytesNoCopy:spanConstCast<uint8_t>(bytes).data() length:bytes.size() options:MTLResourceStorageModeShared deallocator:keepOwnerAlive.get()];
}

} // namespace WebGPU::Metal
