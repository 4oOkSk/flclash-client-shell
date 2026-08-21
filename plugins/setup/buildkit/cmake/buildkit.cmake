# buildkit.cmake — Build Go core as part of the native Linux/Windows build
#
# Include this from a plugin's CMakeLists.txt and call:
#   apply_buildkit()
#
# This adds a custom command that runs build_tool before the native target is linked.

# Resolve at include-time so CMAKE_CURRENT_LIST_DIR is this file's directory
get_filename_component(BUILDKIT_DIR "${CMAKE_CURRENT_LIST_DIR}" DIRECTORY)

function(apply_buildkit)
  if(WIN32)
    set(_launcher "${BUILDKIT_DIR}/run_build_tool.cmd")
  else()
    set(_launcher "${BUILDKIT_DIR}/run_build_tool.sh")
  endif()

  # Project root is one level up from CMAKE_SOURCE_DIR (the top-level CMakeLists.txt
  # lives in linux/ or windows/, so project root is the parent).
  get_filename_component(PROJECT_ROOT "${CMAKE_SOURCE_DIR}" DIRECTORY)

  # The output files the build_tool produces
  if(WIN32)
    set(_output "${PROJECT_ROOT}/libclash/windows/HarborProxyCore.exe")
    set(_platform_args "windows")
  else()
    set(_output "${PROJECT_ROOT}/libclash/linux/HarborProxyCore")
    set(_platform_args "linux")
  endif()

  # The generated core binary is checked into the working tree, so merely
  # declaring it as an OUTPUT lets CMake reuse a stale binary forever. Track
  # the Go module and build-tool inputs explicitly so client/core changes are
  # always present in the package being assembled.
  file(GLOB_RECURSE _core_sources CONFIGURE_DEPENDS
    "${PROJECT_ROOT}/core/*.go"
  )
  file(GLOB_RECURSE _build_tool_sources CONFIGURE_DEPENDS
    "${BUILDKIT_DIR}/build_tool/*.dart"
    "${BUILDKIT_DIR}/build_tool/*.yaml"
  )
  list(APPEND _core_sources
    "${PROJECT_ROOT}/core/go.mod"
    "${PROJECT_ROOT}/core/go.sum"
  )

  set(BUILDKIT_ENV
    "BUILDKIT_CONFIGURATION=$<CONFIG>"
    "PROJECT_DIR=${PROJECT_ROOT}"
  )

  add_custom_command(
    OUTPUT ${_output}
    COMMAND ${CMAKE_COMMAND} -E env ${BUILDKIT_ENV}
    "${_launcher}" ${_platform_args}
    DEPENDS ${_core_sources} ${_build_tool_sources} "${_launcher}"
    WORKING_DIRECTORY "${PROJECT_ROOT}"
    COMMENT "Building Go core via buildkit..."
    VERBATIM
  )

  add_custom_target(setup_buildkit_build DEPENDS ${_output})
endfunction()
