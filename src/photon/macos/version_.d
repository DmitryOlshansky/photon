module photon.macos.version_;


version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;
