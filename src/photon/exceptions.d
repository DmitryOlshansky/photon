module photon.exceptions;

import photon.task;

class ChannelClosed : Exception
{
    this(string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super("Put on the closed channel", file, line, nextInChain);
    }
}

package(photon) __gshared PhotonErrorHandler errorHandler;

/// Photon exception handler type
alias PhotonErrorHandler = void delegate(Throwable, Task) nothrow;

/// Set photon exception handler
void photonErrorHandler(PhotonErrorHandler handler) {
    errorHandler = handler;
}
