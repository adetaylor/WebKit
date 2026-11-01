/*
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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
#include "InitDataRegistry.h"

#if ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)

#include "CDMKeyID.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"
#include <wtf/JSONValues.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/Base64.h>

#if USE(GSTREAMER)
#include <libxml/parser.h>
#include <libxml/parserInternals.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <wtf/Scope.h>
#endif

#if USE(AVFOUNDATION)
#include "CDMFairPlayStreaming.h"
#endif

namespace WebCore {

// The type names, 'cenc' and 'webm' are parsed in InitDataRegistry.swift. The JSON of 'keyids' stays here.

namespace {
    const uint32_t kKeyIdsMinKeyIdSizeInBytes = 1;
    const uint32_t kKeyIdsMaxKeyIdSizeInBytes = 512;
}

// The key IDs of 'cenc' init data are those of pssh boxes and of FairPlay Streaming key requests.
static constexpr size_t cencKeyIDSize = 16;

static std::optional<CDMKeyIDs> extractKeyIDsKeyids(const SharedBuffer& buffer)
{
    // 1. Format
    // https://w3c.github.io/encrypted-media/format-registry/initdata/keyids.html#format
    if (buffer.size() > std::numeric_limits<unsigned>::max())
        return std::nullopt;

    // FIXME: Specification says this should be parsed as UTF-8, not Latin-1.
    auto value = JSON::Value::parseJSON(byteCast<Latin1Character>(buffer.span()));
    if (!value)
        return std::nullopt;

    auto object = value->asObject();
    if (!object)
        return std::nullopt;

    auto kidsArray = object->getArray("kids"_s);
    if (!kidsArray)
        return std::nullopt;

    CDMKeyIDs keyIDs;
    for (auto& value : *kidsArray) {
        auto keyID = value->asString();
        if (!keyID)
            continue;

        auto keyIDData = base64URLDecode(keyID);
        if (!keyIDData)
            continue;

        if (keyIDData->size() < kKeyIdsMinKeyIdSizeInBytes || keyIDData->size() > kKeyIdsMaxKeyIdSizeInBytes)
            return std::nullopt;

        keyIDs.append(SharedBuffer::create(WTF::move(*keyIDData)));
    }

    return keyIDs;
}

static RefPtr<SharedBuffer> sanitizeKeyids(const SharedBuffer& buffer)
{
    // 1. Format
    // https://w3c.github.io/encrypted-media/format-registry/initdata/keyids.html#format
    auto keyIDBuffer = extractKeyIDsKeyids(buffer);
    if (!keyIDBuffer)
        return nullptr;

    auto object = JSON::Object::create();
    auto kidsArray = JSON::Array::create();
    for (auto& buffer : keyIDBuffer.value())
        kidsArray->pushString(base64URLEncodeToString(buffer->span()));
    object->setArray("kids"_s, WTF::move(kidsArray));

    return SharedBuffer::create(object->toJSONString().utf8().span());
}

#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
RefPtr<SharedBuffer> InitDataRegistry::extractFairPlayPsshFromCenc(const SharedBuffer& buffer)
{
    ISOByteRange range;
    if (!fairPlayPsshRangeImpl({ buffer.span() }, range))
        return nullptr;

    return SharedBuffer::create(buffer.span().subspan(range.offset, range.size));
}
#endif

std::optional<CDMKeyIDs> InitDataRegistry::extractKeyIDsCenc(const SharedBuffer& buffer)
{
    Vector<uint8_t> keyIDBytes;
    if (!extractKeyIDsCencImpl({ buffer.span() }, keyIDBytes))
        return std::nullopt;

    CDMKeyIDs keyIDs;
    for (auto bytes = keyIDBytes.span(); !bytes.empty(); bytes = bytes.subspan(cencKeyIDSize))
        keyIDs.append(SharedBuffer::create(bytes.first(cencKeyIDSize)));

    return keyIDs;
}

#if USE(GSTREAMER)
bool isPlayReadySanitizedInitializationData(const SharedBuffer& buffer)
{
    // The protection data starts with a 10-byte PlayReady version
    // header that needs to be skipped over to avoid XML parsing
    // errors.
    StringView view { byteCast<Latin1Character>(buffer.span()) };
    auto startTag = view.find('<');
    if (startTag == notFound)
        return false;

    auto xmlPayload = buffer.span().subspan(startTag);
    if (xmlPayload.size_bytes() > std::numeric_limits<int>::max())
        return false;
    xmlDocPtr protectionDataXML = xmlReadMemory(reinterpret_cast<const char*>(xmlPayload.data()), static_cast<int>(xmlPayload.size_bytes()), "protectionData", "utf-16", 0);
    if (!protectionDataXML)
        return false;

    xmlXPathContextPtr xpathContext = nullptr;
    xmlXPathObjectPtr xpathObject = nullptr;
    auto exitFunction = makeScopeExit([&] {
        if (xpathContext)
            xmlXPathFreeContext(xpathContext);
        if (xpathObject)
            xmlXPathFreeObject(xpathObject);
        xmlFreeDoc(protectionDataXML);
    });

    xmlNode* protectionDataRootElement = xmlDocGetRootElement(protectionDataXML);
    if (!protectionDataRootElement || protectionDataRootElement->type != XML_ELEMENT_NODE
        || xmlStrcmp(protectionDataRootElement->name, reinterpret_cast<const xmlChar*>("WRMHEADER"))
        || !protectionDataRootElement->ns)
        return false;

    xpathContext = xmlXPathNewContext(protectionDataXML);
    if (!xpathContext)
        return false;

    const xmlChar* protectionDataNamespace = protectionDataRootElement->ns->href;
    if (xmlXPathRegisterNs(xpathContext, reinterpret_cast<const xmlChar*>("prhdr"), protectionDataNamespace) < 0)
        return false;

    xpathObject = xmlXPathEvalExpression(reinterpret_cast<const xmlChar*>("//prhdr:KID"), xpathContext);
    if (!xpathObject)
        return false;

    xmlNodeSetPtr keyIDNode = xpathObject->nodesetval;
    int numberOfKeyIDs = keyIDNode ? keyIDNode->nodeNr : 0;
    if (!numberOfKeyIDs || keyIDNode->nodeTab[0]->type != XML_ELEMENT_NODE)
        return false;

    xmlChar* encodedKeyID = xmlNodeGetContent(keyIDNode->nodeTab[0]);
    auto encodedKeyIDSpan = unsafeMakeSpan(reinterpret_cast<const uint8_t*>(encodedKeyID), static_cast<size_t>(xmlStrlen(encodedKeyID)));
    std::optional<Vector<uint8_t>> decodedKeyID = base64Decode(encodedKeyIDSpan);
    xmlFree(encodedKeyID);
    if (!decodedKeyID)
        return false;

    return true;
}
#endif

RefPtr<SharedBuffer> InitDataRegistry::sanitizeCenc(const SharedBuffer& buffer)
{
    // 4. Common SystemID and PSSH Box Format
    // https://w3c.github.io/encrypted-media/format-registry/initdata/cenc.html#common-system
    if (!isValidCencInitDataImpl({ buffer.span() })) {
#if USE(GSTREAMER)
        if (!isPlayReadySanitizedInitializationData(buffer))
#endif
            return nullptr;
    }

    return buffer.makeContiguous();
}

static RefPtr<SharedBuffer> sanitizeWebM(const SharedBuffer& buffer)
{
    // Check if the buffer is a valid WebM initData.
    if (!isValidWebMInitDataImpl(buffer.size()))
        return nullptr;

    return buffer.makeContiguous();
}

static std::optional<CDMKeyIDs> extractKeyIDsWebM(const SharedBuffer& buffer)
{
    CDMKeyIDs keyIDs;
    RefPtr<SharedBuffer> sanitizedBuffer = sanitizeWebM(buffer);
    if (!sanitizedBuffer)
        return std::nullopt;

    // 1. Format
    // https://w3c.github.io/encrypted-media/format-registry/initdata/webm.html#format
    keyIDs.append(sanitizedBuffer.releaseNonNull());
    return keyIDs;
}

static InitDataKind initDataKind(const String& initDataType)
{
    return initDataKindImpl(mediaParserShortName(initDataType));
}

InitDataRegistry& InitDataRegistry::singleton()
{
    static NeverDestroyed<InitDataRegistry> registry;
    return registry.get();
}

InitDataRegistry::InitDataRegistry() = default;
InitDataRegistry::~InitDataRegistry() = default;

RefPtr<SharedBuffer> InitDataRegistry::sanitizeInitData(const String& initDataType, const SharedBuffer& buffer)
{
    switch (initDataKind(initDataType)) {
    case InitDataKind::KeyIDs:
        return sanitizeKeyids(buffer);
    case InitDataKind::Cenc:
        return sanitizeCenc(buffer);
    case InitDataKind::WebM:
        return sanitizeWebM(buffer);
#if USE(AVFOUNDATION)
    case InitDataKind::Sinf:
        return CDMPrivateFairPlayStreaming::sanitizeSinf(buffer);
    case InitDataKind::Skd:
        return CDMPrivateFairPlayStreaming::sanitizeSkd(buffer);
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    case InitDataKind::Mpts:
        return CDMPrivateFairPlayStreaming::sanitizeMpts(buffer);
#endif
#endif
    default:
        return nullptr;
    }
}

std::optional<CDMKeyIDs> InitDataRegistry::extractKeyIDs(const String& initDataType, const SharedBuffer& buffer)
{
    switch (initDataKind(initDataType)) {
    case InitDataKind::KeyIDs:
        return extractKeyIDsKeyids(buffer);
    case InitDataKind::Cenc:
        return extractKeyIDsCenc(buffer);
    case InitDataKind::WebM:
        return extractKeyIDsWebM(buffer);
#if USE(AVFOUNDATION)
    case InitDataKind::Sinf:
        return CDMPrivateFairPlayStreaming::extractKeyIDsSinf(buffer);
    case InitDataKind::Skd:
        return CDMPrivateFairPlayStreaming::extractKeyIDsSkd(buffer);
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    case InitDataKind::Mpts:
        return CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer);
#endif
#endif
    default:
        return std::nullopt;
    }
}

const String& InitDataRegistry::cencName()
{
    static NeverDestroyed<const String> staticCencName(MAKE_STATIC_STRING_IMPL("cenc"));
    return staticCencName;
}

const String& InitDataRegistry::keyidsName()
{
    static NeverDestroyed<const String> staticKeyidsName(MAKE_STATIC_STRING_IMPL("keyids"));
    return staticKeyidsName;
}

const String& InitDataRegistry::webmName()
{
    static NeverDestroyed<const String> staticWebmName(MAKE_STATIC_STRING_IMPL("webm"));
    return staticWebmName;
}

}

#endif // ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)
