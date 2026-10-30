/* =====================================================================
   OMSI Integration Ledger - reference design (part 1 of 4): tables
   Target database : LTInterforAux (middle layer)        SQL Server 2016+
   Schema          : integ
   Purpose         : system of record for business-entity lifecycle and
                     every integration unit of work (outbound + inbound),
                     with retry / dead-letter / reprocessing support.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF SCHEMA_ID(N'integ') IS NULL EXEC (N'CREATE SCHEMA integ AUTHORIZATION dbo;');
GO
IF SCHEMA_ID(N'omsi_adp') IS NULL EXEC (N'CREATE SCHEMA omsi_adp AUTHORIZATION dbo;');
GO

/* ---------------------------------------------------------------------
   A. CONTRACT / CONFIGURATION  (owned by integration team, edited by BAs)
   --------------------------------------------------------------------- */
CREATE TABLE integ.ContractVersion (
    TargetSystem    varchar(20)   NOT NULL,          -- OMSI, LT_API
    ContractVersion varchar(20)   NOT NULL,          -- e.g. OMSI 22.04
    EffectiveFrom   datetime2(0)  NOT NULL,
    EffectiveTo     datetime2(0)  NULL,
    Notes           nvarchar(500) NULL,
    CONSTRAINT PK_ContractVersion PRIMARY KEY (TargetSystem, ContractVersion)
);

-- One row per integration operation (outbound OMSI ops, inbound OMSI log ops, ERP API calls)
CREATE TABLE integ.OperationCatalog (
    OperationCode     int           NOT NULL,
    Direction         char(3)       NOT NULL CONSTRAINT CK_OpCat_Dir CHECK (Direction IN ('OUT','IN')),
    TargetSystem      varchar(20)   NOT NULL,
    Name              varchar(60)   NOT NULL,
    EntityType        varchar(30)   NOT NULL,
    ContractVersion   varchar(20)   NULL,
    AdapterProcedure  sysname       NULL,            -- proc that performs the hop
    DefaultPriority   tinyint       NOT NULL CONSTRAINT DF_OpCat_Pri DEFAULT (5),  -- 1 = highest
    -- Snapshot = payload is the full current state (newest revision makes older ones irrelevant)
    -- Event    = each message is a distinct business fact (must never be dropped)
    PayloadSemantics  varchar(10)   NOT NULL CONSTRAINT DF_OpCat_Sem DEFAULT ('Event')
        CONSTRAINT CK_OpCat_Sem CHECK (PayloadSemantics IN ('Snapshot','Event')),
    -- Which older, undelivered items of the same operation a newer one replaces
    SupersedeScope    varchar(20)   NOT NULL CONSTRAINT DF_OpCat_Sup DEFAULT ('None')
        CONSTRAINT CK_OpCat_Sup CHECK (SupersedeScope IN ('None','Unsent','UnsentAndDeadLetter')),
    -- If the entity's create was never delivered, send this snapshot AS that operation instead
    PromoteToOperationCode int      NULL,
    IsTerminal        bit           NOT NULL CONSTRAINT DF_OpCat_Term DEFAULT (0), -- e.g. cancel
    RequiresAck       bit           NOT NULL CONSTRAINT DF_OpCat_Ack DEFAULT (0),  -- async target (OMSI)
    IsActive          bit           NOT NULL CONSTRAINT DF_OpCat_Act DEFAULT (1),
    CONSTRAINT PK_OperationCatalog PRIMARY KEY (OperationCode),
    -- Only snapshots may replace or be promoted: an Event (payment, accrual) is never dropped
    CONSTRAINT CK_OpCat_SupersedeNeedsSnapshot CHECK (PayloadSemantics = 'Snapshot' OR (SupersedeScope = 'None' AND PromoteToOperationCode IS NULL)),
    CONSTRAINT FK_OpCat_Promote FOREIGN KEY (PromoteToOperationCode) REFERENCES integ.OperationCatalog (OperationCode)
);

-- Which outbound operation(s) a business event produces (fan-out capable)
CREATE TABLE integ.EventRoute (
    EventType      varchar(40) NOT NULL,
    OperationCode  int         NOT NULL CONSTRAINT FK_EventRoute_Op REFERENCES integ.OperationCatalog (OperationCode),
    IsActive       bit         NOT NULL CONSTRAINT DF_EventRoute_Act DEFAULT (1),
    CONSTRAINT PK_EventRoute PRIMARY KEY (EventType, OperationCode)
);

-- What an inbound message means for the business entity, and what it triggers next
CREATE TABLE integ.InboundRoute (
    SourceSystem       varchar(20) NOT NULL,
    MessageType        int         NOT NULL,           -- OMSI log_entry.operation code
    EntityType         varchar(30) NOT NULL,
    ResultingState     varchar(30) NULL,               -- lifecycle state to apply
    IsAcknowledgement  bit         NOT NULL CONSTRAINT DF_InRoute_Ack DEFAULT (0),
    FollowUpEventType  varchar(40) NULL,               -- e.g. FreightAccrualRequested
    IsActive           bit         NOT NULL CONSTRAINT DF_InRoute_Act DEFAULT (1),
    CONSTRAINT PK_InboundRoute PRIMARY KEY (SourceSystem, MessageType)
);

-- Expected lifecycle (state machine). Unexpected transitions are applied but flagged.
CREATE TABLE integ.LifecycleTransition (
    EntityType  varchar(30) NOT NULL,
    FromState   varchar(30) NOT NULL,                  -- '*' = any
    ToState     varchar(30) NOT NULL,
    CONSTRAINT PK_LifecycleTransition PRIMARY KEY (EntityType, FromState, ToState)
);

CREATE TABLE integ.LifecycleSla (
    EntityType        varchar(30) NOT NULL,
    State             varchar(30) NOT NULL,
    MaxMinutesInState int         NOT NULL,
    Severity          varchar(10) NOT NULL CONSTRAINT DF_LcSla_Sev DEFAULT ('Warning'),
    CONSTRAINT PK_LifecycleSla PRIMARY KEY (EntityType, State)
);

-- Code translation (fixes LB vs LBS style drift). Effective-dated.
CREATE TABLE integ.ValueMap (
    Domain        varchar(40)   NOT NULL,              -- WeightUOM, ShipVia->TransportMode ...
    SourceSystem  varchar(20)   NOT NULL,
    SourceValue   nvarchar(100) NOT NULL,
    TargetSystem  varchar(20)   NOT NULL,
    TargetValue   nvarchar(100) NOT NULL,
    EffectiveFrom date          NOT NULL CONSTRAINT DF_ValueMap_From DEFAULT ('19000101'),
    EffectiveTo   date          NULL,
    CONSTRAINT PK_ValueMap PRIMARY KEY (Domain, SourceSystem, SourceValue, TargetSystem, EffectiveFrom)
);

CREATE TABLE integ.RetryPolicy (
    RetryPolicyId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_RetryPolicy PRIMARY KEY,
    OperationCode     int          NULL,              -- NULL = default for all operations
    ErrorClass        varchar(20)  NOT NULL,
    MaxAttempts       int          NOT NULL,
    BaseDelaySeconds  int          NOT NULL,
    BackoffFactor     decimal(4,2) NOT NULL CONSTRAINT DF_Retry_Factor DEFAULT (2.0),
    MaxDelaySeconds   int          NOT NULL CONSTRAINT DF_Retry_MaxDelay DEFAULT (3600),
    CONSTRAINT UQ_RetryPolicy UNIQUE (OperationCode, ErrorClass)
);

-- Translates technical errors into business meaning + owner (for BAs / support)
CREATE TABLE integ.ErrorCatalog (
    ErrorCatalogId   int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErrorCatalog PRIMARY KEY,
    MatchOrder       int           NOT NULL,
    MatchErrorNumber int           NULL,
    MatchPattern     nvarchar(200) NULL,              -- LIKE pattern on message
    ErrorClass       varchar(20)   NOT NULL
        CONSTRAINT CK_ErrCat_Class CHECK (ErrorClass IN ('Transient','Data','Mapping','Contract','Auth','Duplicate','Unknown')),
    IsRetryable      bit           NOT NULL,
    BusinessMeaning  nvarchar(400) NOT NULL,
    ResolutionHint   nvarchar(400) NULL,
    OwnerTeam        nvarchar(60)  NULL
);

CREATE TABLE integ.SlaThreshold (
    OperationCode      int NOT NULL CONSTRAINT PK_SlaThreshold PRIMARY KEY
                           CONSTRAINT FK_Sla_Op REFERENCES integ.OperationCatalog (OperationCode),
    MaxPendingMinutes  int NOT NULL,                  -- created -> dispatched
    MaxAckMinutes      int NULL                       -- dispatched -> acknowledged (async targets)
);
GO

/* ---------------------------------------------------------------------
   B. BUSINESS ENTITY LIFECYCLE
   --------------------------------------------------------------------- */
CREATE TABLE integ.BusinessEntity (
    EntityId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BusinessEntity PRIMARY KEY,
    EntityType      varchar(30)   NOT NULL,           -- Shipment, CarrierInsurance, FreightInvoice
    SourceSystem    varchar(20)   NOT NULL,           -- LT
    SourceKey       nvarchar(100) NOT NULL,           -- shpnum, vendor|type ...
    CurrentState    varchar(30)   NOT NULL,
    StateChangedAt  datetime2(3)  NOT NULL,
    LastContentHash varbinary(32) NULL,               -- last outbound payload hash (no-op suppression)
    CreatedAt       datetime2(3)  NOT NULL CONSTRAINT DF_BE_Created DEFAULT (SYSDATETIME()),
    UpdatedAt       datetime2(3)  NOT NULL CONSTRAINT DF_BE_Updated DEFAULT (SYSDATETIME()),
    RowVer          rowversion    NOT NULL,
    CONSTRAINT UQ_BusinessEntity UNIQUE (EntityType, SourceSystem, SourceKey)
);
CREATE INDEX IX_BusinessEntity_State ON integ.BusinessEntity (EntityType, CurrentState, StateChangedAt);

CREATE TABLE integ.EntityStateHistory (
    StateHistoryId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_EntityStateHistory PRIMARY KEY,
    EntityId           bigint        NOT NULL CONSTRAINT FK_ESH_Entity REFERENCES integ.BusinessEntity (EntityId),
    FromState          varchar(30)   NULL,
    ToState            varchar(30)   NOT NULL,
    IsExpected         bit           NOT NULL,         -- 0 = transition not in LifecycleTransition
    TriggerKind        varchar(10)   NOT NULL CONSTRAINT CK_ESH_Kind CHECK (TriggerKind IN ('EVENT','INBOX','OPERATOR')),
    TriggerId          bigint        NULL,             -- EventId / InboxMessageId / OperatorActionId
    ChangedAt          datetime2(3)  NOT NULL CONSTRAINT DF_ESH_At DEFAULT (SYSDATETIME()),
    ChangedBy          nvarchar(128) NOT NULL CONSTRAINT DF_ESH_By DEFAULT (ORIGINAL_LOGIN())
);
CREATE INDEX IX_ESH_Entity ON integ.EntityStateHistory (EntityId, ChangedAt);
CREATE INDEX IX_ESH_Unexpected ON integ.EntityStateHistory (ChangedAt) WHERE IsExpected = 0;
GO

/* ---------------------------------------------------------------------
   C. OUTBOX  (immutable business events - "what happened")
   --------------------------------------------------------------------- */
CREATE TABLE integ.OutboxEvent (
    EventId             bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutboxEvent PRIMARY KEY,
    EventUid            uniqueidentifier NOT NULL CONSTRAINT DF_OE_Uid DEFAULT (NEWSEQUENTIALID()),
    EntityId            bigint        NOT NULL CONSTRAINT FK_OE_Entity REFERENCES integ.BusinessEntity (EntityId),
    EventType           varchar(40)   NOT NULL,       -- ShipmentReady, ShipmentModified, ShipmentCancelled ...
    SourceChangeVersion bigint        NULL,           -- CT/CDC version or shp_rev key (lineage)
    PayloadJson         nvarchar(max) NOT NULL CONSTRAINT CK_OE_Json CHECK (ISJSON(PayloadJson) = 1),
    PayloadHash         varbinary(32) NOT NULL,
    IdempotencyKey      nvarchar(200) NOT NULL,
    CorrelationId       uniqueidentifier NOT NULL,
    CreatedAt           datetime2(3)  NOT NULL CONSTRAINT DF_OE_Created DEFAULT (SYSDATETIME()),
    CreatedBy           nvarchar(128) NOT NULL CONSTRAINT DF_OE_By DEFAULT (ORIGINAL_LOGIN()),
    CONSTRAINT UQ_OutboxEvent_Idem UNIQUE (IdempotencyKey)
);
CREATE INDEX IX_OE_Entity ON integ.OutboxEvent (EntityId, EventId);
GO

/* ---------------------------------------------------------------------
   D. INBOX  (every inbound message exactly once - "what we were told")
   --------------------------------------------------------------------- */
CREATE TABLE integ.InboxMessage (
    InboxMessageId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InboxMessage PRIMARY KEY,
    SourceSystem       varchar(20)   NOT NULL,
    SourceMessageId    nvarchar(100) NOT NULL,         -- OMSI log_entry_id, API callback id
    MessageType        int           NOT NULL,
    EntityId           bigint        NULL CONSTRAINT FK_IM_Entity REFERENCES integ.BusinessEntity (EntityId),
    CorrelationRef     nvarchar(100) NULL,             -- OMSI operation_id it answers
    PayloadJson        nvarchar(max) NULL,
    ResultCode         int           NULL,
    ResultMessage      nvarchar(4000) NULL,
    Status             varchar(12)   NOT NULL CONSTRAINT DF_IM_Status DEFAULT ('Received')
        CONSTRAINT CK_IM_Status CHECK (Status IN ('Received','Processed','Ignored','Failed')),
    ProcessAttempts    int           NOT NULL CONSTRAINT DF_IM_Att DEFAULT (0),
    ProcessingError    nvarchar(4000) NULL,
    ReceivedAt         datetime2(3)  NOT NULL CONSTRAINT DF_IM_Recv DEFAULT (SYSDATETIME()),
    ProcessedAt        datetime2(3)  NULL,
    CONSTRAINT UQ_InboxMessage UNIQUE (SourceSystem, SourceMessageId)
);
CREATE INDEX IX_IM_Open ON integ.InboxMessage (Status, ReceivedAt) WHERE Status IN ('Received','Failed');

CREATE TABLE integ.HarvestWatermark (
    SourceName  varchar(60)    NOT NULL CONSTRAINT PK_HarvestWatermark PRIMARY KEY,
    LastValue   decimal(20,0)  NOT NULL,
    UpdatedAt   datetime2(3)   NOT NULL CONSTRAINT DF_HW_At DEFAULT (SYSDATETIME())
);
GO

/* ---------------------------------------------------------------------
   E. WORK QUEUE + ATTEMPT LOG  ("how we delivered it" - retryable)
   --------------------------------------------------------------------- */
CREATE TABLE integ.ProcessRun (
    RunId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProcessRun PRIMARY KEY,
    ProcessName    nvarchar(128) NOT NULL,             -- SSIS package / job / service
    HostName       nvarchar(128) NOT NULL CONSTRAINT DF_PR_Host DEFAULT (HOST_NAME()),
    StartedAt      datetime2(3)  NOT NULL CONSTRAINT DF_PR_Start DEFAULT (SYSDATETIME()),
    HeartbeatAt    datetime2(3)  NOT NULL CONSTRAINT DF_PR_Hb DEFAULT (SYSDATETIME()),
    EndedAt        datetime2(3)  NULL,
    Status         varchar(10)   NOT NULL CONSTRAINT DF_PR_Status DEFAULT ('Running')
        CONSTRAINT CK_PR_Status CHECK (Status IN ('Running','Succeeded','Failed','Abandoned')),
    ItemsClaimed   int NOT NULL CONSTRAINT DF_PR_Cl DEFAULT (0),
    ItemsSucceeded int NOT NULL CONSTRAINT DF_PR_Ok DEFAULT (0),
    ItemsFailed    int NOT NULL CONSTRAINT DF_PR_Fail DEFAULT (0),
    Message        nvarchar(4000) NULL
);
CREATE INDEX IX_PR_Name ON integ.ProcessRun (ProcessName, StartedAt DESC);

CREATE TABLE integ.WorkItem (
    WorkItemId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkItem PRIMARY KEY,
    EventId           bigint        NULL CONSTRAINT FK_WI_Event REFERENCES integ.OutboxEvent (EventId),
    InboxMessageId    bigint        NULL CONSTRAINT FK_WI_Inbox REFERENCES integ.InboxMessage (InboxMessageId),
    ParentWorkItemId  bigint        NULL CONSTRAINT FK_WI_Parent REFERENCES integ.WorkItem (WorkItemId),
    SupersededById    bigint        NULL CONSTRAINT FK_WI_Super REFERENCES integ.WorkItem (WorkItemId),
    OperationCode     int           NOT NULL CONSTRAINT FK_WI_Op REFERENCES integ.OperationCatalog (OperationCode),
    TargetSystem      varchar(20)   NOT NULL,
    OrderingKey       nvarchar(100) NOT NULL,          -- FIFO per business entity (e.g. SHP:4171753)
    Priority          tinyint       NOT NULL,
    Status            varchar(12)   NOT NULL CONSTRAINT DF_WI_Status DEFAULT ('Pending')
        CONSTRAINT CK_WI_Status CHECK (Status IN
            ('Pending','Leased','RetryWait','Dispatched','Succeeded','DeadLetter','Superseded','Cancelled')),
    StatusReason      nvarchar(400) NULL,
    AttemptCount      int           NOT NULL CONSTRAINT DF_WI_Att DEFAULT (0),
    NextAttemptAt     datetime2(3)  NOT NULL CONSTRAINT DF_WI_Next DEFAULT (SYSDATETIME()),
    LeaseOwner        nvarchar(128) NULL,
    LeaseExpiresAt    datetime2(3)  NULL,
    ExternalRef       nvarchar(100) NULL,              -- OMSI operation_id / ERP API transaction id
    IdempotencyKey    nvarchar(200) NOT NULL,          -- sent to target; target must reject repeats
    LastErrorClass    varchar(20)   NULL,
    LastErrorMessage  nvarchar(4000) NULL,
    LastErrorCatalogId int          NULL CONSTRAINT FK_WI_ErrCat REFERENCES integ.ErrorCatalog (ErrorCatalogId),
    CreatedAt         datetime2(3)  NOT NULL CONSTRAINT DF_WI_Created DEFAULT (SYSDATETIME()),
    DispatchedAt      datetime2(3)  NULL,
    CompletedAt       datetime2(3)  NULL,
    RowVer            rowversion    NOT NULL,
    CONSTRAINT UQ_WorkItem_Idem UNIQUE (IdempotencyKey),
    CONSTRAINT CK_WI_Source CHECK (EventId IS NOT NULL OR InboxMessageId IS NOT NULL)
);
-- Claim path: only open rows are indexed, so the index stays tiny regardless of history volume
CREATE INDEX IX_WI_Claim ON integ.WorkItem (Priority, NextAttemptAt, WorkItemId)
    INCLUDE (Status, OperationCode, OrderingKey, TargetSystem, LeaseExpiresAt)
    WHERE Status IN ('Pending','RetryWait','Leased');
CREATE INDEX IX_WI_Ordering ON integ.WorkItem (OrderingKey, TargetSystem, WorkItemId)
    INCLUDE (Status)
    WHERE Status IN ('Pending','Leased','RetryWait','DeadLetter');
CREATE INDEX IX_WI_ExternalRef ON integ.WorkItem (TargetSystem, ExternalRef) WHERE ExternalRef IS NOT NULL;
CREATE INDEX IX_WI_AwaitAck ON integ.WorkItem (DispatchedAt) INCLUDE (OperationCode, ExternalRef) WHERE Status = 'Dispatched';
CREATE INDEX IX_WI_Event ON integ.WorkItem (EventId);

CREATE TABLE integ.WorkItemAttempt (
    AttemptId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkItemAttempt PRIMARY KEY,
    WorkItemId       bigint        NOT NULL CONSTRAINT FK_WIA_WI REFERENCES integ.WorkItem (WorkItemId),
    AttemptNo        int           NOT NULL,
    RunId            bigint        NULL CONSTRAINT FK_WIA_Run REFERENCES integ.ProcessRun (RunId),
    LeaseOwner       nvarchar(128) NOT NULL,
    StartedAt        datetime2(3)  NOT NULL CONSTRAINT DF_WIA_Start DEFAULT (SYSDATETIME()),
    EndedAt          datetime2(3)  NULL,
    Outcome          varchar(12)   NULL CONSTRAINT CK_WIA_Out CHECK (Outcome IN ('Succeeded','Dispatched','Failed','Abandoned')),
    ErrorClass       varchar(20)   NULL,
    ErrorNumber      int           NULL,
    ErrorProcedure   nvarchar(128) NULL,
    ErrorLine        int           NULL,
    ErrorMessage     nvarchar(4000) NULL,
    RequestSnapshot  nvarchar(max) NULL,               -- e.g. API request body (masked)
    ResponseSnapshot nvarchar(max) NULL,
    CONSTRAINT UQ_WIA UNIQUE (WorkItemId, AttemptNo)
);
CREATE INDEX IX_WIA_Failed ON integ.WorkItemAttempt (StartedAt) INCLUDE (WorkItemId, ErrorClass) WHERE Outcome = 'Failed';

CREATE TABLE integ.OperatorAction (
    OperatorActionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperatorAction PRIMARY KEY,
    WorkItemId       bigint        NOT NULL CONSTRAINT FK_OA_WI REFERENCES integ.WorkItem (WorkItemId),
    Action           varchar(20)   NOT NULL CONSTRAINT CK_OA_Action CHECK (Action IN ('Retry','Cancel','Replay','ForceComplete')),
    Reason           nvarchar(400) NOT NULL,
    RequestedBy      nvarchar(128) NOT NULL CONSTRAINT DF_OA_By DEFAULT (ORIGINAL_LOGIN()),
    RequestedAt      datetime2(3)  NOT NULL CONSTRAINT DF_OA_At DEFAULT (SYSDATETIME()),
    ResultWorkItemId bigint        NULL
);
GO

/* ---------------------------------------------------------------------
   F. MONITORING
   --------------------------------------------------------------------- */
CREATE TABLE integ.Alert (
    AlertId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Alert PRIMARY KEY,
    AlertKey     nvarchar(200) NOT NULL,              -- dedup key, e.g. DEADLETTER:WI:123
    Category     varchar(30)   NOT NULL,
    Severity     varchar(10)   NOT NULL CONSTRAINT CK_Alert_Sev CHECK (Severity IN ('Info','Warning','Critical')),
    Message      nvarchar(2000) NOT NULL,
    FirstSeenAt  datetime2(3)  NOT NULL CONSTRAINT DF_Alert_First DEFAULT (SYSDATETIME()),
    LastSeenAt   datetime2(3)  NOT NULL CONSTRAINT DF_Alert_Last DEFAULT (SYSDATETIME()),
    Occurrences  int           NOT NULL CONSTRAINT DF_Alert_Occ DEFAULT (1),
    NotifiedAt   datetime2(3)  NULL,
    ResolvedAt   datetime2(3)  NULL
);
CREATE UNIQUE INDEX UX_Alert_Open ON integ.Alert (AlertKey) WHERE ResolvedAt IS NULL;

CREATE TABLE integ.BacklogSnapshot (
    SnapshotAt        datetime2(0) NOT NULL,
    TargetSystem      varchar(20)  NOT NULL,
    OperationCode     int          NOT NULL,
    Status            varchar(12)  NOT NULL,
    ItemCount         int          NOT NULL,
    OldestAgeMinutes  int          NULL,
    CONSTRAINT PK_BacklogSnapshot PRIMARY KEY (SnapshotAt, TargetSystem, OperationCode, Status)
);
GO
