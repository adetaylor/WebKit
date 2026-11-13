/*
 * Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
 * Copyright (C) 2011 University of Szeged
 * Copyright (C) 2011 Renata Hodovan <reni@webkit.org>
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2014 Google Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY UNIVERSITY OF SZEGED ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL UNIVERSITY OF SZEGED OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "SpotLightSource.h"

#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<SpotLightSource> SpotLightSource::create(const FloatPoint3D& position, const FloatPoint3D& direction, float specularExponent, float limitingConeAngle)
{
    return adoptRef(*new SpotLightSource(position, direction, specularExponent, limitingConeAngle));
}

SpotLightSource::SpotLightSource(const FloatPoint3D& position, const FloatPoint3D& pointsAt, float specularExponent, float limitingConeAngle)
    : LightSource(LightType::Spot)
    , m_position(position)
    , m_pointsAt(pointsAt)
    , m_specularExponent(clampTo<float>(specularExponent, 1.0f, 128.0f))
    , m_limitingConeAngle(limitingConeAngle)
{
}

bool SpotLightSource::operator==(const SpotLightSource& other) const
{
    return LightSource::operator==(other)
        && m_position == other.m_position
        && m_pointsAt == other.m_pointsAt
        && m_specularExponent == other.m_specularExponent
        && m_limitingConeAngle == other.m_limitingConeAngle;
}

bool SpotLightSource::setX(float x)
{
    if (m_position.x() == x)
        return false;
    m_position.setX(x);
    return true;
}

bool SpotLightSource::setY(float y)
{
    if (m_position.y() == y)
        return false;
    m_position.setY(y);
    return true;
}

bool SpotLightSource::setZ(float z)
{
    if (m_position.z() == z)
        return false;
    m_position.setZ(z);
    return true;
}

bool SpotLightSource::setPointsAtX(float pointsAtX)
{
    if (m_pointsAt.x() == pointsAtX)
        return false;
    m_pointsAt.setX(pointsAtX);
    return true;
}

bool SpotLightSource::setPointsAtY(float pointsAtY)
{
    if (m_pointsAt.y() == pointsAtY)
        return false;
    m_pointsAt.setY(pointsAtY);
    return true;
}

bool SpotLightSource::setPointsAtZ(float pointsAtZ)
{
    if (m_pointsAt.z() == pointsAtZ)
        return false;
    m_pointsAt.setZ(pointsAtZ);
    return true;
}

bool SpotLightSource::setSpecularExponent(float specularExponent)
{
    specularExponent = clampTo<float>(specularExponent, 1.0f, 128.0f);
    if (m_specularExponent == specularExponent)
        return false;
    m_specularExponent = specularExponent;
    return true;
}

bool SpotLightSource::setLimitingConeAngle(float limitingConeAngle)
{
    if (m_limitingConeAngle == limitingConeAngle)
        return false;
    m_limitingConeAngle = limitingConeAngle;
    return true;
}

TextStream& SpotLightSource::externalRepresentation(TextStream& ts) const
{
    ts << "[type=SPOT-LIGHT] "_s;
    ts << "[position=\"" << position() << "\"]"_s;
    ts << "[direction=\"" << direction() << "\"]"_s;
    ts << "[specularExponent=\"" << specularExponent() << "\"]"_s;
    ts << "[limitingConeAngle=\"" << limitingConeAngle() << "\"]"_s;
    return ts;
}

}; // namespace WebCore
