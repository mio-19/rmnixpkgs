# Native Qt Quick offline Wikipedia reader linked to libzim for reMarkable Paper Pro
# Upstream source: https://github.com/dps/remarkable-wikipedia (MIT)
# Copyright (c) 2019 David Singleton
# Integrated libzim C++ QObject backend eliminating kiwix-serve HTTP daemon.

{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  qt6,
  libzim,
}:
stdenv.mkDerivation {
  pname = "rmpp-wikipedia";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "dps";
    repo = "remarkable-wikipedia";
    rev = "7c48ade8fe485fdf1799fb641523148023963baa";
    hash = "sha256-IXYmzBS1gFZlTwS9TURWXFpCoWflHS0LLW5sEWElgXE=";
  };

  patches = [
    ./0001-use-libzim-backend.patch
  ];

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
    cp ${./wikipedia-backend.h} wikipedia-backend.h
    cp ${./wikipedia-backend.cpp} wikipedia-backend.cpp
    cp ${./CMakeLists.txt} CMakeLists.txt
  '';

  meta = {
    description = "Native Qt Quick offline Wikipedia reader linked to libzim for reMarkable Paper Pro";
    homepage = "https://github.com/dps/remarkable-wikipedia";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
