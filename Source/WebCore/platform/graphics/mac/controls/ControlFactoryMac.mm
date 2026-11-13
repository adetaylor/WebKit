/*
 * Copyright (C) 2022-2023 Apple Inc. All rights reserved.
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
#import "ControlFactoryMac.h"

#if PLATFORM(MAC)

#import "ButtonPart.h"
#import "ColorWellPart.h"
#import "ImageControlsButtonPart.h"
#import "InnerSpinButtonPart.h"
#import "MenuListButtonPart.h"
#import "MenuListPart.h"
#import "MeterPart.h"
#import "PlatformControlMac.h"
#import "ProgressBarPart.h"
#import "SearchFieldCancelButtonPart.h"
#import "SearchFieldPart.h"
#import "SearchFieldResultsPart.h"
#import "SliderThumbPart.h"
#import "SliderTrackPart.h"
#import "SwitchPart.h"
#import "TextAreaPart.h"
#import "TextFieldPart.h"
#import "ToggleButtonPart.h"
#import <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ControlFactoryMac);

Ref<ControlFactory> ControlFactory::create()
{
    return adoptRef(*new ControlFactoryMac());
}

ControlFactoryMac::~ControlFactoryMac() = default;

ControlFactoryMac& ControlFactoryMac::singleton()
{
    return downcast<ControlFactoryMac>(ControlFactory::singleton());
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformControl(ControlPart& part)
{
    return makeUnique<PlatformControlMac>(part, *this);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformButton(ButtonPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformColorWell(ColorWellPart& part)
{
    return createPlatformControl(part);
}

#if ENABLE(SERVICE_CONTROLS)
std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformImageControlsButton(ImageControlsButtonPart& part)
{
    return createPlatformControl(part);
}
#endif

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformInnerSpinButton(InnerSpinButtonPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformMenuList(MenuListPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformMenuListButton(MenuListButtonPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformMeter(MeterPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformProgressBar(ProgressBarPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSearchField(SearchFieldPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSearchFieldCancelButton(SearchFieldCancelButtonPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSearchFieldResults(SearchFieldResultsPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSliderThumb(SliderThumbPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSliderTrack(SliderTrackPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformSwitch(SwitchPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformTextArea(TextAreaPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformTextField(TextFieldPart& part)
{
    return createPlatformControl(part);
}

std::unique_ptr<PlatformControl> ControlFactoryMac::createPlatformToggleButton(ToggleButtonPart& part)
{
    return createPlatformControl(part);
}

} // namespace WebCore

#endif // PLATFORM(MAC)
