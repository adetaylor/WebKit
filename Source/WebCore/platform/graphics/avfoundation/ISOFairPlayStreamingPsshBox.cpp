/*
 * Copyright (C) 2019-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "ISOFairPlayStreamingPsshBox.h"

#if ENABLE(WEBCORE_SWIFT)

#include "WebCore-Swift.h"

namespace WebCore {

bool ISOFairPlayStreamingInfoBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingInfoBoxFields& fields)
{
    return parseISOFairPlayStreamingInfoBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingKeyRequestInfoBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingKeyRequestInfoBoxFields& fields)
{
    return parseISOFairPlayStreamingKeyRequestInfoBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingKeyAssetIdBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingKeyDataBoxFields& fields)
{
    return parseISOFairPlayStreamingKeyDataBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingKeyContextBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingKeyDataBoxFields& fields)
{
    return parseISOFairPlayStreamingKeyDataBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingKeyVersionListBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingKeyVersionListBoxFields& fields)
{
    return parseISOFairPlayStreamingKeyVersionListBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingKeyRequestBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingKeyRequestBoxFields& fields)
{
    return parseISOFairPlayStreamingKeyRequestBoxImpl({ view }, offset, mode, fields);
}

bool ISOFairPlayStreamingInitDataBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingInitDataBoxFields& fields, ISOFairPlayStreamingKeyRequestBoxFieldsVector& appendedRequests)
{
    return parseISOFairPlayStreamingInitDataBoxImpl({ view }, offset, mode, fields, appendedRequests);
}

bool ISOFairPlayStreamingPsshBox::parseFields(const ByteView& view, unsigned& offset, ISOBoxParseMode mode, ISOFairPlayStreamingPsshBoxFields& fields, ISOFairPlayStreamingKeyRequestBoxFieldsVector& appendedRequests)
{
    return parseISOFairPlayStreamingPsshBoxImpl({ view }, offset, mode, fields, appendedRequests);
}

} // namespace WebCore

#endif // ENABLE(WEBCORE_SWIFT)
