/*
 * Copyright (C) 2009-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2021 Apple Inc. All rights reserved.
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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
#import "cocoa/WebCoreANGLECocoa.h"

#if ENABLE(WEBGL)

#import "Logging.h"
#import <pal/spi/cf/CoreVideoSPI.h>
#import <wtf/StdLibExtras.h>
#import <wtf/Vector.h>
#import <wtf/darwin/WeakLinking.h>
#import <wtf/text/StringCommon.h>

// FIXME: Checking for EGL_Initialize does not seem to be robust in recovery OS.
WTF_WEAK_LINK_FORCE_IMPORT(EGL_GetPlatformDisplayEXT);
WTF_WEAK_LINK_FORCE_IMPORT(EGL_Initialize);

static const char* const enabledANGLEMetalFeatures[] = {
    "ensureLoopForwardProgress",
    nullptr
};

static const char* const disabledANGLEMetalFeatures[] = {
    "enableInMemoryMtlLibraryCache", // This would leak all program binary objects.
    "alwaysPreferStagedTextureUploads", // This would timeout tests due to excess staging buffer allocations and fail tests on MacPro.
    "injectAsmStatementIntoLoopBodies", // Replaced by ensureLoopForwardProgress.
    nullptr
};

bool ANGLECocoa::isAvailable()
{
    // The ANGLE is weak linked in full, and the EGL_Initialize is explicitly weak linked above
    // so that we can detect the case where ANGLE is not present.
    return EGL_Initialize != NULL; // NOLINT
}

ANGLEDisplay ANGLECocoa::getMetalDisplay(uint8_t powerPreference, uint64_t gpuID, EGLAttrib displayKey)
{
    // FIXME(http://webkit.org/b/238448): Why is checking EGL_Initialize not robust in recovery OS?
    if (EGL_GetPlatformDisplayEXT == NULL) { // NOLINT
        WTFLogAlways("Inconsistent weak linking for ANGLE shared library.");
        return { };
    }

#if ASSERT_ENABLED
    auto clientExtensions = WTF::unsafeSpan(EGL_QueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS));
    ASSERT(clientExtensions.data());
#endif

    Vector<EGLAttrib> displayAttributes;
    displayAttributes.append(EGL_PLATFORM_ANGLE_TYPE_ANGLE);
    displayAttributes.append(EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE);
    // These properties are defined for EGL_ANGLE_power_preference as EGLContext attributes,
    // but Metal backend uses EGLDisplay attributes.
    if (powerPreference == 2) {
        displayAttributes.append(EGL_POWER_PREFERENCE_ANGLE);
        displayAttributes.append(EGL_HIGH_POWER_ANGLE);
    } else if (powerPreference == 1) {
        displayAttributes.append(EGL_POWER_PREFERENCE_ANGLE);
        displayAttributes.append(EGL_LOW_POWER_ANGLE);
    }
#if PLATFORM(MAC)
    else if (gpuID) {
        ASSERT(WTF::contains(clientExtensions, "EGL_ANGLE_platform_angle_device_id"_span));
        // EGL_PLATFORM_ANGLE_DEVICE_ID_*_ANGLE is the IOKit registry id on EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE.
        displayAttributes.append(EGL_PLATFORM_ANGLE_DEVICE_ID_HIGH_ANGLE);
        displayAttributes.append(static_cast<EGLAttrib>(gpuID >> 32));
        displayAttributes.append(EGL_PLATFORM_ANGLE_DEVICE_ID_LOW_ANGLE);
        displayAttributes.append(static_cast<EGLAttrib>(gpuID));
    }
#else
    UNUSED_PARAM(gpuID);
#endif
    ASSERT(WTF::contains(clientExtensions, "EGL_ANGLE_feature_control"_span));
    displayAttributes.append(EGL_FEATURE_OVERRIDES_DISABLED_ANGLE);
    displayAttributes.append(reinterpret_cast<EGLAttrib>(disabledANGLEMetalFeatures));
    displayAttributes.append(EGL_FEATURE_OVERRIDES_ENABLED_ANGLE);
    displayAttributes.append(reinterpret_cast<EGLAttrib>(enabledANGLEMetalFeatures));
    displayAttributes.append(EGL_PLATFORM_ANGLE_DISPLAY_KEY_ANGLE);
    displayAttributes.append(displayKey);
    displayAttributes.append(EGL_NONE);

    return ANGLEDisplay { EGL_GetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY), displayAttributes.span().data()) };
}

ANGLEContext ANGLECocoa::createWebGLContext(ANGLEDisplay display, ANGLEConfig config, bool isWebGL2, uint32_t ownershipIdentity)
{
    Vector<EGLint> attributes;
    if (isWebGL2) {
        attributes.append(EGL_CONTEXT_CLIENT_VERSION);
        attributes.append(3);
    } else {
        attributes.append(EGL_CONTEXT_CLIENT_VERSION);
        attributes.append(2);
        // ANGLE will upgrade the context to ES3 automatically unless this is specified.
        attributes.append(EGL_CONTEXT_OPENGL_BACKWARDS_COMPATIBLE_ANGLE);
        attributes.append(EGL_FALSE);
    }
    attributes.append(EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE);
    attributes.append(EGL_TRUE);

    // WebGL requires that all resources are cleared at creation.
    attributes.append(EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE);
    attributes.append(EGL_TRUE);

    // Report GPU resets, so that the context can be lost when the GPU resets.
    attributes.append(EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT);
    attributes.append(EGL_LOSE_CONTEXT_ON_RESET_EXT);

    // WebGL doesn't allow client arrays.
    attributes.append(EGL_CONTEXT_CLIENT_ARRAYS_ENABLED_ANGLE);
    attributes.append(EGL_FALSE);
    // WebGL doesn't allow implicit creation of objects on bind.
    attributes.append(EGL_CONTEXT_BIND_GENERATES_RESOURCE_CHROMIUM);
    attributes.append(EGL_FALSE);

#if HAVE(TASK_IDENTITY_TOKEN)
    if (ownershipIdentity) {
        auto displayExtensions = WTF::unsafeSpan(EGL_QueryString(display.get(), EGL_EXTENSIONS));
        if (WTF::contains(displayExtensions, "EGL_ANGLE_metal_create_context_ownership_identity"_span)) {
            attributes.append(EGL_CONTEXT_METAL_OWNERSHIP_IDENTITY_ANGLE);
            attributes.append(ownershipIdentity);
        }
    }
#else
    UNUSED_PARAM(ownershipIdentity);
#endif

    attributes.append(EGL_NONE);
    return ANGLEContext { EGL_CreateContext(display.get(), config.get(), EGL_NO_CONTEXT, attributes.span().data()) };
}

#if HAVE(COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES)
OSType ANGLECocoa::agx420YpCbCr8BiPlanarVideoRange()
{
    return kCVPixelFormatType_AGX_420YpCbCr8BiPlanarVideoRange;
}

OSType ANGLECocoa::agx420YpCbCr8BiPlanarFullRange()
{
    return kCVPixelFormatType_AGX_420YpCbCr8BiPlanarFullRange;
}
#endif

#endif
