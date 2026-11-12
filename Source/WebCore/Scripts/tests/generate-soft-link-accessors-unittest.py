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
        entries = generator.parse_manifest(['# comment', '', 'function Media MediaThingCopyName  # trailing', 'constant Media MediaKey as MediaKeyName', 'class Media MediaPlayer', 'class Media MediaPlayerItem as MediaPlayer.Item'])
        self.assertEqual(entries, [('function', 'Media', 'MediaThingCopyName', None), ('constant', 'Media', 'MediaKey', 'MediaKeyName'), ('class', 'Media', 'MediaPlayer', None), ('class', 'Media', 'MediaPlayerItem', 'MediaPlayer.Item')])

    def test_function_with_pointer(self):
        self.assertEqual(generator.parse_manifest(['function Media MediaRender with pointer']), [('function', 'Media', 'MediaRender', 'pointer')])

    def test_malformed_lines(self):
        for line in ('method Media X', 'function Media', 'function Media X Y', 'function Media X as Y', 'class Media X as', 'member Media MediaPlayer play: play()', 'member Media MediaPlayer play: func play', 'function Media X with', 'class Media X with pointer'):
            with self.assertRaises(generator.GeneratorError, msg=line):
                generator.parse_manifest([line])

    def test_members(self):
        entries = generator.parse_manifest([
            'member Media MediaPlayer playItems:error: func playItems(_ items: NSArray) throws',
            'member Media MediaPlayer items var items: NSArray? { get }',
            'member Media MediaRegion pointsAtScale: func points(atScale scale: CGFloat) -> [CGPoint] counted by pointCount',
        ])
        self.assertEqual([entry[:3] for entry in entries], [('member', 'Media', 'MediaPlayer playItems:error:'), ('member', 'Media', 'MediaPlayer items'), ('member', 'Media', 'MediaRegion pointsAtScale:')])
        play, items, points = (entry[3] for entry in entries)
        self.assertEqual((play.name, play.parameters, play.throws, play.result, play.is_property), ('playItems', [('_', 'items', 'NSArray')], True, 'Void', False))
        self.assertEqual((items.name, items.result, items.is_property), ('items', 'NSArray?', True))
        self.assertEqual((points.parameters, points.result, points.counted_by), ([('atScale', 'scale', 'CGFloat')], '[CGPoint]', 'pointCount'))
        with self.assertRaisesRegex(generator.GeneratorError, 'needs an array result'):
            generator.parse_manifest(['member Media MediaRegion pointsAtScale: func points(atScale scale: CGFloat) -> CGPoint counted by pointCount'])

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
        # A member's class needn't be soft-linked: it's only a static type.
        member = generator.parse_manifest(['member Media MediaBase items var items: NSArray? { get }'])
        generator.validate(member, result, ['Media'])
        with self.assertRaisesRegex(generator.GeneratorError, 'listed twice'):
            generator.validate(member * 2, result, ['Media'])

    def test_webcore_manifest_matches_pal(self):
        with open(os.path.join(WEBCORE_DIR, 'platform', 'cocoa', 'SoftLinkAccessors.in')) as f:
            entries = generator.parse_manifest(f.readlines())
        pal = os.path.join(WEBCORE_DIR, 'PAL', 'pal')
        result = generator.parse_pal([os.path.join(pal, 'cf', 'AudioToolboxSoftLink.h'), os.path.join(pal, 'cf', 'CoreMediaSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFAudioSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFoundationSoftLink.h'), os.path.join(pal, 'cocoa', 'CoreMLSoftLink.h'), os.path.join(pal, 'cocoa', 'VisionSoftLink.h'), os.path.join(pal, 'mac', 'ScreenCaptureKitSoftLink.h')])
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

    def test_required_function_with_pointer(self):
        declaration = generator.Declaration('function', 'Media', 'MediaRender', False)
        lines = generator.function_accessor(declaration, (['Int32'], 'Int32', False), (['_ value: Int32'], 'Int32'), with_pointer=True)
        self.assertIn('var softLinkPointer_MediaRender: PALSoftLink_MediaRender_t { unsafe softLink_MediaRender }', lines)
        with self.assertRaises(generator.GeneratorError):
            generator.function_accessor(generator.Declaration('function', 'Media', 'MediaRender', True), (['Int32'], 'Int32', False), (['_ value: Int32'], 'Int32'), with_pointer=True)

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
        self.assertIn('        return stringConstant((unsafe address.load(as: PALSoftLink_MediaNewKey_t.Pointee.self))! as String) as MediaKeyName', optional)
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
        renamed = '\n'.join(generator.class_accessor(generator.Declaration('class', 'Media', 'MediaPlayerItem', False), 'Media', 'MediaPlayer.Item'))
        self.assertIn('static let MediaPlayerItem: Media.MediaPlayer.Item.Type = {', renamed)
        self.assertIn('return unsafe unsafeBitCast(object as AnyObject, to: Media.MediaPlayer.Item.self)', renamed)

    def test_audited_names(self):
        self.assertEqual(generator.audited_name('AB', '__TEXT,__dlsym_cstr'), '@section("__TEXT,__dlsym_cstr") @used private let auditedName_AB: (CChar, CChar, CChar) = (65, 66, 0)')


class MemberTest(unittest.TestCase):
    HEADERS = ['''
typedef NSString *MediaStage NS_STRING_ENUM;
/* @interface MediaCommentedOut : NSObject
- (void)ignored;
@end */
@interface MediaBase : NSObject <NSCopying>
@property (readonly, nonatomic, copy, nullable) NSArray<__kindof MediaItem*>* items;
- (nullable NSDictionary<MediaStage, NSArray<id<MediaDevice>>*>*) stageDevicesAndReturnError:(NSError**)error NS_REFINED_FOR_SWIFT;
- (void) setDevice:(nullable id<MediaDevice>)device forStage:(MediaStage)stage API_AVAILABLE(macos(14.0));
@end
''', '''
NS_ASSUME_NONNULL_BEGIN
@interface MediaPlayer : MediaBase
- (BOOL)playItems:(NSArray<MediaItem *> *)items error:(NSError **)error;
- (NSArray<MediaText*>*) topTexts:(NSUInteger)count;
- (nullable NSArray<MediaText*>*) bottomTexts:(NSUInteger)count;
@property (nonatomic, assign, getter=isMuted) BOOL muted
#if MEDIA_DEPLOYING_LATER
NS_SWIFT_NONISOLATED
#endif
;
@property (class, readonly) MediaPlayer *sharedPlayer;
@end
@interface MediaRegion : NSObject
@property (readonly) NSUInteger pointCount;
- (const CGPoint*) pointsAtScale:(CGFloat)scale NS_RETURNS_INNER_POINTER;
@end
@interface MediaItem (MediaItemFiltering)
+ (NSArray<MediaItem *> *)itemsFromArray:(NSArray<MediaItem *> *)items withKey:(nullable id)key;
@end
NS_ASSUME_NONNULL_END
@interface MediaLegacy : NSObject
- (NSArray *)legacyItems;
@end
''']

    def member(self, line):
        return generator.parse_manifest([line])[0][3]

    def test_headers(self):
        headers = generator.ObjCHeaders(self.HEADERS)
        self.assertEqual(headers.find('MediaPlayer', 'items'), ('NSArray<MediaItem*>*', []))
        self.assertEqual(headers.find('MediaPlayer', 'playItems:error:'), ('BOOL', ['NSArray<MediaItem*>*', 'NSError**']))
        self.assertEqual(headers.find('MediaBase', 'setDevice:forStage:'), ('void', ['id<MediaDevice>', 'MediaStage']))
        self.assertEqual(headers.find('MediaRegion', 'pointsAtScale:'), ('const CGPoint*', ['CGFloat']))
        self.assertIsNone(headers.find('MediaCommentedOut', 'ignored'))
        self.assertEqual(headers.find('MediaItem', 'itemsFromArray:withKey:', is_class_member=True), ('NSArray<MediaItem*>*', ['NSArray<MediaItem*>*', 'id']))
        self.assertIsNone(headers.find('MediaItem', 'itemsFromArray:withKey:'))
        self.assertIsNone(headers.find('MediaPlayer', 'topTexts:', is_class_member=True))
        self.assertEqual(headers.find('MediaPlayer', 'isMuted'), ('BOOL', []))
        self.assertEqual(headers.find('MediaPlayer', 'setMuted:'), ('void', ['BOOL']))
        self.assertIsNone(headers.find('MediaPlayer', 'muted'))
        self.assertEqual(headers.find('MediaPlayer', 'sharedPlayer', is_class_member=True), ('MediaPlayer*', []))
        self.assertIsNone(headers.find('MediaPlayer', 'sharedPlayer'))
        self.assertIsNone(headers.find('MediaPlayer', 'setSharedPlayer:', is_class_member=True))
        self.assertFalse(headers.result_may_be_nil('MediaPlayer', 'topTexts:'))
        self.assertTrue(headers.result_may_be_nil('MediaPlayer', 'bottomTexts:'))
        self.assertTrue(headers.result_may_be_nil('MediaPlayer', 'items'))
        self.assertTrue(headers.result_may_be_nil('MediaLegacy', 'legacyItems'))
        self.assertIn('MediaStage', headers.string_typedefs)

    def test_checks(self):
        headers = generator.ObjCHeaders(self.HEADERS)
        for line in (
            'member Media MediaPlayer playItems:error: func playItems(_ items: NSArray) throws',
            'member Media MediaPlayer items var items: NSArray? { get }',
            'member Media MediaPlayer stageDevicesAndReturnError: func stageDevices() throws -> NSDictionary',
            'member Media MediaPlayer setDevice:forStage: func setDevice(_ device: AnyObject?, forStage stage: NSString)',
            'member Media MediaPlayer topTexts: func topTexts(_ count: Int) -> NSArray',
            'member Media MediaRegion pointsAtScale: func points(atScale scale: CGFloat) -> [CGPoint] counted by pointCount',
            'member Media MediaItem +itemsFromArray:withKey: func items(from items: NSArray, withKey key: AnyObject?) -> NSArray',
        ):
            headers.check(self.member(line))
        cases = [
            ('member Media MediaPlayer missing: func missing(_ x: Int)', 'declare no such member'),
            ('member Media MediaPlayer playItems:error: func playItems(_ items: NSArray)', 'throws in the SDK'),
            ('member Media MediaPlayer topTexts: func topTexts(_ count: Int) throws -> NSArray', 'does not throw'),
            ('member Media MediaPlayer topTexts: func topTexts(_ count: Int, _ more: Int) -> NSArray', '1 parameters in the SDK, 2'),
            ('member Media MediaPlayer playItems:error: func playItems(_ items: [AnyObject]) throws', 'cannot stand for'),
            ('member Media MediaPlayer items var items: NSDictionary? { get }', 'cannot stand for'),
            ('member Media MediaPlayer setDevice:forStage: func setDevice(_ device: AnyObject?, forStage stage: Int)', 'cannot stand for'),
            ('member Media MediaRegion pointsAtScale: func points(atScale scale: CGFloat) -> [CGPoint]', 'cannot stand for'),
            ('member Media MediaPlayer bottomTexts: func bottomTexts(_ count: Int) -> NSArray', 'may be nil'),
            ('member Media MediaPlayer items var items: NSArray { get }', 'may be nil'),
            ('member Media MediaLegacy legacyItems func legacyItems() -> NSArray', 'may be nil'),
        ]
        for line, message in cases:
            with self.assertRaisesRegex(generator.GeneratorError, message, msg=line):
                headers.check(self.member(line))

    def test_erased_parameters(self):
        headers = generator.ObjCHeaders(self.HEADERS)
        erased = self.member('member Media MediaPlayer playItems:error: func playItems(_ items: NSArray) throws')
        headers.check(erased)
        self.assertTrue(erased.erases_parameters)
        self.assertIn('    @unsafe @objc(playItems:error:) func playItems(_ items: NSArray) throws', generator.member_accessor('Media', erased))
        exact = self.member('member Media MediaPlayer topTexts: func topTexts(_ count: Int) -> NSArray')
        headers.check(exact)
        self.assertFalse(exact.erases_parameters)
        self.assertIn('    @objc(topTexts:) func topTexts(_ count: Int) -> NSArray', generator.member_accessor('Media', exact))
        muted = self.member('member Media MediaPlayer isMuted var isMuted: Bool { get }')
        headers.check(muted)
        self.assertIn('    @objc(isMuted) var isMuted: Bool { get }', generator.member_accessor('Media', muted))
        headers.check(self.member('member Media MediaPlayer setMuted: func setMuted(_ muted: Bool)'))

    def test_views(self):
        lines = generator.member_accessor('Media', self.member('member Media MediaPlayer playItems:error: func playItems(_ items: NSArray) throws'))
        self.assertIn('@objc protocol MediaMember_MediaPlayer_playItems {', lines)
        self.assertIn('    @objc(playItems:error:) func playItems(_ items: NSArray) throws', lines)
        self.assertIn('    static func playItems(of object: Media.MediaPlayer) -> (any MediaMember_MediaPlayer_playItems)? {', lines)
        self.assertIn('        guard object.responds(to: NSSelectorFromString("playItems:error:")) else {', lines)
        self.assertIn('        return unsafe unsafeBitCast(object, to: (any MediaMember_MediaPlayer_playItems).self)', lines)
        lines = generator.member_accessor('Media', self.member('member Media MediaPlayer items var items: NSArray? { get }'))
        self.assertIn('    @objc(items) var items: NSArray? { get }', lines)

    def test_class_members(self):
        member = self.member('member Media MediaItem +itemsFromArray:withKey: func items(from items: NSArray, withKey key: AnyObject?) -> NSArray')
        self.assertEqual(member.key, 'MediaItem +itemsFromArray:withKey:')
        headers = generator.ObjCHeaders(self.HEADERS)
        with self.assertRaisesRegex(generator.GeneratorError, 'no such class member'):
            headers.check(self.member('member Media MediaPlayer +topTexts: func topTexts(_ count: Int) -> NSArray'))
        with self.assertRaisesRegex(generator.GeneratorError, 'no such member'):
            headers.check(self.member('member Media MediaItem itemsFromArray:withKey: func items(from items: NSArray, withKey key: AnyObject?) -> NSArray'))
        with self.assertRaisesRegex(generator.GeneratorError, 'declared as a func'):
            self.member('member Media MediaPlayer +items var items: NSArray? { get }')
        headers.check(member)
        lines = generator.member_accessor('Media', member)
        self.assertIn('// +[MediaItem itemsFromArray:withKey:], with NSArray and NSDictionary for the SDK\'s typed collections.', lines)
        self.assertIn('    @unsafe @objc(itemsFromArray:withKey:) func items(from items: NSArray, withKey key: AnyObject?) -> NSArray', lines)
        self.assertIn('    static func items(of classObject: Media.MediaItem.Type) -> (any MediaMember_MediaItem_items)? {', lines)
        self.assertIn('        let object: AnyObject = classObject', lines)
        self.assertIn('        guard object.responds(to: NSSelectorFromString("itemsFromArray:withKey:")) else {', lines)
        self.assertIn('        return unsafe unsafeBitCast(object, to: (any MediaMember_MediaItem_items).self)', lines)

    def test_counted_adapter(self):
        lines = generator.member_accessor('Media', self.member('member Media MediaRegion pointsAtScale: func points(atScale scale: CGFloat) -> [CGPoint] counted by pointCount'))
        self.assertIn('    @objc(pointsAtScale:) func points(atScale scale: CGFloat) -> UnsafePointer<CGPoint>?', lines)
        self.assertIn('    static func points(of object: Media.MediaRegion, atScale scale: CGFloat) -> [CGPoint]? {', lines)
        self.assertIn('        guard let elements = unsafe view.points(atScale: scale) else {', lines)
        self.assertIn('        return unsafe Array(UnsafeBufferPointer(start: elements, count: object.pointCount))', lines)


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
        self.assertIn('var MediaFrameworkIsAvailable: Bool { unsafe frameworkHandleIfLoaded != nil }', content)
        self.assertNotIn('stringConstant', content)
        typed = generator.accessors_file('Media', [('constant', 'Media', 'MediaKey', 'MediaKeyName')], result, SignatureParsingTest.TYPEDEFS, lambda framework: [], path='/tmp/Fake/Media')
        self.assertIn('dlopen("/tmp/Fake/Media", RTLD_NOW)', typed)
        self.assertIn('private func stringConstant<Constant: RawRepresentable>(_ value: String) -> Constant where Constant.RawValue == String {', typed)
        private = generator.accessors_file('MediaCore', [('function', 'MediaCore', 'MediaCoreFetch', None)], result, '@unsafe public typealias PALSoftLink_MediaCoreFetch_t = @convention(c) (UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus', lambda framework: ['public func MediaCoreFetch(_ out: UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus'])
        self.assertIn('/System/Library/PrivateFrameworks/MediaCore.framework/MediaCore', private)
        self.assertNotIn('softLinkRequiredSymbol', private)
        self.assertNotIn('softLinkClass', private)
        members = generator.parse_manifest(['member Media MediaPlayer playItems:error: func playItems(_ items: NSArray) throws'])
        content = generator.accessors_file('Media', entries + members, result, SignatureParsingTest.TYPEDEFS, lambda framework: [SignatureParsingTest.INTERFACE], lambda framework: generator.ObjCHeaders(MemberTest.HEADERS))
        self.assertIn('enum MediaMember { }', content)
        self.assertIn('@objc protocol MediaMember_MediaPlayer_playItems {', content)
        self.assertNotIn('auditedName_MediaPlayer playItems', content)
        with self.assertRaisesRegex(generator.GeneratorError, 'declare no such member'):
            generator.accessors_file('Media', generator.parse_manifest(['member Media MediaPlayer missing var missing: NSArray? { get }']), result, '', lambda framework: [], lambda framework: generator.ObjCHeaders(MemberTest.HEADERS))

    def test_stub_file(self):
        stub = generator.stub_file('Vision')
        self.assertIn('no Vision', stub)
        self.assertNotIn('import', stub)

    def test_types_header(self):
        header = generator.types_header([('function', 'AudioToolbox', 'AudioUnitRender', None), ('class', 'AVFoundation', 'AVPlayer', None), ('constant', 'AVFoundation', 'AVMediaTypeVideo', None)] + generator.parse_manifest(['member Media MediaPlayer items var items: NSArray? { get }']))
        self.assertIn('#import <AVFoundation/AVFoundation.h>', header)
        self.assertIn('#include <AudioToolbox/AudioToolbox.h>', header)
        self.assertIn('typedef __typeof__(&AudioUnitRender) PALSoftLink_AudioUnitRender_t;', header)
        self.assertIn('typedef __typeof__(&AVMediaTypeVideo) PALSoftLink_AVMediaTypeVideo_t;', header)
        self.assertNotIn('AVPlayer', header)
        self.assertNotIn('MediaPlayer', header)
        result = generator.PALDeclarations()
        generator.parse_pal_header('SOFT_LINK_CONSTANT_MAY_FAIL_FOR_HEADER(PAL, AVFoundation, AVCaptureDeviceTypeDeskViewCamera, NSString *)\n', '', result)
        header = generator.types_header([('constant', 'AVFoundation', 'AVCaptureDeviceTypeDeskViewCamera', None)], result)
        self.assertIn('typedef NSString * const * PALSoftLink_AVCaptureDeviceTypeDeskViewCamera_t;', header)

    @unittest.skipUnless(shutil.which('xcrun') and subprocess.run(['xcrun', '--find', 'clang'], capture_output=True).returncode == 0, 'needs clang')
    def test_types_header_names_deprecated_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            os.makedirs(os.path.join(directory, 'Media'))
            with open(os.path.join(directory, 'Media', 'Media.h'), 'w') as f:
                f.write('extern const int MediaOldKey __attribute__((deprecated));\nvoid MediaOldFunction(void) __attribute__((deprecated));\n')
            with open(os.path.join(directory, 'PALSoftLinkTypes.h'), 'w') as f:
                f.write(generator.types_header([('constant', 'Media', 'MediaOldKey', None), ('function', 'Media', 'MediaOldFunction', None)]))
            source = os.path.join(directory, 'client.c')
            with open(source, 'w') as f:
                f.write('#include "PALSoftLinkTypes.h"\n')
            result = subprocess.run(['xcrun', 'clang', '-fsyntax-only', '-Werror', '-Wdeprecated-declarations', '-I', directory, source], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


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
                pal_header=[os.path.join(pal, 'cf', 'AudioToolboxSoftLink.h'), os.path.join(pal, 'cf', 'CoreMediaSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFAudioSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFoundationSoftLink.h'), os.path.join(pal, 'cocoa', 'CoreMLSoftLink.h'), os.path.join(pal, 'cocoa', 'VisionSoftLink.h'), os.path.join(pal, 'mac', 'ScreenCaptureKitSoftLink.h')],
                framework=['AVFAudio', 'AVFoundation', 'AudioToolbox', 'CoreML', 'CoreMedia', 'ScreenCaptureKit', 'Vision'], stub_framework=[], output_dir=output, types_output_dir=None, sdk=sdk, target='arm64-apple-macos15.0',
                synthesize_interface=None, synthesize_argument=[])
            generator.generate(arguments)
            with open(os.path.join(output, 'AudioToolboxSoftLinkAccessors.swift')) as f:
                audio = f.read()
            self.assertIn('func AudioUnitRender(_ inUnit: AudioUnit, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inOutputBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus', audio)
            with open(os.path.join(output, 'AVFoundationSoftLinkAccessors.swift')) as f:
                avfoundation = f.read()
            self.assertIn('static let AVContentKeySystemFairPlayStreaming: AVContentKeySystem? = {', avfoundation)
            with open(os.path.join(output, 'CoreMediaSoftLinkAccessors.swift')) as f:
                coremedia = f.read()
            self.assertIn('func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {', coremedia)
            self.assertTrue(os.path.exists(os.path.join(output, 'PALSoftLinkTypes', 'module.modulemap')))
            with open(os.path.join(output, 'VisionSoftLinkAccessors.swift')) as f:
                vision = f.read()
            self.assertIn('static let VNBarcodeSymbologyQR: VNBarcodeSymbology = {', vision)
            self.assertIn('static func pointsInImage(of object: Vision.VNFaceLandmarkRegion2D, imageSize: CGSize) -> [CGPoint]? {', vision)

    def test_stub_frameworks(self):
        sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
        pal = os.path.join(WEBCORE_DIR, 'PAL', 'pal')
        with tempfile.TemporaryDirectory() as output:
            arguments = argparse.Namespace(
                manifest=os.path.join(WEBCORE_DIR, 'platform', 'cocoa', 'SoftLinkAccessors.in'),
                pal_header=[os.path.join(pal, 'cf', 'AudioToolboxSoftLink.h'), os.path.join(pal, 'cf', 'CoreMediaSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFAudioSoftLink.h'), os.path.join(pal, 'cocoa', 'AVFoundationSoftLink.h'), os.path.join(pal, 'cocoa', 'CoreMLSoftLink.h')],
                framework=['AVFAudio', 'AVFoundation', 'AudioToolbox', 'CoreML', 'CoreMedia'], stub_framework=['ScreenCaptureKit', 'Vision'], output_dir=output, types_output_dir=None, sdk=sdk, target='arm64-apple-macos15.0',
                synthesize_interface=None, synthesize_argument=[])
            generator.generate(arguments)
            with open(os.path.join(output, 'VisionSoftLinkAccessors.swift')) as f:
                self.assertEqual(f.read(), generator.stub_file('Vision'))
            with open(os.path.join(output, 'PALSoftLinkTypes', 'PALSoftLinkTypes.h')) as f:
                self.assertNotIn('Vision', f.read())


if __name__ == '__main__':
    unittest.main()
