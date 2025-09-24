module photon.windows.support;
version(Windows):
import core.sys.windows.core;
import core.sys.windows.winsock2;
import std.format;
import core.stdc.stdlib;

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
  DWORD              g,
  DWORD              dwFlags
) nothrow;

// hackish, we do not use LPCONDITIONPROC
alias LPCONDITIONPROC = void*;
alias LPWSABUF = WSABUF*;

extern(Windows) SOCKET WSAAccept(
  SOCKET          s,
  sockaddr        *addr,
  LPINT           addrlen,
  LPCONDITIONPROC lpfnCondition,
  DWORD_PTR       dwCallbackData
) nothrow;

extern(Windows) int WSARecv(
  SOCKET                             s,
  LPWSABUF                           lpBuffers,
  DWORD                              dwBufferCount,
  LPDWORD                            lpNumberOfBytesRecvd,
  LPDWORD                            lpFlags,
  LPWSAOVERLAPPED                    lpOverlapped,
  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
) nothrow;

extern(Windows) int WSASend(
  SOCKET                             s,
  LPWSABUF                           lpBuffers,
  DWORD                              dwBufferCount,
  LPDWORD                            lpNumberOfBytesSent,
  DWORD                              dwFlags,
  LPWSAOVERLAPPED                    lpOverlapped,
  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
) nothrow;

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
) nothrow;

enum WSA_FLAG_OVERLAPPED  =  0x01;

struct TP_POOL;

alias PTP_POOL = TP_POOL*;

extern(Windows) PTP_POOL CreateThreadpool(
  PVOID reserved
) nothrow;

extern(Windows) void SetThreadpoolThreadMaximum(
  PTP_POOL ptpp,
  DWORD    cthrdMost
) nothrow;

extern(Windows) BOOL SetThreadpoolThreadMinimum(
  PTP_POOL ptpp,
  DWORD    cthrdMic
) nothrow;

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

VOID InitializeThreadpoolEnvironment(PTP_CALLBACK_ENVIRON cbe) nothrow {
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
) nothrow;

// inline "function"
VOID SetThreadpoolCallbackPool(PTP_CALLBACK_ENVIRON cbe, PTP_POOL pool) nothrow { cbe.Pool = pool; }

struct TP_WORK;
alias PTP_WORK = TP_WORK*;

struct TP_WAIT;
alias PTP_WAIT = TP_WAIT*;

struct TP_TIMER;
alias PTP_TIMER = TP_TIMER*;

alias TP_WAIT_RESULT = DWORD;

alias PTP_WORK_CALLBACK = extern(Windows) VOID function (PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WORK Work);
alias PTP_WAIT_CALLBACK = extern(Windows) VOID function (PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT  Wait, TP_WAIT_RESULT WaitResult);
alias PTP_TIMER_CALLBACK = extern(Windows) VOID function(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_TIMER Timer);

extern(Windows) PTP_WORK CreateThreadpoolWork(
  PTP_WORK_CALLBACK    pfnwk,
  PVOID                pv,
  PTP_CALLBACK_ENVIRON pcbe
) nothrow;

extern(Windows) PTP_WAIT CreateThreadpoolWait(PTP_WAIT_CALLBACK pfnwa, PVOID pv, PTP_CALLBACK_ENVIRON pcbe) nothrow;

extern(Windows) void SubmitThreadpoolWork(
  PTP_WORK pwk
) nothrow;

extern(Windows) void CloseThreadpoolWork(
  PTP_WORK pwk
) nothrow;

extern(Windows) void SetThreadpoolWait(
  PTP_WAIT  pwa,
  HANDLE    h,
  PFILETIME pftTimeout
) nothrow;

extern(Windows) void CloseThreadpoolWait(
  PTP_WAIT pwa
) nothrow;

extern(Windows) PTP_TIMER CreateThreadpoolTimer(
  PTP_TIMER_CALLBACK   pfnti,
  PVOID                pv,
  PTP_CALLBACK_ENVIRON pcbe
) nothrow;

extern(Windows) void SetThreadpoolTimer(
  PTP_TIMER pti,
  PFILETIME pftDueTime,
  DWORD     msPeriod,
  DWORD     msWindowLength
) nothrow;

extern(Windows) void CloseThreadpoolTimer(
  PTP_TIMER pti
) nothrow;


void outputToConsole(const(wchar)[] msg) nothrow
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

void checked(bool arg, string msg) nothrow {
  if (!arg) {
      try {
          formattedWrite(&outputToConsole, msg);
          formattedWrite(&outputToConsole, "\n");
      } catch (Throwable t) {}
      abort();
  }
}

enum WSA_FLAG_REGISTERED_IO = 256;

enum IOC_OUT = 0x40000000;
enum IOC_IN =  0x80000000;
enum IOC_INOUT = (IOC_IN|IOC_OUT);
enum IOC_WS2 = 0x08000000;
               
ULONG _WSAIORW(ULONG x, ULONG y) => (IOC_INOUT|(x)|(y));
struct GUID {
    uint  Data1;
    ushort Data2;
    ushort Data3;
    ubyte[8] Data4;
}
static assert (GUID.sizeof == 16);

enum SIO_GET_EXTENSION_FUNCTION_POINTER  = _WSAIORW(IOC_WS2,6);
enum SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER = _WSAIORW(IOC_WS2, 36);
/* 8509e081-96dd-4005-b165-9e2ee8c79e3f */ 
enum WSAID_MULTIPLE_RIO = GUID(0x8509e081,0x96dd,0x4005,[0xb1,0x65,0x9e,0x2e,0xe8,0xc7,0x9e,0x3f]);
    

struct RIO_EXTENSION_FUNCTION_TABLE {
  DWORD                         cbSize;
  LPFN_RIORECEIVE               RIOReceive;
  LPFN_RIORECEIVEEX             RIOReceiveEx;
  LPFN_RIOSEND                  RIOSend;
  LPFN_RIOSENDEX                RIOSendEx;
  LPFN_RIOCLOSECOMPLETIONQUEUE  RIOCloseCompletionQueue;
  LPFN_RIOCREATECOMPLETIONQUEUE RIOCreateCompletionQueue;
  LPFN_RIOCREATEREQUESTQUEUE    RIOCreateRequestQueue;
  LPFN_RIODEQUEUECOMPLETION     RIODequeueCompletion;
  LPFN_RIODEREGISTERBUFFER      RIODeregisterBuffer;
  LPFN_RIONOTIFY                RIONotify;
  LPFN_RIOREGISTERBUFFER        RIORegisterBuffer;
  LPFN_RIORESIZECOMPLETIONQUEUE RIOResizeCompletionQueue;
  LPFN_RIORESIZEREQUESTQUEUE    RIOResizeRequestQueue;
}

struct RIO_BUFFERID_t;
alias RIO_BUFFERID = RIO_BUFFERID_t*;

struct RIO_RQ_t; 
alias RIO_RQ = RIO_RQ_t*;

struct RIO_CQ_t; 
alias RIO_CQ = RIO_CQ_t*;

struct RIO_BUF {
  RIO_BUFFERID BufferId;
  ULONG        Offset;
  ULONG        Length;
}

struct RIORESULT {
  LONG      Status;
  ULONG     BytesTransferred;
  ULONGLONG SocketContext;
  ULONGLONG RequestContext;
}

alias PRIORESULT = RIORESULT*;

alias PRIO_BUF = RIO_BUF*;

alias PRIO_EXTENSION_FUNCTION_TABLE = RIO_EXTENSION_FUNCTION_TABLE*;

alias LPFN_RIORECEIVE = BOOL function(
  RIO_RQ SocketQueue,
  PRIO_BUF pData,
  ULONG DataBufferCount,
  DWORD Flags,
  PVOID RequestContext
);

alias LPFN_RIORECEIVEEX = int function(
  RIO_RQ SocketQueue,
  PRIO_BUF pData,
  ULONG DataBufferCount,
  PRIO_BUF pLocalAddress,
  PRIO_BUF pRemoteAddress,
  PRIO_BUF pControlContext,
  PRIO_BUF pFlags,
  DWORD Flags,
  PVOID RequestContext
);


alias LPFN_RIOREGISTERBUFFER = RIO_BUFFERID function(
  PCHAR DataBuffer,
  DWORD DataLength
);

alias LPFN_RIORESIZECOMPLETIONQUEUE  = BOOL function(
  RIO_CQ CQ,
  DWORD QueueSize
);

alias LPFN_RIORESIZEREQUESTQUEUE = BOOL function(
  RIO_RQ RQ,
  DWORD MaxOutstandingReceive,
  DWORD MaxOutstandingSend
);

alias LPFN_RIOSEND = BOOL function(
  RIO_RQ SocketQueue,
  PRIO_BUF pData,
  ULONG DataBufferCount,
  DWORD Flags,
  PVOID RequestContext
);

alias LPFN_RIOSENDEX = BOOL function(
  RIO_RQ SocketQueue,
  PRIO_BUF pData,
  ULONG DataBufferCount,
  PRIO_BUF pLocalAddress,
  PRIO_BUF pRemoteAddress,
  PRIO_BUF pControlContext,
  PRIO_BUF pFlags,
  DWORD Flags,
  PVOID RequestContext
);

enum RIO_NOTIFICATION_COMPLETION_TYPE : int {
  RIO_EVENT_COMPLETION = 1,
  RIO_IOCP_COMPLETION = 2
} 

struct RIO_NOTIFICATION_COMPLETION {
  RIO_NOTIFICATION_COMPLETION_TYPE Type;
  union {
    struct {
      HANDLE EventHandle;
      BOOL   NotifyReset;
    }
    struct {
      HANDLE IocpHandle;
      PVOID  CompletionKey;
      PVOID  Overlapped;
    }
  }
} 
alias PRIO_NOTIFICATION_COMPLETION = RIO_NOTIFICATION_COMPLETION*;

alias LPFN_RIOCLOSECOMPLETIONQUEUE = VOID function(
  RIO_CQ CQ
);

alias LPFN_RIOCREATECOMPLETIONQUEUE  = RIO_CQ function(
  DWORD QueueSize,
  PRIO_NOTIFICATION_COMPLETION NotificationCompletion
);

alias LPFN_RIOCREATEREQUESTQUEUE = RIO_RQ function(
  SOCKET Socket,
  ULONG MaxOutstandingReceive,
  ULONG MaxReceiveDataBuffers,
  ULONG MaxOutstandingSend,
  ULONG MaxSendDataBuffers,
  RIO_CQ ReceiveCQ,
  RIO_CQ SendCQ,
  PVOID SocketContext
);

alias LPFN_RIODEQUEUECOMPLETION = ULONG function(
  RIO_CQ CQ,
  PRIORESULT Array,
  ULONG ArraySize
);

alias LPFN_RIODEREGISTERBUFFER = VOID function(
  RIO_BUFFERID BufferId
);

alias LPFN_RIONOTIFY = INT function(
  RIO_CQ CQ
);
