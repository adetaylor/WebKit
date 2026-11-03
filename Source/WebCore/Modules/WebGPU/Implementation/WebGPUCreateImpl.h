/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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

#if HAVE(WEBGPU_IMPLEMENTATION)

#include <WebCore/WebGPU.h>
#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/RefPtr.h>

namespace WebCore {

class ProcessIdentity;
struct WebGPUExternalImageSource;
struct WebGPUExternalTextureDescriptor;

// Runs a work item on the thread that the WebGPU objects call back on.
using WebGPUScheduleWorkFunction = Function<void(Function<void()>&&)>;
WEBCORE_EXPORT RefPtr<WebGPUIntegration> createWebGPUIntegration(WebGPUScheduleWorkFunction&&, const ProcessIdentity*);

// The WebGPU implementation's forms of a source and a descriptor that name WebCore objects, as the integration that
// createWebGPUIntegration() makes passes them on. std::nullopt if the source has nothing to copy.
WEBCORE_EXPORT std::optional<::WebGPU::ImageCopyExternalImage> backingImageCopyExternalImage(const WebGPUExternalImageSource&);
WEBCORE_EXPORT ::WebGPU::ExternalTextureDescriptor backingExternalTextureDescriptor(const WebGPUExternalTextureDescriptor&);

} // namespace WebCore

#endif // HAVE(WEBGPU_IMPLEMENTATION)
