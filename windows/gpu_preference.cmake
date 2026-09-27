# desktop_multi_window 0.3.0 creates engines before its public callback fires.
# Compile an adapted copy of that one source file so detached windows use the
# same GPU selection and fallback as the main window. Never edit the Pub cache.
set(TAL_MULTI_WINDOW_TARGET desktop_multi_window_plugin)
get_target_property(TAL_MULTI_WINDOW_DIR ${TAL_MULTI_WINDOW_TARGET} SOURCE_DIR)
set(TAL_MULTI_WINDOW_SOURCE "${TAL_MULTI_WINDOW_DIR}/flutter_window.cc")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${TAL_MULTI_WINDOW_SOURCE}")
file(READ "${TAL_MULTI_WINDOW_SOURCE}" TAL_MULTI_WINDOW_CONTENT)
set(TAL_CONTROLLER_CREATION
  "std::make_unique<flutter::FlutterViewController>(")
set(TAL_CONTROLLER_CHECK
  "!flutter_controller_->engine() || !flutter_controller_->view()")
foreach(EXPECTED IN ITEMS TAL_CONTROLLER_CREATION TAL_CONTROLLER_CHECK)
  string(FIND "${TAL_MULTI_WINDOW_CONTENT}" "${${EXPECTED}}" MATCH_POSITION)
  if(MATCH_POSITION EQUAL -1)
    message(FATAL_ERROR
      "desktop_multi_window changed; update windows/gpu_preference.cmake before building.")
  endif()
endforeach()
string(REPLACE "${TAL_CONTROLLER_CREATION}" "tal::CreateFlutterController("
  TAL_MULTI_WINDOW_CONTENT "${TAL_MULTI_WINDOW_CONTENT}")
string(REPLACE "${TAL_CONTROLLER_CHECK}" "!flutter_controller_"
  TAL_MULTI_WINDOW_CONTENT "${TAL_MULTI_WINDOW_CONTENT}")
set(TAL_GENERATED_GPU_DIR "${CMAKE_CURRENT_BINARY_DIR}/gpu_preference")
file(MAKE_DIRECTORY "${TAL_GENERATED_GPU_DIR}")
set(TAL_GENERATED_WINDOW "${TAL_GENERATED_GPU_DIR}/flutter_window.cc")
file(WRITE "${TAL_GENERATED_WINDOW}"
  "#include \"gpu_preference.h\"\n${TAL_MULTI_WINDOW_CONTENT}")
get_target_property(TAL_MULTI_WINDOW_SOURCES ${TAL_MULTI_WINDOW_TARGET} SOURCES)
list(REMOVE_ITEM TAL_MULTI_WINDOW_SOURCES "flutter_window.cc"
  "${TAL_MULTI_WINDOW_SOURCE}")
set_property(TARGET ${TAL_MULTI_WINDOW_TARGET} PROPERTY SOURCES
  ${TAL_MULTI_WINDOW_SOURCES} "${TAL_GENERATED_WINDOW}")
target_include_directories(${TAL_MULTI_WINDOW_TARGET} PRIVATE
  "${TAL_MULTI_WINDOW_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/runner")
