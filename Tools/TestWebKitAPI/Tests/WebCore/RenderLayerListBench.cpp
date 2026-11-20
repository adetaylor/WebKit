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
#include "TestPageHarness.h"

#include <WebCore/CSSPropertyNames.h>
#include <WebCore/CSSValueKeywords.h>
#include <WebCore/ContainerNodeInlines.h>
#include <WebCore/Document.h>
#include <WebCore/Element.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLDivElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/HitTestRequest.h>
#include <WebCore/HitTestResult.h>
#include <WebCore/IntPoint.h>
#include <WebCore/RenderElement.h>
#include <WebCore/RenderLayer.h>
#include <WebCore/RenderLayerModelObject.h>
#include <WebCore/RenderView.h>
#include <WebCore/StyledElement.h>
#include <algorithm>
#include <limits>
#include <optional>
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <cstdio>
#include <cstdlib>

// A benchmark of RenderLayer's paint-order lists (the negative and positive z-order lists and the
// normal-flow list).
//
// Rebuild and walk benchmarks (ZOrderRebuildWide, ZOrderRebuildDeep, NormalFlowRebuild, PaintOrderWalk, ReverseWalk,
// DirtyRebuildMany, ListHeavy) time only calls on RenderLayer's exported "ForTesting" hooks: dirty a list, bring it up
// to date, read it back. Their layer tree is built, laid out and captured before the timed pass: the layers, and each
// list's entries by identity. A pass compares what it reads with the captured entries and folds the counts and the
// mismatches into its checksum, together with a digest of the captured order (by tree position), so a different order
// in any build changes the checksum. Nothing in a pass reads a layer pointer, or a RenderLayer member that is not an
// exported function, so one TestWebKitAPI binary measures any build of WebCore.
//
// The Tree benchmarks (Tree<Kind>5k, Tree<Kind>200k) are described where they begin, below.
//
// The DOM benchmarks (StyleChange, Mixed, Destroy) change the tree through DOM and style calls; layout and the list
// rebuilds they cause are part of the pass.
//
// Each TEST runs one pass and compares its checksum with the value recorded from the C++. With
// WEBKIT_RUN_BENCHMARKS=1 in the environment it repeats the pass for at least a second and prints
//     <Name>: <ms> ms <n> MB/s checksum=<digest of the first pass>
// where the rate counts eight bytes for each list entry the pass reads back.

namespace TestWebKitAPI {

using namespace WebCore;

namespace {

class Rng {
public:
    explicit Rng(uint64_t seed)
        : m_state(seed)
    {
    }

    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<uint32_t>(m_state >> 33);
    }

    unsigned below(unsigned limit) { return next() % limit; }
    int between(int low, int high) { return low + static_cast<int>(below(static_cast<unsigned>(high - low + 1))); }

private:
    uint64_t m_state;
};

class Digest {
public:
    void mix(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_value ^= (value >> (i * 8)) & 0xff;
            m_value *= 0x100000001b3ULL;
        }
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

struct PassResult {
    uint64_t checksum { 0 };
    uint64_t listEntries { 0 };
};

// Generates the markup of a layer tree. Elements get consecutive numeric ids.
class TreeGenerator {
public:
    explicit TreeGenerator(uint64_t seed)
        : m_rng(seed)
    {
    }

    Rng& rng() { return m_rng; }
    unsigned count() const { return m_count; }
    const Vector<unsigned>& positionedIds() const { return m_positionedIds; }
    const Vector<std::optional<int>>& originalZIndices() const { return m_originalZ; }
    String markup() { return makeString("<body style=\"margin:0\">"_s, m_markup.toString(), "</body>"_s); }

    // An element that holds its children; closed with close().
    template<typename Style>
    unsigned open(Style style)
    {
        unsigned id = allocate(std::nullopt);
        m_markup.append("<div id=\""_s, id, "\" style=\""_s, style, "\">"_s);
        return id;
    }

    void close() { m_markup.append("</div>"_s); }

    // An element with a given tag and attributes; closed with closeTag().
    unsigned openTag(ASCIILiteral tag, ASCIILiteral attributes, ASCIILiteral style)
    {
        unsigned id = allocate(std::nullopt);
        m_markup.append("<"_s, tag, " id=\""_s, id, "\" "_s, attributes, " style=\""_s, style, "\">"_s);
        return id;
    }

    void closeTag(ASCIILiteral tag) { m_markup.append("</"_s, tag, ">"_s); }

    unsigned leaf(ASCIILiteral style, int left, int top, std::optional<int> zIndex)
    {
        unsigned id = allocate(zIndex);
        m_markup.append("<div id=\""_s, id, "\" style=\""_s, style, "left:"_s, left, "px;top:"_s, top, "px;"_s);
        if (zIndex)
            m_markup.append("z-index:"_s, *zIndex, ";"_s);
        m_markup.append("\"></div>"_s);
        m_positionedIds.append(id);
        return id;
    }

    // Children of one stacking context, in a fixed mix: negative z-index, positive z-index, normal-flow
    // only (overflow), and positioned with z-index auto.
    void listMix(unsigned count)
    {
        for (unsigned i = 0; i < count; ++i) {
            int left = m_rng.between(0, 700);
            int top = m_rng.between(0, 500);
            switch (m_rng.below(4)) {
            case 0: {
                int z = -1 - static_cast<int>(m_rng.below(4));
                leaf("position:absolute;width:6px;height:6px;"_s, left, top, z);
                break;
            }
            case 1: {
                int z = 1 + static_cast<int>(m_rng.below(9));
                leaf("position:absolute;width:6px;height:6px;"_s, left, top, z);
                break;
            }
            case 2:
                open("overflow:hidden;width:6px;height:6px;"_s);
                close();
                break;
            default:
                leaf("position:absolute;width:6px;height:6px;"_s, left, top, std::nullopt);
                break;
            }
        }
    }

    // A random subtree with mixed layer kinds: stacking contexts, positioned layers with z-index
    // auto, normal-flow-only layers (overflow) and opacity layers.
    void randomSubtree(unsigned depth, unsigned& budget)
    {
        if (!budget)
            return;
        --budget;
        unsigned kind = m_rng.below(6);
        int left = m_rng.between(0, 700);
        int top = m_rng.between(0, 500);
        std::optional<int> z;
        if (kind < 2)
            z = m_rng.between(1, 9);
        else if (kind == 2)
            z = -m_rng.between(1, 9);
        unsigned id = allocate(z);
        StringBuilder style;
        switch (kind) {
        case 0:
        case 1:
        case 2:
            style.append("position:absolute;z-index:"_s, *z, ";left:"_s, left, "px;top:"_s, top, "px;width:40px;height:40px;"_s);
            m_positionedIds.append(id);
            break;
        case 3:
            style.append("position:relative;left:"_s, left / 100, "px;width:60px;height:20px;"_s);
            m_positionedIds.append(id);
            break;
        case 4:
            style.append("overflow:hidden;width:60px;height:20px;"_s);
            break;
        default:
            style.append("opacity:0.9;width:60px;height:20px;"_s);
            break;
        }
        m_markup.append("<div id=\""_s, id, "\" style=\""_s, style.toString(), "\">"_s);
        if (depth) {
            unsigned children = m_rng.below(4);
            for (unsigned i = 0; i < children; ++i)
                randomSubtree(depth - 1, budget);
        }
        m_markup.append("</div>"_s);
    }

    // A fixed page-like fragment: nested blocks, positioned and overflow boxes, a transformed box, a box with a
    // reflection, an open dialog and a popover that is not shown.
    void pageFragment()
    {
        open("position:relative;width:600px;height:300px;"_s);
        open("overflow:hidden;width:580px;height:60px;"_s);
        leaf("position:absolute;width:30px;height:30px;"_s, 10, 10, 2);
        close();
        open("transform:translateX(3px);width:100px;height:40px;"_s);
        leaf("position:absolute;width:10px;height:10px;"_s, 5, 5, -1);
        close();
        open("position:relative;-webkit-box-reflect:below 2px;width:50px;height:20px;"_s);
        close();
        open("overflow:auto;width:200px;height:50px;"_s);
        open("position:relative;z-index:1;width:300px;height:30px;"_s);
        close();
        close();
        openTag("dialog"_s, "open"_s, "position:absolute;z-index:4;left:300px;top:100px;width:120px;height:60px;"_s);
        closeTag("dialog"_s);
        openTag("div"_s, "popover"_s, "width:50px;height:50px;"_s);
        closeTag("div"_s);
        close();
    }

private:
    unsigned allocate(std::optional<int> zIndex)
    {
        m_originalZ.append(zIndex);
        return m_count++;
    }

    Rng m_rng;
    unsigned m_count { 0 };
    StringBuilder m_markup;
    Vector<unsigned> m_positionedIds;
    Vector<std::optional<int>> m_originalZ;
};

using LayerIds = HashMap<const RenderLayer*, unsigned>;

class Scene {
public:
    Scene(const String& markup, unsigned elementCount)
        : m_harness(TestPageHarness::create())
    {
        m_harness.loadHTML(markup);
        for (unsigned i = 0; i < elementCount; ++i)
            addElement(m_harness.getElementById(String::number(i)));
    }

    Document& document() { return m_harness.document(); }

    unsigned addElement(RefPtr<Element>&& element)
    {
        RELEASE_ASSERT(element);
        unsigned id = static_cast<unsigned>(m_elements.size());
        m_elementIds.add(element.get(), id);
        m_elements.append(WTF::move(element));
        return id;
    }

    Element& element(unsigned id) { return *m_elements[id]; }
    StyledElement& styled(unsigned id) { return downcast<StyledElement>(element(id)); }

    unsigned idOf(const Element* element) const { return m_elementIds.get(element); }

    RenderLayer* layerOf(unsigned id)
    {
        auto* renderer = dynamicDowncast<RenderLayerModelObject>(element(id).renderer());
        return renderer ? renderer->layer() : nullptr;
    }

    RenderLayer& requireLayer(unsigned id)
    {
        RenderLayer* layer = layerOf(id);
        RELEASE_ASSERT(layer);
        return *layer;
    }

    RenderLayer& rootLayer()
    {
        RenderView* view = document().renderView();
        RELEASE_ASSERT(view);
        RenderLayer* layer = view->layer();
        RELEASE_ASSERT(layer);
        return *layer;
    }

    void setZIndex(unsigned id, int z) { styled(id).setInlineStyleProperty(CSSPropertyID::ZIndex, String::number(z)); }
    void setZIndexAuto(unsigned id) { styled(id).setInlineStyleProperty(CSSPropertyID::ZIndex, CSSValueID::Auto); }
    void setVisibility(unsigned id, bool visible) { styled(id).setInlineStyleProperty(CSSPropertyID::Visibility, visible ? CSSValueID::Visible : CSSValueID::Hidden); }
    void setDisplay(unsigned id, bool shown) { styled(id).setInlineStyleProperty(CSSPropertyID::Display, shown ? CSSValueID::Block : CSSValueID::None); }

    void relayout() { document().updateLayout(); }

    // Updates layout and hit tests at a point. The hit test brings the lists of every layer it
    // reaches up to date; the topmost element it finds depends on the z-order lists.
    void settle(Digest& digest, Rng& rng)
    {
        int x = rng.between(0, 780);
        int y = rng.between(0, 580);
        HitTestRequest request;
        HitTestResult result(IntPoint(x, y));
        bool hit = document().hitTest(request, result);
        digest.mix(hit);
        if (RefPtr hitElement = result.innerNonSharedElement())
            digest.mix(1 + idOf(hitElement.get()));
    }

private:
    TestPageHarness m_harness;
    Vector<RefPtr<Element>> m_elements;
    HashMap<const Element*, unsigned> m_elementIds;
};

void indexLayers(const RenderLayer& layer, LayerIds& ids)
{
    ids.add(&layer, static_cast<unsigned>(ids.size()));
    for (auto* child = layer.firstChildForTesting(); child; child = child->nextSiblingForTesting())
        indexLayers(*child, ids);
}

unsigned idOf(const LayerIds& ids, const RenderLayer* layer)
{
    return layer ? 1 + ids.get(layer) : 0;
}

void updateAllLists(RenderLayer& layer)
{
    layer.updateLayerListsIfNeededForTesting();
    for (auto* child = layer.firstChildForTesting(); child; child = child->nextSiblingForTesting())
        updateAllLists(*child);
}

// The layers of a laid-out scene, in tree order, and for each layer the entries of its three lists once they are
// up to date. Taken during setup. Layers are identified by their position in the tree.
struct LayerLists {
    Vector<RenderLayer*> negative;
    Vector<RenderLayer*> normalFlow;
    Vector<RenderLayer*> positive;
};

class Capture {
public:
    explicit Capture(Scene& scene)
    {
        scene.relayout();
        collect(scene.rootLayer());
        for (auto* layer : m_layers)
            layer->updateLayerListsIfNeededForTesting();
        m_digest.mix(m_layers.size());
        for (auto* layer : m_layers) {
            LayerLists lists;
            for (size_t i = 0; i < layer->negativeZOrderLayerCountForTesting(); ++i)
                lists.negative.append(layer->negativeZOrderLayerAtForTesting(i));
            for (size_t i = 0; i < layer->normalFlowLayerCountForTesting(); ++i)
                lists.normalFlow.append(layer->normalFlowLayerAtForTesting(i));
            for (size_t i = 0; i < layer->positiveZOrderLayerCountForTesting(); ++i)
                lists.positive.append(layer->positiveZOrderLayerAtForTesting(i));
            m_digest.mix(static_cast<uint32_t>(layer->zIndexForTesting()));
            mixEntries(lists.negative);
            mixEntries(lists.normalFlow);
            mixEntries(lists.positive);
            m_lists.append(WTF::move(lists));
        }
    }

    const Vector<RenderLayer*>& layers() const { return m_layers; }
    const Vector<LayerLists>& lists() const { return m_lists; }
    const LayerLists& listsOf(const RenderLayer& layer) const { return m_lists[m_ids.get(&layer)]; }
    const LayerIds& ids() const { return m_ids; }
    uint64_t setupDigest() const { return m_digest.value(); }

private:
    void collect(RenderLayer& layer)
    {
        m_ids.add(&layer, static_cast<unsigned>(m_layers.size()));
        m_layers.append(&layer);
        for (auto* child = layer.firstChildForTesting(); child; child = child->nextSiblingForTesting())
            collect(*child);
    }

    void mixEntries(const Vector<RenderLayer*>& entries)
    {
        m_digest.mix(entries.size());
        for (auto* entry : entries)
            m_digest.mix(idOf(m_ids, entry));
    }

    Vector<RenderLayer*> m_layers;
    Vector<LayerLists> m_lists;
    LayerIds m_ids;
    Digest m_digest;
};

// Reads one list through the hooks and compares it with the captured entries. Folds the entry count and the number
// of entries that differ from the captured ones into the digest.
template<typename At>
void checkList(Digest& digest, const Vector<RenderLayer*>& expected, size_t count, At&& at, bool reverse, uint64_t& entries)
{
    uint64_t mismatches = 0;
    for (size_t step = 0; step < count; ++step) {
        size_t i = reverse ? count - 1 - step : step;
        if (i >= expected.size() || at(i) != expected[i])
            ++mismatches;
    }
    entries += count;
    digest.mix(count);
    digest.mix(mismatches);
}

void checkNegative(Digest& digest, const RenderLayer& layer, const LayerLists& expected, bool reverse, uint64_t& entries)
{
    checkList(digest, expected.negative, layer.negativeZOrderLayerCountForTesting(), [&](size_t i) { return layer.negativeZOrderLayerAtForTesting(i); }, reverse, entries);
}

void checkNormalFlow(Digest& digest, const RenderLayer& layer, const LayerLists& expected, bool reverse, uint64_t& entries)
{
    checkList(digest, expected.normalFlow, layer.normalFlowLayerCountForTesting(), [&](size_t i) { return layer.normalFlowLayerAtForTesting(i); }, reverse, entries);
}

void checkPositive(Digest& digest, const RenderLayer& layer, const LayerLists& expected, bool reverse, uint64_t& entries)
{
    checkList(digest, expected.positive, layer.positiveZOrderLayerCountForTesting(), [&](size_t i) { return layer.positiveZOrderLayerAtForTesting(i); }, reverse, entries);
}

// All three lists of one layer, in paint order (negative, normal flow, positive) or its reverse.
void checkAllLists(Digest& digest, const RenderLayer& layer, const LayerLists& expected, bool reverse, uint64_t& entries)
{
    if (!reverse) {
        checkNegative(digest, layer, expected, false, entries);
        checkNormalFlow(digest, layer, expected, false, entries);
        checkPositive(digest, layer, expected, false, entries);
    } else {
        checkPositive(digest, layer, expected, true, entries);
        checkNormalFlow(digest, layer, expected, true, entries);
        checkNegative(digest, layer, expected, true, entries);
    }
}

// Every layer of the capture: all lists, in tree order or in its reverse.
void walkCapture(Digest& digest, const Capture& capture, bool reverse, uint64_t& entries)
{
    size_t count = capture.layers().size();
    for (size_t step = 0; step < count; ++step) {
        size_t i = reverse ? count - 1 - step : step;
        checkAllLists(digest, *capture.layers()[i], capture.lists()[i], reverse, entries);
    }
}

void rebuildZOrder(Digest& digest, RenderLayer& layer, const LayerLists& expected, uint64_t& entries)
{
    layer.dirtyZOrderListsForTesting();
    layer.updateLayerListsIfNeededForTesting();
    checkNegative(digest, layer, expected, false, entries);
    checkPositive(digest, layer, expected, false, entries);
}

void rebuildNormalFlow(Digest& digest, RenderLayer& layer, const LayerLists& expected, uint64_t& entries)
{
    layer.dirtyNormalFlowListForTesting();
    layer.updateLayerListsIfNeededForTesting();
    checkNormalFlow(digest, layer, expected, false, entries);
}

// The size of each list and the dirty state of one layer: cheap enough to take after every operation.
void mixListShape(Digest& digest, const RenderLayer& layer)
{
    bool zDirty = layer.zOrderListsDirtyForTesting();
    bool flowDirty = layer.normalFlowListDirtyForTesting();
    digest.mix(zDirty | (flowDirty << 1) | (layer.isStackingContextForTesting() << 2) | (layer.isNormalFlowOnlyForTesting() << 3));
    if (!zDirty) {
        digest.mix(layer.negativeZOrderLayerCountForTesting());
        digest.mix(layer.positiveZOrderLayerCountForTesting());
    }
    if (!flowDirty)
        digest.mix(layer.normalFlowLayerCountForTesting());
}

// Every list of every layer, in order, by tree position.
void mixAllLists(Digest& digest, const RenderLayer& layer, const LayerIds& ids, uint64_t& entries)
{
    mixListShape(digest, layer);
    if (!layer.zOrderListsDirtyForTesting()) {
        for (size_t i = 0; i < layer.negativeZOrderLayerCountForTesting(); ++i)
            digest.mix(idOf(ids, layer.negativeZOrderLayerAtForTesting(i)));
        for (size_t i = 0; i < layer.positiveZOrderLayerCountForTesting(); ++i)
            digest.mix(idOf(ids, layer.positiveZOrderLayerAtForTesting(i)));
        entries += layer.negativeZOrderLayerCountForTesting() + layer.positiveZOrderLayerCountForTesting();
    }
    if (!layer.normalFlowListDirtyForTesting()) {
        for (size_t i = 0; i < layer.normalFlowLayerCountForTesting(); ++i)
            digest.mix(idOf(ids, layer.normalFlowLayerAtForTesting(i)));
        entries += layer.normalFlowLayerCountForTesting();
    }
    for (auto* child = layer.firstChildForTesting(); child; child = child->nextSiblingForTesting())
        mixAllLists(digest, *child, ids, entries);
}

// Paint order: negative z-order, normal flow, then positive z-order, descending into each layer.
void walkPaintOrder(Digest& digest, const RenderLayer& layer, const LayerIds& ids, uint64_t& entries)
{
    bool zClean = !layer.zOrderListsDirtyForTesting();
    bool flowClean = !layer.normalFlowListDirtyForTesting();
    if (zClean) {
        for (size_t i = 0; i < layer.negativeZOrderLayerCountForTesting(); ++i) {
            auto* child = layer.negativeZOrderLayerAtForTesting(i);
            digest.mix(idOf(ids, child));
            ++entries;
            walkPaintOrder(digest, *child, ids, entries);
        }
    }
    if (flowClean) {
        for (size_t i = 0; i < layer.normalFlowLayerCountForTesting(); ++i) {
            auto* child = layer.normalFlowLayerAtForTesting(i);
            digest.mix(idOf(ids, child));
            ++entries;
            walkPaintOrder(digest, *child, ids, entries);
        }
    }
    if (zClean) {
        for (size_t i = 0; i < layer.positiveZOrderLayerCountForTesting(); ++i) {
            auto* child = layer.positiveZOrderLayerAtForTesting(i);
            digest.mix(idOf(ids, child));
            ++entries;
            walkPaintOrder(digest, *child, ids, entries);
        }
    }
}

// The end of a pass whose tree can gain and lose layers: the layers are indexed afresh.
PassResult finish(Scene& scene, Digest& digest, uint64_t entries)
{
    LayerIds ids;
    indexLayers(scene.rootLayer(), ids);
    mixAllLists(digest, scene.rootLayer(), ids, entries);
    return { digest.value(), entries };
}

bool benchmarksEnabled()
{
    const char* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && *value != '0';
}

// Runs the pass once, checks its checksum, and under WEBKIT_RUN_BENCHMARKS repeats it on the
// same scene for at least a second. A pass that reads fewer than minEntries list entries did not
// reach the lists it names. The DOM benchmarks' passes start from the state the previous one left, so
// only the first pass's checksum is recorded.
template<typename Pass>
void runShape(const char* name, uint64_t expectedChecksum, uint64_t minEntries, Pass&& pass)
{
    MonotonicTime start = MonotonicTime::now();
    PassResult first = pass();
    uint64_t entries = first.listEntries;
    if (benchmarksEnabled()) {
        while (MonotonicTime::now() - start < 1_s)
            entries += pass().listEntries;
    }
    Seconds elapsed = MonotonicTime::now() - start;
    double megabytes = static_cast<double>(entries) * 8 / 1e6;
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, elapsed.milliseconds(), megabytes / elapsed.seconds(), static_cast<unsigned long long>(first.checksum));
    fflush(stdout);
    if (minEntries)
        EXPECT_GE(first.listEntries, minEntries);
    if (!benchmarksEnabled())
        EXPECT_EQ(first.checksum, expectedChecksum);
}

constexpr unsigned operationsPerPass = 24;

// 500 stacking contexts under one root, each with a fixed mix of children. Returns the contexts' ids.
Vector<unsigned> generateContexts(TreeGenerator& generator, unsigned contextCount, unsigned childrenPerContext)
{
    Vector<unsigned> contexts;
    generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < contextCount; ++i) {
        int z = generator.rng().between(-3, 9);
        contexts.append(generator.open(makeString("position:absolute;z-index:"_s, z, ";left:0px;top:0px;width:40px;height:40px;"_s)));
        generator.listMix(childrenPerContext);
        generator.close();
    }
    generator.close();
    return contexts;
}

} // namespace

// One stacking context with 2,000 positioned children and z-index 0 to 63 (many ties): each rebuild
// dirties the z-order lists, brings them up to date and reads them.
TEST(RenderLayerListBench, ZOrderRebuildWide)
{
    constexpr uint64_t expectedChecksum = 0x273c3e2e6c57cdf8ULL;
    constexpr unsigned childCount = 2000;
    constexpr unsigned rebuilds = 4;
    TreeGenerator generator(1);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < childCount; ++i) {
        int z = generator.rng().between(0, 63);
        int left = generator.rng().between(0, 770);
        int top = generator.rng().between(0, 570);
        generator.leaf("position:absolute;width:8px;height:8px;"_s, left, top, z);
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& expected = capture.listsOf(context);

    runShape("ZOrderRebuildWide", expectedChecksum, rebuilds * childCount / 2, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (unsigned i = 0; i < rebuilds; ++i)
            rebuildZOrder(digest, context, expected, entries);
        return PassResult { digest.value(), entries };
    });
}

// A chain of 300 nested positioned layers with z-index auto under one stacking context: the context's
// list takes all of them, one level of the collection after another.
TEST(RenderLayerListBench, ZOrderRebuildDeep)
{
    constexpr uint64_t expectedChecksum = 0x3ddcd142085a5188ULL;
    constexpr unsigned chainLength = 300;
    constexpr unsigned rebuilds = 60;
    TreeGenerator generator(2);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < chainLength; ++i)
        generator.open("position:relative;width:700px;height:500px;"_s);
    for (unsigned i = 0; i < chainLength; ++i)
        generator.close();
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& expected = capture.listsOf(context);

    runShape("ZOrderRebuildDeep", expectedChecksum, rebuilds * chainLength / 2, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (unsigned i = 0; i < rebuilds; ++i)
            rebuildZOrder(digest, context, expected, entries);
        return PassResult { digest.value(), entries };
    });
}

// One stacking context with 2,000 normal-flow-only children (overflow): each rebuild dirties the
// normal-flow list, brings it up to date and reads it.
TEST(RenderLayerListBench, NormalFlowRebuild)
{
    constexpr uint64_t expectedChecksum = 0xec76203ef3526402ULL;
    constexpr unsigned childCount = 2000;
    constexpr unsigned rebuilds = 4;
    TreeGenerator generator(3);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < childCount; ++i) {
        generator.open("overflow:auto;width:100px;height:2px;"_s);
        generator.close();
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& expected = capture.listsOf(context);

    runShape("NormalFlowRebuild", expectedChecksum, rebuilds * childCount / 2, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (unsigned i = 0; i < rebuilds; ++i)
            rebuildNormalFlow(digest, context, expected, entries);
        return PassResult { digest.value(), entries };
    });
}

// A tree of about 5,000 layers in 500 stacking contexts whose lists are all up to date: every list of
// every layer is read in paint order, with no change to the tree.
TEST(RenderLayerListBench, PaintOrderWalk)
{
    constexpr uint64_t expectedChecksum = 0xd041ff4defbd2a21ULL;
    constexpr unsigned walks = 4;
    TreeGenerator generator(4);
    generateContexts(generator, 500, 9);
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);

    runShape("PaintOrderWalk", expectedChecksum, walks * 2000, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (unsigned i = 0; i < walks; ++i)
            walkCapture(digest, capture, false, entries);
        return PassResult { digest.value(), entries };
    });
}

// The same tree, read in reverse paint order (the order of hit testing and of the opaque-rect search).
TEST(RenderLayerListBench, ReverseWalk)
{
    constexpr uint64_t expectedChecksum = 0xabf7f13b7df38a31ULL;
    constexpr unsigned walks = 4;
    TreeGenerator generator(4);
    generateContexts(generator, 500, 9);
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);

    runShape("ReverseWalk", expectedChecksum, walks * 2000, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (unsigned i = 0; i < walks; ++i)
            walkCapture(digest, capture, true, entries);
        return PassResult { digest.value(), entries };
    });
}

// 500 stacking contexts of 10 children each: every context's lists are dirtied, then all are brought up
// to date, then read. The lists are small, so their allocation and freeing dominate.
TEST(RenderLayerListBench, DirtyRebuildMany)
{
    constexpr uint64_t expectedChecksum = 0x14129fd208691274ULL;
    TreeGenerator generator(5);
    Vector<unsigned> contextIds = generateContexts(generator, 500, 10);
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    Vector<RenderLayer*> contexts;
    for (unsigned id : contextIds)
        contexts.append(&scene.requireLayer(id));

    runShape("DirtyRebuildMany", expectedChecksum, contexts.size() * 10 / 2, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (auto* context : contexts) {
            context->dirtyZOrderListsForTesting();
            context->dirtyNormalFlowListForTesting();
        }
        for (auto* context : contexts)
            context->updateLayerListsIfNeededForTesting();
        for (auto* context : contexts)
            checkAllLists(digest, *context, capture.listsOf(*context), false, entries);
        return PassResult { digest.value(), entries };
    });
}

// One stacking context with 20,000 positioned children and z-index -50 to 50: the rebuild, then three
// reads of the lists.
TEST(RenderLayerListBench, ListHeavy)
{
    constexpr uint64_t expectedChecksum = 0xbbf62c708134722fULL;
    constexpr unsigned childCount = 20000;
    TreeGenerator generator(6);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < childCount; ++i) {
        int z = generator.rng().between(-50, 50);
        int left = generator.rng().between(0, 770);
        int top = generator.rng().between(0, 570);
        generator.leaf("position:absolute;width:6px;height:6px;"_s, left, top, z);
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& expected = capture.listsOf(context);

    runShape("ListHeavy", expectedChecksum, childCount * 4 / 2, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        rebuildZOrder(digest, context, expected, entries);
        for (unsigned i = 0; i < 2; ++i) {
            checkNegative(digest, context, expected, false, entries);
            checkPositive(digest, context, expected, false, entries);
        }
        return PassResult { digest.value(), entries };
    });
}

// A tree of about 2,000 layers in which a seeded 5% of the positioned layers change stacking: a layer with
// a z-index gets z-index auto, one without gets a z-index. Style, layout, the lists and a read of them follow,
// and then the changes are undone and the same follows.
TEST(RenderLayerListBench, StyleChange)
{
    constexpr uint64_t expectedChecksum = 0xfffa42c8eeb8d02aULL;
    TreeGenerator generator(7);
    generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    unsigned budget = 2000;
    while (budget)
        generator.randomSubtree(5, budget);
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    Rng selection(70);
    Vector<unsigned> flips;
    for (unsigned id : generator.positionedIds()) {
        if (!selection.below(20))
            flips.append(id);
    }
    Vector<std::optional<int>> originalZ = generator.originalZIndices();

    runShape("StyleChange", expectedChecksum, 0, [&] {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        for (bool restore : { false, true }) {
            for (unsigned id : flips) {
                bool hadZIndex = originalZ[id].has_value();
                if (hadZIndex != restore)
                    scene.setZIndexAuto(id);
                else if (hadZIndex)
                    scene.setZIndex(id, *originalZ[id]);
                else
                    scene.setZIndex(id, 3);
            }
            scene.relayout();
            updateAllLists(scene.rootLayer());
            mixAllLists(digest, scene.rootLayer(), capture.ids(), entries);
        }
        return PassResult { digest.value(), entries };
    });
}

// A page-like fragment and random subtrees; z-index changes, visibility changes, layers added and
// removed, hit tests and reads of the lists.
TEST(RenderLayerListBench, Mixed)
{
    constexpr uint64_t expectedChecksum = 0x5a98cdb4c007bd39ULL;
    TreeGenerator generator(8);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    generator.pageFragment();
    unsigned budget = 1500;
    while (budget)
        generator.randomSubtree(4, budget);
    generator.close();
    Scene scene(generator.markup(), generator.count());
    auto targets = generator.positionedIds();

    runShape("Mixed", expectedChecksum, 0, [&] {
        Rng rng(18);
        Digest digest;
        uint64_t entries = 0;
        Vector<unsigned> added;
        for (unsigned op = 0; op < operationsPerPass; ++op) {
            switch (rng.below(5)) {
            case 0:
                {
                    unsigned target = targets[rng.below(static_cast<unsigned>(targets.size()))];
                    scene.setZIndex(target, rng.between(-9, 9));
                }
                break;
            case 1:
                {
                    unsigned target = targets[rng.below(static_cast<unsigned>(targets.size()))];
                    scene.setVisibility(target, rng.below(2));
                }
                break;
            case 2: {
                Ref child = HTMLDivElement::create(scene.document());
                child->setInlineStyleProperty(CSSPropertyID::Position, CSSValueID::Absolute);
                int z = rng.between(-9, 9);
                int left = rng.between(0, 770);
                int top = rng.between(0, 570);
                unsigned parentId = targets[rng.below(static_cast<unsigned>(targets.size()))];
                child->setInlineStyleProperty(CSSPropertyID::ZIndex, String::number(z));
                child->setInlineStyleProperty(CSSPropertyID::Width, "8px"_s);
                child->setInlineStyleProperty(CSSPropertyID::Height, "8px"_s);
                child->setInlineStyleProperty(CSSPropertyID::Left, makeString(left, "px"_s));
                child->setInlineStyleProperty(CSSPropertyID::Top, makeString(top, "px"_s));
                Ref parent = scene.element(parentId);
                if (!parent->appendChild(child).hasException())
                    added.append(scene.addElement(RefPtr<Element> { child.ptr() }));
                break;
            }
            case 3:
                if (!added.isEmpty()) {
                    unsigned index = added.takeLast();
                    static_cast<void>(scene.element(index).remove());
                }
                break;
            default:
                break;
            }
            scene.settle(digest, rng);
            mixListShape(digest, scene.requireLayer(container));
            if (!(op % 6)) {
                scene.relayout();
                updateAllLists(scene.rootLayer());
                LayerIds ids;
                indexLayers(scene.rootLayer(), ids);
                walkPaintOrder(digest, scene.rootLayer(), ids, entries);
            }
        }
        // Leave the tree as the next pass expects to find it.
        while (!added.isEmpty())
            static_cast<void>(scene.element(added.takeLast()).remove());
        scene.settle(digest, rng);
        return finish(scene, digest, entries);
    });
}

// Subtrees of about 2,000 layers in all, every layer in a list, are removed from rendering and brought
// back, so that the layers are destroyed while lists still hold them.
TEST(RenderLayerListBench, Destroy)
{
    constexpr uint64_t expectedChecksum = 0x88e36f3fb65fc5a9ULL;
    constexpr unsigned groupCount = 10;
    TreeGenerator generator(9);
    Vector<unsigned> groups;
    generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned group = 0; group < groupCount; ++group) {
        groups.append(generator.open("position:absolute;z-index:0;left:0px;top:0px;width:780px;height:580px;"_s));
        unsigned budget = 200;
        while (budget)
            generator.randomSubtree(4, budget);
        generator.close();
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());

    runShape("Destroy", expectedChecksum, 0, [&] {
        Rng rng(19);
        Digest digest;
        uint64_t entries = 0;
        for (unsigned group : groups) {
            scene.relayout();
            updateAllLists(scene.rootLayer());
            LayerIds ids;
            indexLayers(scene.rootLayer(), ids);
            walkPaintOrder(digest, scene.rootLayer(), ids, entries);
            scene.setDisplay(group, false);
            scene.settle(digest, rng);
            scene.setDisplay(group, true);
            scene.settle(digest, rng);
        }
        return finish(scene, digest, entries);
    });
}

// Tree benchmarks. The layers of a tree of N elements (one container below the body; the class of an element, its index
// modulo 5, gives every kind of layer: positioned with z-index auto, positive and negative z-index, overflow, opacity)
// are made and removed through the DOM; their links are read and changed only through exported functions. Walk,
// Ancestors and Enclosing time WebCore's own walks of the links and enclosing-layer queries (the reads are inlined
// there); Move changes the links through RenderLayer's layer-level addChild and removeChild; the churn benchmarks create and
// destroy layers while weak references to layers are held. A pass leaves the tree as it found it.
namespace {

// Recorded from the C++ implementation, in Release; the 20k values are for the large benchmarks' size with assertions on.
constexpr uint64_t kExpectedTreeBuild5k = 0x20449cb05f083f37ULL;
constexpr uint64_t kExpectedTreeBuild200k = 0xcc91d3a1bf2c12a5ULL;
constexpr uint64_t kExpectedTreeBuild20k = 0x2be67e734d21b6b3ULL;
constexpr uint64_t kExpectedTreeWalk5k = 0xa46a49db45852645ULL;
constexpr uint64_t kExpectedTreeWalk200k = 0x5192fd0e3de6a5a2ULL;
constexpr uint64_t kExpectedTreeWalk20k = 0xffd4bfbdff601d49ULL;
constexpr uint64_t kExpectedTreeAncestors5k = 0xc06550ee41e2131aULL;
constexpr uint64_t kExpectedTreeAncestors200k = 0xa08147c58f94285cULL;
constexpr uint64_t kExpectedTreeAncestors20k = 0x7207f7b34c68628eULL;
constexpr uint64_t kExpectedTreeEnclosing5k = 0x323c73020bde0e86ULL;
constexpr uint64_t kExpectedTreeEnclosing200k = 0xa4ab51adcdf40353ULL;
constexpr uint64_t kExpectedTreeEnclosing20k = 0xdfe93bba1f009d72ULL;
constexpr uint64_t kExpectedTreeMove5k = 0x1a6c08441e32f9c6ULL;
constexpr uint64_t kExpectedTreeMove200k = 0x5fe3e686fa7405c9ULL;
constexpr uint64_t kExpectedTreeMove20k = 0x7240050b0d836a90ULL;
constexpr uint64_t kExpectedTreeDestroy5k = 0x02cfa6749e47f392ULL;
constexpr uint64_t kExpectedTreeDestroy200k = 0x5c21acc64792d8e8ULL;
constexpr uint64_t kExpectedTreeDestroy20k = 0x2b5d7d7d81b17674ULL;
constexpr uint64_t kExpectedTreeMixed5k = 0x2f44832c5c8e064aULL;
constexpr uint64_t kExpectedTreeMixed200k = 0xf0a1b7a890b7b824ULL;
constexpr uint64_t kExpectedTreeMixed20k = 0x94d372b444270c98ULL;
constexpr uint64_t kExpectedTreeLayerChurn5k = 0xfe792ab55d154c8bULL;
constexpr uint64_t kExpectedTreeLayerChurn200k = 0xe89fb59fdf238077ULL;
constexpr uint64_t kExpectedTreeLayerChurn20k = 0x513e5249ce696c71ULL;
constexpr uint64_t kExpectedTreeLayerChurnStyle5k = 0xfe792ab55d154c8bULL;
constexpr uint64_t kExpectedTreeLayerChurnStyle200k = 0xe89fb59fdf238077ULL;
constexpr uint64_t kExpectedTreeLayerChurnStyle20k = 0x513e5249ce696c71ULL;
constexpr uint64_t kExpectedTreePaintOrderWalk200k = 0xf26cce3221a38d7dULL;
constexpr uint64_t kExpectedTreePaintOrderWalk20k = 0xb571b53551927d39ULL;
constexpr uint64_t kExpectedTreeZOrderRebuildWide200k = 0xa45bc9c1c9bc7e3dULL;
constexpr uint64_t kExpectedTreeZOrderRebuildWide20k = 0xa59f23bc3e401ff9ULL;
constexpr uint64_t kExpectedTreeZOrderRebuildDeep200k = 0x966d5285fb936547ULL;
constexpr uint64_t kExpectedTreeZOrderRebuildDeep20k = 0x52bd66caf5ee05beULL;
constexpr uint64_t kExpectedTreeLayerChurnDirect5k = 0x5de737e4df96cfdbULL;
constexpr uint64_t kExpectedTreeLayerChurnDirect200k = 0x948d11e29f5e3e67ULL;
constexpr uint64_t kExpectedTreeLayerChurnDirect20k = 0xfa2ff637058546e1ULL;

constexpr size_t kTreeSmall = 5000;
constexpr size_t kTreeLargeFull = 200000;
#if ASSERT_ENABLED
constexpr size_t kTreeLargeDefault = 20000;
#else
constexpr size_t kTreeLargeDefault = kTreeLargeFull;
#endif

// The size of the large benchmarks, 200,000 layers (20,000 with assertions on). WEBKIT_RENDER_LAYER_BENCH_LARGE sets another
// size, to take a checksum for one; the recorded checksums are not compared then.
size_t treeLargeCount()
{
    if (const char* value = getenv("WEBKIT_RENDER_LAYER_BENCH_LARGE"); value && *value)
        return static_cast<size_t>(strtoull(value, nullptr, 10));
    return kTreeLargeDefault;
}

// Part of a benchmark that scales with the large size: n for 200,000 layers.
unsigned treeScaled(unsigned n) { return static_cast<unsigned>(static_cast<uint64_t>(n) * treeLargeCount() / kTreeLargeFull); }

// Nominal bytes a layer stands for, so that the MB/s column compares benchmarks of different sizes.
constexpr size_t kNominalBytesPerLayer = 256;

// Keeps the optimizer from dropping a pass whose result nothing reads.
volatile uint64_t treeBenchmarkSink = 0;

// Accumulates the time of the regions a pass marks as measured; setup and checksums are not.
class TreePassTimer {
public:
    // Not inlined, so that a profile can tell the measured regions from the rest of a pass.
    template<typename F> NEVER_INLINE void measure(F&& function)
    {
        auto start = MonotonicTime::now();
        function();
        m_total += MonotonicTime::now() - start;
    }
    Seconds total() const { return m_total; }
    void reset() { m_total = 0_s; }

private:
    Seconds m_total;
};

// Runs the pass once with checksum on, checks its checksum, and under WEBKIT_RUN_BENCHMARKS repeats it until the measured
// regions add up to a second. pass(computeChecksum, timer) returns the checksum of the pass when computeChecksum is set.
template<typename Pass>
void runTreeShape(const char* name, size_t layers, uint64_t expected, Pass&& pass)
{
    TreePassTimer timer;
    uint64_t checksum = pass(true, timer);
    unsigned passes = 1;
    Seconds measured = timer.total();
    if (benchmarksEnabled()) {
        timer.reset();
        auto start = MonotonicTime::now();
        passes = 0;
        while (timer.total() < 1_s && MonotonicTime::now() - start < 60_s) {
            treeBenchmarkSink = pass(false, timer);
            ++passes;
        }
        measured = timer.total();
    }
    double perPassMs = measured.milliseconds() / passes;
    double megabytes = static_cast<double>(layers * kNominalBytesPerLayer) / (1024 * 1024);
    double rate = perPassMs > 0 ? megabytes / (perPassMs / 1000) : 0;
    printf("%s: %.3f ms %.1f MB/s checksum=%016llx\n", name, perPassMs, rate, static_cast<unsigned long long>(checksum));
    fflush(stdout);
    if (!getenv("WEBKIT_RENDER_LAYER_BENCH_LARGE"))
        EXPECT_EQ(checksum, expected);
}

uint64_t mixDigest(uint64_t a, uint64_t b)
{
    Digest digest;
    digest.mix(a);
    digest.mix(b);
    return digest.value();
}

// Weak references to the layers of elements, held through the exported table.
class WeakReferences {
public:
    WeakReferences() = default;
    WeakReferences(const WeakReferences&) = delete;
    ~WeakReferences() { releaseAll(); }

    void acquire(const Element& element)
    {
        size_t slot = renderLayerWeakReferenceAcquireForTesting(element);
        if (slot != notFound)
            m_slots.append(slot);
    }

    size_t size() const { return m_slots.size(); }

    size_t nullCount() const
    {
        size_t count = 0;
        for (size_t slot : m_slots)
            count += renderLayerWeakReferenceIsNullForTesting(slot);
        return count;
    }

    void releaseAll()
    {
        for (size_t slot : m_slots)
            renderLayerWeakReferenceReleaseForTesting(slot);
        m_slots.clear();
    }

private:
    Vector<size_t> m_slots;
};

// Every layer reachable from the root layer, in preorder, through the exported link reads.
Vector<RenderLayer*> collectTreeLayers(RenderLayer& root)
{
    Vector<RenderLayer*> layers;
    RenderLayer* layer = &root;
    while (true) {
        layers.append(layer);
        if (RenderLayer* child = layer->firstChildForTesting()) {
            layer = child;
            continue;
        }
        while (true) {
            if (layer == &root)
                return layers;
            if (RenderLayer* next = layer->nextSiblingForTesting()) {
                layer = next;
                break;
            }
            layer = layer->parentForTesting();
        }
    }
}

// The lists of a layer and of the layers in them, in paint order, folded by what each entry is (z-index and kind), not by
// tree position: the large trees build no LayerIds map.
void mixTreePaintOrder(Digest& digest, const RenderLayer& layer, uint64_t& entries)
{
    auto mixEntry = [&](const RenderLayer& entry) {
        digest.mix(static_cast<uint32_t>(entry.zIndexForTesting()) | (static_cast<uint64_t>(entry.isStackingContextForTesting()) << 32) | (static_cast<uint64_t>(entry.isNormalFlowOnlyForTesting()) << 33));
        ++entries;
        mixTreePaintOrder(digest, entry, entries);
    };
    if (layer.zOrderListsDirtyForTesting() || layer.normalFlowListDirtyForTesting()) {
        digest.mix(0xd1);
        return;
    }
    for (size_t i = 0, count = layer.negativeZOrderLayerCountForTesting(); i < count; ++i)
        mixEntry(*layer.negativeZOrderLayerAtForTesting(i));
    for (size_t i = 0, count = layer.normalFlowLayerCountForTesting(); i < count; ++i)
        mixEntry(*layer.normalFlowLayerAtForTesting(i));
    for (size_t i = 0, count = layer.positiveZOrderLayerCountForTesting(); i < count; ++i)
        mixEntry(*layer.positiveZOrderLayerAtForTesting(i));
}

String treeCommonStyle() { return "width: 90px; height: 90px; "_s; }
String treeAbsolute() { return "position: absolute; left: 0; top: 0; "_s; }

// The style of element i of the tree. The Style variant flips which elements are stacking contexts.
String treeStyleFor(size_t i, bool variant)
{
    switch (i % 5) {
    case 0:
        if (variant)
            return makeString(treeAbsolute(), "z-index: 3; "_s, treeCommonStyle());
        return makeString(treeAbsolute(), treeCommonStyle());
    case 1: {
        int z = 1 + static_cast<int>(i % 7);
        if (variant)
            return makeString(treeAbsolute(), "z-index: auto; "_s, treeCommonStyle());
        return makeString(treeAbsolute(), "z-index: "_s, z, "; "_s, treeCommonStyle());
    }
    case 2: {
        int z = -(1 + static_cast<int>(i % 5));
        if (variant)
            z = 2;
        return makeString(treeAbsolute(), "z-index: "_s, z, "; "_s, treeCommonStyle());
    }
    case 3:
        if (variant)
            return makeString("position: relative; z-index: 1; overflow: hidden; "_s, treeCommonStyle());
        return makeString("overflow: hidden; "_s, treeCommonStyle());
    default:
        if (variant)
            return makeString(treeAbsolute(), "opacity: 1; "_s, treeCommonStyle());
        return makeString(treeAbsolute(), "opacity: 0.9; "_s, treeCommonStyle());
    }
}

class TreeFixture {
public:
    explicit TreeFixture(size_t count)
        : m_harness(TestPageHarness::create())
        , m_count(count)
    {
        m_harness.loadHTML("<!DOCTYPE html><html><head><style>html, body { margin: 0; }</style></head><body></body></html>"_s);
        Document& doc = document();
        auto container = doc.createElementForBindings("div"_s);
        RELEASE_ASSERT(!container.hasException());
        m_container = container.releaseReturnValue();
        m_container->setAttributeWithoutSynchronization(HTMLNames::styleAttr, "position: relative; width: 100px; height: 100px;"_s);
        Rng rng(0xabcdef12);
        m_elements.reserveInitialCapacity(count);
        for (size_t i = 0; i < count; ++i) {
            auto created = doc.createElementForBindings("div"_s);
            RELEASE_ASSERT(!created.hasException());
            Ref<Element> element = created.releaseReturnValue();
            element->setAttributeWithoutSynchronization(HTMLNames::styleAttr, AtomString { treeStyleFor(i, false) });
            Element* parent = i ? m_elements[rng.below(static_cast<unsigned>(i))].ptr() : m_container.get();
            RELEASE_ASSERT(!parent->appendChild(element).hasException());
            m_elements.append(WTF::move(element));
        }
        for (size_t i = 0; i < count; ++i) {
            auto changed = treeStyleFor(i, true);
            if (changed == treeStyleFor(i, false))
                continue;
            m_changed.append(i);
            m_changedStyles.append(AtomString { changed });
        }
    }

    Document& document() { return m_harness.document(); }
    size_t count() const { return m_count; }
    Element& element(size_t i) { return m_elements[i]; }
    Element& container() { return *m_container; }
    void layout() { document().updateLayout(); }
    void updateStyle() { document().updateStyleIfNeeded(); }

    RenderLayer& rootLayer()
    {
        RenderView* view = document().renderView();
        RELEASE_ASSERT(view && view->layer());
        return *view->layer();
    }

    // Layers are made and linked by style resolution and the render tree updater.
    void attach()
    {
        RELEASE_ASSERT(!m_attached);
        RELEASE_ASSERT(!document().body()->appendChild(*m_container).hasException());
        layout();
        m_attached = true;
    }

    // Removing the container destroys every renderer, and with it every layer.
    void detach()
    {
        RELEASE_ASSERT(m_attached);
        RELEASE_ASSERT(!document().body()->removeChild(*m_container).hasException());
        layout();
        m_attached = false;
    }

    void checkAttached()
    {
        RELEASE_ASSERT(collectTreeLayers(rootLayer()).size() > m_count * 9 / 10);
    }

    void applyStyleVariant()
    {
        for (size_t k = 0; k < m_changed.size(); ++k)
            m_elements[m_changed[k]]->setAttributeWithoutSynchronization(HTMLNames::styleAttr, m_changedStyles[k]);
        layout();
    }

    void restoreStyle()
    {
        for (size_t i : m_changed)
            m_elements[i]->setAttributeWithoutSynchronization(HTMLNames::styleAttr, AtomString { treeStyleFor(i, false) });
        layout();
    }

    void updateAllLists()
    {
        for (auto* layer : collectTreeLayers(rootLayer()))
            layer->updateLayerListsIfNeededForTesting();
    }

private:
    TestPageHarness m_harness;
    size_t m_count;
    RefPtr<Element> m_container;
    Vector<Ref<Element>> m_elements;
    Vector<size_t> m_changed;
    Vector<AtomString> m_changedStyles;
    bool m_attached { false };
};

uint64_t treeWalkChecksum(TreeFixture& fixture)
{
    return renderLayerPreorderWalkForTesting(fixture.rootLayer());
}

// Reparenting subtrees at the layer level: each step takes a layer out of its parent and puts it into another layer, which
// comes earlier in the original preorder (so the links cannot form a cycle), in front of that layer's first child or at
// the end. The plan is made once, by doing it and undoing it; a pass replays it blind.
class MovePlan {
public:
    MovePlan(const Vector<RenderLayer*>& layers, size_t moves)
    {
        Rng rng(0x6d6f7665);
        for (size_t k = 0; k < moves; ++k) {
            size_t childIndex = 1 + rng.below(static_cast<unsigned>(layers.size() - 1));
            Step step;
            step.child = layers[childIndex];
            step.newParent = layers[rng.below(static_cast<unsigned>(childIndex))];
            step.oldParent = step.child->parentForTesting();
            step.oldNext = step.child->nextSiblingForTesting();
            RELEASE_ASSERT(step.oldParent);
            step.oldParent->removeChildForTesting(*step.child);
            step.before = rng.below(2) ? step.newParent->firstChildForTesting() : nullptr;
            step.newParent->addChildForTesting(*step.child, step.before);
            m_steps.append(step);
        }
        undo();
    }

    void forward()
    {
        for (auto& step : m_steps) {
            step.oldParent->removeChildForTesting(*step.child);
            step.newParent->addChildForTesting(*step.child, step.before);
        }
    }

    void undo()
    {
        for (size_t k = m_steps.size(); k--; ) {
            auto& step = m_steps[k];
            step.newParent->removeChildForTesting(*step.child);
            step.oldParent->addChildForTesting(*step.child, step.oldNext);
        }
    }

private:
    struct Step {
        RenderLayer* child { nullptr };
        RenderLayer* oldParent { nullptr };
        RenderLayer* oldNext { nullptr };
        RenderLayer* newParent { nullptr };
        RenderLayer* before { nullptr };
    };
    Vector<Step> m_steps;
};

// Elements that are added to the tree and removed again, to make and destroy layers: groups of eight elements, the
// first of each group the root of a subtree of the other seven.
class ChurnPool {
public:
    ChurnPool(Document& document, size_t count)
    {
        Rng rng(0x636875726e);
        for (size_t i = 0; i < count; ++i) {
            auto created = document.createElementForBindings("div"_s);
            RELEASE_ASSERT(!created.hasException());
            Ref<Element> element = created.releaseReturnValue();
            element->setAttributeWithoutSynchronization(HTMLNames::styleAttr, AtomString { treeStyleFor(i, false) });
            if (i % 8) {
                Element& parent = m_elements[i - i % 8 + rng.below(static_cast<unsigned>(i % 8))];
                RELEASE_ASSERT(!parent.appendChild(element).hasException());
            } else
                m_roots.append(element.copyRef());
            m_elements.append(WTF::move(element));
        }
    }

    size_t size() const { return m_elements.size(); }
    Element& element(size_t i) { return m_elements[i]; }
    const Vector<Ref<Element>>& roots() const { return m_roots; }

private:
    Vector<Ref<Element>> m_elements;
    Vector<Ref<Element>> m_roots;
};

constexpr size_t kChurnLayers = 2000;
constexpr size_t kChurnResidentWeak = 3000;

void benchBuild(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    runTreeShape(name, count, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        timer.measure([&] {
            fixture.attach();
        });
        uint64_t checksum = 0;
        if (computeChecksum) {
            fixture.checkAttached();
            checksum = treeWalkChecksum(fixture);
        }
        fixture.detach();
        return checksum;
    });
}

void benchWalk(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    fixture.attach();
    fixture.checkAttached();
    RenderLayer& root = fixture.rootLayer();
    // A tree that fits in cache is walked repeatedly, so that a pass is not a few microseconds.
    size_t walks = std::max<size_t>(1, kTreeLargeFull / count);
    runTreeShape(name, count * walks, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        timer.measure([&] {
            for (size_t i = 0; i < walks; ++i)
                digest.mix(renderLayerPreorderWalkForTesting(root));
        });
        return digest.value();
    });
    fixture.detach();
}

void benchAncestors(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    fixture.attach();
    auto layers = collectTreeLayers(fixture.rootLayer());
    RELEASE_ASSERT(layers.size() > count * 9 / 10);
    Rng rng(0x1234567);
    Vector<const RenderLayer*> probes;
    size_t probeCount = layers.size() * 4;
    probes.reserveInitialCapacity(probeCount);
    for (size_t i = 0; i < probeCount; ++i)
        probes.append(layers[rng.below(static_cast<unsigned>(layers.size()))]);
    runTreeShape(name, probeCount, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        uint64_t checksum = 0;
        timer.measure([&] {
            checksum = renderLayerAncestorWalkForTesting(probes.span());
        });
        return checksum;
    });
    fixture.detach();
}

// The enclosing-layer queries of the paint, hit-test and clip paths (stacking context, overflow clip layer, common ancestor,
// ancestor test) for random layers, through WebCore's own function that calls them.
void benchEnclosing(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    fixture.attach();
    auto layers = collectTreeLayers(fixture.rootLayer());
    RELEASE_ASSERT(layers.size() > count * 9 / 10);
    Rng rng(0x656e636c);
    Vector<RenderLayer*> probes;
    size_t probeCount = layers.size() * 2;
    probes.reserveInitialCapacity(probeCount);
    for (size_t i = 0; i < probeCount; ++i)
        probes.append(layers[rng.below(static_cast<unsigned>(layers.size()))]);
    runTreeShape(name, probeCount, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        uint64_t checksum = 0;
        timer.measure([&] {
            checksum = renderLayerEnclosingWalkForTesting(probes.span());
        });
        return checksum;
    });
    fixture.detach();
}

void benchMove(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    fixture.attach();
    auto layers = collectTreeLayers(fixture.rootLayer());
    RELEASE_ASSERT(layers.size() > count * 9 / 10);
    uint64_t before = treeWalkChecksum(fixture);
    size_t moves = std::max<size_t>(1, count / 10);
    MovePlan plan(layers, moves);
    RELEASE_ASSERT(treeWalkChecksum(fixture) == before);
    runTreeShape(name, moves * 2, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        timer.measure([&] {
            plan.forward();
        });
        if (computeChecksum)
            digest.mix(treeWalkChecksum(fixture));
        timer.measure([&] {
            plan.undo();
        });
        if (computeChecksum) {
            uint64_t restored = treeWalkChecksum(fixture);
            RELEASE_ASSERT(restored == before);
            digest.mix(restored);
        }
        return digest.value();
    });
    fixture.detach();
}

// The layers of a laid-out tree, read back in paint order. Gives the large form of PaintOrderWalk and ZOrderRebuild.
void benchPaintOrderWalkLarge(uint64_t expected, const char* name)
{
    constexpr unsigned childrenPerContext = 9;
    unsigned contexts = treeScaled(20000);
    TreeGenerator generator(14);
    generateContexts(generator, contexts, childrenPerContext);
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    runTreeShape(name, capture.layers().size(), expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        timer.measure([&] {
            walkCapture(digest, capture, false, entries);
        });
        EXPECT_GE(entries, contexts * childrenPerContext / 2);
        return digest.value();
    });
}

void benchZOrderRebuildWideLarge(uint64_t expected, const char* name)
{
    unsigned childCount = treeScaled(200000);
    TreeGenerator generator(11);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned i = 0; i < childCount; ++i) {
        int z = generator.rng().between(0, 63);
        int left = generator.rng().between(0, 770);
        int top = generator.rng().between(0, 570);
        generator.leaf("position:absolute;width:8px;height:8px;"_s, left, top, z);
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& lists = capture.listsOf(context);
    runTreeShape(name, childCount, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        timer.measure([&] {
            rebuildZOrder(digest, context, lists, entries);
        });
        EXPECT_GE(entries, childCount / 2);
        return digest.value();
    });
}

// Chains of 300 nested positioned layers with z-index auto under one stacking context, 200,000 layers in all.
void benchZOrderRebuildDeepLarge(uint64_t expected, const char* name)
{
    constexpr unsigned chainLength = 300;
    unsigned chains = std::max(1u, treeScaled(200000) / chainLength);
    TreeGenerator generator(12);
    unsigned container = generator.open("position:relative;z-index:0;width:780px;height:580px;"_s);
    for (unsigned chain = 0; chain < chains; ++chain) {
        for (unsigned i = 0; i < chainLength; ++i)
            generator.open("position:relative;width:700px;height:500px;"_s);
        for (unsigned i = 0; i < chainLength; ++i)
            generator.close();
    }
    generator.close();
    Scene scene(generator.markup(), generator.count());
    Capture capture(scene);
    RenderLayer& context = scene.requireLayer(container);
    const LayerLists& lists = capture.listsOf(context);
    runTreeShape(name, chains * chainLength, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        digest.mix(capture.setupDigest());
        uint64_t entries = 0;
        timer.measure([&] {
            rebuildZOrder(digest, context, lists, entries);
        });
        EXPECT_GE(entries, chains * chainLength / 2);
        return digest.value();
    });
}

// Remove the whole tree, with weak references to up to 5,000 of its layers held across the removal: afterwards every one reads null.
void benchDestroy(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    WeakReferences weak;
    size_t weakCount = std::min<size_t>(count, 5000);
    runTreeShape(name, count, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        fixture.attach();
        for (size_t k = 0; k < weakCount; ++k)
            weak.acquire(fixture.element(k * count / weakCount));
        uint64_t checksum = 0;
        if (computeChecksum) {
            fixture.checkAttached();
            checksum = mixDigest(treeWalkChecksum(fixture), weak.size() << 32 | weak.nullCount());
        }
        timer.measure([&] {
            fixture.detach();
        });
        uint64_t nulls = weak.nullCount();
        RELEASE_ASSERT(nulls == weak.size());
        weak.releaseAll();
        return computeChecksum ? mixDigest(checksum, nulls) : 0;
    });
}

// Style changes, a walk of the links and ancestors, a move, and a read of the lists in paint order, on one tree.
void benchMixed(size_t count, uint64_t expected, const char* name)
{
    TreeFixture fixture(count);
    fixture.attach();
    fixture.updateAllLists();
    auto layers = collectTreeLayers(fixture.rootLayer());
    RELEASE_ASSERT(layers.size() > count * 9 / 10);
    Rng rng(0x6d697865);
    Vector<const RenderLayer*> probes;
    for (size_t i = 0; i < layers.size(); ++i)
        probes.append(layers[rng.below(static_cast<unsigned>(layers.size()))]);
    MovePlan plan(layers, std::max<size_t>(1, count / 20));
    runTreeShape(name, count, expected, [&](bool, TreePassTimer& timer) -> uint64_t {
        Digest digest;
        auto readAll = [&] {
            digest.mix(renderLayerPreorderWalkForTesting(fixture.rootLayer()));
            digest.mix(renderLayerAncestorWalkForTesting(probes.span()));
            uint64_t entries = 0;
            mixTreePaintOrder(digest, fixture.rootLayer(), entries);
            digest.mix(entries);
        };
        // The layers are moved, read, and moved back before any layout, so that layout never sees links that differ from the
        // renderers'. The style variant keeps every layer, so the probes stay valid.
        timer.measure([&] {
            plan.forward();
            fixture.updateAllLists();
            readAll();
            plan.undo();
        });
        timer.measure([&] {
            fixture.applyStyleVariant();
            fixture.updateAllLists();
            readAll();
        });
        timer.measure([&] {
            fixture.restoreStyle();
            fixture.updateAllLists();
        });
        return digest.value();
    });
    fixture.detach();
}

// Layers made and destroyed by adding elements to the tree and removing them, 2,000 layers a pass, with weak references to
// 3,000 layers of the tree and to each new layer held across the removal. Every new layer's reference reads null
// afterwards and the others do not.
void benchLayerChurn(size_t resident, uint64_t expected, const char* name)
{
    TreeFixture fixture(resident);
    fixture.attach();
    fixture.updateStyle();
    ChurnPool pool(fixture.document(), kChurnLayers);
    WeakReferences residentWeak;
    for (size_t k = 0; k < kChurnResidentWeak; ++k)
        residentWeak.acquire(fixture.element(k * resident / kChurnResidentWeak));
    RELEASE_ASSERT(residentWeak.size() == kChurnResidentWeak);
    runTreeShape(name, kChurnLayers, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        WeakReferences poolWeak;
        size_t liveBefore = 0;
        size_t nullAfter = 0;
        size_t acquired = 0;
        size_t residentNull = 0;
        timer.measure([&] {
            for (auto& root : pool.roots())
                RELEASE_ASSERT(!fixture.container().appendChild(root).hasException());
            fixture.updateStyle();
            for (size_t i = 0; i < pool.size(); ++i)
                poolWeak.acquire(pool.element(i));
            acquired = poolWeak.size();
            liveBefore = poolWeak.size() - poolWeak.nullCount() + residentWeak.size() - residentWeak.nullCount();
            for (auto& root : pool.roots())
                RELEASE_ASSERT(!fixture.container().removeChild(root).hasException());
            nullAfter = poolWeak.nullCount();
            residentNull = residentWeak.nullCount();
            poolWeak.releaseAll();
        });
        RELEASE_ASSERT(!residentNull);
        RELEASE_ASSERT(acquired > kChurnLayers / 2 && nullAfter == acquired);
        Digest digest;
        digest.mix(acquired);
        digest.mix(liveBefore);
        digest.mix(nullAfter);
        if (computeChecksum) {
            fixture.layout();
            fixture.checkAttached();
            digest.mix(treeWalkChecksum(fixture));
        }
        return digest.value();
    });
    residentWeak.releaseAll();
    fixture.detach();
}

// The same, with the elements staying in the tree and the layers made and destroyed by changing their style.
void benchLayerChurnStyle(size_t resident, uint64_t expected, const char* name)
{
    TreeFixture fixture(resident);
    ChurnPool pool(fixture.document(), kChurnLayers);
    for (auto& root : pool.roots())
        RELEASE_ASSERT(!fixture.container().appendChild(root).hasException());
    AtomString plain { "width: 8px; height: 8px;"_s };
    Vector<AtomString> layered;
    for (size_t i = 0; i < pool.size(); ++i)
        layered.append(AtomString { treeStyleFor(i, false) });
    auto setStyles = [&](bool withLayers) {
        for (size_t i = 0; i < pool.size(); ++i)
            pool.element(i).setAttributeWithoutSynchronization(HTMLNames::styleAttr, withLayers ? layered[i] : plain);
        fixture.updateStyle();
    };
    fixture.attach();
    setStyles(false);
    WeakReferences residentWeak;
    for (size_t k = 0; k < kChurnResidentWeak; ++k)
        residentWeak.acquire(fixture.element(k * resident / kChurnResidentWeak));
    runTreeShape(name, kChurnLayers, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        WeakReferences poolWeak;
        size_t liveBefore = 0;
        size_t nullAfter = 0;
        size_t acquired = 0;
        timer.measure([&] {
            setStyles(true);
            for (size_t i = 0; i < pool.size(); ++i)
                poolWeak.acquire(pool.element(i));
            acquired = poolWeak.size();
            liveBefore = poolWeak.size() - poolWeak.nullCount() + residentWeak.size() - residentWeak.nullCount();
            setStyles(false);
            nullAfter = poolWeak.nullCount();
            poolWeak.releaseAll();
        });
        RELEASE_ASSERT(acquired > kChurnLayers / 2 && nullAfter == acquired);
        Digest digest;
        digest.mix(acquired);
        digest.mix(liveBefore);
        digest.mix(nullAfter);
        if (computeChecksum) {
            fixture.layout();
            digest.mix(treeWalkChecksum(fixture));
        }
        return digest.value();
    });
    residentWeak.releaseAll();
    fixture.detach();
}

// The layers of 2,000 elements of the tree are destroyed and made again where the elements stand, as a style change that
// loses a layer and gains it back does, with no style resolution: ownership and links without the DOM's work. Weak references
// to the 2,000 layers and to 3,000 others are held across it; every reference to a destroyed layer reads null and
// no other does.
void benchLayerChurnDirect(size_t resident, uint64_t expected, const char* name)
{
    TreeFixture fixture(resident);
    fixture.attach();
    size_t stride = resident / kChurnLayers;
    RELEASE_ASSERT(stride >= 2);
    Vector<Element*> targets;
    WeakReferences residentWeak;
    for (size_t i = 0; i < resident; ++i) {
        if (!(i % stride) && targets.size() < kChurnLayers)
            targets.append(&fixture.element(i));
        else if (residentWeak.size() < kChurnResidentWeak)
            residentWeak.acquire(fixture.element(i));
    }
    RELEASE_ASSERT(targets.size() == kChurnLayers && residentWeak.size() == kChurnResidentWeak);
    runTreeShape(name, kChurnLayers, expected, [&](bool computeChecksum, TreePassTimer& timer) -> uint64_t {
        WeakReferences targetWeak;
        size_t liveBefore = 0;
        size_t recreated = 0;
        size_t nullAfter = 0;
        size_t residentNull = 0;
        timer.measure([&] {
            for (auto* element : targets)
                targetWeak.acquire(*element);
            liveBefore = targetWeak.size() - targetWeak.nullCount() + residentWeak.size() - residentWeak.nullCount();
            for (auto* element : targets)
                recreated += renderLayerRecreateForTesting(*element);
            nullAfter = targetWeak.nullCount();
            residentNull = residentWeak.nullCount();
            targetWeak.releaseAll();
        });
        RELEASE_ASSERT(!residentNull);
        RELEASE_ASSERT(recreated == kChurnLayers && nullAfter == kChurnLayers);
        Digest digest;
        digest.mix(liveBefore);
        digest.mix(recreated);
        digest.mix(nullAfter);
        if (computeChecksum) {
            fixture.layout();
            fixture.checkAttached();
            digest.mix(treeWalkChecksum(fixture));
        }
        return digest.value();
    });
    residentWeak.releaseAll();
    fixture.detach();
}

// A recorded checksum for a large benchmark: the 200,000-layer value, and the 20,000-layer one Debug builds compare.
constexpr uint64_t expectedLarge([[maybe_unused]] uint64_t release200k, [[maybe_unused]] uint64_t debug20k)
{
#if ASSERT_ENABLED
    return debug20k;
#else
    return release200k;
#endif
}

// The name of a large benchmark, with the size it runs at.
const char* largeName(const char* shape)
{
    static char buffer[64];
    snprintf(buffer, sizeof(buffer), "%s-%zu", shape, treeLargeCount());
    return buffer;
}

} // namespace

TEST(RenderLayerListBench, TreeBuild5k) { benchBuild(kTreeSmall, kExpectedTreeBuild5k, "TreeBuild-5000"); }
TEST(RenderLayerListBench, TreeBuild200k) { benchBuild(treeLargeCount(), expectedLarge(kExpectedTreeBuild200k, kExpectedTreeBuild20k), largeName("TreeBuild")); }
TEST(RenderLayerListBench, TreeWalk5k) { benchWalk(kTreeSmall, kExpectedTreeWalk5k, "TreeWalk-5000"); }
TEST(RenderLayerListBench, TreeWalk200k) { benchWalk(treeLargeCount(), expectedLarge(kExpectedTreeWalk200k, kExpectedTreeWalk20k), largeName("TreeWalk")); }
TEST(RenderLayerListBench, TreeAncestors5k) { benchAncestors(kTreeSmall, kExpectedTreeAncestors5k, "TreeAncestors-5000"); }
TEST(RenderLayerListBench, TreeAncestors200k) { benchAncestors(treeLargeCount(), expectedLarge(kExpectedTreeAncestors200k, kExpectedTreeAncestors20k), largeName("TreeAncestors")); }
TEST(RenderLayerListBench, TreeEnclosing5k) { benchEnclosing(kTreeSmall, kExpectedTreeEnclosing5k, "TreeEnclosing-5000"); }
TEST(RenderLayerListBench, TreeEnclosing200k) { benchEnclosing(treeLargeCount(), expectedLarge(kExpectedTreeEnclosing200k, kExpectedTreeEnclosing20k), largeName("TreeEnclosing")); }
TEST(RenderLayerListBench, TreeMove5k) { benchMove(kTreeSmall, kExpectedTreeMove5k, "TreeMove-5000"); }
TEST(RenderLayerListBench, TreeMove200k) { benchMove(treeLargeCount(), expectedLarge(kExpectedTreeMove200k, kExpectedTreeMove20k), largeName("TreeMove")); }
TEST(RenderLayerListBench, TreeDestroy5k) { benchDestroy(kTreeSmall, kExpectedTreeDestroy5k, "TreeDestroy-5000"); }
TEST(RenderLayerListBench, TreeDestroy200k) { benchDestroy(treeLargeCount(), expectedLarge(kExpectedTreeDestroy200k, kExpectedTreeDestroy20k), largeName("TreeDestroy")); }
TEST(RenderLayerListBench, TreeMixed5k) { benchMixed(kTreeSmall, kExpectedTreeMixed5k, "TreeMixed-5000"); }
TEST(RenderLayerListBench, TreeMixed200k) { benchMixed(treeLargeCount(), expectedLarge(kExpectedTreeMixed200k, kExpectedTreeMixed20k), largeName("TreeMixed")); }
TEST(RenderLayerListBench, TreeLayerChurn5k) { benchLayerChurn(kTreeSmall, kExpectedTreeLayerChurn5k, "TreeLayerChurn-5000"); }
TEST(RenderLayerListBench, TreeLayerChurn200k) { benchLayerChurn(treeLargeCount(), expectedLarge(kExpectedTreeLayerChurn200k, kExpectedTreeLayerChurn20k), largeName("TreeLayerChurn")); }
TEST(RenderLayerListBench, TreeLayerChurnStyle5k) { benchLayerChurnStyle(kTreeSmall, kExpectedTreeLayerChurnStyle5k, "TreeLayerChurnStyle-5000"); }
TEST(RenderLayerListBench, TreeLayerChurnStyle200k) { benchLayerChurnStyle(treeLargeCount(), expectedLarge(kExpectedTreeLayerChurnStyle200k, kExpectedTreeLayerChurnStyle20k), largeName("TreeLayerChurnStyle")); }
TEST(RenderLayerListBench, TreeLayerChurnDirect5k) { benchLayerChurnDirect(kTreeSmall, kExpectedTreeLayerChurnDirect5k, "TreeLayerChurnDirect-5000"); }
TEST(RenderLayerListBench, TreeLayerChurnDirect200k) { benchLayerChurnDirect(treeLargeCount(), expectedLarge(kExpectedTreeLayerChurnDirect200k, kExpectedTreeLayerChurnDirect20k), largeName("TreeLayerChurnDirect")); }
TEST(RenderLayerListBench, TreePaintOrderWalk200k) { benchPaintOrderWalkLarge(expectedLarge(kExpectedTreePaintOrderWalk200k, kExpectedTreePaintOrderWalk20k), largeName("TreePaintOrderWalk")); }
TEST(RenderLayerListBench, TreeZOrderRebuildWide200k) { benchZOrderRebuildWideLarge(expectedLarge(kExpectedTreeZOrderRebuildWide200k, kExpectedTreeZOrderRebuildWide20k), largeName("TreeZOrderRebuildWide")); }
TEST(RenderLayerListBench, TreeZOrderRebuildDeep200k) { benchZOrderRebuildDeepLarge(expectedLarge(kExpectedTreeZOrderRebuildDeep200k, kExpectedTreeZOrderRebuildDeep20k), largeName("TreeZOrderRebuildDeep")); }

// Pages whose layers number from below 255 to above 257, around the 256 at which storage kept for destroyed layers may
// be released, are built, destroyed with weak references held to every layer, and built again twice: each build has the
// first build's tree, and every weak reference reads null after its layer's destruction.
TEST(RenderLayerListBench, DestroyAndRebuildAround256Layers)
{
    size_t fewestLayers = std::numeric_limits<size_t>::max();
    size_t mostLayers = 0;
    for (size_t count = 248; count <= 260; ++count) {
        TreeFixture fixture(count);
        uint64_t firstChecksum = 0;
        size_t firstLayers = 0;
        for (unsigned round = 0; round < 3; ++round) {
            fixture.attach();
            fixture.checkAttached();
            size_t layers = collectTreeLayers(fixture.rootLayer()).size();
            uint64_t checksum = treeWalkChecksum(fixture);
            if (!round) {
                firstChecksum = checksum;
                firstLayers = layers;
            }
            EXPECT_EQ(layers, firstLayers);
            EXPECT_EQ(checksum, firstChecksum);
            WeakReferences weak;
            for (size_t i = 0; i < count; ++i)
                weak.acquire(fixture.element(i));
            EXPECT_GT(weak.size(), count * 9 / 10);
            EXPECT_EQ(weak.nullCount(), 0u);
            fixture.detach();
            EXPECT_EQ(weak.nullCount(), weak.size());
        }
        fewestLayers = std::min(fewestLayers, firstLayers);
        mostLayers = std::max(mostLayers, firstLayers);
    }
    EXPECT_LT(fewestLayers, 255u);
    EXPECT_GT(mostLayers, 257u);
}

} // namespace TestWebKitAPI
