/*
 * Copyright (C) 2012-2025 Apple Inc. All rights reserved.
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

#pragma once

#if ENABLE(VIDEO)

#include <WebCore/InbandTextTrackPrivateClient.h>
#if PLATFORM(COCOA)
#include <WebCore/ISOVTTCue.h>
#include <WebCore/SharedBuffer.h>
#endif
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMallocInlines.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebCore {

enum class InbandTextTrackPrivateMode : uint8_t {
    Disabled,
    Hidden,
    Showing
};

class InbandTextTrackPrivate : public TrackPrivateBase {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(InbandTextTrackPrivate);
public:
    enum class CueFormat : uint8_t {
        Data,
        Generic,
        WebVTT,
        Unknown
    };
    static Ref<InbandTextTrackPrivate> create(CueFormat format) { return adoptRef(*new InbandTextTrackPrivate(format)); }
    virtual ~InbandTextTrackPrivate() = default;

    using Mode = InbandTextTrackPrivateMode;
    virtual void setMode(Mode mode) { m_mode = mode; };
    virtual InbandTextTrackPrivate::Mode mode() const { return m_mode; }

    enum class Kind : uint8_t {
        Subtitles,
        Captions,
        Descriptions,
        Chapters,
        Metadata,
        Forced,
        None
    };
    virtual Kind kind() const { return Kind::Subtitles; }

    virtual bool isClosedCaptions() const { return false; }
    virtual bool isSDH() const { return false; }
    virtual bool containsOnlyForcedSubtitles() const { return false; }
    virtual bool isMainProgramContent() const { return true; }
    virtual bool isEasyToRead() const { return false; }
    virtual bool isDefault() const { return false; }
    virtual bool isMachineGenerated() const { return false; }
    String label() const override { return emptyString(); }
    String language() const override { return emptyString(); }
    std::optional<String> trackUID() const override { return emptyString(); }
    virtual String inBandMetadataTrackDispatchType() const { return emptyString(); }

    CueFormat cueFormat() const { return m_format; }
    
    bool operator==(const InbandTextTrackPrivate& track) const
    {
        return TrackPrivateBase::operator==(track)
            && cueFormat() == track.cueFormat()
            && kind() == track.kind()
            && isClosedCaptions() == track.isClosedCaptions()
            && isSDH() == track.isSDH()
            && containsOnlyForcedSubtitles() == track.containsOnlyForcedSubtitles()
            && isMainProgramContent() == track.isMainProgramContent()
            && isEasyToRead() == track.isEasyToRead()
            && isDefault() == track.isDefault()
            && inBandMetadataTrackDispatchType() == track.inBandMetadataTrackDispatchType();
    }

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const override { return "InbandTextTrackPrivate"_s; }
#endif

    Type type() const final { return Type::Text; };

    enum class InbandTextTrackType : uint8_t {
        BaseTrack,
        AVFTrack
    };
    virtual InbandTextTrackType inbandTextTrackType() const { return InbandTextTrackType::BaseTrack; }

protected:
    InbandTextTrackPrivate(CueFormat format)
        : m_format(format)
    {
    }

private:
    CueFormat m_format { CueFormat::Unknown };
    Mode m_mode { Mode::Disabled };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if PLATFORM(COCOA)
// A track client for Swift (TrackPrivateClientSwiftAdapters.swift). The adapter is its track's client from create() to its
// destruction, with the callbacks on the main thread, and forwards them to the Swift delegate that create() is given:
// an Unmanaged retained box that the adapter releases when destroyed, which holds the delegate weakly.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/TrackPrivateClientSwiftAdapters.swift") SwiftInbandTextTrackPrivateClientAdapter final
    : public ThreadSafeRefCounted<SwiftInbandTextTrackPrivateClientAdapter, WTF::DestructionThread::Main>
    , public InbandTextTrackPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(SwiftInbandTextTrackPrivateClientAdapter);
public:
    // Unsafe: the box must be a retained delegate box made for this adapter.
    SWIFT_UNSAFE static SwiftInbandTextTrackPrivateClientAdapter* WTF_NONNULL create(InbandTextTrackPrivate&, uintptr_t delegateBox) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~SwiftInbandTextTrackPrivateClientAdapter();

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    // For Swift, which doesn't import InbandTextTrackPrivate's operator==.
    static bool equal(const InbandTextTrackPrivate& a, const InbandTextTrackPrivate& b) { return a == b; }

private:
    SwiftInbandTextTrackPrivateClientAdapter(InbandTextTrackPrivate&, uintptr_t delegateBox);
    // Unsafe: the box must be one that create() was given, which only the destructor releases.
    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    SWIFT_MAIN_ACTOR void idChanged(TrackID) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void labelChanged(const String&) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void languageChanged(const String&) final;
    SWIFT_MAIN_ACTOR void willRemove() final;
    SWIFT_MAIN_ACTOR void addGenericCue(InbandGenericCue&) final;
    SWIFT_MAIN_ACTOR void updateGenericCue(InbandGenericCue&) final;
    SWIFT_MAIN_ACTOR void removeGenericCue(InbandGenericCue&) final;

    // The forms that Swift can't take (rvalues, spans, references to times), which the C++ forwards to the members after.
    void addDataCue(const MediaTime& start, const MediaTime& end, std::span<const uint8_t>) final;
#if ENABLE(DATACUE_VALUE)
    void addDataCue(const MediaTime& start, const MediaTime& end, Ref<SerializedPlatformDataCue>&&, const String&) final;
    void updateDataCue(const MediaTime& start, const MediaTime& end, SerializedPlatformDataCue&) final;
    void removeDataCue(const MediaTime& start, const MediaTime& end, SerializedPlatformDataCue&) final;
#endif
    void parseWebVTTFileHeader(String&&) final;
    void parseWebVTTCueData(std::span<const uint8_t>) final;
    void parseWebVTTCueData(ISOWebVTTCue&&) final;

    SWIFT_MAIN_ACTOR void swiftAddDataCue(MediaTime start, MediaTime end, SharedBuffer&);
#if ENABLE(DATACUE_VALUE)
    SWIFT_MAIN_ACTOR void swiftAddDataCueWithType(MediaTime start, MediaTime end, SerializedPlatformDataCue&, String type);
    SWIFT_MAIN_ACTOR void swiftUpdateDataCue(MediaTime start, MediaTime end, SerializedPlatformDataCue&);
    SWIFT_MAIN_ACTOR void swiftRemoveDataCue(MediaTime start, MediaTime end, SerializedPlatformDataCue&);
#endif
    SWIFT_MAIN_ACTOR void swiftParseWebVTTFileHeader(String);
    SWIFT_MAIN_ACTOR void swiftParseWebVTTCueData(SharedBuffer&);
    SWIFT_MAIN_ACTOR void swiftParseWebVTTCue(ISOWebVTTCue);

    const Ref<InbandTextTrackPrivate> m_track;
    const uintptr_t m_delegateBox;
    size_t m_clientIndex { 0 };
};
#endif

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::InbandTextTrackPrivate)
static bool isType(const WebCore::TrackPrivateBase& track) { return track.type() == WebCore::TrackPrivateBase::Type::Text; }
SPECIALIZE_TYPE_TRAITS_END()

IGNORE_CLANG_WARNINGS_END

#endif // ENABLE(VIDEO)

