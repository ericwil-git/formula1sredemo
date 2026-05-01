-- =============================================================================
-- F1 SRE Demo — schema for the f1demo database (Azure SQL Managed Instance).
-- Matches docs/techspec.md §4. Run against an empty database.
--
-- Usage (from sqlcmd against the MI private endpoint):
--   sqlcmd -S <mi-name>.<dns-zone>.database.windows.net -U f1adm -P <pwd> \
--          -d master -i db/schema.sql
-- =============================================================================

IF DB_ID(N'f1demo') IS NULL
BEGIN
    CREATE DATABASE f1demo;
END;
GO

USE f1demo;
GO

-- -----------------------------------------------------------------------------
-- Drop in reverse-FK order to allow re-running the script during dev.
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.RaceResults', 'U') IS NOT NULL DROP TABLE dbo.RaceResults;
IF OBJECT_ID(N'dbo.QualiResults', 'U') IS NOT NULL DROP TABLE dbo.QualiResults;
IF OBJECT_ID(N'dbo.Telemetry',    'U') IS NOT NULL DROP TABLE dbo.Telemetry;
IF OBJECT_ID(N'dbo.Laps',         'U') IS NOT NULL DROP TABLE dbo.Laps;
IF OBJECT_ID(N'dbo.Drivers',      'U') IS NOT NULL DROP TABLE dbo.Drivers;
IF OBJECT_ID(N'dbo.Sessions',     'U') IS NOT NULL DROP TABLE dbo.Sessions;
IF OBJECT_ID(N'dbo.Events',       'U') IS NOT NULL DROP TABLE dbo.Events;
IF OBJECT_ID(N'dbo.Seasons',      'U') IS NOT NULL DROP TABLE dbo.Seasons;
GO

-- -----------------------------------------------------------------------------
-- Seasons
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Seasons (
    SeasonId    INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_Seasons PRIMARY KEY,
    [Year]      INT             NOT NULL,
    [Name]      NVARCHAR(64)    NOT NULL,
    CONSTRAINT UQ_Seasons_Year UNIQUE ([Year])
);
GO

-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Events (
    EventId     INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_Events PRIMARY KEY,
    SeasonId    INT             NOT NULL,
    Round       INT             NOT NULL,
    Country     NVARCHAR(64)    NOT NULL,
    Location    NVARCHAR(128)   NOT NULL,
    EventName   NVARCHAR(128)   NOT NULL,
    EventDate   DATE            NOT NULL,
    CONSTRAINT FK_Events_Seasons FOREIGN KEY (SeasonId) REFERENCES dbo.Seasons(SeasonId),
    CONSTRAINT UQ_Events_Season_Round UNIQUE (SeasonId, Round)
);
GO

-- -----------------------------------------------------------------------------
-- Sessions  (FP1/FP2/FP3/Q/Sprint/R)
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Sessions (
    SessionId       INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_Sessions PRIMARY KEY,
    EventId         INT             NOT NULL,
    SessionType     NVARCHAR(8)     NOT NULL,
    StartTimeUtc    DATETIME2(0)    NOT NULL,
    TotalLaps       INT             NULL,
    CONSTRAINT FK_Sessions_Events FOREIGN KEY (EventId) REFERENCES dbo.Events(EventId),
    CONSTRAINT CK_Sessions_Type CHECK (SessionType IN ('FP1','FP2','FP3','Q','Sprint','R'))
);
GO

-- -----------------------------------------------------------------------------
-- Drivers
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Drivers (
    DriverId    INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_Drivers PRIMARY KEY,
    Code        NVARCHAR(8)     NOT NULL,    -- e.g. VER, LEC
    FullName    NVARCHAR(128)   NOT NULL,
    TeamName    NVARCHAR(128)   NOT NULL,
    SeasonId    INT             NOT NULL,
    CONSTRAINT FK_Drivers_Seasons FOREIGN KEY (SeasonId) REFERENCES dbo.Seasons(SeasonId),
    CONSTRAINT UQ_Drivers_Code_Season UNIQUE (SeasonId, Code)
);
GO

-- -----------------------------------------------------------------------------
-- Laps
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Laps (
    LapId           BIGINT          NOT NULL IDENTITY(1,1) CONSTRAINT PK_Laps PRIMARY KEY,
    SessionId       INT             NOT NULL,
    DriverId        INT             NOT NULL,
    LapNumber       INT             NOT NULL,
    LapTimeMs       INT             NULL,
    Sector1Ms       INT             NULL,
    Sector2Ms       INT             NULL,
    Sector3Ms       INT             NULL,
    Compound        NVARCHAR(16)    NULL,
    TyreLife        INT             NULL,
    Position        INT             NULL,
    IsPersonalBest  BIT             NOT NULL CONSTRAINT DF_Laps_IsPB DEFAULT(0),
    CONSTRAINT FK_Laps_Sessions FOREIGN KEY (SessionId) REFERENCES dbo.Sessions(SessionId),
    CONSTRAINT FK_Laps_Drivers  FOREIGN KEY (DriverId)  REFERENCES dbo.Drivers(DriverId)
);
GO

-- -----------------------------------------------------------------------------
-- Telemetry
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Telemetry (
    TelemetryId     BIGINT          NOT NULL IDENTITY(1,1) CONSTRAINT PK_Telemetry PRIMARY KEY,
    LapId           BIGINT          NOT NULL,
    SampleTimeMs    INT             NOT NULL,
    SpeedKph        SMALLINT        NULL,
    RPM             INT             NULL,
    Throttle        TINYINT         NULL,    -- 0..100
    Brake           BIT             NULL,
    Gear            TINYINT         NULL,
    DRS             TINYINT         NULL,
    CONSTRAINT FK_Telemetry_Laps FOREIGN KEY (LapId) REFERENCES dbo.Laps(LapId)
);
GO

-- -----------------------------------------------------------------------------
-- QualiResults
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.QualiResults (
    SessionId   INT             NOT NULL,
    DriverId    INT             NOT NULL,
    Position    INT             NULL,
    Q1Ms        INT             NULL,
    Q2Ms        INT             NULL,
    Q3Ms        INT             NULL,
    CONSTRAINT PK_QualiResults PRIMARY KEY (SessionId, DriverId),
    CONSTRAINT FK_Quali_Sessions FOREIGN KEY (SessionId) REFERENCES dbo.Sessions(SessionId),
    CONSTRAINT FK_Quali_Drivers  FOREIGN KEY (DriverId)  REFERENCES dbo.Drivers(DriverId)
);
GO

-- -----------------------------------------------------------------------------
-- RaceResults
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.RaceResults (
    SessionId       INT             NOT NULL,
    DriverId        INT             NOT NULL,
    Position        INT             NULL,
    GridPosition    INT             NULL,
    [Status]        NVARCHAR(64)    NULL,
    Points          DECIMAL(5,2)    NULL,
    FastestLapMs    INT             NULL,
    CONSTRAINT PK_RaceResults PRIMARY KEY (SessionId, DriverId),
    CONSTRAINT FK_Race_Sessions FOREIGN KEY (SessionId) REFERENCES dbo.Sessions(SessionId),
    CONSTRAINT FK_Race_Drivers  FOREIGN KEY (DriverId)  REFERENCES dbo.Drivers(DriverId)
);
GO

-- -----------------------------------------------------------------------------
-- Indexes (per techspec §4)
-- -----------------------------------------------------------------------------
CREATE INDEX IX_Laps_Session_Driver_Lap ON dbo.Laps (SessionId, DriverId, LapNumber);
CREATE INDEX IX_Telemetry_Lap_Time      ON dbo.Telemetry (LapId, SampleTimeMs);
CREATE INDEX IX_Sessions_Event_Type     ON dbo.Sessions (EventId, SessionType);
GO
