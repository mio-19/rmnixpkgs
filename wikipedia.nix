# Native Qt Quick offline Wikipedia reader linked to libzim for reMarkable Paper Pro
# Base QML concept from https://github.com/dps/remarkable-wikipedia (MIT)
# Copyright (c) 2019 David Singleton
# Integrated libzim C++ QObject backend eliminating kiwix-serve HTTP daemon.

{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  qt6,
  libzim,
}:
stdenv.mkDerivation {
  pname = "rmpp-wikipedia";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./CMakeLists-wikipedia.txt
      ./wikipedia-backend.h
      ./wikipedia-backend.cpp
      ./wikipedia-main.cpp
      ./WikipediaMain.qml
      ./WikipediaKeyboard.qml
      ./WikipediaKeyboardKey.qml
      ./WikipediaButton.qml
      ./WikipediaSwipeArea.qml
      ./wikipedia.qrc
    ];
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtdeclarative
    libzim
  ];

  preConfigure = ''
    cp CMakeLists-wikipedia.txt CMakeLists.txt
  '';

  meta = {
    description = "Native Qt Quick offline Wikipedia reader linked to libzim for reMarkable Paper Pro";
    homepage = "https://github.com/dps/remarkable-wikipedia";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
