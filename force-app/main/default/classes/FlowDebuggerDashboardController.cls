/**
 * FlowDebuggerDashboardController
 *
 * Provides all data methods for the flowDebuggerDashboard LWC.
 * Aggregates Flow_Error_Log__c records by flow, enriches with
 * analysis data, and returns dashboard summaries and metrics.
 */
public with sharing class FlowDebuggerDashboardController {

    // ── Wrapper Classes ──

    public class DashboardData {
        @AuraEnabled public Integer totalErrors24h;
        @AuraEnabled public Integer criticalFlowsCount;
        @AuraEnabled public Integer aiAnalyzedCount;
        @AuraEnabled public String avgResolutionTime;
        @AuraEnabled public Integer errorsTrendPercent;
    }

    public class AggregatedError {
        @AuraEnabled public Id id;
        @AuraEnabled public String flowName;
        @AuraEnabled public Integer errorCount;
        @AuraEnabled public String status;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String latestErrorMessage;
        @AuraEnabled public DateTime latestTimestamp;
        @AuraEnabled public String severity;
        @AuraEnabled public Boolean isCritical;
        @AuraEnabled public Boolean isAnalyzed;
        @AuraEnabled public String rootCause;
        @AuraEnabled public String immediateAction;
        @AuraEnabled public String fixSteps;
        @AuraEnabled public Decimal confidenceScore;
    }

    public class DebuggerConfig {
        @AuraEnabled public Boolean isPlatformEventsEnabled;
    }

    public class MetricsSummary {
        @AuraEnabled public List<FlowErrorMetric> topErrorFlows;
    }

    public class FlowErrorMetric {
        @AuraEnabled public String name;
        @AuraEnabled public Integer errorCount;
    }

    // ── Dashboard Summary Cards ──

    @AuraEnabled(cacheable=true)
    public static DashboardData getDashboardData() {
        DashboardData data = new DashboardData();
        DateTime last24h = System.now().addHours(-24);
        DateTime prior24h = System.now().addHours(-48);

        // Total errors in last 24h
        data.totalErrors24h = [
            SELECT COUNT()
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :last24h
        ];

        // Critical flows count (distinct flows with Critical severity)
        List<AggregateResult> criticalFlows = [
            SELECT Flow_API_Name__c
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :last24h
            AND Severity__c = 'Critical'
            GROUP BY Flow_API_Name__c
        ];
        data.criticalFlowsCount = criticalFlows.size();

        // AI analyzed count
        data.aiAnalyzedCount = [
            SELECT COUNT()
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :last24h
            AND AI_Analysis_Complete__c = true
        ];

        // Average resolution time
        List<AggregateResult> avgRes = [
            SELECT AVG(Resolution_Time_Minutes__c) avgMin
            FROM Flow_Error_Log__c
            WHERE Resolution_Time_Minutes__c != null
            AND Error_Timestamp__c >= :last24h
        ];
        Decimal avgMinutes = avgRes.isEmpty() ? 0 : (Decimal) avgRes[0].get('avgMin');
        if (avgMinutes == null) avgMinutes = 0;
        if (avgMinutes < 60) {
            data.avgResolutionTime = avgMinutes.intValue() + 'm';
        } else {
            data.avgResolutionTime = (avgMinutes / 60).intValue() + 'h ' + Math.mod(avgMinutes.intValue(), 60) + 'm';
        }

        // Trend: compare last 24h vs prior 24h
        Integer priorCount = [
            SELECT COUNT()
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :prior24h
            AND Error_Timestamp__c < :last24h
        ];
        if (priorCount > 0) {
            data.errorsTrendPercent = ((data.totalErrors24h - priorCount) * 100) / priorCount;
        } else if (data.totalErrors24h > 0) {
            data.errorsTrendPercent = 100;
        } else {
            data.errorsTrendPercent = 0;
        }

        return data;
    }

    // ── Aggregated Errors (main table) ──

    @AuraEnabled(cacheable=true)
    public static List<AggregatedError> getAggregatedErrors(
        String timeRangeFilter,
        String severityFilter,
        String searchTerm
    ) {
        // Build time range
        DateTime since;
        if (timeRangeFilter == '24h') {
            since = System.now().addHours(-24);
        } else if (timeRangeFilter == '7d') {
            since = System.now().addDays(-7);
        } else if (timeRangeFilter == '30d') {
            since = System.now().addDays(-30);
        } else {
            since = DateTime.newInstance(2000, 1, 1);
        }

        // Build dynamic query — exclude Resolved errors from the active table
        String query = 'SELECT Id, Flow_API_Name__c, Flow_Label__c, Element_API_Name__c, '
            + 'Error_Message__c, Error_Timestamp__c, Severity__c, Status__c, '
            + 'AI_Analysis_Complete__c, User__c, User__r.Name '
            + 'FROM Flow_Error_Log__c '
            + 'WHERE Error_Timestamp__c >= :since'
            + ' AND Status__c != \'Resolved\'';

        if (String.isNotBlank(severityFilter) && severityFilter != 'All') {
            query += ' AND Severity__c = :severityFilter';
        }

        if (String.isNotBlank(searchTerm)) {
            String searchWild = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            query += ' AND (Flow_API_Name__c LIKE :searchWild OR Flow_Label__c LIKE :searchWild OR Error_Message__c LIKE :searchWild)';
        }

        query += ' ORDER BY Error_Timestamp__c DESC LIMIT 2000';

        String searchWild = String.isNotBlank(searchTerm) ? '%' + String.escapeSingleQuotes(searchTerm) + '%' : null;
        List<Flow_Error_Log__c> allErrors = Database.query(query);

        if (allErrors.isEmpty()) {
            return new List<AggregatedError>();
        }

        // Group by Flow_API_Name__c, pick the latest error per flow
        Map<String, List<Flow_Error_Log__c>> groupedMap = new Map<String, List<Flow_Error_Log__c>>();
        for (Flow_Error_Log__c err : allErrors) {
            String key = err.Flow_API_Name__c;
            if (!groupedMap.containsKey(key)) {
                groupedMap.put(key, new List<Flow_Error_Log__c>());
            }
            groupedMap.get(key).add(err);
        }

        // Collect IDs for analysis lookup
        Set<Id> latestIds = new Set<Id>();
        Map<String, Flow_Error_Log__c> latestByFlow = new Map<String, Flow_Error_Log__c>();
        for (String flowKey : groupedMap.keySet()) {
            Flow_Error_Log__c latest = groupedMap.get(flowKey)[0]; // already sorted DESC
            latestByFlow.put(flowKey, latest);
            latestIds.add(latest.Id);
        }

        // Fetch analysis for latest errors
        Map<Id, Flow_Error_Analysis__c> analysisMap = new Map<Id, Flow_Error_Analysis__c>();
        for (Flow_Error_Analysis__c a : [
            SELECT Flow_Error_Log__c, Root_Cause__c, Immediate_Action__c,
                   Fix_Steps__c, Confidence_Score__c
            FROM Flow_Error_Analysis__c
            WHERE Flow_Error_Log__c IN :latestIds
        ]) {
            analysisMap.put(a.Flow_Error_Log__c, a);
        }

        // Build aggregated results
        List<AggregatedError> results = new List<AggregatedError>();
        for (String flowKey : groupedMap.keySet()) {
            List<Flow_Error_Log__c> errors = groupedMap.get(flowKey);
            Flow_Error_Log__c latest = latestByFlow.get(flowKey);
            Flow_Error_Analysis__c analysis = analysisMap.get(latest.Id);

            AggregatedError agg = new AggregatedError();
            agg.id = latest.Id;
            agg.flowName = String.isNotBlank(latest.Flow_Label__c) ? latest.Flow_Label__c : latest.Flow_API_Name__c;
            agg.errorCount = errors.size();
            agg.status = latest.Status__c;
            agg.ownerId = latest.User__c;
            agg.ownerName = latest.User__r != null ? latest.User__r.Name : '';
            agg.latestErrorMessage = latest.Error_Message__c;
            agg.latestTimestamp = latest.Error_Timestamp__c;
            agg.severity = latest.Severity__c;
            agg.isCritical = latest.Severity__c == 'Critical';
            agg.isAnalyzed = latest.AI_Analysis_Complete__c;

            if (analysis != null) {
                agg.rootCause = analysis.Root_Cause__c;
                agg.immediateAction = analysis.Immediate_Action__c;
                agg.fixSteps = analysis.Fix_Steps__c;
                agg.confidenceScore = analysis.Confidence_Score__c;
            } else {
                agg.rootCause = 'Not yet analyzed.';
                agg.immediateAction = 'Run AI Analysis to generate recommendations.';
                agg.fixSteps = '';
                agg.confidenceScore = 0;
            }

            results.add(agg);
        }

        // Sort by error count descending
        results.sort(new AggregatedErrorComparator());
        return results;
    }

    /**
     * Comparator to sort aggregated errors by count descending.
     */
    private class AggregatedErrorComparator implements Comparator<AggregatedError> {
        public Integer compare(AggregatedError a, AggregatedError b) {
            return b.errorCount - a.errorCount;
        }
    }

    // ── Ad-Hoc Analysis ──

    @AuraEnabled
    public static String runAdHocAnalysis() {
        List<String> messages = new List<String>();
        Integer newErrorsCreated = 0;

        // Step 1: Try to poll for failed flow interviews (best-effort)
        try {
            newErrorsCreated = pollAndCreateErrorLogs();
            if (newErrorsCreated > 0) {
                messages.add(newErrorsCreated + ' new error(s) captured from Flow Interviews.');
            }
        } catch (Exception e) {
            messages.add('Interview poll: ' + e.getMessage());
        }

        // Step 2: Count total active (non-resolved) error logs
        Integer totalErrors = [SELECT COUNT() FROM Flow_Error_Log__c WHERE Status__c != 'Resolved'];

        // Step 3: Trigger AI analysis on any unanalyzed error logs
        List<Flow_Error_Log__c> unanalyzed = [
            SELECT Id
            FROM Flow_Error_Log__c
            WHERE AI_Analysis_Complete__c = false
            ORDER BY Error_Timestamp__c DESC
            LIMIT 50
        ];

        if (!unanalyzed.isEmpty()) {
            Set<Id> ids = new Set<Id>();
            for (Flow_Error_Log__c log : unanalyzed) {
                ids.add(log.Id);
            }
            FlowErrorAnalysisService.performAIAnalysisAsync(ids);
            messages.add(unanalyzed.size() + ' queued for AI analysis.');
        }

        // Build summary message
        String msg = totalErrors + ' active error(s) found.';
        if (!messages.isEmpty()) {
            msg += ' ' + String.join(messages, ' ');
        }
        return msg;
    }

    /**
     * Polls for failed FlowInterviews using standard SOQL (no Tooling API / HTTP).
     * Creates Flow_Error_Log__c records for any new failures found.
     * Returns the number of new error logs created.
     */
    private static Integer pollAndCreateErrorLogs() {
        DateTime since = System.now().addHours(-24);

        // Query failed flow interviews via standard SOQL
        List<FlowInterview> failedInterviews;
        try {
            failedInterviews = [
                SELECT Id, InterviewLabel, CurrentElement, InterviewStatus,
                       CreatedDate, CreatedById
                FROM FlowInterview
                WHERE InterviewStatus = 'Error'
                AND CreatedDate >= :since
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'FlowInterview query failed: ' + e.getMessage());
            return 0;
        }

        if (failedInterviews.isEmpty()) {
            return 0;
        }

        // Get existing interview GUIDs to avoid duplicates
        Set<String> existingGuids = new Set<String>();
        for (Flow_Error_Log__c existing : [
            SELECT Interview_GUID__c FROM Flow_Error_Log__c
            WHERE Interview_GUID__c != null
            AND Error_Timestamp__c >= :since
        ]) {
            existingGuids.add(existing.Interview_GUID__c);
        }

        // Get flow labels from FlowDefinitionView
        // FlowDefinitionView does not support queryMore(), max batch size ~200
        Map<String, String> flowLabelMap = new Map<String, String>();
        for (FlowDefinitionView fdv : [
            SELECT ApiName, Label
            FROM FlowDefinitionView
            WHERE IsActive = true
            LIMIT 200
        ]) {
            flowLabelMap.put(fdv.ApiName, fdv.Label);
        }

        List<Flow_Error_Log__c> newLogs = new List<Flow_Error_Log__c>();

        for (FlowInterview fi : failedInterviews) {
            String guid = fi.Id;

            // Skip duplicates
            if (existingGuids.contains(guid)) {
                continue;
            }

            // Extract flow developer name from interview label
            // Interview label format is typically: "FlowLabel MM/DD/YYYY, HH:MM AM/PM"
            String flowApiName = extractFlowApiName(fi.InterviewLabel, flowLabelMap);
            String flowLabel = flowLabelMap.containsKey(flowApiName)
                ? flowLabelMap.get(flowApiName) : fi.InterviewLabel;

            Flow_Error_Log__c log = new Flow_Error_Log__c(
                Flow_API_Name__c = flowApiName,
                Flow_Label__c = flowLabel,
                Element_API_Name__c = fi.CurrentElement,
                Error_Message__c = 'FLOW_ELEMENT_ERROR An unhandled fault has occurred in this flow. '
                    + 'Flow interview failed at element: ' + fi.CurrentElement
                    + '. Interview: ' + fi.InterviewLabel,
                Error_Type__c = 'FLOW_ELEMENT_ERROR',
                Interview_GUID__c = guid,
                User__c = fi.CreatedById,
                Error_Timestamp__c = fi.CreatedDate,
                Severity__c = 'Medium',
                Status__c = 'New',
                AI_Analysis_Complete__c = false
            );

            newLogs.add(log);
        }

        if (!newLogs.isEmpty()) {
            insert newLogs;
        }

        return newLogs.size();
    }

    /**
     * Extracts flow API name by matching interview label against known flow labels.
     */
    private static String extractFlowApiName(String interviewLabel, Map<String, String> flowLabelMap) {
        if (String.isBlank(interviewLabel)) return 'Unknown';

        // Try matching by flow label (interview label starts with flow label)
        for (String apiName : flowLabelMap.keySet()) {
            String label = flowLabelMap.get(apiName);
            if (interviewLabel.startsWith(label)) {
                return apiName;
            }
        }

        // Fallback: use the interview label itself cleaned up
        // Remove trailing date/time portion (e.g. " 3/22/2026, 11:20 PM")
        String cleaned = interviewLabel.replaceAll('\\s+\\d{1,2}/\\d{1,2}/\\d{4}.*$', '');
        return cleaned.replaceAll('\\s+', '_');
    }

    // ── Config ──

    @AuraEnabled(cacheable=true)
    public static DebuggerConfig getDebuggerConfig() {
        DebuggerConfig config = new DebuggerConfig();

        // Check if the FlowErrorAlertTrigger is effectively enabled
        // by seeing if we have recent platform-event-sourced records
        Integer recentPECount = [
            SELECT COUNT()
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :System.now().addHours(-1)
            LIMIT 1
        ];
        config.isPlatformEventsEnabled = recentPECount > 0;

        return config;
    }

    // ── Metrics ──

    @AuraEnabled(cacheable=true)
    public static MetricsSummary getMetricsSummary(String timeRange) {
        DateTime since;
        if (timeRange == '24h') {
            since = System.now().addHours(-24);
        } else if (timeRange == '7d') {
            since = System.now().addDays(-7);
        } else if (timeRange == '30d') {
            since = System.now().addDays(-30);
        } else {
            since = DateTime.newInstance(2000, 1, 1);
        }

        MetricsSummary summary = new MetricsSummary();
        summary.topErrorFlows = new List<FlowErrorMetric>();

        List<AggregateResult> topFlows = [
            SELECT Flow_API_Name__c flowName, Flow_Label__c flowLabel, COUNT(Id) errorCount
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :since
            GROUP BY Flow_API_Name__c, Flow_Label__c
            ORDER BY COUNT(Id) DESC
            LIMIT 5
        ];

        for (AggregateResult ar : topFlows) {
            FlowErrorMetric metric = new FlowErrorMetric();
            String label = (String) ar.get('flowLabel');
            metric.name = String.isNotBlank(label) ? label : (String) ar.get('flowName');
            metric.errorCount = (Integer) ar.get('errorCount');
            summary.topErrorFlows.add(metric);
        }

        return summary;
    }
}
