module photon.core;

version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;

// TODO: time to factor out common parts of schedulers?
version(linux) public import photon.reactor;
else version(FreeBSD) public import photon.freebsd.core;
else version(Darwin) public import photon.reactor;
else version(Windows) public import photon.windows.core;
