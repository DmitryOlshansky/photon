module photon.support;

version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;

version(linux) public import photon.linux.support;
else version(FreeBSD) public import photon.freebsd.support;
else version(Darwin) public import photon.macos.support;
else version(Windows) public import photon.windows.support;
