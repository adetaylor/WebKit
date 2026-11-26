/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
#include "Helpers/Test.h"

#if ENABLE(WEBGL) && USE(COORDINATED_GRAPHICS)

#include "Helpers/WebCoreTestUtilities.h"
#include <WebCore/GraphicsContextGLCoordinated.h>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <string_view>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>

// A WebGL benchmark: 200 frames of 256 small draws, each with its own uniform colour, and one readPixels per frame,
// on a GraphicsContextGLCoordinated. The TEST runs two passes and checks that they read back the same pixels; the
// checksum depends on the GL driver, so it is printed, not compared. With WEBKIT_RUN_BENCHMARKS=1 it repeats for at
// least a second and prints
//     WebGLDrawLoop: <ms> ms <n> MB/s checksum=<digest>

namespace TestWebKitAPI {

using namespace WebCore;

namespace {

constexpr unsigned frameCount = 200;
constexpr unsigned drawsPerFrame = 256;
constexpr unsigned gridSide = 16;
constexpr int surfaceSide = 64;
constexpr unsigned bytesPerFrame = surfaceSide * surfaceSide * 4;

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    uint64_t next()
    {
        m_state ^= m_state >> 12;
        m_state ^= m_state << 25;
        m_state ^= m_state >> 27;
        return m_state * 2685821657736338717ull;
    }

private:
    uint64_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint8_t byte)
    {
        value ^= byte;
        value *= 1099511628211ull;
    }
};

bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string_view(value) != "0";
}

class DrawLoop {
public:
    static std::optional<DrawLoop> create()
    {
        GraphicsContextGLAttributes attributes;
        auto context = GraphicsContextGLCoordinated::create(WTF::move(attributes));
        if (!context)
            return std::nullopt;
        DrawLoop loop(context.releaseNonNull());
        if (!loop.setUp())
            return std::nullopt;
        return loop;
    }

    // One pass: frameCount frames of drawsPerFrame draws, a readPixels after each. Folds the pixels into `checksum`.
    void runPass(Checksum* checksum)
    {
        using GL = GraphicsContextGL;
        Random random(0x9e3779b97f4a7c15ull);
        for (unsigned frame = 0; frame < frameCount; ++frame) {
            m_context->clearColor(0.f, 0.f, 0.f, 1.f);
            m_context->clear(GL::COLOR_BUFFER_BIT);
            for (unsigned draw = 0; draw < drawsPerFrame; ++draw) {
                uint64_t bits = random.next();
                m_context->uniform4f(0, static_cast<float>(bits & 0xff) / 255.f, static_cast<float>((bits >> 8) & 0xff) / 255.f, static_cast<float>((bits >> 16) & 0xff) / 255.f, 1.f);
                m_context->drawArrays(GL::TRIANGLES, draw * 3, 3);
            }
            m_context->readPixels({ 0, 0, surfaceSide, surfaceSide }, GL::RGBA, GL::UNSIGNED_BYTE, m_pixels.mutableSpan(), 1, 0, false);
            if (checksum) {
                for (uint8_t byte : m_pixels.span())
                    checksum->add(byte);
            }
        }
    }

    bool hasErrors() { return !m_context->getErrors().isEmpty(); }

private:
    explicit DrawLoop(Ref<GraphicsContextGLCoordinated>&& context)
        : m_context(WTF::move(context))
        , m_pixels(FillWith { }, bytesPerFrame, 0)
    {
    }

    bool setUp()
    {
        using GL = GraphicsContextGL;
        m_context->reshape(surfaceSide, surfaceSide);
        m_context->viewport(0, 0, surfaceSide, surfaceSide);

        auto vertexShader = m_context->createShader(GL::VERTEX_SHADER);
        m_context->shaderSource(vertexShader, "attribute vec2 position; uniform vec4 color; varying vec4 vColor; void main() { gl_Position = vec4(position, 0.0, 1.0); vColor = color; }"_s);
        m_context->compileShader(vertexShader);
        auto fragmentShader = m_context->createShader(GL::FRAGMENT_SHADER);
        m_context->shaderSource(fragmentShader, "precision mediump float; varying vec4 vColor; void main() { gl_FragColor = vColor; }"_s);
        m_context->compileShader(fragmentShader);
        if (!m_context->getShaderi(vertexShader, GL::COMPILE_STATUS) || !m_context->getShaderi(fragmentShader, GL::COMPILE_STATUS))
            return false;

        auto program = m_context->createProgram();
        m_context->attachShader(program, vertexShader);
        m_context->attachShader(program, fragmentShader);
        m_context->bindAttribLocation(program, 0, "position"_s);
        m_context->linkProgram(program);
        if (!m_context->getProgrami(program, GL::LINK_STATUS))
            return false;
        m_context->useProgram(program);

        // One triangle in each cell of a gridSide x gridSide grid, in clip space, in the order of the draws.
        Vector<float> vertices;
        vertices.reserveInitialCapacity(drawsPerFrame * 3 * 2);
        float cell = 2.f / gridSide;
        for (unsigned row = 0; row < gridSide; ++row) {
            for (unsigned column = 0; column < gridSide; ++column) {
                float left = -1.f + column * cell;
                float bottom = -1.f + row * cell;
                vertices.append(left);
                vertices.append(bottom);
                vertices.append(left + cell);
                vertices.append(bottom);
                vertices.append(left);
                vertices.append(bottom + cell);
            }
        }
        auto buffer = m_context->createBuffer();
        m_context->bindBuffer(GL::ARRAY_BUFFER, buffer);
        m_context->bufferData(GL::ARRAY_BUFFER, asByteSpan(vertices.span()), GL::STATIC_DRAW);
        m_context->enableVertexAttribArray(0);
        m_context->vertexAttribPointer(0, 2, GL::FLOAT, false, 0, 0);
        return !hasErrors();
    }

    Ref<GraphicsContextGLCoordinated> m_context;
    Vector<uint8_t> m_pixels;
};

} // namespace

TEST(GPUProcessBench, WebGLDrawLoop)
{
#if ENABLE(GPU_PROCESS)
    ScopedSetAuxiliaryProcessTypeForTesting scopedProcessType { WTF::AuxiliaryProcessType::GPU };
#else
    ScopedSetAuxiliaryProcessTypeForTesting scopedProcessType { WTF::AuxiliaryProcessType::WebContent };
#endif
    auto loop = DrawLoop::create();
    ASSERT_TRUE(loop.has_value());

    Checksum checksum;
    loop->runPass(&checksum);
    EXPECT_FALSE(loop->hasErrors());
    Checksum secondPass;
    loop->runPass(&secondPass);
    EXPECT_EQ(secondPass.value, checksum.value);
    SAFE_PRINTF("WebGLDrawLoop: checksum=%016llx\n", static_cast<unsigned long long>(checksum.value));

    if (!runsBenchmarks())
        return;

    unsigned passes = 0;
    auto start = MonotonicTime::now();
    double seconds = 0;
    do {
        loop->runPass(nullptr);
        ++passes;
        seconds = (MonotonicTime::now() - start).seconds();
    } while (seconds < 1.0);

    Checksum lastPass;
    loop->runPass(&lastPass);
    EXPECT_EQ(lastPass.value, checksum.value);

    double bytes = static_cast<double>(bytesPerFrame) * frameCount * passes;
    SAFE_PRINTF("WebGLDrawLoop: %.1f ms %.1f MB/s checksum=%016llx\n", seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEBGL) && USE(COORDINATED_GRAPHICS)
