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

#pragma once

#include <array>
#include <wtf/text/ASCIILiteral.h>

namespace TestWebKitAPI::ContentSecurityPolicyBenchInputs {

// Policies in the shapes large sites send: host allowlists, nonces with 'strict-dynamic', hashes, wildcards, ports,
// report-only companions, Trusted Types, and the deprecated or misspelled directives that are still common.
// Host names are under example.com, example.net and example.org. An empty report-only policy means none is sent.
struct SitePolicy {
    ASCIILiteral enforce;
    ASCIILiteral reportOnly;
};

static constexpr std::array typicalSitePolicies {
    SitePolicy {
        "default-src 'none'; base-uri 'self'; child-src www.example.com/assets-cdn/worker/ gist.example.com/assets-cdn/worker/; "
        "connect-src 'self' uploads.example.com status.example.org collector.example.com raw.example.org api.example.com "
        "objects.example.org objects-origin.example.org *.actions.example.net wss://*.actions.example.net wss://alive.example.com; "
        "font-src assets.example.net; form-action 'self' www.example.com gist.example.com; frame-ancestors 'none'; "
        "frame-src viewscreen.example.org notebooks.example.org; img-src 'self' data: blob: assets.example.net media.example.org "
        "camo.example.org identicons.example.com avatars.example.org *.storage.example.net; manifest-src 'self'; "
        "media-src www.example.com user-images.example.org/ secured-user-images.example.org/ private-user-images.example.org; "
        "script-src assets.example.net; style-src 'unsafe-inline' assets.example.net; upgrade-insecure-requests; "
        "worker-src www.example.com/assets-cdn/worker/ gist.example.com/assets-cdn/worker/"_s,
        ""_s,
    },
    SitePolicy {
        "script-src 'nonce-q8Yr2vZxDm0Lk3PcWtE1sA' 'strict-dynamic' 'report-sample' 'unsafe-eval' 'unsafe-inline' https: http:; "
        "object-src 'none'; base-uri 'self'; report-uri https://csp.example.com/csp/gws/other-hp"_s,
        "require-trusted-types-for 'script'; report-uri https://csp.example.com/csp/gws/other-hp"_s,
    },
    SitePolicy {
        "default-src data: blob: 'self' https://*.example.net *.example.com 'unsafe-inline' 'unsafe-eval'; "
        "script-src *.example.com *.example.net *.example.org blob: data: 'self' 'unsafe-eval' 'unsafe-inline'; "
        "style-src data: blob: 'unsafe-inline' *; connect-src secure.example.com edge-chat.example.com *.example.com:* "
        "*.example.net wss://*.example.com:* wss://*.example.net attachment.example.org blob: 'self' https://api.example.org; "
        "font-src data: *; img-src *.example.com *.example.net data: blob: 'self' https://*.example.org; "
        "media-src *.cdn.example.net blob: data: 'self' https://*.example.org; frame-src *.example.com *.example.net data: blob: "
        "https://*.example.org; worker-src *.example.com blob: data: 'self'; block-all-mixed-content; upgrade-insecure-requests; "
        "report-uri https://www.example.com/csp/reporting/?m=c&minimize=0"_s,
        "default-src *.example.com data: blob: 'self'; script-src *.example.com 'self' 'nonce-Hk2LwQ9vX0pRb7ZcMn4TfA==' "
        "'strict-dynamic'; report-uri https://www.example.com/csp/reporting/?m=t&minimize=0"_s,
    },
    SitePolicy {
        "connect-src 'self' blob: https://api.example.com https://*.api.example.com https://upload.example.com "
        "https://*.example.org wss://*.example.com https://*.video.example.net; default-src 'self'; "
        "form-action 'self' https://example.com https://*.example.com; font-src 'self' https://*.static.example.net; "
        "frame-src 'self' https://example.com https://*.example.com https://*.example.org; "
        "img-src 'self' blob: data: https://*.static.example.net https://*.example.com https://*.example.org; "
        "manifest-src 'self'; media-src 'self' blob: https://*.video.example.net https://*.static.example.net; "
        "object-src 'none'; script-src 'self' 'unsafe-inline' https://*.static.example.net https://*.example.org "
        "'nonce-ZTU0YmM5NjQtMDY4Zi00ZjYz'; style-src 'self' 'unsafe-inline' https://*.static.example.net; "
        "worker-src 'self' blob:; report-to csp-endpoint; report-uri https://example.com/i/csp_report?a=O5RXE%3D%3D%3D"_s,
        ""_s,
    },
    SitePolicy {
        ""_s,
        "script-src 'unsafe-eval' 'self' meta.example.org *.example.org 'unsafe-inline'; default-src 'self' data: blob: "
        "*.example.org; style-src 'self' data: blob: *.example.org 'unsafe-inline'; "
        "report-uri https://www.example.org/w/api.php?action=cspreport&format=json&reportonly=1"_s,
    },
    SitePolicy {
        "upgrade-insecure-requests;report-uri https://metrics.example.com/"_s,
        ""_s,
    },
    SitePolicy {
        "default-src 'self' blob: data: *.example.com 'unsafe-inline'; img-src 'self' blob: data: *.example.com "
        "*.example.net; script-src 'self' 'unsafe-inline' 'unsafe-eval' *.example.com; frame-ancestors 'self' *.example.com"_s,
        ""_s,
    },
    SitePolicy {
        "script-src 'self' 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=' "
        "'sha256-R7BycX6lCwOq9x3CZpytPnOyYvDNpLs38i6qKfpCcVY=' "
        "'sha384-7ESiLXyw12m+pc0XmX8byVbcRkpQ1y6jXb5/289KS91SxFKMEJa2cVyi728F3EVv'; "
        "style-src 'self' 'sha256-IAdwN3biDCQ3brrgp1m8kBEsPQYyqfREKOEfeoREopc='; object-src 'none'; base-uri 'none'; "
        "frame-ancestors 'self'"_s,
        ""_s,
    },
    SitePolicy {
        "require-trusted-types-for 'script'; trusted-types default dompurify goog#html lit-html 'allow-duplicates'; "
        "script-src 'nonce-8IBTHwOdqNKAWeKl7plt8g' 'strict-dynamic' 'unsafe-inline' https:; object-src 'none'; base-uri 'self'"_s,
        "script-src 'nonce-8IBTHwOdqNKAWeKl7plt8g' 'report-sample' 'strict-dynamic' 'unsafe-eval'; "
        "report-uri /cspreport/youtube_main"_s,
    },
    SitePolicy {
        "default-src 'self'; script-src 'self' 'report-sha256' cdn.example.net; img-src 'self' https://images.example.net; "
        "report-to csp-endpoint"_s,
        "default-src 'none'; script-src 'self' 'report-sample'; style-src 'self'; report-to csp-endpoint; report-uri /csp-report"_s,
    },
    SitePolicy {
        "default-src 'self' https://api.example.com:8443 https://static.example.net:443/assets/ http://localhost:*; "
        "connect-src 'self' ws://localhost:35729 wss://socket.example.com:* https://api.example.com:8443; img-src * data:; "
        "frame-src https://www.example.org:443/embed/ https://player.example.net/video/"_s,
        ""_s,
    },
    SitePolicy {
        "sandbox allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox; "
        "form-action 'self' https://checkout.example.com; navigate-to 'self'; default-src 'self' https://*.example.com"_s,
        ""_s,
    },
    SitePolicy {
        "default-src 'self'; plugin-types application/pdf application/x-shockwave-flash; block-all-mixed-content; "
        "referrer no-referrer-when-downgrade; reflected-xss block; object-src 'self'; img-src * data:"_s,
        ""_s,
    },
    SitePolicy {
        "default-src 'self' https://example.com; script-src 'self' 'unsafe-inline' https:/cdn.example.net "
        "https://cdn.example.net/js/?v=12; img-src 'self' data: https://*.example.com/images#top; style-src 'self' 'none'; "
        "font-src 'self' https://fonts.example.org; font-src https://other-fonts.example.org; connect-src default-src"_s,
        ""_s,
    },
    SitePolicy {
        "Default-Src 'SELF' HTTPS://Static.Example.com;  Script-Src 'self'   'Unsafe-Inline' 'NONCE-AbC123' ;object-src 'none';;"
        "\tIMG-SRC *.Example.COM data: ; STYLE-src 'self' 'unsafe-inline'"_s,
        "default-src 'self', script-src 'self' cdn.example.net; report-uri https://reports.example.com/csp"_s,
    },
    SitePolicy {
        "default-src 'self', script-src 'self' https://cdn.example.net 'wasm-unsafe-eval' 'trusted-types-eval' 'unsafe-hashes' "
        "'sha512-CWXHpGFzuaJsGev2gHdrJ3GuVlXCv9Q7vNi21ftHXFNw2S4Pl2Ol2h5YQDH7AmdEBkyONDF0mOFnOttF9Xm2TQ=='"_s,
        "img-src 'self'; report-uri https://reports.example.com/csp; report-to default"_s,
    },
};

} // namespace TestWebKitAPI::ContentSecurityPolicyBenchInputs
