cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Let the linker generate the single UAC fragment. Declaring the execution
# level in runner.exe.manifest as well would conflict with link.exe's default
# asInvoker fragment when mt.exe merges the manifests.
target_link_options(${BINARY_NAME} PRIVATE
  "/MANIFESTUAC:level='requireAdministrator' uiAccess='false'")

# Add preprocessor definitions for the build version.
if(NOT "${FLUTTER_VERSION_BUILD}" MATCHES "^([0-9][0-9][0-9][0-9])([0-9][0-9])([0-9][0-9])([0-9][0-9])$")
  message(FATAL_ERROR
    "HarborProxy build number must use YYYYMMDDNN; got '${FLUTTER_VERSION_BUILD}'")
endif()
set(HARBORPROXY_VERSION_YEAR "${CMAKE_MATCH_1}")
set(HARBORPROXY_VERSION_MONTH "${CMAKE_MATCH_2}")
set(HARBORPROXY_VERSION_DAY "${CMAKE_MATCH_3}")
set(HARBORPROXY_VERSION_ORDINAL "${CMAKE_MATCH_4}")
foreach(component YEAR MONTH DAY ORDINAL)
  string(REGEX REPLACE "^0+" "" HARBORPROXY_VERSION_${component}
    "${HARBORPROXY_VERSION_${component}}")
  if(HARBORPROXY_VERSION_${component} STREQUAL "")
    set(HARBORPROXY_VERSION_${component} 0)
  endif()
endforeach()
if(HARBORPROXY_VERSION_YEAR LESS 2000 OR HARBORPROXY_VERSION_YEAR GREATER 9999 OR
   HARBORPROXY_VERSION_MONTH LESS 1 OR HARBORPROXY_VERSION_MONTH GREATER 12 OR
   HARBORPROXY_VERSION_ORDINAL LESS 1 OR HARBORPROXY_VERSION_ORDINAL GREATER 99)
  message(FATAL_ERROR
    "HarborProxy build number has an invalid calendar date or ordinal: '${FLUTTER_VERSION_BUILD}'")
endif()
set(HARBORPROXY_VERSION_MAX_DAY 31)
if(HARBORPROXY_VERSION_MONTH EQUAL 4 OR HARBORPROXY_VERSION_MONTH EQUAL 6 OR
   HARBORPROXY_VERSION_MONTH EQUAL 9 OR HARBORPROXY_VERSION_MONTH EQUAL 11)
  set(HARBORPROXY_VERSION_MAX_DAY 30)
elseif(HARBORPROXY_VERSION_MONTH EQUAL 2)
  math(EXPR HARBORPROXY_VERSION_MOD_400 "${HARBORPROXY_VERSION_YEAR} % 400")
  math(EXPR HARBORPROXY_VERSION_MOD_100 "${HARBORPROXY_VERSION_YEAR} % 100")
  math(EXPR HARBORPROXY_VERSION_MOD_4 "${HARBORPROXY_VERSION_YEAR} % 4")
  if(HARBORPROXY_VERSION_MOD_400 EQUAL 0 OR
     (HARBORPROXY_VERSION_MOD_4 EQUAL 0 AND NOT HARBORPROXY_VERSION_MOD_100 EQUAL 0))
    set(HARBORPROXY_VERSION_MAX_DAY 29)
  else()
    set(HARBORPROXY_VERSION_MAX_DAY 28)
  endif()
endif()
if(HARBORPROXY_VERSION_DAY LESS 1 OR
   HARBORPROXY_VERSION_DAY GREATER HARBORPROXY_VERSION_MAX_DAY)
  message(FATAL_ERROR
    "HarborProxy build number has an invalid calendar date: '${FLUTTER_VERSION_BUILD}'")
endif()
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_compile_definitions(${BINARY_NAME} PRIVATE
  "HARBORPROXY_VERSION_YEAR=${HARBORPROXY_VERSION_YEAR}"
  "HARBORPROXY_VERSION_MONTH=${HARBORPROXY_VERSION_MONTH}"
  "HARBORPROXY_VERSION_DAY=${HARBORPROXY_VERSION_DAY}"
  "HARBORPROXY_VERSION_ORDINAL=${HARBORPROXY_VERSION_ORDINAL}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
