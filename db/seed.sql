-- =============================================================================
-- F1 SRE Demo — placeholder seed data.
-- Real data is loaded by the Python ingestion service (see /src/ingestion).
-- This file inserts a single Season + Event so the schema can be smoke-tested.
-- =============================================================================

USE f1demo;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Seasons WHERE [Year] = 2024)
BEGIN
    INSERT INTO dbo.Seasons ([Year], [Name]) VALUES (2024, '2024 FIA Formula One World Championship');
END;
GO

DECLARE @seasonId INT = (SELECT SeasonId FROM dbo.Seasons WHERE [Year] = 2024);

IF NOT EXISTS (SELECT 1 FROM dbo.Events WHERE SeasonId = @seasonId AND Round = 8)
BEGIN
    INSERT INTO dbo.Events (SeasonId, Round, Country, Location, EventName, EventDate)
    VALUES (@seasonId, 8, 'Monaco', 'Monte Carlo', 'Monaco Grand Prix', '2024-05-26');
END;
GO
