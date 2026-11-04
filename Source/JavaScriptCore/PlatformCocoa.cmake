add_definitions(-D__STDC_WANT_LIB_EXT1__)

target_compile_options(JavaScriptCore PRIVATE
    "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:-fno-threadsafe-statics>"
)

find_library(SECURITY_LIBRARY Security)
find_library(COREGRAPHICS_LIBRARY CoreGraphics)
find_library(CORETEXT_LIBRARY CoreText)
list(APPEND JavaScriptCore_LIBRARIES
    ${SECURITY_LIBRARY}
    ${COREGRAPHICS_LIBRARY}
    ${CORETEXT_LIBRARY}
)

target_link_options(JavaScriptCore PRIVATE
    "LINKER:-unexported_symbols_list,${JAVASCRIPTCORE_DIR}/unexported-libc++.txt"
)

list(APPEND JavaScriptCore_UNIFIED_SOURCE_LIST_FILES
    "SourcesCocoa.txt"

    "inspector/remote/SourcesCocoa.txt"
)

list(APPEND JavaScriptCore_PRIVATE_INCLUDE_DIRECTORIES
    ${JAVASCRIPTCORE_DIR}/inspector/cocoa
    ${JAVASCRIPTCORE_DIR}/inspector/remote/cocoa
)

list(APPEND JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    inspector/remote/RemoteInspectorConstants.h

    inspector/remote/cocoa/RemoteInspectorXPCConnection.h
)

# Headers Xcode marks Private but cmake omits from JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS.
list(APPEND JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    ${JavaScriptCore_DERIVED_SOURCES_DIR}/AirOpcode.h

    bytecode/DirectEvalCodeCacheInlines.h

    runtime/FractionToDouble.h

    wasm/WasmTypeSectionState.h

    wasm/js/JSWebAssemblyStreamingContextInlines.h
)

list(REMOVE_ITEM JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    API/glib/JSAPIWrapperGlobalObject.h
    API/glib/JSCAutocleanups.h
    API/glib/JSCCallbackFunction.h
    API/glib/JSCClassPrivate.h
    API/glib/JSCContextInternal.h
    API/glib/JSCContextPrivate.h
    API/glib/JSCExceptionPrivate.h
    API/glib/JSCGLibWrapperObject.h
    API/glib/JSCOptions.h
    API/glib/JSCValuePrivate.h
    API/glib/JSCVirtualMachinePrivate.h
    API/glib/JSCWrapperMap.h
)

list(REMOVE_ITEM JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    API/JSBase.h
    API/JSCallbackConstructor.h
    API/JSCallbackObject.h
    API/JSContext.h
    API/JSContextRef.h
    API/JSExport.h
    API/JSManagedValue.h
    API/JSObjectRef.h
    API/JSStringRef.h
    API/JSStringRefCF.h
    API/JSTypedArray.h
    API/JSValue.h
    API/JSValueRef.h
    API/JSVirtualMachine.h
    API/JavaScript.h
    API/JavaScriptCore.h
)

list(REMOVE_ITEM JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    API/APICallbackFunction.h

    b3/testb3.h

    bytecode/BytecodeBasicBlock.h
    bytecode/ChainedWatchpoint.h
    bytecode/CodeBlockInlines.h
    bytecode/InlineAccess.h
    bytecode/MethodOfGettingAValueProfile.h
    bytecode/TrackedReferences.h

    dfg/DFGCPSRethreadingPhase.h
    dfg/DFGCSEPhase.h
    dfg/DFGInPlaceAbstractState.h
    dfg/DFGLiveCatchVariablePreservationPhase.h
    dfg/DFGRegisteredStructure.h
    dfg/DFGRegisteredStructureSet.h

    ftl/FTLAbbreviatedTypes.h
    ftl/FTLCommonValues.h
    ftl/FTLExitArgumentForOperand.h
    ftl/FTLExitValue.h
    ftl/FTLFormattedValue.h
    ftl/FTLOSREntry.h
    ftl/FTLStackmapArgumentList.h
    ftl/FTLThunks.h
    ftl/FTLValueFromBlock.h
    ftl/FTLValueRange.h

    jit/JITThunks.h
    jit/SIMDShuffle.h
    jit/SpillRegistersMode.h

    llint/InPlaceInterpreter.h
    llint/LLIntCLoop.h
    llint/LLIntOfflineAsmConfig.h
    llint/LLIntPCRanges.h

    lol/LOLJIT.h
    lol/LOLRegisterAllocator.h

    profiler/ProfilerDumper.h

    runtime/ArrayIteratorPrototype.h
    runtime/BigInteger.h
    runtime/IndexingTypeInlines.h
    runtime/JSSetIteratorInlines.h
    runtime/JSSourceCodeInlines.h
    runtime/JSStringIteratorInlines.h
    runtime/JSStringJoiner.h
    runtime/MachineContext.h
    runtime/ModuleGraphLoadingState.h
    runtime/ModuleLoaderPayload.h
    runtime/ModuleLoadingContext.h
    runtime/ModuleRegistryEntry.h
    runtime/RegExpInlines.h
    runtime/RegExpMatchesArray.h
    runtime/TemporalNow.h

    wasm/WasmParser.h
    wasm/WasmPlan.h

    wasm/debugger/WasmBreakpointManager.h
    wasm/debugger/WasmExecutionHandler.h
    wasm/debugger/WasmMemoryHandler.h
    wasm/debugger/WasmModuleManager.h
    wasm/debugger/WasmQueryHandler.h

    wasm/js/WebAssemblyPromising.h
    wasm/js/WebAssemblySuspending.h
    wasm/js/WebAssemblySuspendingConstructor.h
    wasm/js/WebAssemblySuspendingPrototype.h
)

if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/AugmentableInspectorControllerClient.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/AugmentableInspectorControllerClient.h "#include \"inspector/augmentable/AugmentableInspectorControllerClient.h\"")
endif ()
if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorFrontendRouter.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorFrontendRouter.h "#include \"inspector/InspectorFrontendRouter.h\"")
endif ()
if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorBackendDispatcher.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorBackendDispatcher.h "#include \"inspector/InspectorBackendDispatcher.h\"")
endif ()
if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorBackendDispatchers.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorBackendDispatchers.h "#include \"inspector/InspectorBackendDispatchers.h\"")
endif ()
if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorFrontendDispatchers.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorFrontendDispatchers.h "#include \"inspector/InspectorFrontendDispatchers.h\"")
endif ()
if (NOT EXISTS ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorProtocolObjects.h)
    file(WRITE ${JavaScriptCore_DERIVED_SOURCES_DIR}/InspectorProtocolObjects.h "#include \"inspector/InspectorProtocolObjects.h\"")
endif ()


if (JavaScriptCore_INSTALL_NAME_DIR)
    set_target_properties(JavaScriptCore PROPERTIES
        INSTALL_NAME_DIR "${JavaScriptCore_INSTALL_NAME_DIR}"
    )
endif ()

# Used to substitute placeholders in Info.plist.
set(BUNDLE_VERSION "${MACOSX_FRAMEWORK_BUNDLE_VERSION}")
set(SHORT_VERSION_STRING "${MACOSX_FRAMEWORK_SHORT_VERSION_STRING}")
set(PRODUCT_NAME "JavaScriptCore")
set(PRODUCT_BUNDLE_IDENTIFIER "com.apple.JavaScriptCore")
set(PLATFORM_NAME "${WEBKIT_SDK_NAME}")

if (WEBKIT_SDK_IS_MACOS)
    set_target_properties(JavaScriptCore PROPERTIES
        MACOSX_FRAMEWORK_INFO_PLIST ${JAVASCRIPTCORE_DIR}/Info.plist)
endif ()

# iOS-family framework packaging (identity, versioning, Info.plist, and the
# private headers / module maps / sandbox profile the iOS framework ships).
if (WEBKIT_SDK_IS_IOS_FAMILY)
    set(MACOSX_FRAMEWORK_IDENTIFIER com.apple.JavaScriptCore)

    if (WTF_LIBRARY_TYPE STREQUAL "STATIC")
        target_link_options(JavaScriptCore PRIVATE
            "LINKER:-force_load,$<TARGET_FILE:WTF>"
        )
    endif ()

    # BrowserEngineCore provides the inline-JIT-permissions API (be_memory_*)
    # that threadSelfRestrict uses; weak-linked (iOS 17.4+).
    target_link_options(JavaScriptCore PRIVATE "LINKER:-weak_framework,BrowserEngineCore")

    target_compile_definitions(JavaScriptCore PRIVATE PAS_BMALLOC_HIDDEN=1)

    configure_file(${JAVASCRIPTCORE_DIR}/Info.plist ${CMAKE_CURRENT_BINARY_DIR}/JavaScriptCore-Info.plist)
    set(JavaScriptCore_POST_BUILD_COMMAND
        ${CMAKE_COMMAND} -E copy_if_different ${CMAKE_CURRENT_BINARY_DIR}/JavaScriptCore-Info.plist
            ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/JavaScriptCore.framework/Info.plist
    )

    # arm64e: MacroAssembler.h conditionally includes this via CPU(ARM64E).
    list(APPEND JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
        assembler/MacroAssemblerARM64E.h
        heap/GCSegmentedArrayInlines.h
    )

    # Build-system scripts that ship as private framework headers.
    list(APPEND JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
        Scripts/UpdateContents.py
        Scripts/cssmin.py
        Scripts/generate-combined-inspector-json.py
        Scripts/generate-js-builtins.py
        Scripts/inline-and-minify-stylesheets-and-scripts.py
        Scripts/jsmin.py
        Scripts/lazywriter.py
        Scripts/make-js-file-arrays.py
        Scripts/xxd.pl

        Scripts/wkbuiltins/builtins_generate_combined_header.py
        Scripts/wkbuiltins/builtins_generate_combined_implementation.py
        Scripts/wkbuiltins/builtins_generate_internals_wrapper_header.py
        Scripts/wkbuiltins/builtins_generate_internals_wrapper_implementation.py
        Scripts/wkbuiltins/builtins_generate_separate_header.py
        Scripts/wkbuiltins/builtins_generate_separate_implementation.py
        Scripts/wkbuiltins/builtins_generate_wrapper_header.py
        Scripts/wkbuiltins/builtins_generate_wrapper_implementation.py
        Scripts/wkbuiltins/builtins_generator.py
        Scripts/wkbuiltins/builtins_model.py
        Scripts/wkbuiltins/builtins_templates.py
        Scripts/wkbuiltins/wkbuiltins.py

        inspector/scripts/generate-inspector-protocol-bindings.py

        inspector/scripts/codegen/cpp_generator.py
        inspector/scripts/codegen/cpp_generator_templates.py
        inspector/scripts/codegen/generate_cpp_alternate_backend_dispatcher_header.py
        inspector/scripts/codegen/generate_cpp_backend_dispatcher_header.py
        inspector/scripts/codegen/generate_cpp_backend_dispatcher_implementation.py
        inspector/scripts/codegen/generate_cpp_frontend_dispatcher_header.py
        inspector/scripts/codegen/generate_cpp_frontend_dispatcher_implementation.py
        inspector/scripts/codegen/generate_cpp_protocol_types_header.py
        inspector/scripts/codegen/generate_cpp_protocol_types_implementation.py
        inspector/scripts/codegen/generate_js_backend_commands.py
        inspector/scripts/codegen/generate_objc_backend_dispatcher_header.py
        inspector/scripts/codegen/generate_objc_backend_dispatcher_implementation.py
        inspector/scripts/codegen/generate_objc_configuration_header.py
        inspector/scripts/codegen/generate_objc_configuration_implementation.py
        inspector/scripts/codegen/generate_objc_frontend_dispatcher_implementation.py
        inspector/scripts/codegen/generate_objc_header.py
        inspector/scripts/codegen/generate_objc_internal_header.py
        inspector/scripts/codegen/generate_objc_protocol_type_conversions_header.py
        inspector/scripts/codegen/generate_objc_protocol_type_conversions_implementation.py
        inspector/scripts/codegen/generate_objc_protocol_types_implementation.py
        inspector/scripts/codegen/generator.py
        inspector/scripts/codegen/generator_templates.py
        inspector/scripts/codegen/models.py
        inspector/scripts/codegen/objc_generator.py
        inspector/scripts/codegen/objc_generator_templates.py
    )

    file(MAKE_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/JavaScriptCore.framework")
    configure_file(${JAVASCRIPTCORE_DIR}/framework.sb ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/JavaScriptCore.framework/framework.sb COPYONLY)
    configure_file(${JAVASCRIPTCORE_DIR}/JavaScriptCore.modulemap ${CMAKE_BINARY_DIR}/JavaScriptCore/Modules/module.modulemap COPYONLY)
    configure_file("${JAVASCRIPTCORE_DIR}/JavaScriptCore_Private.modulemap" ${CMAKE_BINARY_DIR}/JavaScriptCore/Modules/module.private.modulemap COPYONLY)
elseif (WEBKIT_SDK_IS_MACOS)
    configure_file(${JAVASCRIPTCORE_DIR}/framework.sb ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/JavaScriptCore.framework/Versions/A/Resources/framework.sb COPYONLY)
endif ()

list(APPEND JavaScriptCore_PUBLIC_FRAMEWORK_HEADERS
    API/JSCallbackFunction.h
    API/JSContext.h
    API/JSContextPrivate.h
    API/JSContextRefPrivate.h
    API/JSExport.h
    API/JSManagedValue.h
    API/JSStringRefCF.h
    API/JSValue.h
    API/JSValuePrivate.h
    API/JSVirtualMachine.h
    API/JavaScriptCore.h
)

# Private headers the JavaScriptCore_Private module map needs to parse.
list(APPEND JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS
    API/MARReportCrashPrivate.h
    API/PASReportCrashPrivate.h
    API/WorkAround173516139.h

    assembler/MacroAssemblerPrinter.h

    debugger/DebuggerEvalEnabler.h

    disassembler/Disassembler.h

    heap/CodeBlockSet.h
    heap/ConservativeRoots.h
    heap/GCIncomingRefCountedSetInlines.h
    heap/HeapSnapshot.h
    heap/JITStubRoutineSet.h
    heap/VerifierSlotVisitorScope.h
    heap/WriteBarrierSupport.h

    inspector/augmentable/AlternateDispatchableAgent.h
    inspector/augmentable/AugmentableInspectorController.h

    jit/BinarySwitch.h
    jit/ExecutableAllocationFuzz.h
    jit/GdbJIT.h
    jit/JITExceptions.h
    jit/JSInterfaceJIT.h

    parser/ModuleScopeData.h

    runtime/PinballHandlerContext.h

    tools/JSDollarVM.h

    yarr/YarrJITRegisters.h
)

# Stage the module maps into the framework bundle so the Swift Clang importer
# finds JavaScriptCore / JavaScriptCore_Private as modules via -F. Otherwise
# <JavaScriptCore/*.h> is parsed textually and collides with other importers.
set(_jsc_modules_dir "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/JavaScriptCore.framework/${WEBKIT_FRAMEWORK_VERSION_PATH}Modules")
add_custom_command(
    OUTPUT "${_jsc_modules_dir}/module.modulemap"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_jsc_modules_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${JAVASCRIPTCORE_DIR}/JavaScriptCore.modulemap" "${_jsc_modules_dir}/module.modulemap"
    MAIN_DEPENDENCY "${JAVASCRIPTCORE_DIR}/JavaScriptCore.modulemap"
    VERBATIM)
add_custom_command(
    OUTPUT "${_jsc_modules_dir}/module.private.modulemap"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_jsc_modules_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${JAVASCRIPTCORE_DIR}/JavaScriptCore_Private.modulemap" "${_jsc_modules_dir}/module.private.modulemap"
    MAIN_DEPENDENCY "${JAVASCRIPTCORE_DIR}/JavaScriptCore_Private.modulemap"
    VERBATIM)
add_custom_target(JavaScriptCore_CopyModules ALL DEPENDS
    "${_jsc_modules_dir}/module.modulemap"
    "${_jsc_modules_dir}/module.private.modulemap")
add_dependencies(JavaScriptCore JavaScriptCore_CopyModules)

# WK_USE_SWIFT_BIGINT_DIGITS and WK_USE_SWIFT_JSON_PARSER are BaseTarget.xcconfig's settings of the same names, off by
# default as there. As in PlatformWin.cmake, each island's Swift imports only a header that includes only the standard
# library, so one command compiles it whole-module into an object JavaScriptCore links and writes the header its C++
# includes, with the Swift settings of libJavaScriptCore.xcconfig and JavaScriptCore.xcconfig.
option(WK_USE_SWIFT_BIGINT_DIGITS "Compile JSBigInt's digit arithmetic from Swift" OFF)
option(WK_USE_SWIFT_JSON_PARSER "Parse JSON with LiteralParser's Swift implementation" OFF)
if (WK_USE_SWIFT_BIGINT_DIGITS OR WK_USE_SWIFT_JSON_PARSER)
    set(_jsc_swift_flags)
    foreach (_flag IN LISTS WEBKIT_SWIFT_LANGUAGE_FLAGS WEBKIT_SWIFT_UPCOMING_FEATURE_FLAGS WEBKIT_SWIFT_CONCURRENCY_FLAGS
            WEBKIT_SWIFT_FATAL_DIAGNOSTIC_FLAGS WEBKIT_SWIFT_CLANG_IMPORTER_FLAGS WEBKIT_SWIFT_MACRO_FLAGS WEBKIT_SWIFT_DEBUG_INFO_FLAGS
            WEBKIT_SWIFT_EXPERIMENTAL_FEATURE_FLAGS WEBKIT_SWIFT_MEMORY_SAFETY_FLAGS WEBKIT_SWIFT_CXX_INTEROP_FLAGS)
        separate_arguments(_args UNIX_COMMAND "${_flag}")
        list(APPEND _jsc_swift_flags ${_args})
    endforeach ()
    list(APPEND _jsc_swift_flags
        -sdk "${CMAKE_OSX_SYSROOT}" -wmo "$<IF:$<CONFIG:Debug>,-Onone,-O>" -g
        -module-cache-path "${CMAKE_BINARY_DIR}/SwiftModuleCache"
        -Xcc -fexperimental-bounds-safety-attributes -Xcc -fexperimental-late-parse-attributes
        -Xcc -fno-exceptions -Xcc -fignore-exceptions -Xcc -O2 -Xllvm -enable-dfa-jump-thread
        -Xfrontend -clang-header-expose-decls=has-expose-attr-or-stdlib
        -Xfrontend -emit-clang-header-min-access -Xfrontend internal)
    if (CMAKE_Swift_COMPILER_TARGET)
        list(APPEND _jsc_swift_flags -target "${CMAKE_Swift_COMPILER_TARGET}")
    endif ()
    if (LTO_MODE)
        list(APPEND _jsc_swift_flags -Xfrontend -lto=llvm-${LTO_MODE} -Xfrontend -emit-bc)
    endif ()

    # <swiftToCxx/_SwiftCxxInteroperability.h>, which the generated headers include, and the Swift runtime libraries
    # the objects auto-link.
    string(JSON _jsc_swift_paths GET "${WEBKIT_SWIFT_TARGET_INFO}" "paths")
    string(JSON _jsc_swift_resource_path GET "${_jsc_swift_paths}" "runtimeResourcePath")
    string(JSON _jsc_swift_library_path GET "${_jsc_swift_paths}" "runtimeLibraryPaths" 0)
    target_include_directories(JavaScriptCore SYSTEM AFTER PRIVATE "${_jsc_swift_resource_path}")
    target_link_directories(JavaScriptCore PRIVATE "${_jsc_swift_library_path}")
endif ()

if (WK_USE_SWIFT_BIGINT_DIGITS)
    set(_jsc_swift_sources
        runtime/JSBigIntDigits.swift
        runtime/JSBigIntDigitsAddSub.swift
        runtime/JSBigIntDigitsDivide.swift
        runtime/JSBigIntDigitsFFT.swift
        runtime/JSBigIntDigitsMultiply.swift
        runtime/JSBigIntDigitsPrimitives.swift
    )
    list(TRANSFORM _jsc_swift_sources PREPEND "${JAVASCRIPTCORE_DIR}/")
    set(_jsc_swift_dir "${JavaScriptCore_DERIVED_SOURCES_DIR}/JSCSwift")
    set(_jsc_swift_obj "${_jsc_swift_dir}/JSCSwift.o")
    set(_jsc_swift_hdr "${JavaScriptCore_DERIVED_SOURCES_DIR}/JSCSwift-Swift.h")
    file(MAKE_DIRECTORY "${_jsc_swift_dir}")

    add_custom_command(
        OUTPUT "${_jsc_swift_obj}" "${_jsc_swift_hdr}"
        COMMAND "${ORIGINAL_Swift_COMPILER}" -module-name JSCSwift ${_jsc_swift_flags} -D USE_SWIFT_BIGINT_DIGITS
            -Xcc "-fmodule-map-file=${JAVASCRIPTCORE_DIR}/JSCSwiftBoundary.modulemap"
            -emit-clang-header-path "${_jsc_swift_hdr}"
            -c ${_jsc_swift_sources} -o "${_jsc_swift_obj}"
        DEPENDS ${_jsc_swift_sources} "${JAVASCRIPTCORE_DIR}/JSCSwiftBoundary.modulemap"
            "${JAVASCRIPTCORE_DIR}/runtime/JSBigIntSwiftDigits.h"
        COMMENT "Compiling JSCSwift"
        COMMAND_EXPAND_LISTS
        VERBATIM)
    add_custom_target(JSCSwift DEPENDS "${_jsc_swift_obj}" "${_jsc_swift_hdr}")

    list(APPEND JavaScriptCore_SOURCES "${_jsc_swift_obj}")
    set_source_files_properties("${_jsc_swift_obj}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
    # JSBigInt.cpp, in a unified source, includes the generated header.
    list(APPEND JavaScriptCore_DEPENDENCIES JSCSwift)
    # JSBigInt.h declares its digit helpers only when this is 0, so every JavaScriptCore translation unit gets it.
    add_compile_definitions(USE_SWIFT_BIGINT_DIGITS=1)
endif ()

if (WK_USE_SWIFT_JSON_PARSER)
    set(_jsc_swift_dir "${JavaScriptCore_DERIVED_SOURCES_DIR}/LiteralParserSwift")
    set(_jsc_swift_obj "${_jsc_swift_dir}/LiteralParserSwift.o")
    set(_jsc_swift_hdr "${JavaScriptCore_DERIVED_SOURCES_DIR}/JavaScriptCore-Swift.h")
    file(MAKE_DIRECTORY "${_jsc_swift_dir}")
    # JavaScriptCore_Private.modulemap's LiteralParserSwiftTypes, the one submodule the Swift imports.
    file(WRITE "${_jsc_swift_dir}/module.modulemap"
        "module JavaScriptCore_Private {\n"
        "    explicit module LiteralParserSwiftTypes {\n"
        "        header \"${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwiftTypes.h\"\n"
        "        requires cplusplus\n"
        "        export *\n"
        "    }\n"
        "}\n")

    add_custom_command(
        OUTPUT "${_jsc_swift_obj}" "${_jsc_swift_hdr}"
        COMMAND "${ORIGINAL_Swift_COMPILER}" -module-name JavaScriptCore -parse-as-library ${_jsc_swift_flags}
            -D USE_SWIFT_JSON_PARSER -Werror SendableClosureCaptures -Xcc "-I${_jsc_swift_dir}"
            -emit-clang-header-path "${_jsc_swift_hdr}"
            -c "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwift.swift" -o "${_jsc_swift_obj}"
        DEPENDS "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwift.swift" "${JAVASCRIPTCORE_DIR}/runtime/LiteralParserSwiftTypes.h"
        COMMENT "Compiling LiteralParserSwift.swift"
        COMMAND_EXPAND_LISTS
        VERBATIM)

    list(APPEND JavaScriptCore_SOURCES runtime/LiteralParserSwiftFacade.cpp "${_jsc_swift_obj}")
    set_source_files_properties("${_jsc_swift_obj}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
    set_source_files_properties(runtime/LiteralParserSwiftFacade.cpp PROPERTIES OBJECT_DEPENDS "${_jsc_swift_hdr}")
    # Every C++ translation unit that includes LiteralParser.h must agree on the class it declares.
    add_compile_definitions(USE_SWIFT_JSON_PARSER=1)
endif ()
