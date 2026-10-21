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
  "media_session.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Системный оверлей Windows (SMTC) написан на C++/WinRT. Заголовки лежат в
# Windows SDK отдельной папкой `cppwinrt`, и CMake её не подключает: ищем
# сами. $ENV{} не умеет скобки в имени, поэтому Program Files (x86) указан
# буквально — это обычное место установки SDK.
file(GLOB MOPS_CPPWINRT_HEADERS
  "C:/Program Files (x86)/Windows Kits/10/Include/*/cppwinrt/winrt/base.h"
  "C:/Program Files/Windows Kits/10/Include/*/cppwinrt/winrt/base.h")
if(MOPS_CPPWINRT_HEADERS)
  # Сортировка по имени версии: последняя — самая свежая.
  list(SORT MOPS_CPPWINRT_HEADERS)
  list(GET MOPS_CPPWINRT_HEADERS -1 MOPS_CPPWINRT_BASE_H)
  get_filename_component(_mops_winrt_dir "${MOPS_CPPWINRT_BASE_H}" DIRECTORY)
  get_filename_component(MOPS_CPPWINRT_INCLUDE "${_mops_winrt_dir}" DIRECTORY)
  target_include_directories(${BINARY_NAME} PRIVATE "${MOPS_CPPWINRT_INCLUDE}")
  target_compile_definitions(${BINARY_NAME} PRIVATE "MOPS_HAS_SMTC")
  # C++/WinRT зовёт Windows Runtime через этот умбрелла-импорт.
  target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
  message(STATUS "SMTC: C++/WinRT из ${MOPS_CPPWINRT_INCLUDE}")
else()
  # Медиаклавиши (WM_APPCOMMAND) от оверлея не зависят: без заголовков
  # собираем окно как раньше, только без карточки в системе.
  message(WARNING "C++/WinRT не найден в Windows SDK — сборка без SMTC")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
