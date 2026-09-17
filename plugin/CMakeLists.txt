# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# kwin-canvas-passthrough: a binary KWin plugin that lets pointer input reach
# the real windows while the canvas is in pan mode. Optional; the QML effect
# works without it. Built against the installed KWin and loaded only by that
# exact KWin version (KWin's own plugin interface carries the version).
cmake_minimum_required(VERSION 3.20)
project(kwin-canvas-passthrough LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
# Qt's versionless macros need this before any Qt config is loaded.
set(QT_DEFAULT_MAJOR_VERSION 6)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
# Plugins land in build/plugin/bin/kwin/plugins, a Qt plugin path for the nest.
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets DBus Qml Quick)
find_package(KF6CoreAddons REQUIRED)
find_package(KWin REQUIRED)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" CANVAS_VERSION)
string(STRIP "${CANVAS_VERSION}" CANVAS_VERSION)

kcoreaddons_add_plugin(kwin_canvas_passthrough INSTALL_NAMESPACE "kwin/plugins")
target_sources(kwin_canvas_passthrough PRIVATE main.cpp passthrough.cpp)
target_compile_definitions(kwin_canvas_passthrough PRIVATE CANVAS_VERSION="${CANVAS_VERSION}")
target_link_libraries(kwin_canvas_passthrough PRIVATE KWin::kwin KF6::CoreAddons Qt6::Core Qt6::Gui Qt6::DBus)
