module photon.windows.support;
version(Windows):
import core.sys.windows.core;
import core.sys.windows.winsock2;
import std.format;

struct WSABUF
{
    uint length;
    void* buf;
}

extern(Windows) SOCKET WSASocketW(
  int                af,
  int                type,
  int                protocol,
  void*              lpProtocolInfo,
  WORD               g,
  DWORD              dwFlags
);

// hackish, we do not use LPCONDITIONPROC
alias LPCONDITIONPROC = void*;
alias LPWSABUF = WSABUF*;

extern(Windows) SOCKET WSAAccept(
  SOCKET          s,
  sockaddr        *addr,
  LPINT           addrlen,
  LPCONDITIONPROC lpfnCondition,
  DWORD_PTR       dwCallbackData
);

extern(Windows) int WSARecv(
  SOCKET                             s,
  LPWSABUF                           lpBuffers,
  DWORD                              dwBufferCount,
  LPDWORD                            lpNumberOfBytesRecvd,
  LPDWORD                            lpFlags,
  LPWSAOVERLAPPED                    lpOverlapped,
  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
);

extern(Windows) int WSASend(
  SOCKET                             s,
  LPWSABUF                           lpBuffers,
  DWORD                              dwBufferCount,
  LPDWORD                            lpNumberOfBytesSent,
  DWORD                              dwFlags,
  LPWSAOVERLAPPED                    lpOverlapped,
  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
);

struct OVERLAPPED_ENTRY {
  ULONG_PTR    lpCompletionKey;
  LPOVERLAPPED lpOverlapped;
  ULONG_PTR    Internal;
  DWORD        dwNumberOfBytesTransferred;
}

alias LPOVERLAPPED_ENTRY = OVERLAPPED_ENTRY*;

extern(Windows) BOOL GetQueuedCompletionStatusEx(
  HANDLE             CompletionPort,
  LPOVERLAPPED_ENTRY lpCompletionPortEntries,
  ULONG              ulCount,
  PULONG             ulNumEntriesRemoved,
  DWORD              dwMilliseconds,
  BOOL               fAlertable
);

enum WSA_FLAG_OVERLAPPED  =  0x01;

struct TP_POOL;

alias PTP_POOL = TP_POOL*;

extern(Windows) PTP_POOL CreateThreadpool(
  PVOID reserved
);

extern(Windows) void SetThreadpoolThreadMaximum(
  PTP_POOL ptpp,
  DWORD    cthrdMost
);

extern(Windows) BOOL SetThreadpoolThreadMinimum(
  PTP_POOL ptpp,
  DWORD    cthrdMic
);

alias TP_VERSION = DWORD;
alias PTP_VERSION = TP_VERSION*;

struct TP_CALLBACK_INSTANCE;
alias PTP_CALLBACK_INSTANCE = TP_CALLBACK_INSTANCE*;

alias PTP_SIMPLE_CALLBACK = extern(Windows) VOID function(PTP_CALLBACK_INSTANCE, PVOID);

enum TP_CALLBACK_PRIORITY : int {
  TP_CALLBACK_PRIORITY_HIGH,
  TP_CALLBACK_PRIORITY_NORMAL,
  TP_CALLBACK_PRIORITY_LOW,
  TP_CALLBACK_PRIORITY_INVALID,
  TP_CALLBACK_PRIORITY_COUNT = TP_CALLBACK_PRIORITY_INVALID
}

struct TP_POOL_STACK_INFORMATION {
  SIZE_T StackReserve;
  SIZE_T StackCommit;
}
alias PTP_POOL_STACK_INFORMATION = TP_POOL_STACK_INFORMATION*;

struct TP_CLEANUP_GROUP;
alias PTP_CLEANUP_GROUP = TP_CLEANUP_GROUP*;

alias PTP_CLEANUP_GROUP_CANCEL_CALLBACK = extern(Windows) VOID function(PVOID, PVOID);

struct ACTIVATION_CONTEXT;

struct TP_CALLBACK_ENVIRON_V3 {
  TP_VERSION Version;
  PTP_POOL Pool;
  PTP_CLEANUP_GROUP CleanupGroup;
  PTP_CLEANUP_GROUP_CANCEL_CALLBACK CleanupGroupCancelCallback;
  PVOID RaceDll;
  ACTIVATION_CONTEXT* ActivationContext;
  PTP_SIMPLE_CALLBACK FinalizationCallback;
  DWORD Flags;
  TP_CALLBACK_PRIORITY CallbackPriority;
  DWORD Size;
}

alias TP_CALLBACK_ENVIRON = TP_CALLBACK_ENVIRON_V3;
alias PTP_CALLBACK_ENVIRON = TP_CALLBACK_ENVIRON*;

VOID InitializeThreadpoolEnvironment(PTP_CALLBACK_ENVIRON cbe) {
  cbe.Pool = NULL;
  cbe.CleanupGroup = NULL;
  cbe.CleanupGroupCancelCallback = NULL;
  cbe.RaceDll = NULL;
  cbe.ActivationContext = NULL;
  cbe.FinalizationCallback = NULL;
  cbe.Flags = 0;
  cbe.Version = 3;
  cbe.CallbackPriority = TP_CALLBACK_PRIORITY.TP_CALLBACK_PRIORITY_NORMAL;
  cbe.Size = TP_CALLBACK_ENVIRON.sizeof;
}

extern(Windows) void CloseThreadpool(
  PTP_POOL ptpp
);

// inline "function"
VOID SetThreadpoolCallbackPool(PTP_CALLBACK_ENVIRON cbe, PTP_POOL pool) { cbe.Pool = pool; }

struct TP_WORK;
alias PTP_WORK = TP_WORK*;

struct TP_WAIT;
alias PTP_WAIT = TP_WAIT*;

struct TP_TIMER;
alias PTP_TIMER = TP_TIMER*;

alias TP_WAIT_RESULT = DWORD;

alias PTP_WORK_CALLBACK = extern(Windows) VOID function (PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WORK Work);
alias PTP_WAIT_CALLBACK = extern(Windows) VOID function (PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT Wait, TP_WAIT_RESULT WaitResult);
alias PTP_TIMER_CALLBACK = extern(Windows) VOID function(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_TIMER Timer);

extern(Windows) PTP_WORK CreateThreadpoolWork(
  PTP_WORK_CALLBACK    pfnwk,
  PVOID                pv,
  PTP_CALLBACK_ENVIRON pcbe
);

extern(Windows) PTP_WAIT CreateThreadpoolWait(PTP_WAIT_CALLBACK pfnwa, PVOID pv, PTP_CALLBACK_ENVIRON pcbe);

extern(Windows) void SubmitThreadpoolWork(
  PTP_WORK pwk
);

extern(Windows) void CloseThreadpoolWork(
  PTP_WORK pwk
);

extern(Windows) void SetThreadpoolWait(
  PTP_WAIT  pwa,
  HANDLE    h,
  PFILETIME pftTimeout
);

extern(Windows) void CloseThreadpoolWait(
  PTP_WAIT pwa
);

extern(Windows) PTP_TIMER CreateThreadpoolTimer(
  PTP_TIMER_CALLBACK   pfnti,
  PVOID                pv,
  PTP_CALLBACK_ENVIRON pcbe
);

extern(Windows) void SetThreadpoolTimer(
  PTP_TIMER pti,
  PFILETIME pftDueTime,
  DWORD     msPeriod,
  DWORD     msWindowLength
);

extern(Windows) void CloseThreadpoolTimer(
  PTP_TIMER pti
);


void outputToConsole(const(wchar)[] msg)
{
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    uint size = cast(uint)msg.length;
    WriteConsole(output, msg.ptr, size, &size, null);
}

void logf(T...)(const(wchar)[] fmt, T args)
{
    debug(photon) try {
        formattedWrite(&outputToConsole, fmt, args);
        formattedWrite(&outputToConsole, "\n");
    }
    catch (Exception e) {
        outputToConsole("ARGH!"w);
    }
}

