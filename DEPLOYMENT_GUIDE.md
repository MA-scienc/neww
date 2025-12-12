SUBMISSION_OVERVIEW_SQL = """
SELECT
    b.Name AS BrokerName,
    s.SubmissionReceivedDate,
    s.SparkSubmissionId,
    s.AccountNumber AS AccountId,
    lob.InsuranceAppliedFor,
    providers.ProviderNames AS ThirdPartyEnrichment
FROM Underwriting.Submissions s
LEFT JOIN Underwriting.Brokers b
    ON b.Id = s.BrokerId
OUTER APPLY (
    SELECT TOP (1)
        cp_inner.OriginalConvrPayloadJson
    FROM Underwriting.ConvrPayloads cp_inner
    WHERE cp_inner.SubmissionId = s.Id
    ORDER BY
        cp_inner.ProcessedAtUtc DESC,
        cp_inner.ReceivedAtUtc DESC,
        cp_inner.CreatedAt DESC
) cp
OUTER APPLY (
    SELECT
        STRING_AGG(lob_entries.Lob, ', ')
            WITHIN GROUP (ORDER BY lob_entries.Lob) AS InsuranceAppliedFor
    FROM OPENJSON(
        cp.OriginalConvrPayloadJson,
        '$.d3Submission.d3LineOfBusiness'
    )
    WITH (
        Lob NVARCHAR(200) '$.lob'
    ) AS lob_entries
) lob
OUTER APPLY (
    SELECT
        STRING_AGG(tpd.ProviderName, ', ')
            WITHIN GROUP (ORDER BY tpd.ProviderName) AS ProviderNames
    FROM thirdpartydata.ThirdPartyDataRecords tpd
    WHERE
        tpd.SubmissionId = s.Id
        AND (tpd.IsActive IS NULL OR tpd.IsActive = 1)
) providers
WHERE s.Id = ?;
"""
