/*
 * Copyright (C) 2004-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#if defined(HAVE_CONFIG_H) && HAVE_CONFIG_H && defined(BUILDING_WITH_CMAKE)
#include "cmakeconfig.h"
#endif

#include "ExportMacros.h"

#include "WebGPU.h"

// webgpu.h's handles point to no object, now that its functions are gone, but its structs still
// name them. Defining these keeps the structs from using forward declared types.
struct WGPUAdapterImpl { };
struct WGPUBindGroupImpl { };
struct WGPUBindGroupLayoutImpl { };
struct WGPUBufferImpl { };
struct WGPUCommandBufferImpl { };
struct WGPUCommandEncoderImpl { };
struct WGPUComputePassEncoderImpl { };
struct WGPUComputePipelineImpl { };
struct WGPUDeviceImpl { };
struct WGPUExternalTextureImpl { };
struct WGPUInstanceImpl { };
struct WGPUPipelineLayoutImpl { };
struct WGPUQuerySetImpl { };
struct WGPUQueueImpl { };
struct WGPURenderBundleImpl { };
struct WGPURenderBundleEncoderImpl { };
struct WGPURenderPassEncoderImpl { };
struct WGPURenderPipelineImpl { };
struct WGPUResourceTableImpl { };
struct WGPUSamplerImpl { };
struct WGPUShaderModuleImpl { };
struct WGPUSharedBufferMemoryImpl { };
struct WGPUSharedFenceImpl { };
struct WGPUSharedTextureMemoryImpl { };
struct WGPUSurfaceImpl { };
struct WGPUTexelBufferViewImpl { };
struct WGPUTextureImpl { };
struct WGPUTextureViewImpl { };

#include <Metal/Metal.h>

#include <wtf/Assertions.h>

#include <wtf/Platform.h>

#include <wtf/RetainPtr.h>
