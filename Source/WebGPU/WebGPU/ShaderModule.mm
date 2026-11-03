/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

#import "config.h"
#import "ShaderModule.h"

#import "APIConversions.h"
#import "Device.h"
#import "RenderBundleEncoder.h"

#import <unicode/uchar.h>
#import <unicode/uset.h>
#import <wtf/DataLog.h>
#import <wtf/HashSet.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/Threading.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WGSL::Interop {

IdentifierRanges icuIdentifierRanges(bool xidContinue)
{
    UErrorCode status = U_ZERO_ERROR;
    const USet* set = u_getBinaryPropertySet(xidContinue ? UCHAR_XID_CONTINUE : UCHAR_XID_START, &status);
    RELEASE_ASSERT(U_SUCCESS(status));
    int32_t itemCount = uset_getItemCount(set);
    IdentifierRanges result;
    result.reserveInitialCapacity(2 * itemCount);
    for (int32_t i = 0; i < itemCount; ++i) {
        UChar32 start = 0;
        UChar32 end = 0;
        auto stringLength = uset_getItem(set, i, &start, &end, nullptr, 0, &status);
        RELEASE_ASSERT(!stringLength && U_SUCCESS(status));
        result.append(start);
        result.append(end + 1);
    }
    return result;
}

} // namespace WGSL::Interop

namespace WebGPU::Metal {

struct ShaderModuleImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ShaderModuleImplBox);
    WebGPUSwift::ShaderModuleImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ShaderModuleImplBox);

// The compiler built without optimization needs a larger stack than the WebGPU thread's; it then runs on its own thread.
void runOnWGSLCompileThread(NOESCAPE void (^work)(void))
{
    auto stackSize = WebGPUSwift::wgslRecommendedCompileStackSize();
    if (!stackSize) {
        work();
        return;
    }

    Thread::create("WGSL compile"_s, [&work] {
        work();
    }, ThreadType::Graphics, Thread::QOS::UserInteractive, Thread::SchedulingPolicy::Other, StackAllocationSpecification::RequestSize(stackSize))->waitForCompletion();
}

void sortInWTFHashTableOrder(std::span<uint32_t> keys NOESCAPE)
{
    // Iterates in the order of a HashMap with the same key type, hash and traits filled the same way (table sizing
    // ignores the value type). A key equal to the traits' empty or deleted value hits HashTable's RELEASE_ASSERT.
    HashSet<uint32_t, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>> table;
    for (auto key : keys)
        table.add(key);
    RELEASE_ASSERT(table.size() == keys.size());
    size_t index = 0;
    for (auto key : table)
        keys[index++] = key;
}

RefPtr<WebGPU::ShaderModule> Device::createShaderModule(const WebGPU::ShaderModuleDescriptor& descriptor)
{
    if (!isValid())
        return ShaderModule::createInvalid(*this);

    // FIXME: re-enable early compilation of descriptor.hints later on once deferred compilation is fully implemented
    // https://bugs.webkit.org/show_bug.cgi?id=254258
    auto impl = makeUnique<ShaderModuleImplBox>(ShaderModuleImplBox {
        .impl = WebGPUSwift::createShaderModuleImpl(this, swiftImpl(), descriptor)
    });
    return ShaderModule::create(WTF::move(impl));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ShaderModule);

Ref<ShaderModule> ShaderModule::create(std::unique_ptr<ShaderModuleImplBox>&& impl)
{
    return adoptRef(*new ShaderModule(WTF::move(impl)));
}

Ref<ShaderModule> ShaderModule::createWithStagedImpl(Device& device)
{
    return create(makeUnique<ShaderModuleImplBox>(ShaderModuleImplBox { .impl = device.swiftImpl().takeStagedShaderModuleImpl() }));
}

Ref<ShaderModule> ShaderModule::createInvalid(Device& device)
{
    auto impl = makeUnique<ShaderModuleImplBox>(ShaderModuleImplBox {
        .impl = WebGPUSwift::makeInvalidShaderModuleImpl(&device, device.swiftImpl())
    });
    return adoptRef(*new ShaderModule(WTF::move(impl)));
}

ShaderModule::ShaderModule(std::unique_ptr<ShaderModuleImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

ShaderModule::~ShaderModule() = default;

bool ShaderModule::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPUSwift::ShaderModuleImpl& ShaderModule::swiftImpl() const
{
    return m_impl->impl;
}

Device& ShaderModule::device() const
{
    return borrowSwiftRetained(m_impl->impl.shellDevice());
}

void ShaderModule::compilationInfo(CompletionHandler<void(WebGPU::CompilationInfo&&)>&& callback)
{
    auto& impl = m_impl->impl;
    auto count = impl.compilationMessageCount();
    auto errorCount = impl.compilationErrorCount();
    WebGPU::CompilationInfo compilationInfo;
    compilationInfo.messages.reserveInitialCapacity(static_cast<size_t>(count));
    for (decltype(count) i = 0; i < count; ++i) {
        compilationInfo.messages.append({
            .message = impl.compilationMessageText(i),
            .type = i < errorCount ? WebGPU::CompilationMessageType::Error : WebGPU::CompilationMessageType::Warning,
            .lineNum = impl.compilationMessageLineNumber(i),
            .linePos = impl.compilationMessageLineOffset(i) + 1,
            .offset = impl.compilationMessageOffset(i),
            .length = impl.compilationMessageLength(i),
        });
    }
    callback(WTF::move(compilationInfo));
}

void ShaderModule::setLabel(String&&)
{
    // Nothing to label: the module has no Metal object of its own.
}

} // namespace WebGPU::Metal
