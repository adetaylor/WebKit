// Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
// Copyright (C) 2019 Google Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// The GL extensions of a context: the ones ANGLE supports, the ones it can enable on request, and the ones the
// context has enabled, by name, and as the GCGLExtension sets of the ones WebKit knows.
struct GLExtensions {
    // GCGLExtension's names, in its order.
    static let names: [String] = [
        "GL_ANGLE_base_vertex_base_instance",
        "GL_ANGLE_clip_cull_distance",
        "GL_ANGLE_compressed_texture_etc",
        "GL_ANGLE_depth_texture",
        "GL_ANGLE_framebuffer_blit",
        "GL_ANGLE_framebuffer_multisample",
        "GL_ANGLE_instanced_arrays",
        "GL_ANGLE_multi_draw",
        "GL_ANGLE_pack_reverse_row_order",
        "GL_ANGLE_polygon_mode",
        "GL_ANGLE_provoking_vertex",
        "GL_ANGLE_stencil_texturing",
        "GL_ANGLE_texture_compression_dxt3",
        "GL_ANGLE_texture_compression_dxt5",
        "GL_ANGLE_translated_shader_source",
        "GL_CHROMIUM_color_buffer_float_rgb",
        "GL_CHROMIUM_color_buffer_float_rgba",
        "GL_EXT_blend_func_extended",
        "GL_EXT_blend_minmax",
        "GL_EXT_clip_control",
        "GL_EXT_color_buffer_float",
        "GL_EXT_color_buffer_half_float",
        "GL_EXT_conservative_depth",
        "GL_EXT_depth_clamp",
        "GL_EXT_disjoint_timer_query",
        "GL_EXT_draw_buffers",
        "GL_EXT_float_blend",
        "GL_EXT_frag_depth",
        "GL_EXT_polygon_offset_clamp",
        "GL_EXT_render_snorm",
        "GL_EXT_sRGB",
        "GL_EXT_shader_texture_lod",
        "GL_EXT_texture_compression_bptc",
        "GL_EXT_texture_compression_dxt1",
        "GL_EXT_texture_compression_rgtc",
        "GL_EXT_texture_compression_s3tc_srgb",
        "GL_EXT_texture_filter_anisotropic",
        "GL_EXT_texture_mirror_clamp_to_edge",
        "GL_EXT_texture_norm16",
        "GL_IMG_texture_compression_pvrtc",
        "GL_KHR_parallel_shader_compile",
        "GL_KHR_texture_compression_astc_hdr",
        "GL_KHR_texture_compression_astc_ldr",
        "GL_NV_shader_noperspective_interpolation",
        "GL_OES_compressed_ETC1_RGB8_texture",
        "GL_OES_depth24",
        "GL_OES_depth_texture",
        "GL_OES_draw_buffers_indexed",
        "GL_OES_element_index_uint",
        "GL_OES_fbo_render_mipmap",
        "GL_OES_packed_depth_stencil",
        "GL_OES_rgb8_rgba8",
        "GL_OES_sample_variables",
        "GL_OES_shader_multisample_interpolation",
        "GL_OES_standard_derivatives",
        "GL_OES_texture_float",
        "GL_OES_texture_float_linear",
        "GL_OES_texture_half_float",
        "GL_OES_texture_half_float_linear",
        "GL_OES_vertex_array_object",
        "GL_QCOM_render_shared_exponent",
    ]

    // The GCGLExtensions the island itself asks about.
    enum Known: UInt8 {
        case angleBaseVertexBaseInstance = 0
        case chromiumColorBufferFloatRGB = 15
        case chromiumColorBufferFloatRGBA = 16
    }

    private static let indices: [String: UInt8] = {
        var indices: [String: UInt8] = [:]
        for (index, name) in names.enumerated() {
            indices[name] = UInt8(index)
        }
        return indices
    }()

    static func name(of extension: UInt8) -> String? {
        Int(`extension`) < names.count ? names[Int(`extension`)] : nil
    }

    private var supported: Set<String> = []
    private var allRequestable: Set<String> = []
    private var allEnabledRequestable: Set<String> = []
    private(set) var isNVFramebufferBlitEnabled = false

    // GCGLExtension sets, as EnumSet's raw values.
    var knownActive: UInt64 = 0
    var requestable: UInt64 = 0

    mutating func setSupported(_ extensionsString: std.string, requestable requestableString: std.string) {
        supported = Self.split(extensionsString)
        allRequestable = Self.split(requestableString)
        updateCachedState()
    }

    func isSupported(_ name: String) -> Bool {
        supported.contains(name)
    }

    func isEnabled(_ name: String) -> Bool {
        supported.contains(name) || allEnabledRequestable.contains(name)
    }

    func isKnownActive(_ known: Known) -> Bool {
        knownActive & (1 << UInt64(known.rawValue)) != 0
    }

    // The names to request so that every one of names is enabled, or nil if one of them isn't supported.
    func requestsToEnable(_ names: [String]) -> [String]? {
        var requests: [String] = []
        requests.reserveCapacity(names.count)
        for name in names {
            if supported.contains(name) {
                continue
            }
            if !allRequestable.contains(name) {
                return nil
            }
            if allEnabledRequestable.contains(name) {
                continue
            }
            requests.append(name)
        }
        return requests
    }

    mutating func didEnableRequestable(_ name: String) {
        allEnabledRequestable.insert(name)
        updateCachedState()
    }

    mutating func computeKnownActiveAndRequestable(supportsWebGLDraftExtensions: Bool) {
        for name in supported {
            if let index = Self.indices[name] {
                knownActive |= 1 << UInt64(index)
            }
        }
        for name in allEnabledRequestable {
            if let index = Self.indices[name] {
                knownActive |= 1 << UInt64(index)
            }
        }
        for name in allRequestable {
            if let index = Self.indices[name] {
                if index == Known.angleBaseVertexBaseInstance.rawValue && !supportsWebGLDraftExtensions {
                    continue
                }
                requestable |= 1 << UInt64(index)
            }
        }
    }

    private mutating func updateCachedState() {
        isNVFramebufferBlitEnabled = isEnabled("GL_NV_framebuffer_blit")
    }

    private static func split(_ string: std.string) -> Set<String> {
        var result: Set<String> = []
        for name in String(string).split(separator: " ") {
            result.insert(String(name))
        }
        return result
    }
}
