# WebCoreEME, the Swift of encrypted media that both WebCore's Swift and WebKit's Swift use: a static library linked into
# WebCore.framework. It is pure Swift, with no C++ in its API. It is in a directory of its own so that its .swiftmodule
# doesn't sit beside WebCore's, and WebKit's Swift can import it without seeing WebCore's own Swift module.
add_library(WebCoreEME STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/WTFBase64.swift
)
set_target_properties(WebCoreEME PROPERTIES Swift_MODULE_NAME WebCoreEME)

# No C++ includes the generated header; the macro below needs the target anyway.
set(WebCoreEME_SWIFT_INTEROP_SOURCES "")
add_custom_target(WebCoreEME_SwiftInterop)

WEBKIT_SETUP_SWIFT_AND_GENERATE_SWIFT_CPP_INTEROP_HEADER(WebCoreEME WebCoreEME
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "WebCoreEMESwift-Generated.h")

# WebCore's Swift settings that its other Swift has.
webkit_target_add_swift_options(WebCoreEME
    "-Werror DeprecatedDeclaration"
    "-Werror SendableClosureCaptures"
    -warnings-as-errors
)

# For the Swift that imports the module.
set(WebCoreEME_SWIFT_MODULE_DIR "${CMAKE_CURRENT_BINARY_DIR}" CACHE INTERNAL "Where WebCoreEME.swiftmodule is built")
set(WebCoreEME_INTEROP_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE INTERNAL "The module map of WebCoreEME's underlying module")
