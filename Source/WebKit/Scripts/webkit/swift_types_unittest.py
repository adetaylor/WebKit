# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import os
import sys
import unittest

module_directory = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.abspath(os.path.join(module_directory, os.path.pardir)))
from webkit import swift_types  # noqa: E402


class SwiftTypeAndCoderTest(unittest.TestCase):
    def test_types(self):
        for cpp_type, expected in [
            ('uint32_t', ('UInt32', 'UInt32')),
            ('const String&', ('String?', 'IPCCoding.WTFString')),
            ('AtomString', ('String?', 'IPCCoding.WTFString')),
            ('const WTF::AtomString&', ('String?', 'IPCCoding.WTFString')),
            ('Vector<AtomString>', ('[String?]', 'IPCCoding.Vector<IPCCoding.WTFString>')),
            ('WebKit::IPCTesterInner', ('IPCTypes.IPCTesterInner', 'IPCTypes.CxxName.WebKit_IPCTesterInner')),
            ('struct WebKit::IPCTesterInner', ('IPCTypes.IPCTesterInner', 'IPCTypes.CxxName.WebKit_IPCTesterInner')),
            ('WebCore::PlatformEvent::Kind', ('IPCTypes.Kind', 'IPCTypes.CxxName.WebCore_PlatformEvent_Kind')),
            ('::WebGPU::IndexFormat', ('IPCTypes.IndexFormat', 'IPCTypes.CxxName.WebGPU_IndexFormat')),
            ('std::optional<::WebGPU::LoadOp>', ('IPCTypes.LoadOp?', 'IPCCoding.StdOptional<IPCTypes.CxxName.WebGPU_LoadOp>')),
            ('Vector<WebKit::IPCTesterInner>', ('[IPCTypes.IPCTesterInner]', 'IPCCoding.Vector<IPCTypes.CxxName.WebKit_IPCTesterInner>')),
            ('Vector<Ref<WebKit::Node>>', ('[IPCTypes.Node]', 'IPCCoding.Vector<IPCTypes.CxxName.WebKit_Node>')),
            ('RefPtr<WebKit::Node>', ('IPCTypes.Node?', 'IPCCoding.StdOptional<IPCTypes.CxxName.WebKit_Node>')),
            ('Markable<WebCore::FrameIdentifier>', ('IPCTypes.FrameIdentifier?', 'IPCCoding.Markable<IPCTypes.CxxName.WebCore_FrameIdentifier>')),
            ('OptionSet<WebKit::Flag>', ('IPCTypes.Flag', 'IPCTypes.CxxName.WebKit_Flag')),
            ('std::optional<Vector<String>>', ('[String?]?', 'IPCCoding.StdOptional<IPCCoding.Vector<IPCCoding.WTFString>>')),
            ('std::pair<uint8_t, String>', ('(UInt8, String?)', 'IPCCoding.Pair<UInt8, IPCCoding.WTFString>')),
            ('std::span<const uint8_t>', ('[UInt8]', 'IPCCoding.Vector<UInt8>')),
            ('unsigned', ('UInt32', 'UInt32')),
            ('int', ('Int32', 'Int32')),
            ('Seconds', ('Double', 'Double')),
            ('WTF::Seconds', ('Double', 'Double')),
            ('WallTime', ('Double', 'Double')),
            ('WTF::WallTime', ('Double', 'Double')),
            ('WTFLogLevel', ('IPCTypes.WTFLogLevel', 'IPCTypes.CxxName.WTFLogLevel')),
            ('std::span<const float>', ('[Float]', 'IPCCoding.Vector<Float>')),
            ('std::span<const double, 6>', ('[Double]', 'IPCCoding.FixedSpan<Double, IPCCoding.Extent6>')),
            ('Vector<std::pair<Ref<WebCore::SharedBuffer>, WebCore::CDMKeyStatus>>', ('[(WebCore.SharedBuffer, IPCTypes.CDMKeyStatus)]', 'IPCCoding.Vector<IPCCoding.Pair<IPCCoding.CxxDecoded.SharedBuffer, IPCTypes.CxxName.WebCore_CDMKeyStatus>>')),
            ('Ref<WebCore::SharedBuffer>', ('WebCore.SharedBuffer', 'IPCCoding.CxxDecoded.SharedBuffer')),
            ('RefPtr<WebCore::SharedBuffer>', ('WebCore.SharedBuffer?', 'IPCCoding.StdOptional<IPCCoding.CxxDecoded.SharedBuffer>')),
            ('RefPtr<WebCore::VideoInfo>', ('WebCore.VideoInfo?', 'IPCCoding.StdOptional<IPCCoding.CxxDecoded.VideoInfo>')),
            ('std::optional<std::pair<WebCore::CDMMessageType, Ref<WebCore::SharedBuffer>>>', ('(IPCTypes.CDMMessageType, WebCore.SharedBuffer)?', 'IPCCoding.StdOptional<IPCCoding.Pair<IPCTypes.CxxName.WebCore_CDMMessageType, IPCCoding.CxxDecoded.SharedBuffer>>')),
            ('MachSendRight', ('IPCTypes.MachSendRight', 'IPCTypes.MachSendRight')),
            ('WTF::MachSendRight', ('IPCTypes.MachSendRight', 'IPCTypes.MachSendRight')),
            ('IPC::Semaphore', ('IPCTypes.Semaphore', 'IPCTypes.Semaphore')),
            ('IPC::Signal', ('IPCTypes.Signal', 'IPCTypes.Signal')),
            ('WebCore::SharedMemory::Handle', ('IPCTypes.SharedMemoryHandle', 'IPCTypes.SharedMemoryHandle')),
            ('std::optional<WebCore::SharedMemoryHandle>', ('IPCTypes.SharedMemoryHandle?', 'IPCCoding.OwnedOptional<IPCTypes.SharedMemoryHandle>')),
            ('Vector<MachSendRight>', ('IPCTypes.MachSendRightVector', 'IPCTypes.MachSendRightVector')),
            ('UInt32', ('UInt32', 'UInt32')),
            ('AudioStreamBasicDescription', ('IPCTypes.AudioStreamBasicDescription', 'IPCTypes.CxxName.AudioStreamBasicDescription')),
            ('RetainPtr<CVPixelBufferRef>', ('IPCTypes.MachSendRight?', 'IPCCoding.OwnedOptional<IPCTypes.MachSendRight>')),
            ('MediaTime', ('IPCTypes.MediaTime', 'IPCTypes.CxxName.WTF_MediaTime')),
            ('const WTF::MediaTime&', ('IPCTypes.MediaTime', 'IPCTypes.CxxName.WTF_MediaTime')),
            ('std::optional<MediaTime>', ('IPCTypes.MediaTime?', 'IPCCoding.StdOptional<IPCTypes.CxxName.WTF_MediaTime>')),
            ('GenericPromise::Result', ('Bool', 'Bool')),
            ('std::expected<MediaTime, WebCore::PlatformMediaError>', ('Result<IPCTypes.MediaTime, IPCUnexpected<IPCTypes.PlatformMediaError>>', 'IPCCoding.Expected<IPCTypes.CxxName.WTF_MediaTime, IPCTypes.CxxName.WebCore_PlatformMediaError>')),
            ('std::expected<void, WebCore::PlatformMediaError>', ('Result<Void, IPCUnexpected<IPCTypes.PlatformMediaError>>', 'IPCCoding.ExpectedVoid<IPCTypes.CxxName.WebCore_PlatformMediaError>')),
            ('std::expected<Vector<String>, uint8_t>', ('Result<[String?], IPCUnexpected<UInt8>>', 'IPCCoding.Expected<IPCCoding.Vector<IPCCoding.WTFString>, UInt8>')),
            ('WebCore::PathSegment::Data', ('IPCTypes.PathSegmentData', 'IPCTypes.CxxName.WebCore_PathSegment_Data')),
            ('Vector<WebCore::PathRoundedRect::Strategy>', ('[IPCTypes.PathRoundedRectStrategy]', 'IPCCoding.Vector<IPCTypes.CxxName.WebCore_PathRoundedRect_Strategy>')),
            ('WebCore::ColorSpace', ('IPCTypes.ColorSpace', 'IPCTypes.ColorSpace')),
            ('const WebCore::ColorSpace&', ('IPCTypes.ColorSpace', 'IPCTypes.ColorSpace')),
            ('std::optional<WebCore::ColorSpace>', ('IPCTypes.ColorSpace?', 'IPCCoding.StdOptional<IPCTypes.ColorSpace>')),
            ('std::array<float, 20>', ('IPCCoding.StdArray20<Float>.Value', 'IPCCoding.StdArray20<Float>')),
            ('std::array<WebCore::FloatPoint, 20>', ('[IPCTypes.FloatPoint]', 'IPCCoding.FixedSpan<IPCTypes.CxxName.WebCore_FloatPoint, IPCCoding.Extent20>')),
            ('WebCore::PathSegment', ('CGRendererPathSegment', 'IPCCoding.CxxDecoded.PathSegment')),
            ('std::array<WebCore::FloatPoint, 6>', ('[IPCTypes.FloatPoint]', 'IPCCoding.FixedSpan<IPCTypes.CxxName.WebCore_FloatPoint, IPCCoding.Extent6>')),
            ('std::span<const WebCore::GlyphBufferAdvance>', ('[CGSize]', 'IPCCoding.TrivialSpan<CGSize>')),
            ('std::span<const ::WebCore::GlyphBufferGlyph>', ('[CGGlyph]', 'IPCCoding.TrivialSpan<CGGlyph>')),
            ('std::span<const WebCore::FloatSegment>', ('IPCTypes.LineSegments', 'IPCTypes.LineSegments')),
            ('const std::span<const WebCore::PathDataLineColorThickness>&', ('IPCTypes.LineStrokes', 'IPCTypes.LineStrokes')),
        ]:
            self.assertEqual(swift_types.swift_type_and_coder(cpp_type), expected)

    def test_owned_types(self):
        for cpp_type in ['MachSendRight', 'IPC::Semaphore', 'const WebCore::SharedMemory::Handle&', 'std::optional<IPC::Semaphore>', 'Vector<WTF::MachSendRight>', 'RetainPtr<CVPixelBufferRef>']:
            self.assertTrue(swift_types.is_owned_type(cpp_type), cpp_type)
        for cpp_type in ['uint32_t', 'String', 'Vector<uint8_t>', 'std::optional<WebCore::FrameIdentifier>', 'RefPtr<WebCore::SharedBuffer>']:
            self.assertFalse(swift_types.is_owned_type(cpp_type), cpp_type)

    def test_coders_without_cxx_names(self):
        self.assertEqual(swift_types.swift_type_and_coder('Vector<Ref<WebKit::Node>>', cxx_name_coders=False), ('[IPCTypes.Node]', 'IPCCoding.Vector<IPCTypes.Node>'))
        self.assertEqual(swift_types.swift_type_and_coder('WebCore::FrameIdentifier', cxx_name_coders=False), ('IPCTypes.FrameIdentifier', 'IPCTypes.FrameIdentifier'))

    def test_unmappable_types(self):
        for cpp_type in ['long', 'URL', 'WTF::URL', '::WTF::URL', 'std::monostate', '::std::monostate', 'HashMap<String, String>', 'std::pair<uint8_t, long>', 'std::pair<uint8_t>', 'std::span<uint8_t>', 'std::span<const String>', 'std::span<const uint8_t, 4>', 'std::span<const String, 6>', 'std::span<const double, N>', 'Vector<IPC::Semaphore>', 'std::optional<Vector<MachSendRight>>', 'std::pair<MachSendRight, uint32_t>', 'RefPtr<IPC::Semaphore>', 'RetainPtr<CGImageRef>', 'std::array<float, 3>', 'std::array<float, N>', 'std::array<URL, 6>', 'std::span<WebCore::FloatSegment>', 'std::span<const WebCore::FloatSegment, 6>', 'std::span<const WebCore::FloatRect>']:
            with self.assertRaises(swift_types.UnmappableSwiftType):
                swift_types.swift_type_and_coder(cpp_type)

    def test_swift_form_names(self):
        self.assertEqual(swift_types.swift_form_name('WebCore::FrameIdentifier'), 'FrameIdentifier')
        self.assertEqual(swift_types.swift_form_name('::WebCore::PathSegment::Data'), 'PathSegmentData')

    def test_hand_written_types(self):
        self.assertTrue(swift_types.is_hand_written('const WebCore::ColorSpace&'))
        self.assertTrue(swift_types.is_hand_written('::WebCore::ColorSpace'))
        self.assertFalse(swift_types.is_hand_written('WebCore::PlatformColorSpace'))
        self.assertFalse(swift_types.is_owned_type('WebCore::ColorSpace'))
        self.assertEqual(swift_types.swift_type_and_coder('WebCore::Color'), ('IPCTypes.WebCoreColor', 'IPCTypes.WebCoreColor'))
        glyph_run = 'IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>'
        self.assertEqual(swift_types.swift_type_and_coder(glyph_run), ('IPCTypes.GlyphRun', 'IPCTypes.GlyphRun'))
        self.assertTrue(swift_types.takes_decode_context('const %s&' % glyph_run))
        self.assertFalse(swift_types.takes_decode_context('WebCore::Color'))

    def test_trivial_span_elements(self):
        self.assertTrue(swift_types.is_trivial_span_element('const WebCore::FloatSegment'))
        self.assertTrue(swift_types.is_trivial_span_element('::WebCore::PathDataLineColorThickness'))
        self.assertFalse(swift_types.is_trivial_span_element('WebCore::FloatRect'))

    def test_cxx_enum_types(self):
        self.assertTrue(swift_types.is_hand_written('WebCore::StyleAppearance'))
        self.assertEqual(swift_types.swift_type_and_coder('WebCore::StyleAppearance'), ('WebCore.StyleAppearance', 'IPCCoding.CxxEnum<WebCore.StyleAppearance>'))
        self.assertEqual(swift_types.swift_type_and_coder('std::optional<WebCore::StyleAppearance>'), ('WebCore.StyleAppearance?', 'IPCCoding.StdOptional<IPCCoding.CxxEnum<WebCore.StyleAppearance>>'))
        self.assertEqual(swift_types.swift_type_and_coder('WebCore::FontSmoothingMode'), ('WebCore.FontSmoothingMode', 'IPCCoding.CxxEnum<WebCore.FontSmoothingMode>'))
        self.assertEqual(swift_types.swift_type_and_coder('WebCore::StrokeStyle'), ('WebCore.StrokeStyle', 'IPCCoding.CxxEnum<WebCore.StrokeStyle>'))

    def test_cxx_name(self):
        self.assertEqual(swift_types.swift_cxx_name('WebCore::FrameIdentifier'), 'WebCore_FrameIdentifier')
        self.assertEqual(swift_types.swift_cxx_name('::WebCore::PlatformEvent::Kind'), 'WebCore_PlatformEvent_Kind')

    def test_helpers(self):
        self.assertEqual(swift_types.strip_cpp_type_decorations(' const struct WebKit::S& '), 'WebKit::S')
        self.assertEqual(swift_types.split_template_arguments('Vector<uint8_t>, HashMap<String, uint32_t>, int'), ['Vector<uint8_t>', 'HashMap<String, uint32_t>', 'int'])


class SwiftConditionTest(unittest.TestCase):
    def test_conditions(self):
        for condition, expected in [
            ('ENABLE(FOO)', 'ENABLE_FOO'),
            ('ENABLE(FOO) && (PLATFORM(COCOA) || !HAVE(BAR))', 'ENABLE_FOO && (WTF_PLATFORM_COCOA || !HAVE_BAR)'),
            ('USE(GLIB) || ASSERT_ENABLED', 'USE_GLIB || ASSERT_ENABLED'),
            ('!(ENABLE_FOO)', '!(ENABLE_FOO)'),
        ]:
            self.assertEqual(swift_types.swift_condition(condition), expected)

    def test_unavailable_macros(self):
        for condition, name in [
            ('CGFLOAT_IS_DOUBLE', 'CGFLOAT_IS_DOUBLE'),
            ('!RELEASE_LOG_DISABLED', 'RELEASE_LOG_DISABLED'),
            ('ENABLE(FOO) && LOG_DISABLED', 'LOG_DISABLED'),
            ('PLATFORM(MAC) && __MAC_OS_X_VERSION_MIN_REQUIRED', '__MAC_OS_X_VERSION_MIN_REQUIRED'),
            ('OS(WINDOWS)', r'OS\(\)'),
            ('defined(FOO)', r'defined\(\)'),
        ]:
            with self.assertRaisesRegex(swift_types.UnmappableSwiftCondition, r'cannot be evaluated in Swift: %s is not available there' % name):
                swift_types.swift_condition(condition)

    def test_unsupported_expressions(self):
        for condition in ['0', 'ENABLE(FOO) || 1', 'ENABLE(FOO) == 1', 'USE(FOO) && HAVE_BAR >= 2', 'ENABLE(FOO, BAR)', 'ENABLE_FOO(BAR)']:
            with self.assertRaisesRegex(swift_types.UnmappableSwiftCondition, r'cannot be evaluated in Swift'):
                swift_types.swift_condition(condition)


if __name__ == '__main__':
    unittest.main()
