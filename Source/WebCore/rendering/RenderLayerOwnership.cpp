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

/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2005 Allan Sandfeld Jensen (kde@carewolf.com)
 *           (C) 2005, 2006 Samuel Weinig (sam.weinig@gmail.com)
 * Copyright (C) 2005-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2010-2015 Google Inc. All rights reserved.
 * Copyright (C) 2023, 2024 Igalia S.L.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "RenderLayer.h"

#include "RenderLayerModelObject.h"
#include "WebCore-Swift.h"
#include <wtf/NeverDestroyed.h>

namespace WebCore {

// The owners of every renderer's layer (RenderLayerOwners, in RenderLayerOwners.swift). Only RenderLayerModelObject and
// RenderLayer reach the store (RenderLayerOwnersKey), through this file, and the store is never destroyed.
static RenderLayerOwners& layerOwners(const RenderLayerOwnersKey& key)
{
    static NeverDestroyed<RenderLayerOwners> owners(RenderLayerOwners::init(key));
    return owners;
}

// The layer is dropped here only if willBeDestroyed() did not drop it. Add any other code to willBeDestroyed().
RenderLayerModelObject::~RenderLayerModelObject()
{
    dropLayer();
}

void RenderLayerModelObject::destroyLayer()
{
    setHasLayer(false);
    dropLayer();
}

// The store frees the layer, and traps if anything else still holds it. No layer may end where code holds layers by
// plain pointers and references.
void RenderLayerModelObject::dropLayerOwner(uint64_t owner, RenderLayer& layer)
{
    RELEASE_ASSERT(!RenderLayer::layerFreeForbidden());
    layer.willBeDropped();
    layerOwners({ }).drop(owner, LayerRef(&layer), layer.renderer().renderTreeBeingDestroyed());
}

void RenderLayerModelObject::dropLayer()
{
    if (auto* layer = std::exchange(m_layer, nullptr))
        dropLayerOwner(std::exchange(m_layerOwner, 0), *layer);
}

void RenderLayerModelObject::createLayer()
{
    RELEASE_ASSERT(!m_layer);
    auto created = layerOwners({ }).make(this);
    m_layerOwner = created.owner;
    m_layer = created.layer;
    setHasLayer(true);
    setMayHaveLayerInSubtreeIncludingAncestors();
    m_layer->insertOnlyThisLayer();
}

uint64_t RenderLayer::s_destructionCount { 0 };

static LayerRef layerRef(const RenderLayer* layer)
{
    return std::bit_cast<LayerRef>(layer);
}

RenderLayer* RenderLayer::weakFieldInStore(LayerWeakField field) const
{
    return static_cast<RenderLayer*>(layerOwners({ }).weakField(std::to_underlying(field), m_ownerHandle, layerRef(this)));
}

// Sets the field's bit before the store holds a reference, and clears it once the store holds none, so that a clear bit
// means null at every point. A null set on a clear bit finds the reference already null, and returns without asking the
// store.
void RenderLayer::setWeakField(LayerWeakField field, RenderLayer* layer)
{
    // RenderLayerOwners.swift's weakField and setWeakField switch on these values.
    static_assert(std::to_underlying(LayerWeakField::BackingProvider) == 1);
    static_assert(std::to_underlying(LayerWeakField::BackingProviderAtEndOfCompositingUpdate) == 2);
    static_assert(std::to_underlying(LayerWeakField::EnclosingPagination) == 4);
    if (!layer && !(m_weakFieldsMayBeSet & std::to_underlying(field))) {
        ASSERT(!weakFieldInStore(field));
        return;
    }
    if (layer)
        m_weakFieldsMayBeSet |= std::to_underlying(field);
    layerOwners({ }).setWeakField(std::to_underlying(field), m_ownerHandle, layerRef(this), layer ? layer->m_ownerHandle : 0, layerRef(layer));
    if (!layer)
        m_weakFieldsMayBeSet &= ~std::to_underlying(field);
}

} // namespace WebCore
