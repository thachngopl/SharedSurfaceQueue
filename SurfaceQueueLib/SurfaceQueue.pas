﻿{ THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
  ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
  THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
  PARTICULAR PURPOSE.

  Copyright (c) Microsoft Corporation. All rights reserved }

{ Notes about the synchronization:  It's important for this library
  to be reasonably parallel; it should be possible to have simultaneously
  enqueues/dequeues.  It is undesirable for a thread to grab the queue
  lock while it calls into a blocking or very time consuming DirectX API.

  The single threaded flag will disable the synchronization constructs.

  There are 4 synchronization primitives used in this library.
  1) Critical Section in CSurfaceProducer/CSurfaceConsumer that protects
  simultaneous access to their apis (Enqueue&Flush/Dequeue).  The public
  functions from those objects are not designed to be multithreaded.  It
  is not designed to support, for example, simultaneous Enqueues to the same
  queue.  This lock guarantees that the Queue can not have simultaneous Enqueues
  and Flushes.  There are a few CSurfaceQueue member variables that are shared
  ONLY between Enqueue and Flush and do not need to be protected in CSurfaceQueue.

  2) A Semaphore to control waiting when the Queue is empty.  The semaphore is
  released on Enqueue/Flush and is waited on in Dequeue.

  3) A SlimReaderWriter lock protecting the CSurfaceQueue object.  All of the
  high frequency calls grab shared locks (Enqueue/Flush/Dequeue) to allow
  parallel access to the queue.  The low frequency state changes
  (i.e. OpenProducer) will grab an exclusive lock.

  4) A critical section protecting the underlying circular queue.  Both Enqueue
  and dequeue will contend for this lock but the duration the lock is held
  is kept to a minimum.
  }

unit SurfaceQueue;

{$IFDEF FPC}
{$MODE delphi}{$H+}
{$ENDIF}

interface

{$Z4}

uses
    Windows, Classes, SysUtils, DX12.DXGI, SRWLock, Direct3D9, DX12.D3D10, DX12.D3D11;

{ This defines the size of staging resource.  The purpose of the staging resource is
  so we can copy & lock as a way to wait for rendering to complete.  We ideally, want
  to copy to a 1x1 staging texture but because of various driver bugs, it is more reliable
  to use a slightly bigger texture (16x16). }

const
    SHARED_SURFACE_COPY_SIZE = 16;

const
    IID_ISurfaceProducer: TGUID = '{B8B0B73B-79C1-4446-BB8A-19595018B0B7}';
    IID_ISurfaceConsumer: TGUID = '{97E305E1-1EC7-41a6-972C-99092DE6A31E}';
    IID_ISurfaceQueue: TGUID = '{1C08437F-48DF-467e-8D55-CA9268C73779}';

type

    TSURFACE_QUEUE_FLAG = (SURFACE_QUEUE_FLAG_DO_NOT_WAIT = $1, SURFACE_QUEUE_FLAG_SINGLE_THREADED = $2);

    TSURFACE_QUEUE_DESC = record
        Width: UINT;
        Height: UINT;
        Format: TDXGI_FORMAT;
        NumSurfaces: UINT;
        MetaDataSize: UINT;
        Flags: dword;
    end;

    PSURFACE_QUEUE_DESC = ^TSURFACE_QUEUE_DESC;

    TSURFACE_QUEUE_CLONE_DESC = record
        MetaDataSize: UINT;
        Flags: dword;
    end;

    TSharedSurfaceState = (SHARED_SURFACE_STATE_UNINITIALIZED = 0, SHARED_SURFACE_STATE_DEQUEUED, SHARED_SURFACE_STATE_ENQUEUED,
        SHARED_SURFACE_STATE_FLUSHED);

    ISurfaceProducer = interface;
    ISurfaceConsumer = interface;
    ISurfaceQueue = interface;

    ISurfaceProducer = interface(IUnknown)
        ['{B8B0B73B-79C1-4446-BB8A-19595018B0B7}']
        function Enqueue(pSurface: IUnknown; pBuffer: Pointer; BufferSize: UINT; Flags: dword): HResult; stdcall;
        function Flush(Flags: dword; out NumSurfaces: UINT): HResult; stdcall;
    end;

    PISurfaceProducer = ^ISurfaceProducer;

    ISurfaceConsumer = interface(IUnknown)
        ['{97E305E1-1EC7-41a6-972C-99092DE6A31E}']
        function Dequeue(const id: TGUID; out ppSurface; pBuffer: Pointer; out pBufferSize: UINT; dwTimeout: dword): HResult; stdcall;
    end;

    PISurfaceConsumer = ^ISurfaceConsumer;

    ISurfaceQueue = interface(IUnknown)
        ['{1C08437F-48DF-467e-8D55-CA9268C73779}']
        function OpenProducer(pDevice: IUnknown; out ppProducer: ISurfaceProducer): HResult; stdcall;
        function OpenConsumer(pDevice: IUnknown; out ppConsumer: ISurfaceConsumer): HResult; stdcall;
        function Clone(const pDesc: TSURFACE_QUEUE_CLONE_DESC; out ppQueue: ISurfaceQueue): HResult; stdcall;
    end;

    PISurfaceQueue = ^ISurfaceQueue;

    { Interface to abstract away different runtime devices.  Each of the runtimes will
      have a wrapper that implements this interface.  This interface contains a small
      subset of the public APIs that the queue needs. }
    ISurfaceQueueDevice = interface
        function CreateSharedSurface(Width: UINT; Height: UINT; Format: TDXGI_FORMAT; out ppSurface; out phandle: THANDLE): HResult; stdcall;
        function ValidateREFIID(const id: TGUID): boolean; stdcall;
        function OpenSurface(hSharedHandle: THANDLE; out ppUnknown; Width: UINT; Height: UINT; Format: TDXGI_FORMAT): HResult; stdcall;
        function GetSharedHandle(pUnknown: IUnknown; out phandle: THANDLE): HResult; stdcall;
        function CreateCopyResource(Format: TDXGI_FORMAT; Width: UINT; Height: UINT; out pRes: IUnknown): HResult; stdcall;

        function CopySurface(pDst: IUnknown; pSrc: IUnknown; Width: UINT; Height: UINT): HResult; stdcall;
        function LockSurface(pSurface: IUnknown; Flags: dword): HResult; stdcall;
        function UnlockSurface(pSurface: IUnknown): HResult; stdcall;
    end;

    PISurfaceQueueDevice = ^ISurfaceQueueDevice;

    // This object is shared between all queues in a network and maintains state
    // about the surface.

    { TSharedSurfaceObject }

    TSharedSurfaceObject = record
        hSharedHandle: THANDLE;
        state: TSharedSurfaceState;
        Width: UINT;
        Height: UINT;
        Format: TDXGI_FORMAT;
        procedure Init(AWidth: UINT; AHeight: UINT; Aformat: TDXGI_FORMAT);
        procedure DeInit;
            // Tracks which queue or device currently is using the surface
        case integer of
            0: (queue: Pointer;
                pSurface: Pointer);
            1: (device: Pointer);
    end;

    PSharedSurfaceObject = ^TSharedSurfaceObject;

    TSharedSurfaceObjectArray = array of PSharedSurfaceObject;

    { TSharedSurfaceQueueEntry }

    TSharedSurfaceQueueEntry = record
        surface: PSharedSurfaceObject;
        pMetaData: PByte;
        bMetaDataSize: UINT;
        pStagingResource: IUnknown;
        procedure Init;
    end;

    PSharedSurfaceQueueEntry = ^TSharedSurfaceQueueEntry;

    TSharedSurfaceQueueEntryArray = array of TSharedSurfaceQueueEntry;
    PSharedSurfaceQueueEntryArray = ^TSharedSurfaceQueueEntryArray;

    TSharedSurfaceOpenedMapping = record
        pObject: PSharedSurfaceObject;
        pSurface: IUnknown;
    end;

    PSharedSurfaceOpenedMapping = ^TSharedSurfaceOpenedMapping;

    TSharedSurfaceOpenedMappingArray = array of TSharedSurfaceOpenedMapping;
    PSharedSurfaceOpenedMappingArray = ^TSharedSurfaceOpenedMappingArray;

    TSurfaceQueue = class;

    { TSurfaceConsumer }

    TSurfaceConsumer = class(TInterfacedObject, ISurfaceConsumer)
    private
        m_RefCount: LONG;
        m_IsMultithreaded: boolean;
        // Weak reference to the queue this is part of
        m_pQueue: TSurfaceQueue;
        // The device this was opened with
        m_pDevice: ISurfaceQueueDevice;
        // Critical Section for the consumer
        m_lock: TRTLCriticalSection;
    public
        function Dequeue(const id: TGUID; out ppSurface; pBuffer: Pointer; out pBufferSize: UINT; dwTimeout: dword): HResult; stdcall;
        // Implementation
        constructor Create(IsMultithreaded: boolean);
        destructor Destroy; override;

        function Initialize(pDevice: IUnknown): HResult;
        procedure SetQueue(queue: TSurfaceQueue);

        function GetDevice(): ISurfaceQueueDevice;
    end;

    { TSurfaceProducer }

    TSurfaceProducer = class(TInterfacedObject, ISurfaceProducer)
    private
        m_RefCount: LONG;
        m_IsMultithreaded: boolean;

        // Reference to the queue this is part of
        m_pQueue: TSurfaceQueue;

        // The producer device
        m_pDevice: ISurfaceQueueDevice;

        // Critical Section for the producer
        m_lock: TRTLCriticalSection;

        // Circular buffer of staging resources
        m_nStagingResources: UINT;
        m_pStagingResources: array of IUnknown;

        // Size of staging resource
        m_uiStagingResourceWidth: UINT;
        m_uiStagingResourceHeight: UINT;

        // Index of current staging resource to use
        m_iCurrentResource: UINT;
    public
        function Enqueue(pSurface: IUnknown; pBuffer: Pointer; BufferSize: UINT; Flags: dword): HResult; stdcall;
        function Flush(Flags: dword; out NumSurfaces: UINT): HResult; stdcall;
        constructor Create(IsMultithreaded: boolean);
        destructor Destroy; override;

        function Initialize(pDevice: IUnknown; uNumSurfaces: UINT; const queueDesc: TSURFACE_QUEUE_DESC): HResult;
        procedure SetQueue(queue: TSurfaceQueue);

        function GetDevice(): ISurfaceQueueDevice;
    end;

    { TSurfaceQueue }

    TSurfaceQueue = class(TInterfacedObject, ISurfaceQueue)
    private
        m_RefCount: LONG;
        m_IsMultithreaded: boolean;

        // Synchronization object to handle concurrent dequeues and enqueues
        // For the single threaded case, we can keep track of the number of
        // availible surfaces to help the user prevent hanging on an empty
        // queue.

        m_hSemaphore: THANDLE;
        m_nFlushedSurfaces: UINT;

        // Refernce to the source queue object
        m_pRootQueue: TSurfaceQueue;

        // Number of Queue objects in the network - only stored in root queue
        m_NumQueuesInNetwork: LONG; // volatile

        // References to producer and consumer objects
        m_pConsumer: TSurfaceConsumer;
        m_pProducer: TSurfaceProducer;

        // Reference to the creating device
        m_pCreator: ISurfaceQueueDevice;

        // FIFO Surface Queue
        m_SurfaceQueue: TSharedSurfaceQueueEntryArray;
        m_QueueHead: UINT;
        m_QueueSize: UINT;

        m_ConsumerSurfaces: TSharedSurfaceOpenedMappingArray;
        m_CreatedSurfaces: TSharedSurfaceObjectArray;

        m_iEnqueuedHead: UINT;
        m_nEnqueuedSurfaces: UINT;

        m_Desc: TSURFACE_QUEUE_DESC;

        // Lock around all of the public queue functions.  This should have very little contention
        // and is used to synchronize rare queue state changes (i.e. the consumer device changes).
        m_lock: TSRWLOCK;

        // Lock for access to the underlying queue
        m_QueueLock: TRTLCriticalSection;
    private
        procedure _Destroy();

        function CreateSurfaces(): HResult;
        procedure CopySurfaceReferences(pRootQueue: TSurfaceQueue);
        function AllocateMetaDataBuffers(): HResult;

        function GetCreatorDevice(): ISurfaceQueueDevice;

        function GetNumQueuesInNetwork(): UINT;
        function AddQueueToNetwork(): UINT;
        function RemoveQueueFromNetwork(): UINT;

        procedure Dequeue(out entry: PSharedSurfaceQueueEntry);
        procedure Enqueue(entry: TSharedSurfaceQueueEntry);
        procedure Front(out entry: PSharedSurfaceQueueEntry);

        function GetSurfaceObjectFromHandle(h: THANDLE): PSharedSurfaceObject;
        function GetOpenedSurface(pObject: PSharedSurfaceObject): IUnknown;
    public
        // ISurfaceQueue functions
        function OpenProducer(pDevice: IUnknown; out ppProducer: ISurfaceProducer): HResult; stdcall;
        function OpenConsumer(pDevice: IUnknown; out ppConsumer: ISurfaceConsumer): HResult; stdcall;
        function Clone(const pDesc: TSURFACE_QUEUE_CLONE_DESC; out ppQueue: ISurfaceQueue): HResult; stdcall;
        // Implementation Functions
        constructor Create;
        destructor Destroy; override;

        // Initializes the queue.  Creates the surfaces, initializes the synchronization code
        function Initialize(pDesc: TSURFACE_QUEUE_DESC; pDevice: IUnknown; pRootQueue: TSurfaceQueue): HResult;
        // Removes the producer device
        procedure RemoveProducer();
        // Removes the consumer device.
        procedure RemoveConsumer();
        function _Enqueue(pSurface: IUnknown; pBuffer: Pointer; BufferSize: UINT; Flags: dword; pStagingResource: IUnknown;
            Width: UINT; Height: UINT): HResult;
        function _Dequeue(out ppSurface; pBuffer: Pointer; out BufferSize: UINT; dwTimeout: dword): HResult;
        function Flush(Flags: dword; out NumSurfaces: UINT): HResult;
    end;

function CreateSurfaceQueue(pDesc: TSURFACE_QUEUE_DESC; pDevice: IUnknown; out ppQueue: ISurfaceQueue): HResult; stdcall;

implementation

uses
    SurfaceQueueDeviceD3D9, Math, SurfaceQueueDeviceD3D10, SurfaceQueueDeviceD3D11;

{ -----------------------------------------------------------------------------
  Helper Functions
  ----------------------------------------------------------------------------- }

function HRESULT_FROM_WIN32(x: ulong): HResult; inline;
begin
    if x <= 0 then
    begin
        Result := HResult(x);
    end
    else
    begin
        Result := ((x and $0000FFFF) or (FACILITY_WIN32 shl 16) or $80000000);
    end;
end;



function CreateDeviceWrapper(pUnknown: IUnknown; out ppDevice: ISurfaceQueueDevice): HResult;
var
    pD3D9Device: IDirect3DDevice9Ex;
    pD3D10Device: ID3D10Device;
    pD3D11Device: ID3D11Device;
begin

    Result := S_OK;
    ppDevice := nil;

    Result := pUnknown.QueryInterface(IID_IDirect3DDevice9Ex, pD3D9Device);
    if Result = S_OK then
    begin
        ppDevice := TSurfaceQueueDeviceD3D9.Create(pD3D9Device);
        pD3D9Device := nil;
    end
    else
    begin
        Result := pUnknown.QueryInterface(IID_ID3D10Device, pD3D10Device);
        if Result = S_OK then
        begin
            ppDevice := TSurfaceQueueDeviceD3D10.Create(pD3D10Device);
            pD3D10Device := nil;
        end
        else
        begin
            Result := pUnknown.QueryInterface(IID_ID3D11Device, pD3D11Device);
            if Result = S_OK then
            begin
                ppDevice := TSurfaceQueueDeviceD3D11.Create(pD3D11Device);
                pD3D11Device := nil;
            end
            else
            begin
                Result := E_INVALIDARG;
            end;
        end;
    end;
end;



function CreateSurfaceQueue(pDesc: TSURFACE_QUEUE_DESC; pDevice: IUnknown; out ppQueue: ISurfaceQueue): HResult; stdcall;
var
    pSurfaceQueue: TSurfaceQueue;
begin
    Result := S_OK;
    ppQueue := nil;

    if (pDevice = nil) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    if (pDesc.NumSurfaces = 0) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    if (pDesc.Width = 0) or (pDesc.Height = 0) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    if (pDesc.Flags <> 0) and (pDesc.Flags <> Ord(SURFACE_QUEUE_FLAG_SINGLE_THREADED)) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    pSurfaceQueue := TSurfaceQueue.Create();

    if (pSurfaceQueue = nil) then
    begin
        Result := E_OUTOFMEMORY;
    end;
    if Result = S_OK then
    begin
        Result := pSurfaceQueue.Initialize(pDesc, pDevice, pSurfaceQueue);
    end;
    if Result = S_OK then
    begin
        Result := pSurfaceQueue.QueryInterface(ISurfaceQueue, ppQueue);
    end;

    if Result <> S_OK then
    begin
        if (pSurfaceQueue <> nil) then
        begin
            pSurfaceQueue.Free;
        end;
        ppQueue := nil;
    end;
end;

{ TSharedSurfaceObject }

procedure TSharedSurfaceObject.Init(AWidth: UINT; AHeight: UINT; Aformat: TDXGI_FORMAT);
begin
    hSharedHandle := 0;
    state := SHARED_SURFACE_STATE_UNINITIALIZED;
    queue := nil;

    Width := AWidth;
    Height := AHeight;
    Format := Aformat;

    pSurface := nil;
end;



procedure TSharedSurfaceObject.DeInit;
begin
    pSurface := nil;
end;

{ TSurfaceProducer }

function TSurfaceProducer.Enqueue(pSurface: IUnknown; pBuffer: Pointer; BufferSize: UINT; Flags: dword): HResult; stdcall;
begin

    // This function essentially does simple error checking and then
    // forwards the call to the queue object.  The SurfaceProducer
    // maintains a circular buffer of staging resources to use and will
    // pass the next availible one to the queue.

    if (m_IsMultithreaded) then
        EnterCriticalSection(m_lock);

    Result := S_OK;

    if (m_pDevice = nil) then
        Result := E_INVALIDARG;
    if (pSurface = nil) then

        Result := E_INVALIDARG;

    if ((Flags <> 0) and (Flags <> Ord(SURFACE_QUEUE_FLAG_DO_NOT_WAIT))) then
        Result := E_INVALIDARG;

    if Result = S_OK then
        // Forward call to queue
        Result := m_pQueue._Enqueue(pSurface, pBuffer, BufferSize, Flags, m_pStagingResources[m_iCurrentResource],
            m_uiStagingResourceWidth, m_uiStagingResourceHeight);

    if (Result = DXGI_ERROR_WAS_STILL_DRAWING) then
    begin
        // Increment the staging resource only if the current one is still
        // being used.  This only happens if the function returns with
        // DXGI_ERROR_WAS_STILL_DRAWING indicating that a future flush
        // will still need the resource

        // We do not need to worry about wrapping around and reusing staging
        // surfaces that are currently in use.  The design of the queue makes
        // it invalid to enqueue when the queue is already full.  If the user
        // does that, the queue will fail the call with E_INVALIDARG.
        m_iCurrentResource := (m_iCurrentResource + 1) mod m_nStagingResources;
    end;

    if (m_IsMultithreaded) then
        LeaveCriticalSection(m_lock);

end;



function TSurfaceProducer.Flush(Flags: dword; out NumSurfaces: UINT): HResult; stdcall;
begin
    if (m_IsMultithreaded) then
        EnterCriticalSection(m_lock);
    Result := S_OK;

    if (m_pDevice = nil) then
        Result := E_INVALIDARG;

    if (Flags <> 0) and (Flags <> Ord(SURFACE_QUEUE_FLAG_DO_NOT_WAIT)) then
        Result := E_INVALIDARG;

    if Result = S_OK then
        // Forward call to queue
        Result := m_pQueue.Flush(Flags, NumSurfaces);

    if (m_IsMultithreaded) then
        LeaveCriticalSection(m_lock);
end;



constructor TSurfaceProducer.Create(IsMultithreaded: boolean);
begin
    m_RefCount := 0;
    m_IsMultithreaded := IsMultithreaded;
    m_pQueue := nil;
    m_pDevice := nil;
    m_nStagingResources := 0;
    SetLength(m_pStagingResources, 0);
    m_uiStagingResourceHeight := 0;
    m_uiStagingResourceWidth := 0;
    m_iCurrentResource := 0;

    if (m_IsMultithreaded) then
        InitializeCriticalSection(m_lock);
end;



destructor TSurfaceProducer.Destroy;
var
    i: integer;
begin
    if (m_pQueue <> nil) then
    begin
        m_pQueue.RemoveProducer();
        m_pQueue := nil;
    end;

    for i := 0 to m_nStagingResources - 1 do
    begin
        m_pStagingResources[i] := nil;

    end;
    SetLength(m_pStagingResources, 0);

    if (m_pDevice <> nil) then
        m_pDevice := nil;

    if (m_IsMultithreaded) then
        DeleteCriticalSection(m_lock);

    inherited Destroy;
end;



function TSurfaceProducer.Initialize(pDevice: IUnknown; uNumSurfaces: UINT; const queueDesc: TSURFACE_QUEUE_DESC): HResult;
var
    i: integer;
    p: IUnknown;
    pp: Pointer;
begin
    Result := CreateDeviceWrapper(pDevice, m_pDevice);

    if Result = S_OK then
    begin
        SetLength(m_pStagingResources, uNumSurfaces);
        m_nStagingResources := uNumSurfaces;

        // Determine the size of the staging resource in case the queue surface is less than SHARED_SURFACE_COPY_SIZE

        m_uiStagingResourceWidth := min(queueDesc.Width, SHARED_SURFACE_COPY_SIZE);
        m_uiStagingResourceHeight := min(queueDesc.Height, SHARED_SURFACE_COPY_SIZE);

        // Create the staging resources
        for i := 0 to m_nStagingResources - 1 do
        begin
            Result := m_pDevice.CreateCopyResource(queueDesc.Format, m_uiStagingResourceWidth, m_uiStagingResourceHeight, m_pStagingResources[i]);
            if Result <> S_OK then
                Break;
        end;
    end;

    if Result <> S_OK then
    begin
        for i := 0 to m_nStagingResources - 1 do
        begin
            m_pStagingResources[i] := nil;
        end;
        SetLength(m_pStagingResources, 0);
        m_nStagingResources := 0;
        if (m_pDevice <> nil) then
            m_pDevice := nil;
    end;
end;



procedure TSurfaceProducer.SetQueue(queue: TSurfaceQueue);
begin
    // ASSERT(!m_pQueue && queue);
    m_pQueue := queue;
end;



function TSurfaceProducer.GetDevice: ISurfaceQueueDevice;
begin
    Result := m_pDevice;
end;

{ TSurfaceQueue }

procedure TSurfaceQueue._Destroy;
var
    i: integer;
begin
    RemoveQueueFromNetwork();

    // The ref counting should guarantee that the root queue object
    // is the last to be deleted
    if (m_pRootQueue <> self) then
        m_pRootQueue := nil;

    // The root queue will destroy the creating device
    if (m_pCreator <> nil) then
        m_pCreator := nil;

    // Release all opened surfaces

    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_ConsumerSurfaces[i].pSurface <> nil) then
            m_ConsumerSurfaces[i].pSurface := nil;
    end;
    SetLength(m_ConsumerSurfaces, 0);

    // Clean up the allocated meta data buffers
    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_SurfaceQueue[i].pMetaData <> nil) then
        begin
            // Dispose(m_SurfaceQueue[i].pMetaData);
            m_SurfaceQueue[i].pMetaData := nil;
        end;
    end;
    SetLength(m_SurfaceQueue, 0);

    // The root queue object created the surfaces.  All other queue
    // objects only have a reference.

    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_pRootQueue = self) and (m_CreatedSurfaces[i] <> nil) then
            Dispose(m_CreatedSurfaces[i]);
        m_CreatedSurfaces[i] := nil;
    end;
    SetLength(m_CreatedSurfaces, 0);

    m_pConsumer := nil;
    m_pProducer := nil;

    if (m_IsMultithreaded) then
    begin
        if (m_hSemaphore <> 0) then
        begin
            CloseHandle(m_hSemaphore);
            m_hSemaphore := 0;
        end;
        DeleteCriticalSection(m_QueueLock);
    end
    else
        m_nFlushedSurfaces := 0;
end;



function TSurfaceQueue.CreateSurfaces: HResult;
var
    i: integer;
    pSurfaceObject: TSharedSurfaceObject;
    lSurface: IUnknown;
    lHandle: THANDLE;
begin
    // This function is only called by the root queue to create the surfaces.
    // The queue has the property that the root queue starts off full (all the
    // surfaces on it are ready for dequeue.  This function will use the creating
    // device to create the shared surfaces and initialize them for dequeue.


    // HRESULT hr = S_OK;
    // ASSERT(m_pRootQueue == this);

    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        lHandle := 0;
        m_CreatedSurfaces[i] := AllocMem(sizeof(TSharedSurfaceObject));
        m_CreatedSurfaces[i]^.Init(m_Desc.Width, m_Desc.Height, m_Desc.Format);

        Result := m_pCreator.CreateSharedSurface(m_Desc.Width, m_Desc.Height, m_Desc.Format, m_CreatedSurfaces[i]^.pSurface, lHandle);
        m_CreatedSurfaces[i]^.hSharedHandle := lHandle;
        if (Result <> S_OK) then
        begin
            Exit;
        end;

        // Important to note that created surfaces start in the flushed state.  This
        // lets the system start in a state that makes it ready to go.
        m_SurfaceQueue[i].surface := m_CreatedSurfaces[i];
        m_SurfaceQueue[i].surface.state := SHARED_SURFACE_STATE_FLUSHED;
        m_SurfaceQueue[i].surface.queue := @self;
    end;

    Result := S_OK;
end;



procedure TSurfaceQueue.CopySurfaceReferences(pRootQueue: TSurfaceQueue);
var
    i: integer;
begin
    // This is called by cloned devices.  They simply take a reference
    // to the shared created surfaces.
    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        m_CreatedSurfaces[i] := pRootQueue.m_CreatedSurfaces[i];
    end;
end;



function TSurfaceQueue.AllocateMetaDataBuffers: HResult;
var
    i: integer;
begin
    // This function allocates the meta data buffers during creation time.
    if (m_Desc.MetaDataSize <> 0) then
    begin
        for i := 0 to m_Desc.NumSurfaces - 1 do
        begin
            m_SurfaceQueue[i].pMetaData := AllocMem(m_Desc.MetaDataSize);
            if (m_SurfaceQueue[i].pMetaData = nil) then
            begin
                Result := E_OUTOFMEMORY;
                Exit;
            end;
        end;
    end;
    Result := S_OK;
end;



function TSurfaceQueue.GetCreatorDevice: ISurfaceQueueDevice;
begin
    Result := m_pRootQueue.m_pCreator;
end;



function TSurfaceQueue.GetNumQueuesInNetwork: UINT;
begin
    Result := m_pRootQueue.m_NumQueuesInNetwork;
end;



function TSurfaceQueue.AddQueueToNetwork: UINT;
begin
    if (m_pRootQueue = self) then
    begin
        Result := InterlockedIncrement(m_NumQueuesInNetwork);
    end
    else
    begin
        Result := m_pRootQueue.AddQueueToNetwork();
    end;
end;



function TSurfaceQueue.RemoveQueueFromNetwork: UINT;
begin
    if (m_pRootQueue = self) then
    begin
        Result := InterlockedDecrement(m_NumQueuesInNetwork);
    end
    else
    begin
        Result := m_pRootQueue.RemoveQueueFromNetwork();
    end;
end;



procedure TSurfaceQueue.Dequeue(out entry: PSharedSurfaceQueueEntry);
begin
    // The semaphore protecting access to the queue guarantees that the queue
    // can not be empty.
    if (m_IsMultithreaded) then
        EnterCriticalSection(m_QueueLock);

    entry := @m_SurfaceQueue[m_QueueHead];
    m_QueueHead := (m_QueueHead + 1) mod m_Desc.NumSurfaces;
    Dec(m_QueueSize);

    if (m_IsMultithreaded) then
        LeaveCriticalSection(m_QueueLock);
end;



procedure TSurfaceQueue.Enqueue(entry: TSharedSurfaceQueueEntry);
var
    ende: UINT;
begin
    // The validation in the queue should guarantee that the queue is not full

    if (m_IsMultithreaded) then
        EnterCriticalSection(m_QueueLock);

    ende := (m_QueueHead + m_QueueSize) mod m_Desc.NumSurfaces;
    Inc(m_QueueSize);

    if (m_IsMultithreaded) then
        LeaveCriticalSection(m_QueueLock);

    m_SurfaceQueue[ende].surface := entry.surface;
    m_SurfaceQueue[ende].bMetaDataSize := entry.bMetaDataSize;
    m_SurfaceQueue[ende].pStagingResource := entry.pStagingResource;
    if (entry.bMetaDataSize <> 0) then
        Move(entry.pMetaData, m_SurfaceQueue[ende].pMetaData, sizeof(byte) * entry.bMetaDataSize);
end;



procedure TSurfaceQueue.Front(out entry: PSharedSurfaceQueueEntry);
begin
    entry := @m_SurfaceQueue[m_QueueHead];
end;



function TSurfaceQueue.GetSurfaceObjectFromHandle(h: THANDLE): PSharedSurfaceObject;
var
    i: integer;
begin

    // This does a linear search through the created surfaces for the specific
    // handle.  When the user enqueues, we get the shared handle from surface
    // and then use the handle to get to the SharedSurfaceObject.  This essentially
    // converts from a "generic d3d surface" to a "surface queue surface".

    // This search is linear with the number of surfaces created.  We expect that
    // number to be small.

    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_CreatedSurfaces[i]^.hSharedHandle = h) then
        begin
            Result := m_CreatedSurfaces[i];
            Exit;
        end;
    end;
    // The user tried to enqueue an shared surface that was not part of the queue.
    Result := nil;
end;



function TSurfaceQueue.GetOpenedSurface(pObject: PSharedSurfaceObject): IUnknown;
var
    i: integer;
begin
    // On OpenConsumer, all of the shared surfaces will be opened by the consuming
    // device and cached.  On dequeue, we simply look in the cache and return the
    // appropriate surface, getting a significant perf bonus over opening/closing
    // the surface on every dequeue/enqueue.

    // This method is also linear with respect to the number of surfaces and a more
    // scalable data structure can be used if the number of surfaces is used.

    Result := nil;
    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_ConsumerSurfaces[i].pObject = pObject) then
        begin
            Result := m_ConsumerSurfaces[i].pSurface;
            Break;
        end;
    end;
end;



function TSurfaceQueue.OpenProducer(pDevice: IUnknown; out ppProducer: ISurfaceProducer): HResult; stdcall;
begin
    if (pDevice = nil) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    ppProducer := nil;

    Result := S_OK;

    if (m_IsMultithreaded) then
        m_lock.AcquireExclusive;

    if (m_pProducer <> nil) then
    begin
        if (m_IsMultithreaded) then
            m_lock.ReleaseExclusive;

        Result := E_INVALIDARG;
        Exit;
    end;

    m_pProducer := TSurfaceProducer.Create(m_IsMultithreaded);
    if (m_pProducer = nil) then
        Result := E_OUTOFMEMORY;

    if Result = S_OK then
        Result := m_pProducer.Initialize(pDevice, m_Desc.NumSurfaces, m_Desc);
    if Result = S_OK then

        Result := m_pProducer.QueryInterface(IID_ISurfaceProducer, ppProducer);
    if Result = S_OK then
        m_pProducer.SetQueue(self);

    if Result <> S_OK then
    begin
        ppProducer := nil;
        if (m_pProducer <> nil) then
        begin
            m_pProducer := nil;
            ppProducer := nil;
        end;
    end;

    if (m_IsMultithreaded) then
        m_lock.ReleaseExclusive;

end;



function TSurfaceQueue.OpenConsumer(pDevice: IUnknown; out ppConsumer: ISurfaceConsumer): HResult; stdcall;
var
    i: integer;
begin
    if (pDevice = nil) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    ppConsumer := nil;

    Result := S_OK;

    if (m_IsMultithreaded) then
        m_lock.AcquireExclusive;


    // If a consumer exists, we need to bail early. The normal error
    // path will deallocate the current consumer.  Instead this will
    // be a no-op for the queue and E_INVALIDARG will be returned.

    if (m_pConsumer <> nil) then
    begin
        if (m_IsMultithreaded) then
            m_lock.ReleaseExclusive;

        Result := E_INVALIDARG;
        Exit;
    end;

    m_pConsumer := TSurfaceConsumer.Create(m_IsMultithreaded);
    if (m_pConsumer = nil) then
    begin
        Result := E_OUTOFMEMORY;

    end;
    if Result = S_OK then
        Result := m_pConsumer.Initialize(pDevice);

    if Result = S_OK then
    begin
        // For all the surfaces in the queue, we want to open it with the producing device.
        // This guarantees that surfaces are only open at creation time.

        for i := 0 to m_Desc.NumSurfaces - 1 do
        begin
            // ASSERT(m_CreatedSurfaces[i]);
            // ASSERT(m_ConsumerSurfaces);
            Result := m_pConsumer.GetDevice().OpenSurface(m_CreatedSurfaces[i]^.hSharedHandle, m_ConsumerSurfaces[i].pSurface,
                m_Desc.Width, m_Desc.Height, m_Desc.Format);
            if Result <> S_OK then
                Break;
            m_ConsumerSurfaces[i].pObject := m_CreatedSurfaces[i];
        end;
    end;
    if Result = S_OK then
        Result := m_pConsumer.QueryInterface(IID_ISurfaceConsumer, ppConsumer);
    if Result = S_OK then
        m_pConsumer.SetQueue(self);

    if Result <> S_OK then
    begin
        ppConsumer := nil;

        if (m_pConsumer <> nil) then
        begin
            if (m_pConsumer.GetDevice() <> nil) then
            begin
                for i := 0 to m_Desc.NumSurfaces - 1 do
                begin
                    if (m_ConsumerSurfaces[i].pSurface <> nil) then
                        m_ConsumerSurfaces[i].pSurface := nil;
                end;
            end;

            ZeroMemory(@m_ConsumerSurfaces, sizeof(TSharedSurfaceOpenedMapping) * m_Desc.NumSurfaces);
            m_pConsumer := nil;
        end;
    end;

    if (m_IsMultithreaded) then
        m_lock.ReleaseExclusive;
end;



function TSurfaceQueue.Clone(const pDesc: TSURFACE_QUEUE_CLONE_DESC; out ppQueue: ISurfaceQueue): HResult; stdcall;
var
    createDesc: TSURFACE_QUEUE_DESC;
    pQueue: TSurfaceQueue;
begin
    Result := S_OK;

    // Have all the clones originate from the root queue.  This makes tracking
    // referenes easier.
    if (m_pRootQueue <> self) then
    begin
        Result := m_pRootQueue.Clone(pDesc, ppQueue);
        Exit;
    end;

    if (pDesc.Flags <> 0) and (pDesc.Flags <> Ord(SURFACE_QUEUE_FLAG_SINGLE_THREADED)) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    ppQueue := nil;

    if (m_IsMultithreaded) then
    begin
        m_lock.AcquireExclusive;
    end;

    createDesc := m_Desc;
    createDesc.MetaDataSize := pDesc.MetaDataSize;
    createDesc.Flags := pDesc.Flags;

    pQueue := TSurfaceQueue.Create;
    if (pQueue = nil) then
    begin
        Result := E_OUTOFMEMORY;
    end;
    if Result = S_OK then
    begin
        Result := pQueue.Initialize(createDesc, nil, self);
    end;
    if Result = S_OK then
    begin
        Result := pQueue.QueryInterface(ISurfaceQueue, ppQueue);
    end;

    if (Result <> S_OK) then
    begin
        if (pQueue <> nil) then
            pQueue.Free;
        ppQueue := nil;
    end;
    if (m_IsMultithreaded) then
        m_lock.ReleaseExclusive;
end;



constructor TSurfaceQueue.Create;
begin
    m_RefCount := 0;
    m_IsMultithreaded := True;
    m_hSemaphore := 0;
    m_pRootQueue := nil;
    m_NumQueuesInNetwork := 0;
    m_pConsumer := nil;
    m_pProducer := nil;
    m_pCreator := nil;
    m_SurfaceQueue := nil;
    m_QueueHead := 0;
    m_QueueSize := 0;
    m_ConsumerSurfaces := nil;
    SetLength(m_CreatedSurfaces, 0);
    m_iEnqueuedHead := 0;
    m_nEnqueuedSurfaces := 0;
end;



destructor TSurfaceQueue.Destroy;
begin
    _Destroy;
    inherited Destroy;
end;



function TSurfaceQueue.Initialize(pDesc: TSURFACE_QUEUE_DESC; pDevice: IUnknown; pRootQueue: TSurfaceQueue): HResult;
var
    i: integer;
begin
    Result := S_OK;

    m_Desc := pDesc;
    m_pRootQueue := pRootQueue;
    m_IsMultithreaded := not (m_Desc.Flags and Ord(SURFACE_QUEUE_FLAG_SINGLE_THREADED) = Ord(SURFACE_QUEUE_FLAG_SINGLE_THREADED));

    AddQueueToNetwork();

    if (m_IsMultithreaded) then
    begin
        InitializeCriticalSection(&m_QueueLock);
    end;

    // Allocate Queue
    SetLength(m_SurfaceQueue, pDesc.NumSurfaces);

    // Allocate array to keep track of opened surfaces
    SetLength(m_ConsumerSurfaces, pDesc.NumSurfaces);

    // Allocate created surface tracking list
    SetLength(m_CreatedSurfaces, pDesc.NumSurfaces);

    // If this is the root queue, create the surfaces
    if (m_pRootQueue = self) then
    begin
        Result := CreateDeviceWrapper(pDevice, m_pCreator);
        Result := CreateSurfaces();
        m_QueueSize := pDesc.NumSurfaces;
    end
    else
    begin
        // Increment the reference count on the src queue
        // m_pRootQueue.AddRef(); -> cause we are using Pascal, we don't need to do such shit ;)
        CopySurfaceReferences(pRootQueue);
        m_QueueSize := 0;
    end;

    if (m_Desc.MetaDataSize <> 0) then
    begin
        Result := AllocateMetaDataBuffers();
    end;

    if (m_IsMultithreaded) then
    begin
        // Create Semaphore for queue synchronization
        if m_pRootQueue = self then
        begin
            m_hSemaphore := CreateSemaphore(nil, pDesc.NumSurfaces, pDesc.NumSurfaces, nil);
        end
        else
        begin
            m_hSemaphore := CreateSemaphore(nil, 0, pDesc.NumSurfaces, nil);
        end;
        if (m_hSemaphore = 0) then
        begin
            Result := HRESULT_FROM_WIN32(GetLastError());
        end;
        // Initialize the slim reader/writer lock
        m_lock := TSRWLOCK.Create;
    end
    else
    begin
        if m_pRootQueue = self then
        begin
            m_nFlushedSurfaces := pDesc.NumSurfaces;
        end
        else
        begin
            m_nFlushedSurfaces := 0;
        end;
    end;

    // cleanup:
    // The object will get destroyed if initialize fails.  Cleanup
    // will happen then.
end;



procedure TSurfaceQueue.RemoveProducer;
begin
    if (m_IsMultithreaded) then
        m_lock.AcquireExclusive;
    m_pProducer := nil;

    if (m_IsMultithreaded) then
        m_lock.ReleaseExclusive;
end;



procedure TSurfaceQueue.RemoveConsumer;
var
    i: integer;
begin
    if (m_IsMultithreaded) then
        m_lock.AcquireExclusive;

    for i := 0 to m_Desc.NumSurfaces - 1 do
    begin
        if (m_ConsumerSurfaces[i].pSurface <> nil) then
            m_ConsumerSurfaces[i].pSurface := nil;
    end;
    ZeroMemory(@m_ConsumerSurfaces[0], sizeof(TSharedSurfaceOpenedMapping) * m_Desc.NumSurfaces);
    m_pConsumer := nil;

    if (m_IsMultithreaded) then
        m_lock.ReleaseExclusive;
end;



function TSurfaceQueue._Enqueue(pSurface: IUnknown; pBuffer: Pointer; BufferSize: UINT; Flags: dword;
    pStagingResource: IUnknown; Width: UINT; Height: UINT): HResult;
var
    QueueEntry: TSharedSurfaceQueueEntry;
    hSharedHandle: THANDLE;
    pSurfaceObject: PSharedSurfaceObject;
    lNumSurfaces: UINT;
begin
    { if (pBuffer = nil) or (BufferSize = 0) then
      begin
      Result := E_INVALIDARG;
      Exit;
      end;
      }

    if (BufferSize > m_Desc.MetaDataSize) then
    begin
        Result := E_INVALIDARG;
        Exit;
    end;

    if (m_IsMultithreaded) then
        m_lock.AcquireShared;

    Result := S_OK;
    // Require both the producer and consumer to be initialized.
    // This avoids a potential race condition
    if (m_pProducer = nil) or (m_pConsumer = nil) then
    begin
        Result := E_INVALIDARG;
    end;
    if Result = S_OK then
    begin
        // Check that the queue is not full.  Enqueuing onto a full queue is
        // not a scenario that makes sense
        if (m_QueueSize = m_Desc.NumSurfaces) then
            Result := E_INVALIDARG;
    end;
    if Result = S_OK then
        // Get the SharedSurfaceObject from the surface
        Result := m_pProducer.GetDevice.GetSharedHandle(pSurface, hSharedHandle);
    if Result = S_OK then
    begin
        pSurfaceObject := GetSurfaceObjectFromHandle(hSharedHandle);
        // Validate that this surface is one that can be part of this queue
        if (pSurfaceObject = nil) then
            Result := E_INVALIDARG;
    end;
    if Result = S_OK then
    begin
        if (pSurfaceObject.state <> SHARED_SURFACE_STATE_DEQUEUED) then
            Result := E_INVALIDARG;
    end;
    if Result = S_OK then
    begin
        QueueEntry.surface := pSurfaceObject;
        QueueEntry.pMetaData := pBuffer;
        QueueEntry.bMetaDataSize := BufferSize;
        QueueEntry.pStagingResource := nil;

        // Copy a small portion of the surface onto the staging surface
        Result := m_pProducer.GetDevice.CopySurface(pStagingResource, pSurface, Width, Height);
    end;
    if Result = S_OK then
    begin
        pSurfaceObject.state := SHARED_SURFACE_STATE_ENQUEUED;
        pSurfaceObject.queue := self;

        // At this point we have succesfully issued the copy to the staging resource.
        // The surface will now must be added to the fifo queue either in the ENQUEUED
        // or FLUSHED state.

        // Do not attempt to flush the surfaces if the DO_NOT_WAIT flag was used.
        // In these cases, simply add the surface to the FIFO queue as an ENQUEUED surface.


        // Note: m_nEnqueuedSurfaces and m_iEnqueuedHead are protected by the lock in the
        // SurfaceProducer.  This value is not shared between the Consumer and Producer and
        // therefore does not need any sychronization in the queue object.

        if (Flags and Ord(SURFACE_QUEUE_FLAG_DO_NOT_WAIT) = Ord(SURFACE_QUEUE_FLAG_DO_NOT_WAIT)) then
        begin
            // The surface should go into the ENQUEUED but not FLUSHED state.
            // Queue the entry into the fifo queue along with the staging resource for it
            QueueEntry.pStagingResource := pStagingResource;
            Enqueue(QueueEntry);
            Inc(m_nEnqueuedSurfaces);

            // Since the surface did not flush, set the return to DXGI_ERROR_WAS_STILL_DRAWING
            // and return.
            Result := DXGI_ERROR_WAS_STILL_DRAWING;
        end
        else if (m_nEnqueuedSurfaces <> 0) then
        begin
            // Enqueued was called without the DO_NOT_WAIT flag but there are enqueued surfaces
            // currently not flushed.  First flush the existing surfaces and then perform the
            // current Enqueue.

            Result := Flush(0, lNumSurfaces);
            // ASSERT(SUCCEEDED(hr));
        end;

        if Result = S_OK then
            // Force rendering to complete by locking the staging resource.
            Result := m_pProducer.GetDevice.LockSurface(pStagingResource, Flags);
        if Result = S_OK then
            Result := m_pProducer.GetDevice.UnlockSurface(pStagingResource);
        if Result = S_OK then
        begin
            // The call to lock the surface completed succesfully meaning the surface if flushed
            // and ready for dequeue.  Mark the surface as such and add it to the fifo queue.
            pSurfaceObject.state := SHARED_SURFACE_STATE_FLUSHED;

            m_iEnqueuedHead := (m_iEnqueuedHead + 1) mod m_Desc.NumSurfaces;
            Enqueue(QueueEntry);

            if (m_IsMultithreaded) then
                // Increment the semaphore
                ReleaseSemaphore(m_hSemaphore, 1, nil)
            else
                Inc(m_nFlushedSurfaces);
        end;
    end;

    if (m_IsMultithreaded) then
        m_lock.ReleaseShared;
end;



function TSurfaceQueue._Dequeue(out ppSurface; pBuffer: Pointer; out BufferSize: UINT; dwTimeout: dword): HResult;
var
    QueueElement: PSharedSurfaceQueueEntry;
    pSurface: IUnknown;
    dwWait: dword;
    p: Pointer;
begin
    { if (pBuffer = nil) and (BufferSize > 0) then
      begin
      Result := E_INVALIDARG;
      Exit;
      end; }
    if (pBuffer <> nil) then
    begin
        if (BufferSize > m_Desc.MetaDataSize) then
        begin
            Result := E_INVALIDARG;
            Exit;
        end;
    end;

    if (m_IsMultithreaded) then
        m_lock.AcquireShared;

    pSurface := nil;
    Result := S_OK;

    // Require both the producer and consumer to be initialized.
    // This avoids a potential race condition
    if (m_pProducer = nil) or (m_pConsumer = nil) then
        Result := E_INVALIDARG;

    if Result = S_OK then
    begin
        if (m_IsMultithreaded) then
        begin
            // Wait on the semaphore until the queue is not empty
            dwWait := WaitForSingleObject(m_hSemaphore, dwTimeout);
            case (dwWait) of
                WAIT_ABANDONED:
                    Result := E_FAIL;
                WAIT_OBJECT_0:
                    Result := S_OK;
                WAIT_TIMEOUT:
                    Result := HRESULT_FROM_WIN32(WAIT_TIMEOUT);
                WAIT_FAILED:
                    Result := HRESULT_FROM_WIN32(GetLastError());
                else
                    Result := E_FAIL;
            end;
        end
        else
        begin
            // In the single threaded case, dequeuing on an empty
            // will return immediately.  The error returned is not
            // *exactly* right but it parallels the multithreaded
            // case.
            if (m_nFlushedSurfaces = 0) then
                Result := HRESULT_FROM_WIN32(WAIT_TIMEOUT)
            else
            begin
                Dec(m_nFlushedSurfaces);
                Result := S_OK;
            end;
        end;
    end;

    // Early return because of timeout or wait error
    if Result = S_OK then
    begin
        // At this point, there must be a surface in the queue ready to be
        // dequeued.  Get a reference to the first surface make sure
        // it is valid.  We don't want the situation where the surface is
        // removed but then fails.


        // At this point there must be an surface in the queue ready to go
        // Dequeue it

        Front(QueueElement);

        // ASSERT (QueueElement.surface->state == SHARED_SURFACE_STATE_FLUSHED);
        // ASSERT (QueueElement.surface->queue == this);


        // Update the state of the surface to dequeued

        QueueElement.surface.state := SHARED_SURFACE_STATE_DEQUEUED;
        QueueElement.surface.device := Pointer(m_pConsumer.GetDevice());

        // Get the surface for the consuming device from the surface object
        pSurface := GetOpenedSurface(QueueElement.surface);
        // ASSERT(pSurface);

        IUnknown(ppSurface) := pSurface;

        // There should be no more failures after here
        if (pBuffer <> nil) and (QueueElement.bMetaDataSize > 0) then
        begin
            Move(QueueElement.pMetaData, pBuffer, sizeof(byte) * QueueElement.bMetaDataSize);
        end;
        // Store the actual number of bytes copied as meta data.
        BufferSize := QueueElement.bMetaDataSize;
        // Remove the element from the queue.  We do it at the very end in case there are
        // errors.

        Dequeue(QueueElement);
    end;

    if (m_IsMultithreaded) then
        m_lock.ReleaseShared;
end;



function TSurfaceQueue.Flush(Flags: dword; out NumSurfaces: UINT): HResult;
var
    uiFlushedSurfaces: UINT;
    index, i: integer;
    uiEnqueuedSize: UINT;
    QueueEntry: PSharedSurfaceQueueEntry;
    pStagingResource: IUnknown;
begin
    if (m_IsMultithreaded) then
        m_lock.AcquireShared;

    Result := S_OK;
    uiFlushedSurfaces := 0;

    // Store this locally for the loop counter.  The loop will change the
    // value of m_nEnqueuedSurfaces.
    uiEnqueuedSize := m_nEnqueuedSurfaces;

    // Require both the producer and consumer to be initialized.
    // This avoids a potential race condition
    if (m_pProducer = nil) or (m_pConsumer = nil) then
        Result := E_INVALIDARG;

    if Result = S_OK then
    begin
        // Iterate over all queue entries starting at the head.
        index := m_iEnqueuedHead;
        for i := 0 to uiEnqueuedSize - 1 do
        begin
            index := index mod m_Desc.NumSurfaces;
            QueueEntry := @m_SurfaceQueue[index];

            // ASSERT(queueEntry.surface->state == SHARED_SURFACE_STATE_ENQUEUED);
            // ASSERT(queueEntry.surface->queue == this);
            // ASSERT(queueEntry.pStagingResource);

            pStagingResource := QueueEntry^.pStagingResource;

            // Attempt to lock the staging surface to see if the rendering
            // is complete.

            Result := m_pProducer.GetDevice().LockSurface(pStagingResource, Flags);
            if Result <> S_OK then
                Break;

            Result := m_pProducer.GetDevice().UnlockSurface(pStagingResource);
            ASSERT(SUCCEEDED(Result));

            // When the lock is complete, rendering is complete and the the surface is
            // ready for dequeue
            QueueEntry^.surface.state := SHARED_SURFACE_STATE_FLUSHED;
            QueueEntry^.pStagingResource := nil;

            Inc(uiFlushedSurfaces);

            // This is protected by the SurfaceProducer lock.
            Dec(m_nEnqueuedSurfaces);
            m_iEnqueuedHead := (m_iEnqueuedHead + 1) mod m_Desc.NumSurfaces;

            if (m_IsMultithreaded) then
                // Increment the semaphore count
                ReleaseSemaphore(m_hSemaphore, 1, nil)
            else
                Inc(m_nFlushedSurfaces);
            Inc(index);
        end;
    end;

    NumSurfaces := m_nEnqueuedSurfaces;

    if (m_IsMultithreaded) then
        m_lock.ReleaseShared;
end;

{ TSurfaceConsumer }

function TSurfaceConsumer.Dequeue(const id: TGUID; out ppSurface; pBuffer: Pointer; out pBufferSize: UINT; dwTimeout: dword): HResult; stdcall;
begin
    Result := S_OK;

    if (m_IsMultithreaded) then
        EnterCriticalSection(m_lock);

    // Validate that REFIID is correct for a surface from this device
    if (not m_pDevice.ValidateREFIID(id)) then
    begin
        Result := E_INVALIDARG;
    end;
    if Result = S_OK then
    begin
        Pointer(ppSurface) := nil;
        // Forward to queue
        Result := m_pQueue._Dequeue(ppSurface, pBuffer, pBufferSize, dwTimeout);
    end;

    if (m_IsMultithreaded) then
        LeaveCriticalSection(m_lock);
end;



constructor TSurfaceConsumer.Create(IsMultithreaded: boolean);
begin
    m_RefCount := 0;
    m_IsMultithreaded := IsMultithreaded;
    m_pQueue := nil;
    m_pDevice := nil;

    if (m_IsMultithreaded) then
        InitializeCriticalSection(m_lock);
end;



destructor TSurfaceConsumer.Destroy;
begin
    if (m_pQueue <> nil) then
    begin
        m_pQueue.RemoveConsumer();
        m_pQueue := nil;
    end;
    if (m_pDevice <> nil) then
        m_pDevice := nil;

    if (m_IsMultithreaded) then
        DeleteCriticalSection(m_lock);
    inherited Destroy;
end;



function TSurfaceConsumer.Initialize(pDevice: IUnknown): HResult;
begin
    Result := CreateDeviceWrapper(pDevice, m_pDevice);

    if Result <> S_OK then
    begin
        if (m_pDevice <> nil) then
            m_pDevice := nil;
    end;
end;



procedure TSurfaceConsumer.SetQueue(queue: TSurfaceQueue);
begin
    // ASSERT(!m_pQueue && queue);
    m_pQueue := queue;
end;



function TSurfaceConsumer.GetDevice: ISurfaceQueueDevice;
begin
    Result := m_pDevice;
end;

{ TSharedSurfaceQueueEntry }

procedure TSharedSurfaceQueueEntry.Init;
begin
    surface := nil;
    pMetaData := nil;
    bMetaDataSize := 0;
    pStagingResource := nil;
end;

end.
