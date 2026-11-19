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

#if ENABLE(VIDEO)

#include <WebCore/PlatformVideoTrackConfiguration.h>
#include <WebCore/TrackPrivateBase.h>
#include <WebCore/VideoTrackPrivateClient.h>
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMallocInlines.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebCore {

class VideoInfo;

class VideoTrackPrivate : public TrackPrivateBase {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(VideoTrackPrivate);
public:
    virtual void setSelected(bool selected)
    {
        if (m_selected == selected)
            return;
        m_selected = selected;
        notifyClients([selected](auto& client) {
            downcast<VideoTrackPrivateClient>(client).selectedChanged(selected);
        });
        RefPtr<SharedSelectedChangedCallback> selectedChangedCallback;
        {
            Locker locker { m_lock };
            selectedChangedCallback = m_selectedChangedCallback;
        }
        if (selectedChangedCallback)
            selectedChangedCallback->get()(*this, m_selected);
    }
    virtual bool selected() const { return m_selected; }

    enum class Kind : uint8_t { Alternative, Captions, Main, Sign, Subtitles, Commentary, None };
    virtual Kind kind() const { return Kind::None; }

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const final { return "VideoTrackPrivate"_s; }
#endif

    using SelectedChangedCallback = Function<void(VideoTrackPrivate&, bool selected)>;
    void setSelectedChangedCallback(SelectedChangedCallback&& callback)
    {
        RefPtr<SharedSelectedChangedCallback> sharedCallback;
        if (callback)
            sharedCallback = SharedSelectedChangedCallback::create(WTF::move(callback));
        RefPtr<SharedSelectedChangedCallback> previousCallback;
        {
            Locker locker { m_lock };
            previousCallback = std::exchange(m_selectedChangedCallback, WTF::move(sharedCallback));
        }
        // Release the previous callback outside of m_lock; an in-flight setSelected() may still hold it.
    }

    const PlatformVideoTrackConfiguration& configuration() const LIFETIME_BOUND { return m_configuration; }
    void setConfiguration(PlatformVideoTrackConfiguration&& configuration)
    {
        if (configuration == m_configuration)
            return;
        m_configuration = WTF::move(configuration);
        notifyClients([configuration = m_configuration](auto& client) {
            downcast<VideoTrackPrivateClient>(client).configurationChanged(configuration);
        });
    }
    
    bool operator==(const VideoTrackPrivate& track) const
    {
        return TrackPrivateBase::operator==(track)
            && configuration() == track.configuration()
            && kind() == track.kind();
    }

    Type type() const final { return Type::Video; }

    virtual void setFormatDescription(Ref<VideoInfo>&&) { }

protected:
    VideoTrackPrivate() = default;

private:
    bool m_selected { false };
    PlatformVideoTrackConfiguration m_configuration;

    using SharedSelectedChangedCallback = Shared<SelectedChangedCallback>;
    RefPtr<SharedSelectedChangedCallback> m_selectedChangedCallback WTF_GUARDED_BY_LOCK(m_lock);
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if PLATFORM(COCOA)
// A track client for Swift (TrackPrivateClientSwiftAdapters.swift). The adapter is its track's client from create() to its
// destruction, with the callbacks on the main thread, and forwards them to the Swift delegate that create() is given:
// an Unmanaged retained box that the adapter releases when destroyed, which holds the delegate weakly.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/TrackPrivateClientSwiftAdapters.swift") SwiftVideoTrackPrivateClientAdapter final
    : public ThreadSafeRefCounted<SwiftVideoTrackPrivateClientAdapter, WTF::DestructionThread::Main>
    , public VideoTrackPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(SwiftVideoTrackPrivateClientAdapter);
public:
    // Unsafe: the box must be a retained delegate box made for this adapter.
    SWIFT_UNSAFE static SwiftVideoTrackPrivateClientAdapter* WTF_NONNULL create(VideoTrackPrivate&, uintptr_t delegateBox) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~SwiftVideoTrackPrivateClientAdapter();

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    // For Swift, which doesn't import VideoTrackPrivate's configuration(), which returns a reference, or its operator==.
    static PlatformVideoTrackConfiguration configuration(const VideoTrackPrivate& track) { return track.configuration(); }
    static bool equal(const VideoTrackPrivate& a, const VideoTrackPrivate& b) { return a == b; }

private:
    SwiftVideoTrackPrivateClientAdapter(VideoTrackPrivate&, uintptr_t delegateBox);
    // Unsafe: the box must be one that create() was given, which only the destructor releases.
    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    SWIFT_MAIN_ACTOR void idChanged(TrackID) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void labelChanged(const String&) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void languageChanged(const String&) final;
    SWIFT_MAIN_ACTOR void willRemove() final;
    SWIFT_MAIN_ACTOR void selectedChanged(bool) final;
    SWIFT_MAIN_ACTOR SWIFT_UNSAFE void configurationChanged(const PlatformVideoTrackConfiguration&) final;

    const Ref<VideoTrackPrivate> m_track;
    const uintptr_t m_delegateBox;
    size_t m_clientIndex { 0 };
};
#endif

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::VideoTrackPrivate)
static bool isType(const WebCore::TrackPrivateBase& track) { return track.type() == WebCore::TrackPrivateBase::Type::Video; }
SPECIALIZE_TYPE_TRAITS_END()

IGNORE_CLANG_WARNINGS_END

#endif
