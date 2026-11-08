cmake_minimum_required(VERSION 3.16)
project(rmpp-wikipedia LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBZIM REQUIRED IMPORTED_TARGET libzim)

add_executable(rmpp-wikipedia
    main.cpp
    wikipedia-backend.cpp
    qml.qrc
)

target_link_libraries(rmpp-wikipedia PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::DBus
    PkgConfig::LIBZIM
)

install(TARGETS rmpp-wikipedia DESTINATION bin)
