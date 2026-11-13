/*
 * Copyright (C) 2012 Google Inc. All rights reserved.
 * Copyright (C) 2016-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of Google Inc. nor the names of its contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(MEDIA_STREAM)

#include <WebCore/RealtimeMediaSourceSupportedConstraints.h>
#include <cstdlib>
#include <wtf/ArgumentCoder.h>
#include <wtf/Function.h>
#include <wtf/Vector.h>

namespace WebCore {
    
class MediaConstraint {
public:
    enum class DataType : uint8_t { Integer, Double, Boolean, String };
    explicit MediaConstraint(DataType dataType)
        : m_dataType(dataType)
    {
    }

    virtual ~MediaConstraint() = default;

    bool isInt() const { return m_dataType == DataType::Integer; }
    bool isDouble() const { return m_dataType == DataType::Double; }
    bool isBoolean() const { return m_dataType == DataType::Boolean; }
    bool isString() const { return m_dataType == DataType::String; }

    DataType dataType() const { return m_dataType; }

    void log(MediaConstraintType) const;

    virtual bool isRequired() const { return false; }

private:
    DataType m_dataType { DataType::Integer };
};

template<class ValueType>
class NumericConstraint : public MediaConstraint {
public:
    void setMin(ValueType value) { m_min = value; }
    void setMax(ValueType value) { m_max = value; }
    void setExact(ValueType value) { m_exact = value; }
    void setIdeal(ValueType value) { m_ideal = value; }

    bool getMin(ValueType& min) const
    {
        if (!m_min)
            return false;

        min = m_min.value();
        return true;
    }

    bool getMax(ValueType& max) const
    {
        if (!m_max)
            return false;

        max = m_max.value();
        return true;
    }

    bool getExact(ValueType& exact) const
    {
        if (!m_exact)
            return false;

        exact = m_exact.value();
        return true;
    }

    bool getIdeal(ValueType& ideal) const
    {
        if (!m_ideal)
            return false;

        ideal = m_ideal.value();
        return true;
    }

    bool isEmpty() const { return !m_min && !m_max && !m_exact && !m_ideal; }
    bool isMandatory() const { return m_min || m_max || m_exact; }

protected:
    NumericConstraint(DataType dataType)
        : MediaConstraint(dataType)
    {
    }
    
    NumericConstraint(MediaConstraint&& mediaConstraint, std::optional<ValueType>&& min, std::optional<ValueType>&& max, std::optional<ValueType>&& exact, std::optional<ValueType>&& ideal)
        : MediaConstraint(WTF::move(mediaConstraint))
        , m_min(WTF::move(min))
        , m_max(WTF::move(max))
        , m_exact(WTF::move(exact))
        , m_ideal(WTF::move(ideal))
    {
    }

    NumericConstraint() = default;

    bool isRequired() const final { return !!m_min || !!m_max || !!m_exact; }

    std::optional<ValueType> m_min;
    std::optional<ValueType> m_max;
    std::optional<ValueType> m_exact;
    std::optional<ValueType> m_ideal;
};

class IntConstraint final : public NumericConstraint<int> {
public:
    IntConstraint()
        : NumericConstraint<int>(DataType::Integer)
    {
    }

    void logAsInt(MediaConstraintType) const;
    
private:
    friend struct IPC::ArgumentCoder<IntConstraint>;
    
    IntConstraint(MediaConstraint&& mediaConstraint, std::optional<int>&& min, std::optional<int>&& max,                   std::optional<int>&& exact, std::optional<int>&& ideal)
        : NumericConstraint<int>(WTF::move(mediaConstraint), WTF::move(min), WTF::move(max), WTF::move(exact), WTF::move(ideal))
    {
    }
};

class DoubleConstraint final : public NumericConstraint<double> {
public:
    DoubleConstraint()
        : NumericConstraint<double>(DataType::Double)
    {
    }

    void logAsDouble(MediaConstraintType) const;
    
private:
    friend struct IPC::ArgumentCoder<DoubleConstraint>;
    
    DoubleConstraint(MediaConstraint&& mediaConstraint, std::optional<double>&& min, std::optional<double>&& max,                   std::optional<double>&& exact, std::optional<double>&& ideal)
        : NumericConstraint<double>(WTF::move(mediaConstraint), WTF::move(min), WTF::move(max), WTF::move(exact), WTF::move(ideal))
    {
    }
};

class BooleanConstraint final : public MediaConstraint {
public:
    BooleanConstraint()
        : MediaConstraint(DataType::Boolean)
    {
    }

    void setExact(bool value) { m_exact = value; }
    void setIdeal(bool value) { m_ideal = value; }

    bool getExact(bool& exact) const
    {
        if (!m_exact)
            return false;

        exact = m_exact.value();
        return true;
    }

    bool getIdeal(bool& ideal) const
    {
        if (!m_ideal)
            return false;

        ideal = m_ideal.value();
        return true;
    }

    bool isEmpty() const { return !m_exact && !m_ideal; };
    bool isMandatory() const { return bool(m_exact); }

    void logAsBoolean(MediaConstraintType) const;

private:
    friend struct IPC::ArgumentCoder<BooleanConstraint>;
    
    BooleanConstraint(MediaConstraint&& mediaConstraint, std::optional<bool>&& exact, std::optional<bool>&& ideal)
        : MediaConstraint(WTF::move(mediaConstraint))
        , m_exact(WTF::move(exact))
        , m_ideal(WTF::move(ideal))
    {
    }

    bool isRequired() const final { return !!m_exact; }

    std::optional<bool> m_exact;
    std::optional<bool> m_ideal;
};

class StringConstraint : public MediaConstraint {
public:
    StringConstraint()
        : MediaConstraint(DataType::String)
    {
    }

    void setExact(const String& value)
    {
        m_exact.clear();
        m_exact.append(value);
    }

    void appendExact(const String& value)
    {
        m_exact.append(value);
    }

    void setIdeal(const String& value)
    {
        m_ideal.clear();
        m_ideal.append(value);
    }

    void appendIdeal(const String& value)
    {
        m_ideal.append(value);
    }

    bool getExact(Vector<String>& exact) const
    {
        if (m_exact.isEmpty())
            return false;

        exact = m_exact;
        return true;
    }

    bool getIdeal(Vector<String>& ideal) const
    {
        if (m_ideal.isEmpty())
            return false;

        ideal = m_ideal;
        return true;
    }

    const Vector<String>& exactValues() const LIFETIME_BOUND { return m_exact; }
    const Vector<String>& idealValues() const LIFETIME_BOUND { return m_ideal; }

    bool isEmpty() const { return m_exact.isEmpty() && m_ideal.isEmpty(); }
    bool isMandatory() const { return !m_exact.isEmpty(); }

    void removeEmptyStringConstraint()
    {
        m_exact.removeAllMatching([](auto& constraint) {
            return constraint.isEmpty();
        });
        m_ideal.removeAllMatching([](auto& constraint) {
            return constraint.isEmpty();
        });
    }

    StringConstraint isolatedCopy() const;

private:
    friend struct IPC::ArgumentCoder<StringConstraint>;
    
    StringConstraint(MediaConstraint&& mediaConstraint, Vector<String>&& exact, Vector<String>&& ideal)
        : MediaConstraint(WTF::move(mediaConstraint))
        , m_exact(WTF::move(exact))
        , m_ideal(WTF::move(ideal))
    {
    }

    bool isRequired() const final { return !m_exact.isEmpty(); }

    Vector<String> m_exact;
    Vector<String> m_ideal;
};

class MediaTrackConstraintSetMap {
public:
    MediaTrackConstraintSetMap() = default;
    MediaTrackConstraintSetMap(std::optional<IntConstraint> width, std::optional<IntConstraint> height, std::optional<IntConstraint> sampleRate, std::optional<IntConstraint> sampleSize, std::optional<DoubleConstraint> aspectRatio, std::optional<DoubleConstraint> frameRate, std::optional<DoubleConstraint> volume, std::optional<BooleanConstraint> echoCancellation, std::optional<StringConstraint> displaySurface, std::optional<BooleanConstraint> logicalSurface, std::optional<StringConstraint>&& facingMode, std::optional<StringConstraint>&& deviceId, std::optional<StringConstraint>&& groupId, std::optional<StringConstraint>&& whiteBalanceMode, std::optional<DoubleConstraint> zoom, std::optional<BooleanConstraint> torch, std::optional<BooleanConstraint> backgroundBlur, std::optional<BooleanConstraint> powerEfficient)
        : m_width(width)
        , m_height(height)
        , m_sampleRate(sampleRate)
        , m_sampleSize(sampleSize)
        , m_aspectRatio(aspectRatio)
        , m_frameRate(frameRate)
        , m_volume(volume)
        , m_echoCancellation(echoCancellation)
        , m_displaySurface(displaySurface)
        , m_logicalSurface(logicalSurface)
        , m_facingMode(facingMode)
        , m_deviceId(WTF::move(deviceId))
        , m_groupId(WTF::move(groupId))
        , m_whiteBalanceMode(WTF::move(whiteBalanceMode))
        , m_zoom(zoom)
        , m_torch(torch)
        , m_backgroundBlur(backgroundBlur)
        , m_powerEfficient(powerEfficient)
    {
    }

    WEBCORE_EXPORT void forEach(NOESCAPE const Function<void(MediaConstraintType, const MediaConstraint&)>&) const;
    void filter(NOESCAPE const Function<bool(MediaConstraintType, const MediaConstraint&)>&) const;
    bool isEmpty() const;
    WEBCORE_EXPORT bool isValid() const;
    WEBCORE_EXPORT size_t size() const;

    WEBCORE_EXPORT void set(MediaConstraintType, std::optional<IntConstraint>&&);
    WEBCORE_EXPORT void set(MediaConstraintType, std::optional<DoubleConstraint>&&);
    WEBCORE_EXPORT void set(MediaConstraintType, std::optional<BooleanConstraint>&&);
    WEBCORE_EXPORT void set(MediaConstraintType, std::optional<StringConstraint>&&);

    void clearDeviceId() { m_deviceId = { }; }

    const std::optional<IntConstraint>& width() const LIFETIME_BOUND { return m_width; }
    const std::optional<IntConstraint>& height() const LIFETIME_BOUND { return m_height; }
    const std::optional<IntConstraint>& sampleRate() const LIFETIME_BOUND { return m_sampleRate; }
    const std::optional<IntConstraint>& sampleSize() const LIFETIME_BOUND { return m_sampleSize; }

    const std::optional<DoubleConstraint>& aspectRatio() const LIFETIME_BOUND { return m_aspectRatio; }
    const std::optional<DoubleConstraint>& frameRate() const LIFETIME_BOUND { return m_frameRate; }
    const std::optional<DoubleConstraint>& volume() const LIFETIME_BOUND { return m_volume; }

    const std::optional<BooleanConstraint>& echoCancellation() const LIFETIME_BOUND { return m_echoCancellation; }
    const std::optional<StringConstraint>& displaySurface() const LIFETIME_BOUND { return m_displaySurface; }
    const std::optional<BooleanConstraint>& logicalSurface() const LIFETIME_BOUND { return m_logicalSurface; }

    const std::optional<StringConstraint>& facingMode() const LIFETIME_BOUND { return m_facingMode; }
    const std::optional<StringConstraint>& deviceId() const LIFETIME_BOUND { return m_deviceId; }
    const std::optional<StringConstraint>& groupId() const LIFETIME_BOUND { return m_groupId; }

    const std::optional<StringConstraint>& whiteBalanceMode() const LIFETIME_BOUND { return m_whiteBalanceMode; }
    const std::optional<DoubleConstraint>& zoom() const LIFETIME_BOUND { return m_zoom; }
    const std::optional<BooleanConstraint>& torch() const LIFETIME_BOUND { return m_torch; }
    const std::optional<BooleanConstraint>& backgroundBlur() const LIFETIME_BOUND { return m_backgroundBlur; }
    const std::optional<BooleanConstraint>& powerEfficient() const LIFETIME_BOUND { return m_powerEfficient; }

    MediaTrackConstraintSetMap isolatedCopy() const;

private:
    friend struct IPC::ArgumentCoder<MediaTrackConstraintSetMap>;
    std::optional<IntConstraint> m_width;
    std::optional<IntConstraint> m_height;
    std::optional<IntConstraint> m_sampleRate;
    std::optional<IntConstraint> m_sampleSize;

    std::optional<DoubleConstraint> m_aspectRatio;
    std::optional<DoubleConstraint> m_frameRate;
    std::optional<DoubleConstraint> m_volume;

    std::optional<BooleanConstraint> m_echoCancellation;
    std::optional<StringConstraint> m_displaySurface;
    std::optional<BooleanConstraint> m_logicalSurface;

    std::optional<StringConstraint> m_facingMode;
    std::optional<StringConstraint> m_deviceId;
    std::optional<StringConstraint> m_groupId;

    std::optional<StringConstraint> m_whiteBalanceMode;
    std::optional<DoubleConstraint> m_zoom;
    std::optional<BooleanConstraint> m_torch;

    std::optional<BooleanConstraint> m_backgroundBlur;
    std::optional<BooleanConstraint> m_powerEfficient;
};

struct MediaConstraints {
    void setDefaultAudioConstraints();
    void setDefaultVideoConstraints();
    bool isConstraintSet(NOESCAPE const Function<bool(const MediaTrackConstraintSetMap&)>&) const;

    MediaTrackConstraintSetMap mandatoryConstraints;
    Vector<MediaTrackConstraintSetMap> advancedConstraints;
    bool isValid { false };

    MediaConstraints isolatedCopy() const;

    enum class DeviceType : bool { Camera, Microphone };
    bool hasDisallowedRequiredConstraintForDeviceSelection(DeviceType) const;

    WEBCORE_EXPORT bool willUseEchoCancellation() const;
};

} // namespace WebCore

#define SPECIALIZE_TYPE_TRAITS_MEDIACONSTRAINT(ConstraintType, predicate) \
SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::ConstraintType) \
static bool isType(const WebCore::MediaConstraint& constraint) { return constraint.predicate; } \
SPECIALIZE_TYPE_TRAITS_END()

SPECIALIZE_TYPE_TRAITS_MEDIACONSTRAINT(IntConstraint, isInt())
SPECIALIZE_TYPE_TRAITS_MEDIACONSTRAINT(DoubleConstraint, isDouble())
SPECIALIZE_TYPE_TRAITS_MEDIACONSTRAINT(StringConstraint, isString())
SPECIALIZE_TYPE_TRAITS_MEDIACONSTRAINT(BooleanConstraint, isBoolean())

#endif // ENABLE(MEDIA_STREAM)
