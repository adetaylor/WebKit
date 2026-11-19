/*
 * Copyright (C) 2012-2017 Apple Inc. All rights reserved.
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

#include <WebCore/AudioTrackPrivateClient.h>
#include <WebCore/PlatformAudioTrackConfiguration.h>
#include <WebCore/TrackPrivateBase.h>
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(VIDEO)

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebCore {

class AudioInfo;

class AudioTrackPrivate : public TrackPrivateBase {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(AudioTrackPrivate);
public:
    virtual void setEnabled(bool enabled)
    {
        if (m_enabled == enabled)
            return;
        m_enabled = enabled;
        notifyClients([enabled](auto& client) {
            downcast<AudioTrackPrivateClient>(client).enabledChanged(enabled);
        });
        RefPtr<SharedEnabledChangedCallback> enabledChangedCallback;
        {
            Locker locker { m_lock };
            enabledChangedCallback = m_enabledChangedCallback;
        }
        if (enabledChangedCallback)
            enabledChangedCallback->get()(*this, m_enabled);
    }

    bool enabled() const { return m_enabled; }

    enum class Kind : uint8_t { Alternative, Description, Main, MainDesc, Translation, Commentary, None };
    virtual Kind kind() const { return Kind::None; }

    virtual bool isBackedByMediaStreamTrack() const { return false; }

    using EnabledChangedCallback = Function<void(AudioTrackPrivate&, bool enabled)>;
    void setEnabledChangedCallback(EnabledChangedCallback&& callback)
    {
        RefPtr<SharedEnabledChangedCallback> sharedCallback;
        if (callback)
            sharedCallback = SharedEnabledChangedCallback::create(WTF::move(callback));
        RefPtr<SharedEnabledChangedCallback> previousCallback;
        {
            Locker locker { m_lock };
            previousCallback = std::exchange(m_enabledChangedCallback, WTF::move(sharedCallback));
        }
        // Release the previous callback outside of m_lock; an in-flight setEnabled() may still hold it.
    }

    const PlatformAudioTrackConfiguration& configuration() const LIFETIME_BOUND { return m_configuration; }
    void setConfiguration(PlatformAudioTrackConfiguration&& configuration)
    {
        if (configuration == m_configuration)
            return;
        m_configuration = WTF::move(configuration);
        notifyClients([configuration = m_configuration](auto& client) {
            downcast<AudioTrackPrivateClient>(client).configurationChanged(configuration);
        });
    }

    virtual void setFormatDescription(Ref<AudioInfo>&&) { }

    bool operator==(const AudioTrackPrivate& track) const
    {
        return TrackPrivateBase::operator==(track)
            && configuration() == track.configuration()
            && kind() == track.kind();
    }

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const override { return "AudioTrackPrivate"_s; }
#endif

    Type type() const final { return Type::Audio; }

protected:
    AudioTrackPrivate() = default;

private:
    bool m_enabled { false };
    PlatformAudioTrackConfiguration m_configuration;
    using SharedEnabledChangedCallback = Shared<EnabledChangedCallback>;
    RefPtr<SharedEnabledChangedCallback> m_enabledChangedCallback WTF_GUARDED_BY_LOCK(m_lock);
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if PLATFORM(COCOA)
// A track client for Swift (TrackPrivateClientSwiftAdapters.swift). The adapter is its track's client from create() to its
// destruction, with the callbacks on the main thread, and forwards them to the Swift delegate that create() is given:
// an Unmanaged retained box that the adapter releases when destroyed, which holds the delegate weakly.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/TrackPrivateClientSwiftAdapters.swift") SwiftAudioTrackPrivateClientAdapter final
    : public ThreadSafeRefCounted<SwiftAudioTrackPrivateClientAdapter, WTF::DestructionThread::Main>
    , public AudioTrackPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(SwiftAudioTrackPrivateClientAdapter);
public:
    // Unsafe: the box must be a retained delegate box made for this adapter.
    SWIFT_UNSAFE static SwiftAudioTrackPrivateClientAdapter* WTF_NONNULL create(AudioTrackPrivate&, uintptr_t delegateBox) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~SwiftAudioTrackPrivateClientAdapter();

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    // For Swift, which doesn't import AudioTrackPrivate's configuration(), which returns a reference, or its operator==.
    static PlatformAudioTrackConfiguration configuration(const AudioTrackPrivate& track) { return track.configuration(); }
    static bool equal(const AudioTrackPrivate& a, const AudioTrackPrivate& b) { return a == b; }

private:
    SwiftAudioTrackPrivateClientAdapter(AudioTrackPrivate&, uintptr_t delegateBox);
    // Unsafe: the box must be one that create() was given, which only the destructor releases.
    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    SWIFT_MAIN_ACTOR void idChanged(TrackID) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void labelChanged(const String&) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void languageChanged(const String&) final;
    SWIFT_MAIN_ACTOR void willRemove() final;
    SWIFT_MAIN_ACTOR void enabledChanged(bool) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void configurationChanged(const PlatformAudioTrackConfiguration&) final;

    const Ref<AudioTrackPrivate> m_track;
    const uintptr_t m_delegateBox;
    size_t m_clientIndex { 0 };
};
#endif

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::AudioTrackPrivate)
static bool isType(const WebCore::TrackPrivateBase& track) { return track.type() == WebCore::TrackPrivateBase::Type::Audio; }
SPECIALIZE_TYPE_TRAITS_END()

IGNORE_CLANG_WARNINGS_END

#endif
