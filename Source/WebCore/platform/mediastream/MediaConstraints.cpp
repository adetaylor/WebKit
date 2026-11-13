/*
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

#include "config.h"
#include "MediaConstraints.h"

#if ENABLE(MEDIA_STREAM)
#include "RealtimeMediaSourceCenter.h"
#include "RealtimeMediaSourceSupportedConstraints.h"
#include <wtf/CrossThreadCopier.h>
#include <wtf/StdLibExtras.h>

namespace WebCore {

void MediaTrackConstraintSetMap::forEach(NOESCAPE const Function<void(MediaConstraintType, const MediaConstraint&)>& callback) const
{
    filter([&callback](auto type, auto& constraint) {
        callback(type, constraint);
        return false;
    });
}

void MediaTrackConstraintSetMap::filter(NOESCAPE const Function<bool(MediaConstraintType, const MediaConstraint&)>& callback) const
{
    if (m_width && !m_width->isEmpty() && callback(MediaConstraintType::Width, *m_width))
        return;
    if (m_height && !m_height->isEmpty() && callback(MediaConstraintType::Height, *m_height))
        return;
    if (m_sampleRate && !m_sampleRate->isEmpty() && callback(MediaConstraintType::SampleRate, *m_sampleRate))
        return;
    if (m_sampleSize && !m_sampleSize->isEmpty() && callback(MediaConstraintType::SampleSize, *m_sampleSize))
        return;

    if (m_aspectRatio && !m_aspectRatio->isEmpty() && callback(MediaConstraintType::AspectRatio, *m_aspectRatio))
        return;
    if (m_frameRate && !m_frameRate->isEmpty() && callback(MediaConstraintType::FrameRate, *m_frameRate))
        return;
    if (m_volume && !m_volume->isEmpty() && callback(MediaConstraintType::Volume, *m_volume))
        return;

    if (m_echoCancellation && !m_echoCancellation->isEmpty() && callback(MediaConstraintType::EchoCancellation, *m_echoCancellation))
        return;

    if (m_facingMode && !m_facingMode->isEmpty() && callback(MediaConstraintType::FacingMode, *m_facingMode))
        return;
    if (m_deviceId && !m_deviceId->isEmpty() && callback(MediaConstraintType::DeviceId, *m_deviceId))
        return;
    if (m_groupId && !m_groupId->isEmpty() && callback(MediaConstraintType::GroupId, *m_groupId))
        return;

    if (m_whiteBalanceMode && !m_whiteBalanceMode->isEmpty() && callback(MediaConstraintType::WhiteBalanceMode, *m_whiteBalanceMode))
        return;
    if (m_zoom && !m_zoom->isEmpty() && callback(MediaConstraintType::Zoom, *m_zoom))
        return;
    if (m_torch && !m_torch->isEmpty() && callback(MediaConstraintType::Torch, *m_torch))
        return;
    if (m_backgroundBlur && !m_backgroundBlur->isEmpty() && callback(MediaConstraintType::BackgroundBlur, *m_backgroundBlur))
        return;
    if (m_powerEfficient && !m_powerEfficient->isEmpty() && callback(MediaConstraintType::PowerEfficient, *m_powerEfficient))
        return;
}

void MediaTrackConstraintSetMap::set(MediaConstraintType constraintType, std::optional<IntConstraint>&& constraint)
{
    switch (constraintType) {
    case MediaConstraintType::Width:
        m_width = WTF::move(constraint);
        break;
    case MediaConstraintType::Height:
        m_height = WTF::move(constraint);
        break;
    case MediaConstraintType::SampleRate:
        m_sampleRate = WTF::move(constraint);
        break;
    case MediaConstraintType::SampleSize:
        m_sampleSize = WTF::move(constraint);
        break;

    case MediaConstraintType::AspectRatio:
    case MediaConstraintType::FrameRate:
    case MediaConstraintType::Volume:
    case MediaConstraintType::EchoCancellation:
    case MediaConstraintType::FacingMode:
    case MediaConstraintType::DeviceId:
    case MediaConstraintType::GroupId:
    case MediaConstraintType::DisplaySurface:
    case MediaConstraintType::LogicalSurface:
    case MediaConstraintType::FocusDistance:
    case MediaConstraintType::WhiteBalanceMode:
    case MediaConstraintType::Zoom:
    case MediaConstraintType::Torch:
    case MediaConstraintType::BackgroundBlur:
    case MediaConstraintType::PowerEfficient:
    case MediaConstraintType::Unknown:
        ASSERT_NOT_REACHED();
        break;
    }
}

void MediaTrackConstraintSetMap::set(MediaConstraintType constraintType, std::optional<DoubleConstraint>&& constraint)
{
    switch (constraintType) {
    case MediaConstraintType::AspectRatio:
        m_aspectRatio = WTF::move(constraint);
        break;
    case MediaConstraintType::FrameRate:
        m_frameRate = WTF::move(constraint);
        break;
    case MediaConstraintType::Volume:
        m_volume = WTF::move(constraint);
        break;
    case MediaConstraintType::Zoom:
        m_zoom = WTF::move(constraint);
        break;

    case MediaConstraintType::Width:
    case MediaConstraintType::Height:
    case MediaConstraintType::SampleRate:
    case MediaConstraintType::SampleSize:
    case MediaConstraintType::EchoCancellation:
    case MediaConstraintType::FacingMode:
    case MediaConstraintType::DeviceId:
    case MediaConstraintType::GroupId:
    case MediaConstraintType::DisplaySurface:
    case MediaConstraintType::LogicalSurface:
    case MediaConstraintType::FocusDistance:
    case MediaConstraintType::WhiteBalanceMode:
    case MediaConstraintType::Torch:
    case MediaConstraintType::BackgroundBlur:
    case MediaConstraintType::PowerEfficient:
    case MediaConstraintType::Unknown:
        ASSERT_NOT_REACHED();
        break;
    }
}

void MediaTrackConstraintSetMap::set(MediaConstraintType constraintType, std::optional<BooleanConstraint>&& constraint)
{
    switch (constraintType) {
    case MediaConstraintType::EchoCancellation:
        m_echoCancellation = WTF::move(constraint);
        break;
    case MediaConstraintType::LogicalSurface:
        m_logicalSurface = WTF::move(constraint);
        break;

    case MediaConstraintType::Torch:
        m_torch = WTF::move(constraint);
        break;
    case MediaConstraintType::BackgroundBlur:
        m_backgroundBlur = WTF::move(constraint);
        break;
    case MediaConstraintType::PowerEfficient:
        m_powerEfficient = WTF::move(constraint);
        break;
    case MediaConstraintType::Width:
    case MediaConstraintType::Height:
    case MediaConstraintType::SampleRate:
    case MediaConstraintType::SampleSize:
    case MediaConstraintType::AspectRatio:
    case MediaConstraintType::FrameRate:
    case MediaConstraintType::Volume:
    case MediaConstraintType::FacingMode:
    case MediaConstraintType::DeviceId:
    case MediaConstraintType::DisplaySurface:
    case MediaConstraintType::GroupId:
    case MediaConstraintType::FocusDistance:
    case MediaConstraintType::Zoom:
    case MediaConstraintType::WhiteBalanceMode:
    case MediaConstraintType::Unknown:
        ASSERT_NOT_REACHED();
        break;
    }
}

void MediaTrackConstraintSetMap::set(MediaConstraintType constraintType, std::optional<StringConstraint>&& constraint)
{
    switch (constraintType) {
    case MediaConstraintType::FacingMode:
        m_facingMode = WTF::move(constraint);
        break;
    case MediaConstraintType::DeviceId:
        if (constraint)
            constraint->removeEmptyStringConstraint();
        m_deviceId = WTF::move(constraint);
        break;
    case MediaConstraintType::DisplaySurface:
        if (constraint)
            constraint->removeEmptyStringConstraint();
        m_displaySurface = WTF::move(constraint);
        break;
    case MediaConstraintType::GroupId:
        m_groupId = WTF::move(constraint);
        break;
    case MediaConstraintType::WhiteBalanceMode:
        m_whiteBalanceMode = WTF::move(constraint);
        break;

    case MediaConstraintType::Width:
    case MediaConstraintType::Height:
    case MediaConstraintType::SampleRate:
    case MediaConstraintType::SampleSize:
    case MediaConstraintType::AspectRatio:
    case MediaConstraintType::FrameRate:
    case MediaConstraintType::Volume:
    case MediaConstraintType::EchoCancellation:
    case MediaConstraintType::LogicalSurface:
    case MediaConstraintType::FocusDistance:
    case MediaConstraintType::Zoom:
    case MediaConstraintType::Torch:
    case MediaConstraintType::BackgroundBlur:
    case MediaConstraintType::PowerEfficient:
    case MediaConstraintType::Unknown:
        ASSERT_NOT_REACHED();
        break;
    }
}

size_t MediaTrackConstraintSetMap::size() const
{
    size_t count = 0;
    forEach([&count] (auto, const MediaConstraint&) mutable {
        ++count;
    });

    return count;
}

bool MediaTrackConstraintSetMap::isEmpty() const
{
    return !size();
}

bool MediaTrackConstraintSetMap::isValid() const
{
    bool isValid = true;
    if (isEmpty())
        return true;
    forEach([&isValid] (MediaConstraintType constraintType, const MediaConstraint& constraint) {
        switch (constraintType) {
        case MediaConstraintType::Width:
        case MediaConstraintType::Height:
        case MediaConstraintType::SampleRate:
        case MediaConstraintType::SampleSize:
            isValid &= (constraint.dataType() == MediaConstraint::DataType::Integer);
            break;
        case MediaConstraintType::AspectRatio:
        case MediaConstraintType::FrameRate:
        case MediaConstraintType::Volume:
        case MediaConstraintType::Zoom:
        case MediaConstraintType::FocusDistance:
            isValid &= (constraint.dataType() == MediaConstraint::DataType::Double);
            break;
        case MediaConstraintType::FacingMode:
        case MediaConstraintType::DeviceId:
        case MediaConstraintType::DisplaySurface:
        case MediaConstraintType::GroupId:
        case MediaConstraintType::WhiteBalanceMode:
            isValid &= (constraint.dataType() == MediaConstraint::DataType::String);
            break;
        case MediaConstraintType::EchoCancellation:
        case MediaConstraintType::LogicalSurface:
        case MediaConstraintType::Torch:
        case MediaConstraintType::BackgroundBlur:
            isValid &= (constraint.dataType() == MediaConstraint::DataType::Boolean);
            break;
        case MediaConstraintType::PowerEfficient:
            isValid &= (constraint.dataType() == MediaConstraint::DataType::Boolean);
            break;
        case MediaConstraintType::Unknown:
            ASSERT_NOT_REACHED();
            break;
        }
    });
    return isValid;
}

static inline void addDefaultVideoConstraints(MediaTrackConstraintSetMap& videoConstraints, bool addFrameRateConstraint, bool addWidthConstraint, bool addHeightConstraint)
{
    if (addFrameRateConstraint) {
        DoubleConstraint frameRateConstraint;
        frameRateConstraint.setIdeal(30);
        videoConstraints.set(MediaConstraintType::FrameRate, WTF::move(frameRateConstraint));
    }
    if (addWidthConstraint) {
        IntConstraint widthConstraint;
        widthConstraint.setIdeal(640);
        videoConstraints.set(MediaConstraintType::Width, WTF::move(widthConstraint));
    }
    if (addHeightConstraint) {
        IntConstraint heightConstraint;
        heightConstraint.setIdeal(480);
        videoConstraints.set(MediaConstraintType::Height, WTF::move(heightConstraint));
    }
}

bool MediaConstraints::isConstraintSet(NOESCAPE const Function<bool(const MediaTrackConstraintSetMap&)>& callback) const
{
    if (callback(mandatoryConstraints))
        return true;
    
    for (const auto& constraint : advancedConstraints) {
        if (callback(constraint))
            return true;
    }
    return false;
}

void MediaConstraints::setDefaultAudioConstraints()
{
    bool needsEchoCancellationConstraint = !isConstraintSet([](const MediaTrackConstraintSetMap& constraint) {
        return !!constraint.echoCancellation();
    });

    if (needsEchoCancellationConstraint) {
        BooleanConstraint echoCancellationConstraint;
        echoCancellationConstraint.setIdeal(true);
        mandatoryConstraints.set(MediaConstraintType::EchoCancellation, WTF::move(echoCancellationConstraint));
    }
}

bool MediaConstraints::willUseEchoCancellation() const
{
    // Echo cancellation is enabled by default, so we only expect it to be off if it is explicitly asked for.
    auto requestedValue = [](const MediaTrackConstraintSetMap& constraintSet) -> std::optional<bool> {
        auto& constraint = constraintSet.echoCancellation();
        if (!constraint)
            return { };

        bool value;
        if (constraint->getExact(value) || constraint->getIdeal(value))
            return value;

        return { };
    };

    if (auto value = requestedValue(mandatoryConstraints))
        return *value;

    for (auto& advancedConstraint : advancedConstraints) {
        if (auto value = requestedValue(advancedConstraint))
            return *value;
    }

    return true;
}

void MediaConstraints::setDefaultVideoConstraints()
{
    // 640x480, 30fps camera
    bool needsFrameRateConstraint = !isConstraintSet([](const MediaTrackConstraintSetMap& constraint) {
        return !!constraint.frameRate() || !!constraint.width() || !!constraint.height();
    });
    
    bool needsWidthConstraint = !isConstraintSet([](const MediaTrackConstraintSetMap& constraint) {
        return !!constraint.width() || !!constraint.height();
    });
    
    bool needsHeightConstraint = !isConstraintSet([](const MediaTrackConstraintSetMap& constraint) {
        return !!constraint.width() || !!constraint.height() || !!constraint.aspectRatio() || !!constraint.powerEfficient();
    });

    addDefaultVideoConstraints(mandatoryConstraints, needsFrameRateConstraint, needsWidthConstraint, needsHeightConstraint);
}

void MediaConstraint::log(MediaConstraintType constraintType) const
{
    switch (dataType()) {
    case DataType::Boolean:
        downcast<const BooleanConstraint>(*this).logAsBoolean(constraintType);
        break;
    case DataType::Double:
        downcast<const DoubleConstraint>(*this).logAsDouble(constraintType);
        break;
    case DataType::Integer:
        downcast<const IntConstraint>(*this).logAsInt(constraintType);
        break;
    case DataType::String:
        WTFLogAlways("MediaConstraint %d of type %d", static_cast<int>(constraintType), static_cast<int>(dataType()));
    }
}

void BooleanConstraint::logAsBoolean(MediaConstraintType constraintType) const
{
    WTFLogAlways("BooleanConstraint %d, exact %d, ideal %d", static_cast<int>(constraintType), m_exact ? *m_exact : -1, m_ideal ? *m_ideal : -1);
}

void DoubleConstraint::logAsDouble(MediaConstraintType constraintType) const
{
    WTFLogAlways("DoubleConstraint %d, min %f, max %f, exact %f, ideal %f", static_cast<int>(constraintType), m_min ? *m_min : -1, m_max ? *m_max : -1, m_exact ? *m_exact : -1, m_ideal ? *m_ideal : -1);
}

void IntConstraint::logAsInt(MediaConstraintType constraintType) const
{
    WTFLogAlways("IntConstraint %d, min %d, max %d, exact %d, ideal %d", static_cast<int>(constraintType), m_min ? *m_min : -1, m_max ? *m_max : -1, m_exact ? *m_exact : -1, m_ideal ? *m_ideal : -1);
}

StringConstraint StringConstraint::isolatedCopy() const
{
    return StringConstraint(MediaConstraint { DataType::String }, crossThreadCopy(m_exact), crossThreadCopy(m_ideal));
}

MediaTrackConstraintSetMap MediaTrackConstraintSetMap::isolatedCopy() const
{
    return { m_width, m_height, m_sampleRate, m_sampleSize, m_aspectRatio, m_frameRate, m_volume, m_echoCancellation, m_displaySurface, m_logicalSurface, crossThreadCopy(m_facingMode), crossThreadCopy(m_deviceId), crossThreadCopy(m_groupId), crossThreadCopy(m_whiteBalanceMode), m_zoom, m_torch, m_backgroundBlur, m_powerEfficient };
}

MediaConstraints MediaConstraints::isolatedCopy() const
{
    return { crossThreadCopy(mandatoryConstraints), crossThreadCopy(advancedConstraints), isValid };
}

NODELETE static bool isAllowedRequiredConstraintForDeviceSelection(MediaConstraints::DeviceType deviceType, MediaConstraintType type)
{
    // https://w3c.github.io/mediacapture-main/#dfn-allowed-required-constraints-for-device-selection
    if (type <= MediaConstraintType::GroupId)
        return true;

    if (deviceType == MediaConstraints::DeviceType::Microphone)
        return true;

    return type == MediaConstraintType::DisplaySurface || type == MediaConstraintType::LogicalSurface;
}

bool MediaConstraints::hasDisallowedRequiredConstraintForDeviceSelection(DeviceType deviceType) const
{
    bool result = false;
    mandatoryConstraints.forEach([&] (auto type, const MediaConstraint& constraint) mutable {
        result |= !isAllowedRequiredConstraintForDeviceSelection(deviceType, type) && constraint.isRequired();
    });
    return result;
}

}

#endif // ENABLE(MEDIA_STREAM)
