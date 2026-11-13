// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import Testing
import WGSL

// convertPipelineConstants (Pipeline.mm:89-140) against the C++: the expected spellings are what a copy of Pipeline.mm:89-140
// produced for this module, entry point "main", with one constant per generate.

private let source = """
    enable f16;

    override b: bool;
    override f: f32;
    override i: i32;
    override u: u32;
    override h: f16;
    @id(7) override j: i32 = 3;
    override unused: f32 = 1;

    @group(0) @binding(0) var<storage, read_write> o: array<u32, 6>;

    @compute @workgroup_size(1) fn main() {
        o[0] = select(0u, 1u, b);
        o[1] = u32(f);
        o[2] = u32(i);
        o[3] = u;
        o[4] = u32(h);
        o[5] = u32(j);
    }

    @compute @workgroup_size(1) fn other() {
        o[0] = u32(unused);
    }
    """

/// The C++ results as (key, the double's bits, the C++ spelling).
///
/// They cover a table of typical and boundary values, NaN payloads, infinities and the range boundaries, for the five override types
/// (`7` is the @id of `j`); then an override main does not use, an unknown key, and the name of an override that has an @id.
private let cxxConstLines: [(key: String, bits: UInt64, expected: String)] = [
    ("b", 0x0000_0000_0000_0000, "bool:false"),
    ("b", 0x3ff0_0000_0000_0000, "bool:true"),
    ("b", 0xbff0_0000_0000_0000, "bool:true"),
    ("b", 0x401c_0000_0000_0000, "bool:true"),
    ("b", 0x41df_ffff_ffc0_0000, "bool:true"),
    ("b", 0xc1e0_0000_0000_0000, "bool:true"),
    ("b", 0x41ef_ffff_ffe0_0000, "bool:true"),
    ("b", 0x3fe0_0000_0000_0000, "bool:true"),
    ("b", 0x8000_0000_0000_0000, "bool:false"),
    ("b", 0x4202_a05f_2000_0000, "bool:true"),
    ("b", 0x40ef_fc00_0000_0000, "bool:true"),
    ("b", 0x40ef_fe00_0000_0000, "bool:true"),
    ("b", 0x7ff8_0000_0000_0000, "bool:true"),
    ("b", 0x4807_8287_f49c_4a1d, "bool:true"),
    ("b", 0xfff8_0000_0000_0000, "bool:true"),
    ("b", 0x7ff4_0000_0000_0001, "bool:true"),
    ("b", 0x7ff8_0000_0001_2345, "bool:true"),
    ("b", 0x7ff0_0000_0000_0000, "bool:true"),
    ("b", 0xfff0_0000_0000_0000, "bool:true"),
    ("b", 0x47ef_ffff_e000_0000, "bool:true"),
    ("b", 0x47ef_ffff_f000_0000, "bool:true"),
    ("b", 0xc7ef_ffff_e000_0000, "bool:true"),
    ("b", 0xc7ef_ffff_f000_0000, "bool:true"),
    ("b", 0x41df_ffff_ffe0_0000, "bool:true"),
    ("b", 0xc1e0_0000_0010_0000, "bool:true"),
    ("b", 0xc1e0_0000_001c_cccd, "bool:true"),
    ("b", 0x41df_ffff_fff9_999a, "bool:true"),
    ("b", 0x41ef_ffff_fff0_0000, "bool:true"),
    ("b", 0x41ef_ffff_fffc_cccd, "bool:true"),
    ("b", 0xbfe0_0000_0000_0000, "bool:true"),
    ("b", 0xbfec_cccc_cccc_cccd, "bool:true"),
    ("b", 0x40ef_fde0_0000_0000, "bool:true"),
    ("b", 0x40ef_fc10_0000_0000, "bool:true"),
    ("b", 0xc0ef_fc00_0000_0000, "bool:true"),
    ("b", 0xc0ef_fc10_0000_0000, "bool:true"),
    ("b", 0x3ff8_0000_0000_0000, "bool:true"),
    ("b", 0xbff8_0000_0000_0000, "bool:true"),
    ("b", 0x4004_0000_0000_0000, "bool:true"),
    ("b", 0x3f10_0000_0000_0000, "bool:true"),
    ("b", 0x3e70_0000_0000_0000, "bool:true"),
    ("b", 0x3e60_0000_0000_0000, "bool:true"),
    ("b", 0x3e60_0000_1ad7_f29b, "bool:true"),
    ("b", 0x3662_44ce_242c_5561, "bool:true"),
    ("b", 0x3fb9_9999_9999_999a, "bool:true"),
    ("b", 0x4170_0000_1000_0000, "bool:true"),
    ("f", 0x0000_0000_0000_0000, "f32:0x00000000"),
    ("f", 0x3ff0_0000_0000_0000, "f32:0x3f800000"),
    ("f", 0xbff0_0000_0000_0000, "f32:0xbf800000"),
    ("f", 0x401c_0000_0000_0000, "f32:0x40e00000"),
    ("f", 0x41df_ffff_ffc0_0000, "f32:0x4f000000"),
    ("f", 0xc1e0_0000_0000_0000, "f32:0xcf000000"),
    ("f", 0x41ef_ffff_ffe0_0000, "f32:0x4f800000"),
    ("f", 0x3fe0_0000_0000_0000, "f32:0x3f000000"),
    ("f", 0x8000_0000_0000_0000, "f32:0x80000000"),
    ("f", 0x4202_a05f_2000_0000, "f32:0x501502f9"),
    ("f", 0x40ef_fc00_0000_0000, "f32:0x477fe000"),
    ("f", 0x40ef_fe00_0000_0000, "f32:0x477ff000"),
    ("f", 0x7ff8_0000_0000_0000, "f32:0x7fc00000"),
    ("f", 0x4807_8287_f49c_4a1d, "error:range"),
    ("f", 0xfff8_0000_0000_0000, "f32:0xffc00000"),
    ("f", 0x7ff4_0000_0000_0001, "f32:0x7fe00000"),
    ("f", 0x7ff8_0000_0001_2345, "f32:0x7fc00000"),
    ("f", 0x7ff0_0000_0000_0000, "error:range"),
    ("f", 0xfff0_0000_0000_0000, "error:range"),
    ("f", 0x47ef_ffff_e000_0000, "f32:0x7f7fffff"),
    ("f", 0x47ef_ffff_f000_0000, "error:range"),
    ("f", 0xc7ef_ffff_e000_0000, "f32:0xff7fffff"),
    ("f", 0xc7ef_ffff_f000_0000, "error:range"),
    ("f", 0x41df_ffff_ffe0_0000, "f32:0x4f000000"),
    ("f", 0xc1e0_0000_0010_0000, "f32:0xcf000000"),
    ("f", 0xc1e0_0000_001c_cccd, "f32:0xcf000000"),
    ("f", 0x41df_ffff_fff9_999a, "f32:0x4f000000"),
    ("f", 0x41ef_ffff_fff0_0000, "f32:0x4f800000"),
    ("f", 0x41ef_ffff_fffc_cccd, "f32:0x4f800000"),
    ("f", 0xbfe0_0000_0000_0000, "f32:0xbf000000"),
    ("f", 0xbfec_cccc_cccc_cccd, "f32:0xbf666666"),
    ("f", 0x40ef_fde0_0000_0000, "f32:0x477fef00"),
    ("f", 0x40ef_fc10_0000_0000, "f32:0x477fe080"),
    ("f", 0xc0ef_fc00_0000_0000, "f32:0xc77fe000"),
    ("f", 0xc0ef_fc10_0000_0000, "f32:0xc77fe080"),
    ("f", 0x3ff8_0000_0000_0000, "f32:0x3fc00000"),
    ("f", 0xbff8_0000_0000_0000, "f32:0xbfc00000"),
    ("f", 0x4004_0000_0000_0000, "f32:0x40200000"),
    ("f", 0x3f10_0000_0000_0000, "f32:0x38800000"),
    ("f", 0x3e70_0000_0000_0000, "f32:0x33800000"),
    ("f", 0x3e60_0000_0000_0000, "f32:0x33000000"),
    ("f", 0x3e60_0000_1ad7_f29b, "f32:0x33000001"),
    ("f", 0x3662_44ce_242c_5561, "f32:0x00000000"),
    ("f", 0x3fb9_9999_9999_999a, "f32:0x3dcccccd"),
    ("f", 0x4170_0000_1000_0000, "f32:0x4b800000"),
    ("i", 0x0000_0000_0000_0000, "i32:0"),
    ("i", 0x3ff0_0000_0000_0000, "i32:1"),
    ("i", 0xbff0_0000_0000_0000, "i32:-1"),
    ("i", 0x401c_0000_0000_0000, "i32:7"),
    ("i", 0x41df_ffff_ffc0_0000, "i32:2147483647"),
    ("i", 0xc1e0_0000_0000_0000, "i32:-2147483648"),
    ("i", 0x41ef_ffff_ffe0_0000, "error:range"),
    ("i", 0x3fe0_0000_0000_0000, "i32:0"),
    ("i", 0x8000_0000_0000_0000, "i32:0"),
    ("i", 0x4202_a05f_2000_0000, "error:range"),
    ("i", 0x40ef_fc00_0000_0000, "i32:65504"),
    ("i", 0x40ef_fe00_0000_0000, "i32:65520"),
    ("i", 0x7ff8_0000_0000_0000, "i32:0"),
    ("i", 0x4807_8287_f49c_4a1d, "error:range"),
    ("i", 0xfff8_0000_0000_0000, "i32:0"),
    ("i", 0x7ff4_0000_0000_0001, "i32:0"),
    ("i", 0x7ff8_0000_0001_2345, "i32:0"),
    ("i", 0x7ff0_0000_0000_0000, "error:range"),
    ("i", 0xfff0_0000_0000_0000, "error:range"),
    ("i", 0x47ef_ffff_e000_0000, "error:range"),
    ("i", 0x47ef_ffff_f000_0000, "error:range"),
    ("i", 0xc7ef_ffff_e000_0000, "error:range"),
    ("i", 0xc7ef_ffff_f000_0000, "error:range"),
    ("i", 0x41df_ffff_ffe0_0000, "error:range"),
    ("i", 0xc1e0_0000_0010_0000, "error:range"),
    ("i", 0xc1e0_0000_001c_cccd, "error:range"),
    ("i", 0x41df_ffff_fff9_999a, "error:range"),
    ("i", 0x41ef_ffff_fff0_0000, "error:range"),
    ("i", 0x41ef_ffff_fffc_cccd, "error:range"),
    ("i", 0xbfe0_0000_0000_0000, "i32:0"),
    ("i", 0xbfec_cccc_cccc_cccd, "i32:0"),
    ("i", 0x40ef_fde0_0000_0000, "i32:65519"),
    ("i", 0x40ef_fc10_0000_0000, "i32:65504"),
    ("i", 0xc0ef_fc00_0000_0000, "i32:-65504"),
    ("i", 0xc0ef_fc10_0000_0000, "i32:-65504"),
    ("i", 0x3ff8_0000_0000_0000, "i32:1"),
    ("i", 0xbff8_0000_0000_0000, "i32:-1"),
    ("i", 0x4004_0000_0000_0000, "i32:2"),
    ("i", 0x3f10_0000_0000_0000, "i32:0"),
    ("i", 0x3e70_0000_0000_0000, "i32:0"),
    ("i", 0x3e60_0000_0000_0000, "i32:0"),
    ("i", 0x3e60_0000_1ad7_f29b, "i32:0"),
    ("i", 0x3662_44ce_242c_5561, "i32:0"),
    ("i", 0x3fb9_9999_9999_999a, "i32:0"),
    ("i", 0x4170_0000_1000_0000, "i32:16777217"),
    ("u", 0x0000_0000_0000_0000, "u32:0"),
    ("u", 0x3ff0_0000_0000_0000, "u32:1"),
    ("u", 0xbff0_0000_0000_0000, "error:range"),
    ("u", 0x401c_0000_0000_0000, "u32:7"),
    ("u", 0x41df_ffff_ffc0_0000, "u32:2147483647"),
    ("u", 0xc1e0_0000_0000_0000, "error:range"),
    ("u", 0x41ef_ffff_ffe0_0000, "u32:4294967295"),
    ("u", 0x3fe0_0000_0000_0000, "u32:0"),
    ("u", 0x8000_0000_0000_0000, "u32:0"),
    ("u", 0x4202_a05f_2000_0000, "error:range"),
    ("u", 0x40ef_fc00_0000_0000, "u32:65504"),
    ("u", 0x40ef_fe00_0000_0000, "u32:65520"),
    ("u", 0x7ff8_0000_0000_0000, "u32:0"),
    ("u", 0x4807_8287_f49c_4a1d, "error:range"),
    ("u", 0xfff8_0000_0000_0000, "u32:0"),
    ("u", 0x7ff4_0000_0000_0001, "u32:0"),
    ("u", 0x7ff8_0000_0001_2345, "u32:0"),
    ("u", 0x7ff0_0000_0000_0000, "error:range"),
    ("u", 0xfff0_0000_0000_0000, "error:range"),
    ("u", 0x47ef_ffff_e000_0000, "error:range"),
    ("u", 0x47ef_ffff_f000_0000, "error:range"),
    ("u", 0xc7ef_ffff_e000_0000, "error:range"),
    ("u", 0xc7ef_ffff_f000_0000, "error:range"),
    ("u", 0x41df_ffff_ffe0_0000, "u32:2147483647"),
    ("u", 0xc1e0_0000_0010_0000, "error:range"),
    ("u", 0xc1e0_0000_001c_cccd, "error:range"),
    ("u", 0x41df_ffff_fff9_999a, "u32:2147483647"),
    ("u", 0x41ef_ffff_fff0_0000, "error:range"),
    ("u", 0x41ef_ffff_fffc_cccd, "error:range"),
    ("u", 0xbfe0_0000_0000_0000, "error:range"),
    ("u", 0xbfec_cccc_cccc_cccd, "error:range"),
    ("u", 0x40ef_fde0_0000_0000, "u32:65519"),
    ("u", 0x40ef_fc10_0000_0000, "u32:65504"),
    ("u", 0xc0ef_fc00_0000_0000, "error:range"),
    ("u", 0xc0ef_fc10_0000_0000, "error:range"),
    ("u", 0x3ff8_0000_0000_0000, "u32:1"),
    ("u", 0xbff8_0000_0000_0000, "error:range"),
    ("u", 0x4004_0000_0000_0000, "u32:2"),
    ("u", 0x3f10_0000_0000_0000, "u32:0"),
    ("u", 0x3e70_0000_0000_0000, "u32:0"),
    ("u", 0x3e60_0000_0000_0000, "u32:0"),
    ("u", 0x3e60_0000_1ad7_f29b, "u32:0"),
    ("u", 0x3662_44ce_242c_5561, "u32:0"),
    ("u", 0x3fb9_9999_9999_999a, "u32:0"),
    ("u", 0x4170_0000_1000_0000, "u32:16777217"),
    ("h", 0x0000_0000_0000_0000, "f16:0x0000"),
    ("h", 0x3ff0_0000_0000_0000, "f16:0x3c00"),
    ("h", 0xbff0_0000_0000_0000, "f16:0xbc00"),
    ("h", 0x401c_0000_0000_0000, "f16:0x4700"),
    ("h", 0x41df_ffff_ffc0_0000, "error:range"),
    ("h", 0xc1e0_0000_0000_0000, "error:range"),
    ("h", 0x41ef_ffff_ffe0_0000, "error:range"),
    ("h", 0x3fe0_0000_0000_0000, "f16:0x3800"),
    ("h", 0x8000_0000_0000_0000, "f16:0x8000"),
    ("h", 0x4202_a05f_2000_0000, "error:range"),
    ("h", 0x40ef_fc00_0000_0000, "f16:0x7bff"),
    ("h", 0x40ef_fe00_0000_0000, "error:range"),
    ("h", 0x7ff8_0000_0000_0000, "f16:0x7e00"),
    ("h", 0x4807_8287_f49c_4a1d, "error:range"),
    ("h", 0xfff8_0000_0000_0000, "f16:0xfe00"),
    ("h", 0x7ff4_0000_0000_0001, "f16:0x7f00"),
    ("h", 0x7ff8_0000_0001_2345, "f16:0x7e00"),
    ("h", 0x7ff0_0000_0000_0000, "error:range"),
    ("h", 0xfff0_0000_0000_0000, "error:range"),
    ("h", 0x47ef_ffff_e000_0000, "error:range"),
    ("h", 0x47ef_ffff_f000_0000, "error:range"),
    ("h", 0xc7ef_ffff_e000_0000, "error:range"),
    ("h", 0xc7ef_ffff_f000_0000, "error:range"),
    ("h", 0x41df_ffff_ffe0_0000, "error:range"),
    ("h", 0xc1e0_0000_0010_0000, "error:range"),
    ("h", 0xc1e0_0000_001c_cccd, "error:range"),
    ("h", 0x41df_ffff_fff9_999a, "error:range"),
    ("h", 0x41ef_ffff_fff0_0000, "error:range"),
    ("h", 0x41ef_ffff_fffc_cccd, "error:range"),
    ("h", 0xbfe0_0000_0000_0000, "f16:0xb800"),
    ("h", 0xbfec_cccc_cccc_cccd, "f16:0xbb33"),
    ("h", 0x40ef_fde0_0000_0000, "error:range"),
    ("h", 0x40ef_fc10_0000_0000, "error:range"),
    ("h", 0xc0ef_fc00_0000_0000, "f16:0xfbff"),
    ("h", 0xc0ef_fc10_0000_0000, "error:range"),
    ("h", 0x3ff8_0000_0000_0000, "f16:0x3e00"),
    ("h", 0xbff8_0000_0000_0000, "f16:0xbe00"),
    ("h", 0x4004_0000_0000_0000, "f16:0x4100"),
    ("h", 0x3f10_0000_0000_0000, "f16:0x0400"),
    ("h", 0x3e70_0000_0000_0000, "f16:0x0001"),
    ("h", 0x3e60_0000_0000_0000, "f16:0x0000"),
    ("h", 0x3e60_0000_1ad7_f29b, "f16:0x0001"),
    ("h", 0x3662_44ce_242c_5561, "f16:0x0000"),
    ("h", 0x3fb9_9999_9999_999a, "f16:0x2e66"),
    ("h", 0x4170_0000_1000_0000, "error:range"),
    ("7", 0x0000_0000_0000_0000, "i32:0"),
    ("7", 0x3ff0_0000_0000_0000, "i32:1"),
    ("7", 0xbff0_0000_0000_0000, "i32:-1"),
    ("7", 0x401c_0000_0000_0000, "i32:7"),
    ("7", 0x41df_ffff_ffc0_0000, "i32:2147483647"),
    ("7", 0xc1e0_0000_0000_0000, "i32:-2147483648"),
    ("7", 0x41ef_ffff_ffe0_0000, "error:range"),
    ("7", 0x3fe0_0000_0000_0000, "i32:0"),
    ("7", 0x8000_0000_0000_0000, "i32:0"),
    ("7", 0x4202_a05f_2000_0000, "error:range"),
    ("7", 0x40ef_fc00_0000_0000, "i32:65504"),
    ("7", 0x40ef_fe00_0000_0000, "i32:65520"),
    ("7", 0x7ff8_0000_0000_0000, "i32:0"),
    ("7", 0x4807_8287_f49c_4a1d, "error:range"),
    ("7", 0xfff8_0000_0000_0000, "i32:0"),
    ("7", 0x7ff4_0000_0000_0001, "i32:0"),
    ("7", 0x7ff8_0000_0001_2345, "i32:0"),
    ("7", 0x7ff0_0000_0000_0000, "error:range"),
    ("7", 0xfff0_0000_0000_0000, "error:range"),
    ("7", 0x47ef_ffff_e000_0000, "error:range"),
    ("7", 0x47ef_ffff_f000_0000, "error:range"),
    ("7", 0xc7ef_ffff_e000_0000, "error:range"),
    ("7", 0xc7ef_ffff_f000_0000, "error:range"),
    ("7", 0x41df_ffff_ffe0_0000, "error:range"),
    ("7", 0xc1e0_0000_0010_0000, "error:range"),
    ("7", 0xc1e0_0000_001c_cccd, "error:range"),
    ("7", 0x41df_ffff_fff9_999a, "error:range"),
    ("7", 0x41ef_ffff_fff0_0000, "error:range"),
    ("7", 0x41ef_ffff_fffc_cccd, "error:range"),
    ("7", 0xbfe0_0000_0000_0000, "i32:0"),
    ("7", 0xbfec_cccc_cccc_cccd, "i32:0"),
    ("7", 0x40ef_fde0_0000_0000, "i32:65519"),
    ("7", 0x40ef_fc10_0000_0000, "i32:65504"),
    ("7", 0xc0ef_fc00_0000_0000, "i32:-65504"),
    ("7", 0xc0ef_fc10_0000_0000, "i32:-65504"),
    ("7", 0x3ff8_0000_0000_0000, "i32:1"),
    ("7", 0xbff8_0000_0000_0000, "i32:-1"),
    ("7", 0x4004_0000_0000_0000, "i32:2"),
    ("7", 0x3f10_0000_0000_0000, "i32:0"),
    ("7", 0x3e70_0000_0000_0000, "i32:0"),
    ("7", 0x3e60_0000_0000_0000, "i32:0"),
    ("7", 0x3e60_0000_1ad7_f29b, "i32:0"),
    ("7", 0x3662_44ce_242c_5561, "i32:0"),
    ("7", 0x3fb9_9999_9999_999a, "i32:0"),
    ("7", 0x4170_0000_1000_0000, "i32:16777217"),
    ("unused", 0x3ff0_0000_0000_0000, "skip"),
    ("nope", 0x3ff0_0000_0000_0000, "error:unknown"),
    ("j", 0x3ff0_0000_0000_0000, "error:unknown"),
]

/// The spelling of a converted constant in the expected lines, bit-exact.
private func spelling(_ value: ScalarValue) -> String {
    func hex<T: FixedWidthInteger>(_ bits: T) -> String {
        let digits = String(bits, radix: 16)
        return "0x" + String(repeating: "0", count: T.bitWidth / 4 - digits.count) + digits
    }
    return switch value {
    case .bool(let value): "bool:" + (value ? "true" : "false")
    case .f32(let value): "f32:" + hex(value.bitPattern)
    case .f16(let bits): "f16:" + hex(bits)
    case .i32(let value): "i32:" + String(value)
    case .u32(let value): "u32:" + String(value)
    case .abstractInt(let value): "i64:" + String(value)
    case .abstractFloat(let value): "f64:" + hex(value.bitPattern)
    }
}

/// What the C++ dump prints for one constant: the value, `skip`, or the error (convertPipelineConstants gives no reason; the key
/// tells them apart, as in WGSLDump.swift).
private func spelling(_ result: [OverrideAssignment]?, known: Bool) -> String {
    guard let result else {
        return known ? "error:range" : "error:unknown"
    }
    guard let assignment = result.first else {
        return "skip"
    }
    return spelling(assignment.value)
}

private struct Converted: Sendable {
    var keys: [String]
    var results: [[OverrideAssignment]?]
}

/// Prepares `entryPoints` with default layouts and converts each list of constants on the prepared module.
private func convert(_ constants: [[PipelineConstant]], entryPoints: [String] = ["main"]) -> Converted? {
    onCompileThread { compileThread -> Converted? in
        switch compileThread.staticCheck(wtfSource(source)) {
        case .failure:
            return nil
        case .success(let module):
            switch module.prepare(entryPoints: entryPoints.map { Name($0) }) {
            case .failed:
                return nil
            case .prepared(let prepared):
                var keys: [String] = []
                for information in prepared.entryPoints {
                    keys.append(contentsOf: information.specializationConstants.map(\.key.description))
                }
                return Converted(keys: keys, results: constants.map { prepared.convertPipelineConstants($0) })
            }
        }
    }
}

private func constant(_ key: String, _ value: Double) -> PipelineConstant {
    PipelineConstant(key: Name(key), value: value)
}

@Suite
struct WGSLPipelineConstantsTests {
    @Test
    func cxxConstLinesMatch() throws {
        let converted = try #require(convert(cxxConstLines.map { [constant($0.key, Double(bitPattern: $0.bits))] }))
        #expect(Set(converted.keys) == ["b", "f", "i", "u", "h", "7"])
        for (index, line) in cxxConstLines.enumerated() {
            let actual = spelling(converted.results[index], known: converted.keys.contains(line.key))
            #expect(actual == line.expected, "const \"\(line.key)\" in=\(String(line.bits, radix: 16))")
        }
    }

    // HashMap::set: one assignment per key, at the key's first position, with its last value.
    @Test
    func lastValueOfAKeyWins() throws {
        let converted = try #require(convert([[constant("i", 1), constant("u", 2), constant("i", 3), constant("unused", 4)]]))
        let result = try #require(converted.results[0])
        #expect(result == [OverrideAssignment(key: Name("i"), value: .i32(3)), OverrideAssignment(key: Name("u"), value: .u32(2))])
    }

    // prepareLibrary returns nullopt at the first bad constant, whatever came before it.
    @Test
    func anyBadConstantFailsTheConversion() throws {
        let converted = try #require(
            convert([
                [constant("b", 1), constant("f", 1e39)], [constant("b", 1), constant("nope", 0)], [constant("u", -1), constant("i", 1)],
                [constant("b", 1), constant("h", 65_520)],
            ])
        )
        #expect(converted.results.allSatisfy { $0 == nil })
    }

    @Test
    func noConstants() throws {
        let converted = try #require(convert([[]]))
        #expect(converted.results[0] == [])
    }

    // With several prepared entry points, a key any of them uses converts; `unused` belongs to `other`.
    @Test
    func keysOfEveryPreparedEntryPoint() throws {
        let converted = try #require(convert([[constant("unused", 2.5), constant("b", 0)]], entryPoints: ["main", "other"]))
        let result = try #require(converted.results[0])
        #expect(
            result == [OverrideAssignment(key: Name("unused"), value: .f32(2.5)), OverrideAssignment(key: Name("b"), value: .bool(false))]
        )
    }

    // DEV-13: a NaN passes the range checks; C++ converts it to an integer with UB, which arm64 makes 0.
    @Test
    func DEV_13_nanToIntegerIsZero() throws {
        let converted = try #require(convert([[constant("i", .nan), constant("u", -.nan), constant("7", .signalingNaN)]]))
        let result = try #require(converted.results[0])
        #expect(
            result == [
                OverrideAssignment(key: Name("i"), value: .i32(0)), OverrideAssignment(key: Name("u"), value: .u32(0)),
                OverrideAssignment(key: Name("7"), value: .i32(0)),
            ]
        )
    }
}
