# WebCoreSwiftSupport, value types for WebKit's Swift that are pure Swift: a static library linked into
# WebCore.framework, which WebCore's Swift, WebCoreEME and WebKit's Swift import. It has no C or C++ API, and no
# underlying clang module. It is in a directory of its own so that its .swiftmodule doesn't sit beside WebCore's.
add_library(WebCoreSwiftSupport STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/InlineCodeUnits.swift
)
set_target_properties(WebCoreSwiftSupport PROPERTIES Swift_MODULE_NAME WebCoreSwiftSupport)

# No C++ includes the generated header; the macro below needs the target anyway.
set(WebCoreSwiftSupport_SWIFT_INTEROP_SOURCES "")
add_custom_target(WebCoreSwiftSupport_SwiftInterop)
set(WebCoreSwiftSupport_SWIFT_NO_UNDERLYING_MODULE TRUE)

WEBKIT_SETUP_SWIFT_AND_GENERATE_SWIFT_CPP_INTEROP_HEADER(WebCoreSwiftSupport WebCoreSwiftSupport
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "WebCoreSwiftSupportSwift-Generated.h")

webkit_target_add_swift_options(WebCoreSwiftSupport
    "-Werror DeprecatedDeclaration"
    "-Werror SendableClosureCaptures"
    -warnings-as-errors
)

# For the Swift that imports the module.
set(WebCoreSwiftSupport_SWIFT_MODULE_DIR "${CMAKE_CURRENT_BINARY_DIR}" CACHE INTERNAL "Where WebCoreSwiftSupport.swiftmodule is built")
