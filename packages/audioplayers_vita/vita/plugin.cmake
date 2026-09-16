list(APPEND PLUGIN_SOURCES ${CMAKE_CURRENT_LIST_DIR}/audioplayers.c)
list(APPEND PLUGIN_LIBS SceAudio_stub SceAvPlayer_stub SceSysmodule_stub SceAppMgr_stub)
