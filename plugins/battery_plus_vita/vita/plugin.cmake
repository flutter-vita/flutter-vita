# The C half of battery_plus_vita; tools/build-vita-app.sh includes this
# file into the app's template (templates/vita-app/CMakeLists.txt).
list(APPEND PLUGIN_SOURCES ${CMAKE_CURRENT_LIST_DIR}/battery.c)
list(APPEND PLUGIN_LIBS ScePower_stub)
