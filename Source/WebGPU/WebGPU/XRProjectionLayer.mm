/*
 * Copyright (c) 2024 Apple Inc. All rights reserved.
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
#import "XRProjectionLayer.h"

#import "Device.h"
#import "MetalSPI.h"
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if PLATFORM(MAC)
#import <IOSurface/IOSurfaceRef.h>
#import <wtf/RetainPtr.h>
#endif

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#endif

#if USE(APPLE_INTERNAL_SDK) && HAVE(COMPOSITOR_SERVICES)
#import <CompositorServices/CompositorServices_Private.h>
#import <Metal/MTLRasterizationRate_Private.h>
#import <wtf/SoftLinking.h>
#import <wtf/darwin/WeakLinking.h>

SOFT_LINK_FRAMEWORK_FOR_SOURCE(WebCore, CompositorServices)

SOFT_LINK_CLASS_FOR_HEADER(WebCore, CP_OBJECT_cp_proxy_process_rasterization_rate_map)
typedef CP_OBJECT_cp_proxy_process_rasterization_rate_map* cp_proxy_process_rasterization_rate_map_t;

SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_create, cp_proxy_process_rasterization_rate_map_t, (id<MTLDevice> device, cp_layer_renderer_layout layout, size_t view_count), (device, layout, view_count))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_create, cp_proxy_process_rasterization_rate_map_t, (id<MTLDevice> device, cp_layer_renderer_layout layout, size_t view_count), (device, layout, view_count))
#define cp_proxy_process_rasterization_rate_map_create WebCore::softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_create


SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_rasterization_rate_map_update_shared_from_layered_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, MTLRasterizationRateMapDescriptor* descriptor), (proxy_map, descriptor))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_rasterization_rate_map_update_shared_from_layered_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, MTLRasterizationRateMapDescriptor* descriptor), (proxy_map, descriptor))
#define cp_rasterization_rate_map_update_shared_from_layered_descriptor WebCore::softLink_CompositorServices_cp_rasterization_rate_map_update_shared_from_layered_descriptor


SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_maps, NSArray<id<MTLRasterizationRateMap>>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_maps, NSArray<id<MTLRasterizationRateMap>>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
#define cp_proxy_process_rasterization_rate_map_get_metal_maps WebCore::softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_maps


SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_descriptors, NSArray<MTLRasterizationRateMapDescriptor*>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_rasterization_rate_map_update_from_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, __unsafe_unretained MTLRasterizationRateMapDescriptor* descriptors[2]), (proxy_map, descriptors))
SOFT_LINK_CLASS_FOR_SOURCE(WebCore, CompositorServices, CP_OBJECT_cp_proxy_process_rasterization_rate_map)

SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_drawable_get_layer_renderer_layout, cp_layer_renderer_layout_private, (cp_drawable_t drawable), (drawable))

SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_descriptors, NSArray<MTLRasterizationRateMapDescriptor*>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))

SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_rasterization_rate_map_update_from_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, __unsafe_unretained MTLRasterizationRateMapDescriptor* descriptors[2]), (proxy_map, descriptors))

#define cp_proxy_process_rasterization_rate_map_get_metal_descriptors WebCore::softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_descriptors
#define cp_proxy_process_rasterization_rate_map_get_metal_descriptors WebCore::softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_descriptors
#define cp_rasterization_rate_map_update_from_descriptor WebCore::softLink_CompositorServices_cp_rasterization_rate_map_update_from_descriptor
#define cp_drawable_get_layer_renderer_layout WebCore::softLink_CompositorServices_cp_drawable_get_layer_renderer_layout

#endif


namespace WebGPU::Metal {

#if USE(APPLE_INTERNAL_SDK) && PLATFORM(VISION) && !PLATFORM(IOS_FAMILY_SIMULATOR)

id<MTLTexture> makeXRSharedTexture(id<MTLDevice> device, mach_port_t machPort)
{
    MTLSharedTextureHandle* handle = [[MTLSharedTextureHandle alloc] initWithMachPort:machPort];
    return [device newSharedTextureWithHandle:handle];
}

id<MTLSharedEvent> makeXRSharedEvent(id<MTLDevice> device, mach_port_t machPort)
{
    return [(id<MTLDeviceSPI>)device newSharedEventWithMachPort:machPort];
}

NSArray<id<MTLRasterizationRateMap>> *makeXRRasterizationRateMaps(id<MTLDevice> device, unsigned screenWidth, unsigned screenHeight, std::span<const float> horizontalSamplesLeft NOESCAPE, std::span<const float> horizontalSamplesRight NOESCAPE, std::span<const float> verticalSamples NOESCAPE)
{
    MTLSize screenSize = MTLSizeMake(screenWidth, screenHeight, 0);
    MTLRasterizationRateLayerDescriptor* layerLeft = [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(horizontalSamplesLeft.size(), verticalSamples.size(), 0) horizontal:horizontalSamplesLeft.data() vertical:verticalSamples.data()];

    MTLRasterizationRateLayerDescriptor* layerRight = [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(horizontalSamplesRight.size(), verticalSamples.size(), 0) horizontal:horizontalSamplesRight.data() vertical:verticalSamples.data()];

    auto setSpiProperties = ^(MTLRasterizationRateMapDescriptor* desc) {
        auto spi = (id<MTLRasterizationRateMapDescriptorSPI>)desc;
        spi.skipSampleValidationAndApplySampleAtTileGranularity = YES;
        spi.mutability = MTLMutabilityMutable;
        spi.minFactor = 0.01;
    };
    MTLRasterizationRateMapDescriptor* rateMapDescriptorLeft = [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:screenSize layer:layerLeft];
    setSpiProperties(rateMapDescriptorLeft);

    MTLRasterizationRateMapDescriptor* rateMapDescriptorRight = [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:screenSize layer:layerRight];
    setSpiProperties(rateMapDescriptorRight);

    __unsafe_unretained MTLRasterizationRateMapDescriptor* descriptors[] = { rateMapDescriptorLeft, rateMapDescriptorRight };
    auto rateMap = cp_proxy_process_rasterization_rate_map_create(device, cp_layer_renderer_layout_dedicated, 2);
    cp_rasterization_rate_map_update_from_descriptor(rateMap, descriptors);

    return cp_proxy_process_rasterization_rate_map_get_metal_maps(rateMap);
}

#else

#if PLATFORM(MAC)

// The Mac has no compositor. There a frame's buffer is an IOSurface, which only WebKit's simulated XR device sends.
id<MTLTexture> makeXRSharedTexture(id<MTLDevice> device, mach_port_t machPort)
{
    RetainPtr surface = adoptCF(IOSurfaceLookupFromMachPort(machPort));
    if (!surface)
        return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:IOSurfaceGetWidth(surface.get()) height:IOSurfaceGetHeight(surface.get()) mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:descriptor iosurface:surface.get() plane:0];
}

#else

id<MTLTexture> makeXRSharedTexture(id<MTLDevice>, mach_port_t)
{
    return nil;
}

#endif

id<MTLSharedEvent> makeXRSharedEvent(id<MTLDevice>, mach_port_t)
{
    return nil;
}

NSArray<id<MTLRasterizationRateMap>> *makeXRRasterizationRateMaps(id<MTLDevice>, unsigned, unsigned, std::span<const float> horizontalSamplesLeft NOESCAPE, std::span<const float> horizontalSamplesRight NOESCAPE, std::span<const float> verticalSamples NOESCAPE)
{
    UNUSED_PARAM(horizontalSamplesLeft);
    UNUSED_PARAM(horizontalSamplesRight);
    UNUSED_PARAM(verticalSamples);
    return nil;
}

#endif

} // namespace WebGPU::Metal
