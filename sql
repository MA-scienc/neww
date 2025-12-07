-- 1. Create a new database
CREATE DATABASE UnderwritingJsonProto;
GO

-- 2. Switch to this database
USE UnderwritingJsonProto;
GO

-- 3. Create a schema named "underwriting"
CREATE SCHEMA underwriting;
GO

-- 4. Create a table with the new JSON data type
CREATE TABLE underwriting.ConvrPayloadJsonProto
(
    ID            INT IDENTITY(1,1) PRIMARY KEY,
    SubmissionID  NVARCHAR(50) NOT NULL,
    PayloadJson   JSON NOT NULL
);
GO

---------

INSERT INTO underwriting.ConvrPayloadJsonProto (SubmissionID, PayloadJson)
SELECT 'A12345', BulkColumn
FROM OPENROWSET(BULK '/json_samples/payload1.json', SINGLE_CLOB) AS j;

