/*
 * Copyright (C) 2011-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(FULLSCREEN_API)

#include "FullScreenMediaDetails.h"
#include "MessageReceiver.h"
#include <WebCore/BoxExtents.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/HTMLMediaElementEnums.h>
#include <WebCore/IntPoint.h>
#include <WebCore/ProcessIdentifier.h>
#include <wtf/CheckedRef.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Markable.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Seconds.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Variant.h>
#include <wtf/Vector.h>

namespace WebCore {
class FloatSize;
class IntRect;

enum class ScreenOrientationType : uint8_t;
}

namespace WebKit {

class RemotePageFullscreenManagerProxy;
class WebFullScreenManagerProxy;
class WebPageProxy;
class WebProcessProxy;
struct SharedPreferencesForWebProcess;

class WebFullScreenManagerProxyClient : public CanMakeCheckedPtr<WebFullScreenManagerProxyClient> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(WebFullScreenManagerProxyClient);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(WebFullScreenManagerProxyClient);
public:
    virtual ~WebFullScreenManagerProxyClient() { }

    virtual void closeFullScreenManager() = 0;
    virtual bool isFullScreen() = 0;
    virtual void enterFullScreen(WebCore::FloatSize mediaDimensions, CompletionHandler<void(bool)>&&) = 0;
#if ENABLE(QUICKLOOK_FULLSCREEN)
    virtual void updateImageSource() = 0;
#endif
    virtual void exitFullScreen(CompletionHandler<void()>&&) = 0;
    virtual void beganEnterFullScreen(const WebCore::IntRect& initialFrame, const WebCore::IntRect& finalFrame, CompletionHandler<void(bool)>&&) = 0;
    virtual void beganExitFullScreen(const WebCore::IntRect& initialFrame, const WebCore::IntRect& finalFrame, CompletionHandler<void()>&&) = 0;
    virtual WebCore::IntRect convertMainFrameCoordinatesInFullscreenPlaceholderViewToScreen(WebPageProxy&, WebCore::IntRect) const;

    virtual bool lockFullscreenOrientation(WebCore::ScreenOrientationType) { return false; }
    virtual void unlockFullscreenOrientation() { }
};

class WebFullScreenManagerProxy : public IPC::MessageReceiver, public CanMakeCheckedPtr<WebFullScreenManagerProxy>, public RefCounted<WebFullScreenManagerProxy> {
    WTF_MAKE_TZONE_ALLOCATED(WebFullScreenManagerProxy);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(WebFullScreenManagerProxy);
public:
    static Ref<WebFullScreenManagerProxy> create(WebPageProxy&, WebFullScreenManagerProxyClient&);
    virtual ~WebFullScreenManagerProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    WebFullScreenManagerProxyClient* client() { return m_client.get(); }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess(const IPC::Connection&) const;

    bool isFullScreen();
    bool NODELETE blocksReturnToFullscreenFromPictureInPicture() const;
#if ENABLE(VIDEO_USES_ELEMENT_FULLSCREEN)
    bool isVideoElement() const;
#endif
#if ENABLE(QUICKLOOK_FULLSCREEN)
    bool isImageElement() const;
    void prepareQuickLookImageURL(CompletionHandler<void(URL&&)>&&) const;
    bool launchInImmersive() const;
#endif // QUICKLOOK_FULLSCREEN
    void close();
    void detachFromClient();
    void NODELETE attachToNewClient(WebFullScreenManagerProxyClient&);

    enum class NeedsPresentationUpdate : bool { No, Yes };
    void enterFullScreenForOwnerElementsInOtherProcesses(WebCore::FrameIdentifier, CompletionHandler<void(NeedsPresentationUpdate)>&&);
    void exitFullScreenInOtherProcesses(WebCore::FrameIdentifier, CompletionHandler<void()>&&);

    enum class FullscreenState : uint8_t {
        NotInFullscreen,
        EnteringFullscreen,
        InFullscreen,
        ExitingFullscreen,
    };
    FullscreenState fullscreenState() const;
    void setAnimatingFullScreen(bool);
    void requestRestoreFullScreen(CompletionHandler<void(bool)>&&);
    void requestExitFullScreen();
    void setFullscreenInsets(const WebCore::FloatBoxExtent&);
    void setFullscreenAutoHideDuration(Seconds);
    void closeWithCallback(CompletionHandler<void()>&&);
    bool lockFullscreenOrientation(WebCore::ScreenOrientationType);
    void unlockFullscreenOrientation();

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) override;

private:
    WebFullScreenManagerProxy(WebPageProxy&, WebFullScreenManagerProxyClient&);

    // Data the web process supplied when it asked to enter fullscreen. It lives for exactly as long
    // as a fullscreen session does, so it is stored in the states that have a session rather than in
    // a member that outlives one.
    struct FullscreenSession {
        bool blocksReturnToFullscreenFromPictureInPicture { false };
#if ENABLE(VIDEO_USES_ELEMENT_FULLSCREEN)
        bool isVideoElement { false };
#endif
#if ENABLE(QUICKLOOK_FULLSCREEN)
        std::optional<FullScreenMediaDetails> mediaDetails;
        bool launchInImmersive { false };
#endif
        WebCore::IntPoint rootFrameOriginInMainFrameCoordinates;
    };

    // The six states the fullscreen handshake actually has. Each one carries exactly the data that
    // is known in it: in particular only the states reached via BeganEnterFullScreen know which
    // frame is fullscreen, so nothing else can read a fullscreen frame identifier at all.
    struct NotInFullscreen { };
    // EnterFullScreen has arrived and the client is preparing to present. No fullscreen UI exists
    // yet, so this reports as NotInFullscreen through the public API.
    struct WaitingToEnterFullscreen {
        FullscreenSession session;
    };
    // The client accepted; willEnterFullscreen has been dispatched.
    struct EnteringFullscreen {
        FullscreenSession session;
    };
    // BeganEnterFullScreen has arrived, so the fullscreen frame is now known.
    struct PresentingFullscreen {
        FullscreenSession session;
        WebCore::FrameIdentifier frameID;
    };
    struct InFullscreen {
        FullscreenSession session;
        WebCore::FrameIdentifier frameID;
    };
    // Reachable from any state that has a session, including ones that never learned a frame.
    struct ExitingFullscreen {
        FullscreenSession session;
        Markable<WebCore::FrameIdentifier> frameID;
    };

    using State = Variant<NotInFullscreen, WaitingToEnterFullscreen, EnteringFullscreen, PresentingFullscreen, InFullscreen, ExitingFullscreen>;

    const FullscreenSession* currentSession() const;
    FullscreenSession* currentSession();
    Markable<WebCore::FrameIdentifier> fullScreenFrameID() const;

    Awaitable<bool> enterFullScreen(IPC::Connection&, WebCore::FrameIdentifier, bool blocksReturnToFullscreenFromPictureInPicture, FullScreenMediaDetails);
#if ENABLE(QUICKLOOK_FULLSCREEN)
    void updateImageSource(FullScreenMediaDetails&&);
#endif
    Awaitable<void> exitFullScreen();
    Awaitable<bool> beganEnterFullScreen(IPC::Connection&, WebCore::FrameIdentifier, WebCore::IntRect initialFrameInRootViewCoordinates, WebCore::IntRect finalFrameInRootViewCoordinates);
    Awaitable<void> beganExitFullScreen(WebCore::IntRect initialFrameInRootViewCoordinates, WebCore::IntRect finalFrameInRootViewCoordinates);
    void closeFullScreen(IPC::Connection&);
    void callCloseCompletionHandlers();
    // Takes the session by value so that it is vacated from the previous state before m_state is
    // reassigned; binding a reference into the live alternative would read it after destruction.
    void didEnterFullScreen(FullscreenSession, WebCore::FrameIdentifier, CompletionHandler<void(bool)>&&);
    template<typename M> void sendToWebProcess(M&&);

    bool isFrameInSendingProcess(WebCore::FrameIdentifier, IPC::Connection&) const;
    bool isFullScreenInSendingProcess(IPC::Connection&) const;

    std::optional<std::pair<WebCore::IntRect, WebCore::IntRect>> convertFromRootViewToScreenCoordinates(const FullscreenSession&, std::pair<WebCore::IntRect, WebCore::IntRect> rectsInRootViewCoordinates);

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const { return m_logger; }
    uint64_t logIdentifier() const { return m_logIdentifier; }
    ASCIILiteral logClassName() const { return "WebFullScreenManagerProxy"_s; }
    WTFLogChannel& NODELETE logChannel() const;
#endif

    WeakPtr<WebPageProxy> m_page;
    CheckedPtr<WebFullScreenManagerProxyClient> m_client;
    State m_state { NotInFullscreen { } };
    Vector<CompletionHandler<void()>> m_closeCompletionHandlers;
    WeakPtr<WebProcessProxy> m_fullScreenProcess;

#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

} // namespace WebKit

#endif // ENABLE(FULLSCREEN_API)
