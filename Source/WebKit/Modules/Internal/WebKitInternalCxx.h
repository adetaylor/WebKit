/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

// Add project-level C++ header files here to be able to access them from within Swift sources.

#pragma once


#import "APIArray.h"
#import "APIObject.h"
#import "IPCTesterReceiverSwiftMessages.h"
#import "IPCTesterReceiverSwiftTypes.h"
#import "Shared/FrameTreeNodeData.h"
#import "Shared/Gamepad/GamepadData.h"
#import "Shared/JSHandleInfo.h"
#import "Shared/LoadedWebArchive.h"
#import "Shared/SessionState.h"
#import "Shared/WebBackForwardListCounts.h"
#import "Shared/WebBackForwardListFrameItem.h"
#import "Shared/WebBackForwardListItem.h"
#import "Shared/WebKeyboardEvent.h"
#import "Shared/WebPushMessage.h"
#import "Shared/WebsiteData/WebsiteData.h"
#import "UIProcess/API/APIHistoryClient.h"
#import "UIProcess/API/APINavigationClient.h"
#import "UIProcess/API/APICustomProtocolManagerClient.h"
#import "UIProcess/AuxiliaryProcessProxy.h"
#import "UIProcess/Inspector/WebPageInspectorController.h"
#import "UIProcess/SwiftDemoLogoConfirmation.h"
#import "UIProcess/WebBackForwardCacheEntry.h"
#import "UIProcess/WebBackForwardListSwiftUtilities.h"
#import "UIProcess/WebFrameProxy.h"
#import "UIProcess/WebNavigationState.h"
#import "UIProcess/WebPageProxy.h"
#import "UIProcess/WebPageProxyInternals.h"
#import "UIProcess/WebPermissionControllerProxy.h"
#import "UIProcess/WebProcessActivityState.h"
#import "UIProcess/WebProcessProxy.h"

// Temporarily here until WebCore is modularized
#import <WebCore/DiagnosticLoggingClient.h>
#import <WebCore/DiagnosticLoggingKeys.h>
#import <WebCore/FrameIdentifier.h>
#import <WebCore/ClientOrigin.h>
#import <WebCore/ElementContext.h>
#import <WebCore/Exception.h>
#import <WebCore/MobileDocumentRequest.h>
#import <WebCore/OpenID4VPRequest.h>
#import <WebCore/RemoteUserInputEventData.h>
#import <WebCore/ShareableBitmapHandle.h>
#import <WebCore/TextIndicator.h>
#import <WebCore/WritingToolsTypes.h>
