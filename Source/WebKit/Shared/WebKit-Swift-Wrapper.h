/**
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

#pragma once

// Anything needing WebKit-Swift.h should instead include this file
// which ensures all pre-requisites are imported, etc.
// This should be the ONLY .h file which includes WebKit-Swift.h.

#include <WebBackForwardListMessages.h>
#include <Shared/WebBackForwardListItem.h>
#include <Shared/SwiftUtilities.h>
#include <wtf/SwiftWrappedFunction.h>

#ifdef __OBJC__
#include "WKUIDelegatePrivate.h"
#endif

#ifdef ENABLE_BACKFORWARDLIST_SWIFT
// TODO work out what the __bridge_transfer stuff is about
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-bridge-casts-disallowed-in-nonarc"
#ifdef GENERATE_SINGLE_SWIFT_INTEROP_FILE
#include "WebKit-Swift.h"
#else
#include "WebKit-Swift-CPP.h"
#endif
#pragma clang diagnostic pop
#endif
