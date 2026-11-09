#!/usr/bin/env python3
#
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

# Unit tests for generate-soft-link-accessors.py. Run: python3 Source/WebCore/Scripts/tests/generate-soft-link-accessors-unittest.py

import argparse
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBCORE_DIR = os.path.dirname(SCRIPTS_DIR)

_loader = importlib.machinery.SourceFileLoader('generate_soft_link_accessors', os.path.join(SCRIPTS_DIR, 'generate-soft-link-accessors.py'))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
generator = importlib.util.module_from_spec(_spec)
_loader.exec_module(generator)
generator.FRAMEWORK_HEADERS.setdefault('Media', '#include <Media/Media.h>')
generator.FRAMEWORK_HEADERS.setdefault('MediaCore', '#include <MediaCore/MediaCore.h>')

HEADER = '''
SOFT_LINK_FRAMEWORK_FOR_HEADER(PAL, Media)
SOFT_LINK_FRAMEWORK_FOR_HEADER(PAL, MediaCore)
SOFT_LINK_FUNCTION_FOR_HEADER(PAL, Media, MediaThingCopyName, OSStatus, (MediaThing thing, CFStringRef* outName), (thing, outName))
#define MediaThingCopyName softLink_Media_MediaThingCopyName
SOFT_LINK_FUNCTION_MAY_FAIL_FOR_HEADER(PAL, MediaCore, MediaCoreFetch, OSStatus, (CFDataRef* out), (out))
// SOFT_LINK_FUNCTION_FOR_HEADER(PAL, Media, CommentedOut, void, (), ())
/* SOFT_LINK_CONSTANT_FOR_HEADER(PAL, Media, AlsoCommentedOut, NSString *) */
SOFT_LINK_CONSTANT_FOR_HEADER(PAL, Media, MediaKey, NSString *)
SOFT_LINK_CONSTANT_MAY_FAIL_FOR_HEADER(PAL, Media, MediaNewKey, NSString *)
SOFT_LINK_CLASS_FOR_HEADER(PAL, MediaPlayer)
SOFT_LINK_CLASS_FOR_HEADER(PAL, MediaSession)
SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, Media, NotPAL, void, (), ())
'''

SOURCE = '''
SOFT_LINK_FRAMEWORK_FOR_SOURCE(PAL, Media)
SOFT_LINK_PRIVATE_FRAMEWORK_FOR_SOURCE_WITH_EXPORT(PAL, MediaCore, PAL_EXPORT)
SOFT_LINK_CLASS_FOR_SOURCE_WITH_EXPORT(PAL, Media, MediaPlayer, PAL_EXPORT)
SOFT_LINK_CLASS_FOR_SOURCE_OPTIONAL_WITH_EXPORT(PAL, Media, MediaSession, PAL_EXPORT)
SOFT_LINK_CLASS_FOR_SOURCE(PAL, Media, NotInTheHeader)
'''


def declarations():
    result = generator.PALDeclarations()
    generator.parse_pal_header(HEADER, SOURCE, result)
    return result


class CreateRuleTest(unittest.TestCase):
    def test_create_and_copy_return_retained(self):
        for name in ('CMTimeCopyAsDictionary', 'CFStringCreateWithCString', 'AudioComponentCopyName', 'CMSampleBufferCreate', 'CopyThing', 'ThingCopy', 'ThingCreate', 'createThing', 'Thing_Copy_2'):
            self.assertTrue(generator.follows_create_rule(name), name)

    def test_other_names_return_unretained(self):
        for name in ('CMSampleBufferGetFormatDescription', 'CFCopyrightGet', 'ThingRecreated', 'Thingrecreate', 'Scopy', 'Creates', 'CreatedThing', 'AudioUnitRender', 'Copier'):
            self.assertFalse(generator.follows_create_rule(name), name)


class PALParsingTest(unittest.TestCase):
    def test_kinds_frameworks_and_may_fail(self):
        symbols = declarations().symbols
        self.assertEqual((symbols['MediaThingCopyName'].kind, symbols['MediaThingCopyName'].framework, symbols['MediaThingCopyName'].may_fail), ('function', 'Media', False))
        self.assertEqual((symbols['MediaCoreFetch'].kind, symbols['MediaCoreFetch'].framework, symbols['MediaCoreFetch'].may_fail), ('function', 'MediaCore', True))
        self.assertEqual((symbols['MediaKey'].kind, symbols['MediaKey'].may_fail), ('constant', False))
        self.assertEqual((symbols['MediaNewKey'].kind, symbols['MediaNewKey'].may_fail), ('constant', True))

    def test_classes_take_framework_and_optionality_from_the_source(self):
        symbols = declarations().symbols
        self.assertEqual((symbols['MediaPlayer'].kind, symbols['MediaPlayer'].framework, symbols['MediaPlayer'].may_fail), ('class', 'Media', False))
        self.assertEqual((symbols['MediaSession'].kind, symbols['MediaSession'].may_fail), ('class', True))
        self.assertNotIn('NotInTheHeader', symbols)

    def test_comments_and_other_namespaces_are_ignored(self):
        symbols = declarations().symbols
        for name in ('CommentedOut', 'AlsoCommentedOut', 'NotPAL'):
            self.assertNotIn(name, symbols)

    def test_private_frameworks(self):
        result = declarations()
        self.assertEqual(result.private_frameworks, {'MediaCore'})
        self.assertEqual(generator.framework_path('MediaCore', result.private_frameworks), '/System/Library/PrivateFrameworks/MediaCore.framework/MediaCore')
        self.assertEqual(generator.framework_path('Media', result.private_frameworks), '/System/Library/Frameworks/Media.framework/Media')

    def test_real_pal_headers(self):
        result = generator.parse_pal([os.path.join(WEBCORE_DIR, 'PAL', 'pal', 'cf', 'AudioToolboxSoftLink.h'), os.path.join(WEBCORE_DIR, 'PAL', 'pal', 'cocoa', 'AVFoundationSoftLink.h')])
        self.assertEqual(result.symbols['AudioUnitRender'].framework, 'AudioToolbox')
        self.assertTrue(result.symbols['AudioComponentFetchServerRegistrations'].may_fail)
        self.assertIn('AudioToolboxCore', result.private_frameworks)
        self.assertEqual(result.symbols['AVContentKeySession'].kind, 'class')
        self.assertTrue(result.symbols['AVContentKeySession'].may_fail)
        self.assertTrue(result.symbols['AVContentKeySystemFairPlayStreaming'].may_fail)


class ManifestTest(unittest.TestCase):
    def test_entries(self):
        entries = generator.parse_manifest(['# comment', '', 'function Media MediaThingCopyName  # trailing', 'constant Media MediaKey as MediaKeyName', 'class Media MediaPlayer'])
        self.assertEqual(entries, [('function', 'Media', 'MediaThingCopyName', None), ('constant', 'Media', 'MediaKey', 'MediaKeyName'), ('class', 'Media', 'MediaPlayer', None)])

    def test_malformed_lines(self):
        for line in ('method Media X', 'function Media', 'function Media X Y', 'class Media X as Y'):
            with self.assertRaises(generator.GeneratorError, msg=line):
                generator.parse_manifest([line])

    def test_validation(self):
        result = declarations()
        generator.validate([('function', 'Media', 'MediaThingCopyName', None)], result, ['Media'])
        cases = [
            ([('function', 'Media', 'Undeclared', None)], 'not soft-linked by PAL'),
            ([('constant', 'Media', 'MediaThingCopyName', None)], 'PAL says function in Media'),
            ([('function', 'MediaCore', 'MediaThingCopyName', None)], 'PAL says function in Media'),
            ([('function', 'Media', 'MediaThingCopyName', None)] * 2, 'listed twice'),
        ]
        for entries, message in cases:
            with self.assertRaisesRegex(generator.GeneratorError, message):
                generator.validate(entries, result, ['Media', 'MediaCore'])
        with self.assertRaisesRegex(generator.GeneratorError, 'not one of the frameworks'):
            generator.validate([('class', 'Media', 'MediaPlayer', None)], result, ['Other'])

    def test_webcore_manifest_matches_pal(self):
        with open(os.path.join(WEBCORE_DIR, 'platform', 'cocoa', 'SoftLinkAccessors.in')) as f:
            entries = generator.parse_manifest(f.readlines())
        pal = os.path.join(WEBCORE_DIR, 'PAL', 'pal')
        result = generator.parse_pal([os.path.join(pal, 'cf', 'AudioToolboxSoftLink.h'), os.path.join(pal, 'cf', 'CoreMediaSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFAudioSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFoundationSoftLink.h')])
        generator.validate(entries, result, sorted({framework for _, framework, _, _ in entries}))


class SignatureParsingTest(unittest.TestCase):
    INTERFACE = '''
public func MediaThingCopyName(_ thing: MediaThing, _ outName: UnsafeMutablePointer<CFString?>) -> OSStatus
@available(macOS 26.0, *)
public func MediaMake(value: Int64, timescale: Int32) -> MediaTime
public func MediaReset(_ thing: MediaThing)
'''
    TYPEDEFS = '''
@unsafe public typealias PALSoftLink_MediaThingCopyName_t = @convention(c, cType: "OSStatus (*)(MediaThing, CFStringRef *)") (MediaThing, UnsafeMutablePointer<Unmanaged<CFString>?>) -> OSStatus
public typealias PALSoftLink_MediaMake_t = @convention(c) (Int64, Int32) -> MediaTime
@unsafe public typealias PALSoftLink_MediaKey_t = UnsafePointer<NSString>
'''

    def test_declarations(self):
        self.assertEqual(generator.find_declaration([self.INTERFACE], 'MediaMake'), (['value: Int64', 'timescale: Int32'], 'MediaTime'))
        self.assertEqual(generator.find_declaration([self.INTERFACE], 'MediaReset'), (['_ thing: MediaThing'], 'Void'))
        self.assertIsNone(generator.find_declaration([self.INTERFACE], 'MediaMissing'))

    def test_typedefs(self):
        self.assertEqual(generator.find_function_typedef(self.TYPEDEFS, 'PALSoftLink_MediaThingCopyName_t'), (['MediaThing', 'UnsafeMutablePointer<Unmanaged<CFString>?>'], 'OSStatus', True))
        self.assertEqual(generator.find_function_typedef(self.TYPEDEFS, 'PALSoftLink_MediaMake_t'), (['Int64', 'Int32'], 'MediaTime', False))
        self.assertEqual(generator.find_constant_typedef(self.TYPEDEFS, 'PALSoftLink_MediaKey_t'), 'NSString')


class AdaptationTest(unittest.TestCase):
    def test_rules(self):
        self.assertEqual(generator.adapt_argument('x', 'Int32', 'Int32'), ('x', False))
        self.assertEqual(generator.adapt_argument('flag', 'Bool', 'DarwinBoolean'), ('DarwinBoolean(flag)', False))
        self.assertEqual(generator.adapt_argument('out', 'UnsafeMutablePointer<CFString?>', 'UnsafeMutablePointer<Unmanaged<CFString>?>'), ('UnsafeMutableRawPointer(out).assumingMemoryBound(to: Unmanaged<CFString>?.self)', True))

    def test_no_rule(self):
        self.assertEqual(generator.adapt_argument('x', 'Int32', 'Int64'), (None, False))
        self.assertEqual(generator.adapt_argument('out', 'UnsafeMutablePointer<CFString?>', 'UnsafeMutablePointer<Unmanaged<CFData>?>'), (None, False))
        self.assertEqual(generator.adapt_argument('out', 'UnsafePointer<CFString?>', 'UnsafeMutablePointer<Unmanaged<CFString>?>'), (None, False))


class AccessorTest(unittest.TestCase):
    def function(self, name, may_fail, typedef, imported):
        return generator.function_accessor(generator.Declaration('function', 'Media', name, may_fail), typedef, imported)

    def test_required_function(self):
        lines = self.function('MediaMake', False, (['Int64', 'Int32'], 'MediaTime', False), (['value: Int64', 'timescale: Int32'], 'MediaTime'))
        self.assertEqual(lines, [
            'private let softLink_MediaMake: PALSoftLink_MediaMake_t = unsafe unsafeBitCast(softLinkRequiredSymbol(auditedName_MediaMake), to: PALSoftLink_MediaMake_t.self)',
            'func MediaMake(value: Int64, timescale: Int32) -> MediaTime { softLink_MediaMake(value, timescale) }',
        ])

    def test_may_fail_function(self):
        lines = self.function('MediaReset', True, (['MediaThing'], 'Void', False), (['_ thing: MediaThing'], 'Void'))
        self.assertEqual(lines[0], 'private let softLink_MediaReset: PALSoftLink_MediaReset_t? = unsafe softLinkSymbol(auditedName_MediaReset).map { unsafe unsafeBitCast($0, to: PALSoftLink_MediaReset_t.self) }')
        self.assertEqual(lines[1], 'var canLoad_Media_MediaReset: Bool { unsafe softLink_MediaReset != nil }')
        self.assertEqual(lines[2], 'func MediaReset(_ thing: MediaThing) { softLink_MediaReset!(thing) }')

    def test_cf_results_follow_the_create_rule(self):
        retained = self.function('MediaCopyDictionary', False, (['MediaTime'], 'Unmanaged<CFDictionary>?', True), (['_ time: MediaTime'], 'CFDictionary?'))
        self.assertTrue(retained[-1].endswith('{ unsafe softLink_MediaCopyDictionary(time)?.takeRetainedValue() }'), retained[-1])
        unretained = self.function('MediaGetDescription', False, (['MediaThing'], 'Unmanaged<CFString>?', True), (['_ thing: MediaThing'], 'CFString?'))
        self.assertTrue(unretained[-1].endswith('{ unsafe softLink_MediaGetDescription(thing)?.takeUnretainedValue() }'), unretained[-1])
        nonnull = self.function('MediaCreateName', False, (['MediaThing'], 'Unmanaged<CFString>', True), (['_ thing: MediaThing'], 'CFString'))
        self.assertTrue(nonnull[-1].endswith('{ unsafe softLink_MediaCreateName(thing).takeRetainedValue() }'), nonnull[-1])

    def test_out_parameters_bool_and_unlabeled_parameters(self):
        lines = self.function('MediaThingCreate', False, (['DarwinBoolean', 'UnsafeMutablePointer<Unmanaged<MediaThing>?>'], 'DarwinBoolean', True), (['_: Bool', 'thingOut: UnsafeMutablePointer<MediaThing?>'], 'Bool'))
        self.assertEqual(lines[-1], 'func MediaThingCreate(_ arg0: Bool, thingOut: UnsafeMutablePointer<MediaThing?>) -> Bool { unsafe softLink_MediaThingCreate(DarwinBoolean(arg0), UnsafeMutableRawPointer(thingOut).assumingMemoryBound(to: Unmanaged<MediaThing>?.self)).boolValue }')

    def test_mismatches_are_errors(self):
        with self.assertRaisesRegex(generator.GeneratorError, 'no adaptation rule'):
            self.function('MediaMake', False, (['Int64'], 'Int32', False), (['_ value: Int64'], 'Int64'))
        with self.assertRaisesRegex(generator.GeneratorError, 'no adaptation rule'):
            self.function('MediaMake', False, (['Int32'], 'Void', False), (['_ value: Int64'], 'Void'))
        with self.assertRaisesRegex(generator.GeneratorError, 'parameters'):
            self.function('MediaMake', False, (['Int64', 'Int32'], 'Void', False), (['_ value: Int64'], 'Void'))

    def test_constants(self):
        required = generator.constant_accessor(generator.Declaration('constant', 'Media', 'MediaKey', False), 'NSString')
        self.assertIn('    static let MediaKey: String = {', required)
        self.assertIn('        let address = unsafe softLinkRequiredSymbol(auditedName_MediaKey)', required)
        self.assertIn('        return unsafe address.load(as: PALSoftLink_MediaKey_t.Pointee.self) as String', required)
        optional = generator.constant_accessor(generator.Declaration('constant', 'Media', 'MediaNewKey', True), 'NSString?', 'MediaKeyName')
        self.assertIn('    static let MediaNewKey: MediaKeyName? = {', optional)
        self.assertIn('        guard let address = unsafe softLinkSymbol(auditedName_MediaNewKey) else {', optional)
        self.assertIn('        return MediaKeyName(rawValue: (unsafe address.load(as: PALSoftLink_MediaNewKey_t.Pointee.self))! as String)', optional)
        value = generator.constant_accessor(generator.Declaration('constant', 'Media', 'MediaZero', False), 'MediaTime')
        self.assertIn('    static let MediaZero: MediaTime = {', value)
        with self.assertRaisesRegex(generator.GeneratorError, 'only to NSString'):
            generator.constant_accessor(generator.Declaration('constant', 'Media', 'MediaZero', False), 'MediaTime', 'Other')

    def test_classes(self):
        required = '\n'.join(generator.class_accessor(generator.Declaration('class', 'Media', 'MediaPlayer', False), 'Media'))
        self.assertIn('static let MediaPlayer: Media.MediaPlayer.Type = {', required)
        self.assertIn('preconditionFailure("MediaPlayer is missing")', required)
        self.assertIn('static func cast(_ object: AnyObject?, to _: Media.MediaPlayer.Type) -> Media.MediaPlayer? {', required)
        self.assertIn('guard let object = object as? NSObject, object.isKind(of: MediaPlayer) else {', required)
        self.assertIn('return unsafe unsafeBitCast(object as AnyObject, to: Media.MediaPlayer.self)', required)
        optional = '\n'.join(generator.class_accessor(generator.Declaration('class', 'Media', 'MediaSession', True), 'Media'))
        self.assertIn('static let MediaSession: Media.MediaSession.Type? = {', optional)
        self.assertNotIn('preconditionFailure', optional)
        self.assertIn('static func cast(_ object: AnyObject?, to _: Media.MediaSession.Type?) -> Media.MediaSession? {', optional)
        self.assertIn('guard let classObject = MediaSession, let object = object as? NSObject, object.isKind(of: classObject) else {', optional)

    def test_audited_names(self):
        self.assertEqual(generator.audited_name('AB', '__TEXT,__dlsym_cstr'), '@section("__TEXT,__dlsym_cstr") @used private let auditedName_AB: (CChar, CChar, CChar) = (65, 66, 0)')


class FileTest(unittest.TestCase):
    def test_accessors_file(self):
        result = declarations()
        entries = [('function', 'Media', 'MediaThingCopyName', None), ('constant', 'Media', 'MediaKey', None), ('class', 'Media', 'MediaSession', None)]
        content = generator.accessors_file('Media', entries, result, SignatureParsingTest.TYPEDEFS, lambda framework: [SignatureParsingTest.INTERFACE])
        self.assertIn('dlopen("/System/Library/Frameworks/Media.framework/Media", RTLD_NOW)', content)
        self.assertIn('@section("__TEXT,__dlsym_cstr") @used private let auditedName_MediaThingCopyName', content)
        self.assertIn('@section("__TEXT,__getClass_cstr") @used private let auditedName_MediaSession', content)
        self.assertIn('enum MediaSoftLink { }', content)
        self.assertIn('enum MediaClass { }', content)
        self.assertIn('private func softLinkRequiredSymbol', content)
        self.assertIn('import Media\n', content)
        self.assertNotIn('internal import', content)
        private = generator.accessors_file('MediaCore', [('function', 'MediaCore', 'MediaCoreFetch', None)], result, '@unsafe public typealias PALSoftLink_MediaCoreFetch_t = @convention(c) (UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus', lambda framework: ['public func MediaCoreFetch(_ out: UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus'])
        self.assertIn('/System/Library/PrivateFrameworks/MediaCore.framework/MediaCore', private)
        self.assertNotIn('softLinkRequiredSymbol', private)
        self.assertNotIn('softLinkClass', private)

    def test_types_header(self):
        header = generator.types_header([('function', 'AudioToolbox', 'AudioUnitRender', None), ('class', 'AVFoundation', 'AVPlayer', None), ('constant', 'AVFoundation', 'AVMediaTypeVideo', None)])
        self.assertIn('#import <AVFoundation/AVFoundation.h>', header)
        self.assertIn('#include <AudioToolbox/AudioToolbox.h>', header)
        self.assertIn('typedef __typeof__(&AudioUnitRender) PALSoftLink_AudioUnitRender_t;', header)
        self.assertIn('typedef __typeof__(&AVMediaTypeVideo) PALSoftLink_AVMediaTypeVideo_t;', header)
        self.assertNotIn('AVPlayer', header)


class SynthesizerTest(unittest.TestCase):
    class FakeSynthesizer(generator.Synthesizer):
        LISTINGS = {
            'Media': 'import Media.Thing\nimport MediaCore_Private\nimport Other\n',
            'Media.Thing': 'public func MediaThing()\n',
            'MediaCore': 'import MediaCore.Component\n',
            'MediaCore.Component': 'public func MediaComponentFind()\n',
            'MediaCore_Private': 'public func MediaPrivateThing()\n',
        }

        def __init__(self):
            super().__init__(['tool'], 'sdk', 'target', [])
            self.calls = []

        def __call__(self, module, include_dirs=()):
            self.calls.append(module)
            return self.LISTINGS.get(module, '')

    def test_submodules_then_reexported_modules(self):
        synthesizer = self.FakeSynthesizer()
        self.assertEqual(generator.find_declaration(synthesizer.framework('Media'), 'MediaThing'), ([], 'Void'))
        self.assertEqual(synthesizer.calls, ['Media', 'Media.Thing'])
        self.assertEqual(generator.find_declaration(synthesizer.framework('Media'), 'MediaComponentFind'), ([], 'Void'))
        self.assertNotIn('MediaCore_Private', synthesizer.calls)
        self.assertEqual(generator.find_declaration(synthesizer.framework('Media'), 'MediaPrivateThing'), ([], 'Void'))
        self.assertNotIn('Other', synthesizer.calls)


@unittest.skipUnless(shutil.which('xcrun') and subprocess.run(['xcrun', '--find', 'swift-synthesize-interface'], capture_output=True).returncode == 0, 'needs the SDK and swift-synthesize-interface')
class SDKTest(unittest.TestCase):
    def test_webcore_manifest(self):
        sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
        pal = os.path.join(WEBCORE_DIR, 'PAL', 'pal')
        with tempfile.TemporaryDirectory() as output:
            arguments = argparse.Namespace(
                manifest=os.path.join(WEBCORE_DIR, 'platform', 'cocoa', 'SoftLinkAccessors.in'),
                pal_header=[os.path.join(pal, 'cf', 'AudioToolboxSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFAudioSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFoundationSoftLink.h')],
                framework=['AVFAudio', 'AVFoundation', 'AudioToolbox'], output_dir=output, types_output_dir=None, sdk=sdk, target='arm64-apple-macos15.0',
                synthesize_interface=None, synthesize_argument=[])
            generator.generate(arguments)
            with open(os.path.join(output, 'AudioToolboxSoftLinkAccessors.swift')) as f:
                audio = f.read()
            self.assertIn('func AudioUnitRender(_ inUnit: AudioUnit, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inOutputBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus', audio)
            with open(os.path.join(output, 'AVFoundationSoftLinkAccessors.swift')) as f:
                avfoundation = f.read()
            self.assertIn('static let AVContentKeySystemFairPlayStreaming: AVContentKeySystem? = {', avfoundation)
            self.assertTrue(os.path.exists(os.path.join(output, 'PALSoftLinkTypes', 'module.modulemap')))


if __name__ == '__main__':
    unittest.main()
