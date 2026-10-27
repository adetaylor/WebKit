set(WebGPU_OUTPUT_NAME WebGPU)

list(APPEND WebGPU_UNIFIED_SOURCE_LIST_FILES
    "Sources.txt"
)

set(WebGPU_PUBLIC_FRAMEWORK_HEADERS
)

set(WebGPU_PRIVATE_FRAMEWORK_HEADERS
    ${WebGPU_CPP_API_HEADERS}
    CxxBridgingPublic.h
    WebGPU.h
)

set(WebGPU_PRIVATE_INCLUDE_DIRECTORIES
    "${CMAKE_BINARY_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

set(WebGPU_PRIVATE_DEFINITIONS
    WGPU_IMPLEMENTATION
    WGPU_SHARED_LIBRARY
    __WEBGPU__
)

set(WebGPU_COMPILE_OPTIONS
    $<$<NOT:$<COMPILE_LANGUAGE:Swift>>:-fobjc-arc>
)

find_library(COREFOUNDATION_FRAMEWORK CoreFoundation)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics)
find_library(COREVIDEO_FRAMEWORK CoreVideo)
find_library(FOUNDATION_FRAMEWORK Foundation)
find_library(IOSURFACE_FRAMEWORK IOSurface)
find_library(METAL_FRAMEWORK Metal)
find_library(QUARTZCORE_FRAMEWORK QuartzCore)

set(WebGPU_FRAMEWORKS
    JavaScriptCore
    WTF
    bmalloc
)

set(WebGPU_PRIVATE_LIBRARIES
    ${COREFOUNDATION_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
    ${COREVIDEO_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
    ${IOSURFACE_FRAMEWORK}
    ${METAL_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
    ICU::uc
)

# The public watchOS SDK has no Metal or IOSurface, so find_library() finds the additions SDK's link stubs, which have
# no headers. Linking a framework by path also puts its directory on the compile lines, ahead of the symlinked headers,
# and the stubs hide them. Link the stubs by name instead.
if (WEBKIT_SDK_IS_WATCHOS AND NOT USE_APPLE_INTERNAL_SDK)
    list(REMOVE_ITEM WebGPU_PRIVATE_LIBRARIES ${IOSURFACE_FRAMEWORK} ${METAL_FRAMEWORK})
    list(APPEND WebGPU_PRIVATE_LIBRARIES "-F${WEBKIT_SDK_ADDITIONS_DIR}/System/Library/Frameworks" "-framework IOSurface" "-framework Metal")
endif ()

# WebKit::WebGPU aliases an INTERFACE library whose only link content is this
# variable; without it consumers link nothing and get undefined wgpu* symbols.
set(WebGPU_INTERFACE_LIBRARIES WebGPU)

WEBKIT_FRAMEWORK_DECLARE(WebGPU)
WEBKIT_ADD_TARGET_UNSAFE_BUFFER_WARNINGS(WebGPU)

if (WebGPU_INSTALL_NAME_DIR)
    set_target_properties(WebGPU PROPERTIES
        INSTALL_NAME_DIR "${WebGPU_INSTALL_NAME_DIR}"
    )
endif ()

# Variables used to generate Info.plist.
set(BUNDLE_VERSION "${MACOSX_FRAMEWORK_BUNDLE_VERSION}")
set(SHORT_VERSION_STRING "${MACOSX_FRAMEWORK_SHORT_VERSION_STRING}")
set(PRODUCT_NAME "WebGPU")
set(PRODUCT_BUNDLE_IDENTIFIER "com.apple.WebGPU")
set_target_properties(WebGPU PROPERTIES
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/../Info.plist"
)

# These #import the generated Swift interop header, so they build in a
# subtarget that can be ordered after it. Keep them out of the bundles.
set(WebGPU_SWIFT_INTEROP_SOURCES
    Adapter.mm
    BindGroup.mm
    BindGroupLayout.mm
    Buffer.mm
    CommandBuffer.mm
    CommandEncoder.mm
    ComputePassEncoder.mm
    ComputePipeline.mm
    Device.mm
    ExternalTexture.mm
    HardwareCapabilities.mm
    Instance.mm
    Pipeline.mm
    PipelineLayout.mm
    PresentationContextIOSurface.mm
    QuerySet.mm
    Queue.mm
    RenderBundle.mm
    RenderBundleEncoder.mm
    RenderPassEncoder.mm
    RenderPipeline.mm
    Sampler.mm
    ShaderModule.mm
    Texture.mm
    TextureView.mm
    XRProjectionLayer.mm
    XRSubImage.mm
)
foreach (_f IN LISTS WebGPU_SWIFT_INTEROP_SOURCES)
    list(APPEND WebGPU_UNIFIED_SOURCE_EXCLUDES "(^|/)${_f}( |$)")
endforeach ()

WEBKIT_COMPUTE_SOURCES(WebGPU)

list(APPEND WebGPU_SOURCES ${WebGPU_ARC_SOURCES})

WEBKIT_COPY_FILES(WebGPU_CopyHeaders
    DESTINATION ${WebGPU_HEADERS_DIR}
    FILES ${WebGPU_PUBLIC_FRAMEWORK_HEADERS}
    FLATTENED
)

WEBKIT_COPY_FILES(WebGPU_CopyPrivateHeaders
    DESTINATION ${WebGPU_PRIVATE_HEADERS_DIR}
    FILES ${WebGPU_PRIVATE_FRAMEWORK_HEADERS}
    FLATTENED
)

# Stage the module maps into the bundle so the Swift clang importer finds WebGPU
# and WebGPU_Private via -F. WEBKIT_COPY_FILES cannot rename, so these need the
# same explicit rules JavaScriptCore_CopyModules uses. Internal/module.modulemap
# is not staged; it is consumed in place via -I below.
set(_webgpu_modules_dir "${CMAKE_BINARY_DIR}/WebGPU.framework/${WEBKIT_FRAMEWORK_VERSION_PATH}Modules")
add_custom_command(
    OUTPUT "${_webgpu_modules_dir}/module.modulemap"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_webgpu_modules_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/WebGPU.modulemap"
        "${_webgpu_modules_dir}/module.modulemap"
    MAIN_DEPENDENCY "${CMAKE_CURRENT_SOURCE_DIR}/WebGPU.modulemap"
    VERBATIM)
add_custom_command(
    OUTPUT "${_webgpu_modules_dir}/module.private.modulemap"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_webgpu_modules_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/WebGPU_Private.modulemap"
        "${_webgpu_modules_dir}/module.private.modulemap"
    MAIN_DEPENDENCY "${CMAKE_CURRENT_SOURCE_DIR}/WebGPU_Private.modulemap"
    VERBATIM)
add_custom_target(WebGPU_CopyModules ALL DEPENDS
    "${_webgpu_modules_dir}/module.modulemap"
    "${_webgpu_modules_dir}/module.private.modulemap")

set(WebGPU_DEPENDENCIES
    WebGPU_CopyHeaders
    WebGPU_CopyPrivateHeaders
    WebGPU_CopyModules
)

set(_webgpu_swiftmodule_dir "${_webgpu_modules_dir}/WebGPU.swiftmodule")
set(WebGPU_POST_BUILD_COMMAND
    ${CMAKE_COMMAND} -E make_directory "${_webgpu_swiftmodule_dir}")
foreach (_ext IN ITEMS swiftmodule swiftdoc abi.json)
    list(APPEND WebGPU_POST_BUILD_COMMAND
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_BINARY_DIR}/WebGPU.${_ext}"
            "${_webgpu_swiftmodule_dir}/${WEBKIT_SWIFT_MODULE_TRIPLE}.${_ext}")
endforeach ()

WEBKIT_FRAMEWORK(WebGPU)
WEBKIT_ADD_PREFIX_HEADER(WebGPU WebGPUPrefix.h PREFIX_LANGUAGES OBJCXX)

target_sources(WebGPU PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/Adapter.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/BindGroup.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/BindGroupLayout.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Buffer.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/CommandBuffer.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/CommandEncoder.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/ComputePassEncoder.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/ComputePipeline.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/DebugToggles.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Device.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/DeviceHelpers.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/EncoderModel.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/ExternalTexture.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/ExternalTextureImport.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/HardwareCapabilities.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Instance.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/LayoutConversion.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Pipeline.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/PipelineLayout.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/PipelineModel.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/PresentationContextIOSurface.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/QuerySet.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Queue.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderBundle.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderBundleEncoder.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderBundleEncoderCreation.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderPassEncoder.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderPipeline.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/RenderPipelineTables.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Sampler.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/ShaderModule.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/StdLibExtras.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/Texture.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/TextureFormats.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/TextureView.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/WGSLBridge.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/XRProjectionLayer.swift
    ${CMAKE_CURRENT_SOURCE_DIR}/XRSubImage.swift
)
target_link_libraries(WebGPU PRIVATE WGSL)
# Without -force_load the linker drops archive members that hold only types and conformances.
# The compiler's Swift symbols are an implementation detail of WebGPU.framework.
target_link_options(WebGPU PRIVATE
    "LINKER:-force_load,$<TARGET_FILE:WGSL>"
    "LINKER:-unexported_symbol,_$s*4WGSL*"
)
webkit_target_compile_definitions(WebGPU PRIVATE HAVE_WGSL_COMPILER=1)

webkit_target_add_swift_options(WebGPU
    -I${CMAKE_CURRENT_SOURCE_DIR}/Internal
    "-library-level spi"
    "-Werror SendableClosureCaptures"
)

set(WebGPU_SWIFT_EMIT_CLANG_HEADER_MIN_ACCESS internal)

# Whole-module optimization outside Debug, as for WGSL: the C++ classes call small Swift methods
# on every command, which need cross-file inlining.
WGSL_SETUP_SWIFT_TARGET(WebGPU)

# Outside the dyld shared cache, the Objective-C runtime rewrites an image's @protocol references when it loads it.
# The Swift code references Metal's protocols, so keep those references in __DATA, on the page the selector
# references already dirty, rather than dirtying a page of __DATA_CONST in every process that maps WebGPU.
target_link_options(WebGPU PRIVATE "LINKER:-rename_section,__DATA_CONST,__objc_protorefs,__DATA,__objc_protorefs")

WEBKIT_SETUP_SWIFT_AND_GENERATE_SWIFT_CPP_INTEROP_HEADER(WebGPU WebGPU
    "${WebGPU_HEADERS_DIR}"
    "WebGPUSwift-Generated.h")

WEBKIT_DEFINE_SUBTARGET(WebGPU_SwiftInterop WebGPU ${WebGPU_SWIFT_INTEROP_SOURCES})
target_precompile_headers(WebGPU_SwiftInterop REUSE_FROM WebGPU)
# FIXME: This objects.rsp plumbing is duplicated in WebCore, WebKit and
# WEBKIT_DEFINE_SUBTARGET_WITH_PREFIX; factor it into a shared helper.
set(_interop_objs "$<FILTER:$<TARGET_OBJECTS:WebGPU_SwiftInterop>,EXCLUDE,\\.(g|p)ch$>")
set(_interop_rsp "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/WebGPU_SwiftInterop.dir/objects.rsp")
file(GENERATE OUTPUT "${_interop_rsp}" CONTENT "$<JOIN:${_interop_objs},\n>")
target_link_options(WebGPU PRIVATE "@${_interop_rsp}")
set_property(TARGET WebGPU APPEND PROPERTY LINK_DEPENDS "${_interop_objs};${_interop_rsp}")
