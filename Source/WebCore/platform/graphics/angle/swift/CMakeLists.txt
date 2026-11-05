# The WebGL island's Swift module, WebCoreWebGL: a static library linked into WebCore.framework. It is in a directory of
# its own so that its .swiftmodule and generated C++ header don't sit beside WebCore's, and WebKit's Swift can import it
# without seeing WebCore's own Swift module.
add_library(WebCoreWebGL STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/GLContext.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLContextArrays.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLContextPlatform.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLExtensions.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLLog.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLScopes.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/GLState.swift
)
if (APPLE)
    target_sources(WebCoreWebGL PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/cocoa/CocoaGLPlatform.swift
        ${CMAKE_CURRENT_SOURCE_DIR}/cocoa/GLVideoUpload.swift
    )
endif ()
set_target_properties(WebCoreWebGL PROPERTIES Swift_MODULE_NAME WebCoreWebGL)

# WTF's staged headers, where its module map is, and not WTF's usage requirements: WTF is an OBJECT library on Cocoa, so
# linking it would copy its objects into this archive, and its header map would make the Swift clang importer see a
# second, non-modular copy of every wtf header.
target_include_directories(WebCoreWebGL PRIVATE
    ${WTF_FRAMEWORK_HEADERS_DIR}
    ${bmalloc_FRAMEWORK_HEADERS_DIR}
    ${bmalloc_PRIVATE_FRAMEWORK_HEADERS_DIR}
    ${CMAKE_BINARY_DIR}/ICU/Headers
    ${ANGLE_FRAMEWORK_HEADERS_DIR}
)
add_dependencies(WebCoreWebGL WTF_CopyHeaders GLESv2Framework)

# As WebCore's Swift: the imported C++ is compiled with WebCore's exception settings, and optimised outside Debug, so
# that C++ inline functions inline into the Swift.
webkit_target_add_swift_options(WebCoreWebGL
    "-Xcc -fno-exceptions"
    "-Xcc -fignore-exceptions"
    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<NOT:$<CONFIG:Debug>>>:SHELL:-Xcc -O2>"
    "-Werror DeprecatedDeclaration"
    "-Werror SendableClosureCaptures"
    -warnings-as-errors
)
WEBKIT_SWIFT_WHOLE_MODULE_OUTSIDE_DEBUG(WebCoreWebGL)

# The C++ that includes the generated header is in WebCore_SwiftInterop, which WebCore orders after this through
# WebCoreWebGL_SwiftInterop.
set(WebCoreWebGL_SWIFT_INTEROP_SOURCES "")
add_custom_target(WebCoreWebGL_SwiftInterop)

WEBKIT_SETUP_SWIFT_AND_GENERATE_SWIFT_CPP_INTEROP_HEADER(WebCoreWebGL WebCoreWebGL
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "WebCoreWebGLSwift-Generated.h")

set(WebCoreWebGL_SWIFT_MODULE_DIR "${CMAKE_CURRENT_BINARY_DIR}" CACHE INTERNAL "Where WebCoreWebGL.swiftmodule is built")
set(WebCoreWebGL_INTEROP_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE INTERNAL "The module maps WebCoreWebGL's clients load")
set(WebCoreWebGL_HEADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/include" CACHE INTERNAL "Where WebCoreWebGLSwift-Generated.h is generated")
