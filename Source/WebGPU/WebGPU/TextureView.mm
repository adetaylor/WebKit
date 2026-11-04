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
#import "TextureView.h"

#import "APIConversions.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Texture.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPUSwift::TextureViewImpl) == sizeof(void*) && alignof(WebGPUSwift::TextureViewImpl) == alignof(void*));

WTF_MAKE_TZONE_ALLOCATED_IMPL(TextureView);

Ref<TextureView> TextureView::create(const WebGPUSwift::TextureViewImpl& impl)
{
    return adoptRef(*new TextureView(impl));
}

Ref<TextureView> TextureView::createInvalid(Texture& texture, Device& device)
{
    return create(makeInvalidTextureViewImpl(texture.swiftImpl(), &device));
}

TextureView::TextureView(const WebGPUSwift::TextureViewImpl& impl)
{
    new (m_impl) WebGPUSwift::TextureViewImpl(impl);
}

TextureView::~TextureView()
{
    std::destroy_at(&swiftImpl());
}

WebGPUSwift::TextureViewImpl& TextureView::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPUSwift::TextureViewImpl*>(const_cast<std::byte*>(m_impl)));
}

void TextureView::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

bool TextureView::isValid() const
{
    return swiftImpl().isValid();
}

} // namespace WebGPU::Metal
