public with sharing class FlowErrorAnalysisService {

    public static void analyzeErrors(List<Flow_Error_Alert__e> alerts) {
        List<Flow_Error_Log__c> errorLogs = new List<Flow_Error_Log__c>();

        for (Flow_Error_Alert__e alert : alerts) {
            Flow_Error_Log__c errorLog = createErrorLog(alert);
            errorLogs.add(errorLog);
        }

        if (!errorLogs.isEmpty()) {
            insert errorLogs;

            Set<Id> errorLogIds = new Set<Id>();
            for (Flow_Error_Log__c log : errorLogs) {
                errorLogIds.add(log.Id);
            }

            performAIAnalysisAsync(errorLogIds);
        }
    }

    private static Flow_Error_Log__c createErrorLog(Flow_Error_Alert__e alert) {
        FlowMetadataService.FlowMetadata metadata =
            FlowMetadataService.getFlowMetadata(alert.Flow_API_Name__c);

        Flow_Error_Log__c errorLog = new Flow_Error_Log__c(
            Flow_API_Name__c = alert.Flow_API_Name__c,
            Flow_Label__c = alert.Flow_Label__c != null ? alert.Flow_Label__c :
                           (metadata != null ? metadata.label : alert.Flow_API_Name__c),
            Flow_Version__c = metadata != null ? metadata.version : null,
            Element_API_Name__c = alert.Element_API_Name__c,
            Element_Type__c = alert.Element_Type__c,
            Error_Message__c = alert.Error_Message__c,
            Error_Type__c = alert.Error_Type__c,
            Interview_GUID__c = alert.Interview_GUID__c,
            Related_Record_Id__c = alert.Related_Record_Id__c,
            User__c = alert.User_Id__c,
            Error_Timestamp__c = alert.Error_Timestamp__c,
            Severity__c = calculateSeverity(alert),
            Status__c = 'New',
            AI_Analysis_Complete__c = false
        );

        return errorLog;
    }

    private static String calculateSeverity(Flow_Error_Alert__e alert) {
        Integer recentErrorCount = [
            SELECT COUNT()
            FROM Flow_Error_Log__c
            WHERE Flow_API_Name__c = :alert.Flow_API_Name__c
            AND Error_Timestamp__c >= :System.now().addMinutes(-10)
        ];

        if (recentErrorCount >= 10) {
            return 'Critical';
        } else if (recentErrorCount >= 5) {
            return 'High';
        } else if (recentErrorCount >= 2) {
            return 'Medium';
        } else {
            return 'Low';
        }
    }

    @future(callout=true)
    private static void performAIAnalysisAsync(Set<Id> errorLogIds) {
        List<Flow_Error_Log__c> errorLogs = [
            SELECT Id, Flow_API_Name__c, Element_API_Name__c, Element_Type__c,
                   Error_Message__c, Error_Type__c, Interview_GUID__c,
                   Related_Record_Id__c, User__c, Severity__c
            FROM Flow_Error_Log__c
            WHERE Id IN :errorLogIds
        ];

        for (Flow_Error_Log__c errorLog : errorLogs) {
            analyzeErrorWithAI(errorLog);
        }
    }

    private static void analyzeErrorWithAI(Flow_Error_Log__c errorLog) {
        Long startTime = System.currentTimeMillis();

        try {
            // Build enriched context from Flow metadata
            String flowContext = buildAnalysisContext(errorLog);

            // Build similar errors summary for pattern detection
            String similarErrorsSummary = buildSimilarErrorsSummary(errorLog);

            // Call Einstein LLM via FlowDoctorAIService
            FlowDoctorAIService.AIAnalysisResult aiResult =
                FlowDoctorAIService.analyzeFlowError(errorLog, flowContext, similarErrorsSummary);

            // Create the analysis record from AI response
            createAIAnalysis(errorLog.Id, aiResult, startTime);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AI analysis failed for ' + errorLog.Id + ': ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            // Fall back to basic analysis when AI is unavailable
            createFallbackAnalysis(errorLog.Id, startTime, e.getMessage());
        }
    }

    /**
     * Creates Flow_Error_Analysis__c from the AI structured response.
     */
    private static void createAIAnalysis(Id errorLogId, FlowDoctorAIService.AIAnalysisResult aiResult, Long startTime) {
        Flow_Error_Analysis__c analysis = new Flow_Error_Analysis__c(
            Flow_Error_Log__c = errorLogId,
            Root_Cause__c = truncateField(aiResult.rootCause, 32000),
            Root_Cause_Category__c = truncateField(aiResult.rootCauseCategory, 255),
            Affected_Element_Details__c = truncateField(aiResult.affectedElementDetails, 32000),
            User_Impact_Description__c = truncateField(aiResult.userImpactDescription, 32000),
            Immediate_Action__c = truncateField(aiResult.immediateAction, 32000),
            Long_Term_Fix__c = truncateField(aiResult.longTermFix, 32000),
            Fix_Steps__c = truncateField(aiResult.fixSteps, 32000),
            Test_Scenario__c = truncateField(aiResult.testScenario, 32000),
            Documentation_URL__c = truncateField(aiResult.documentationUrl, 255),
            Pattern_Detected__c = aiResult.patternDetected != null ? aiResult.patternDetected : false,
            Confidence_Score__c = aiResult.confidenceScore != null ? aiResult.confidenceScore : 50,
            Analysis_Duration_MS__c = System.currentTimeMillis() - startTime,
            Analysis_Timestamp__c = System.now()
        );

        insert analysis;

        update new Flow_Error_Log__c(
            Id = errorLogId,
            AI_Analysis_Complete__c = true,
            Status__c = 'Analyzed'
        );
    }

    /**
     * Builds enriched context JSON from Flow metadata for the AI prompt.
     */
    private static String buildAnalysisContext(Flow_Error_Log__c errorLog) {
        FlowMetadataService.FlowMetadata metadata =
            FlowMetadataService.getFlowMetadata(errorLog.Flow_API_Name__c);

        FlowMetadataService.FlowElement element =
            FlowMetadataService.getElementDetails(
                errorLog.Flow_API_Name__c,
                errorLog.Element_API_Name__c
            );

        Map<String, Object> context = new Map<String, Object>{
            'flowApiName' => errorLog.Flow_API_Name__c,
            'flowLabel' => metadata != null ? metadata.label : errorLog.Flow_API_Name__c,
            'flowVersion' => metadata != null ? metadata.version : null,
            'flowProcessType' => metadata != null ? metadata.processType : null,
            'flowTriggerType' => metadata != null ? metadata.triggerType : null,
            'elementApiName' => errorLog.Element_API_Name__c,
            'elementType' => errorLog.Element_Type__c,
            'elementLabel' => element != null ? element.label : null,
            'elementHasFaultPath' => element != null ? element.hasFaultPath : false,
            'elementConnectedTo' => element != null ? element.connectedTo : null,
            'totalFlowElements' => metadata != null && metadata.elements != null ? metadata.elements.size() : 0,
            'errorMessage' => errorLog.Error_Message__c,
            'severity' => errorLog.Severity__c
        };

        return JSON.serializePretty(context);
    }

    /**
     * Builds a summary of similar recent errors for pattern detection.
     */
    private static String buildSimilarErrorsSummary(Flow_Error_Log__c errorLog) {
        List<Flow_Error_Log__c> similarErrors = [
            SELECT Element_API_Name__c, Error_Message__c, Element_Type__c,
                   Error_Type__c, Error_Timestamp__c, Severity__c
            FROM Flow_Error_Log__c
            WHERE Flow_API_Name__c = :errorLog.Flow_API_Name__c
            AND Error_Timestamp__c >= :System.now().addHours(-24)
            AND Id != :errorLog.Id
            ORDER BY Error_Timestamp__c DESC
            LIMIT 10
        ];

        if (similarErrors.isEmpty()) {
            return null;
        }

        String summary = 'Found ' + similarErrors.size() + ' similar errors in the last 24 hours:\n';
        for (Flow_Error_Log__c err : similarErrors) {
            summary += '- Element: ' + err.Element_API_Name__c
                     + ' | Type: ' + err.Element_Type__c
                     + ' | Error: ' + err.Error_Message__c
                     + ' | Severity: ' + err.Severity__c
                     + ' | Time: ' + err.Error_Timestamp__c + '\n';
        }

        return summary;
    }

    /**
     * Fallback analysis when AI service is unavailable.
     * Provides basic rule-based categorization from the error message.
     */
    private static void createFallbackAnalysis(Id errorLogId, Long startTime, String failureReason) {
        Flow_Error_Log__c errorLog = [
            SELECT Error_Message__c, Element_Type__c, Element_API_Name__c
            FROM Flow_Error_Log__c
            WHERE Id = :errorLogId
            LIMIT 1
        ];

        String rootCauseCategory = categorizeFromErrorMessage(errorLog.Error_Message__c);

        Flow_Error_Analysis__c fallback = new Flow_Error_Analysis__c(
            Flow_Error_Log__c = errorLogId,
            Root_Cause__c = 'Automated AI analysis was unavailable (' + truncateField(failureReason, 200)
                          + '). Based on keyword matching, the error appears to be: '
                          + rootCauseCategory + '. Manual review recommended.',
            Root_Cause_Category__c = rootCauseCategory,
            User_Impact_Description__c = 'This Flow error may be blocking a business process. '
                                       + 'Review the error in Flow Builder and check the affected element: '
                                       + errorLog.Element_API_Name__c,
            Immediate_Action__c = 'Open Flow Builder, navigate to element "'
                                + errorLog.Element_API_Name__c
                                + '", and add a Fault path to handle this error gracefully.',
            Long_Term_Fix__c = 'Add comprehensive error handling with fault paths on all DML and '
                             + 'external service elements. Consider adding Decision elements to validate '
                             + 'data before processing.',
            Confidence_Score__c = 20,
            Analysis_Duration_MS__c = System.currentTimeMillis() - startTime,
            Analysis_Timestamp__c = System.now()
        );

        insert fallback;

        update new Flow_Error_Log__c(
            Id = errorLogId,
            AI_Analysis_Complete__c = true,
            Status__c = 'Analyzed'
        );
    }

    /**
     * Simple keyword-based error categorization for fallback mode.
     */
    private static String categorizeFromErrorMessage(String errorMessage) {
        if (String.isBlank(errorMessage)) return 'Configuration Error';

        String msg = errorMessage.toLowerCase();

        if (msg.contains('null') || msg.contains('uninitialized')) {
            return 'Null Reference';
        } else if (msg.contains('validation') || msg.contains('required field')
                   || msg.contains('duplicate') || msg.contains('trigger')) {
            return 'DML Exception';
        } else if (msg.contains('too many soql') || msg.contains('too many dml')
                   || msg.contains('cpu time') || msg.contains('governor') || msg.contains('limit')) {
            return 'Governor Limits';
        } else if (msg.contains('insufficient') || msg.contains('permission')
                   || msg.contains('access') || msg.contains('sharing')) {
            return 'Permission Error';
        } else if (msg.contains('lock') || msg.contains('unable to obtain')) {
            return 'Record Locking';
        } else if (msg.contains('callout') || msg.contains('timeout')
                   || msg.contains('endpoint') || msg.contains('external')) {
            return 'External Service';
        } else if (msg.contains('loop') || msg.contains('maximum iterations')) {
            return 'Loop Error';
        } else {
            return 'Configuration Error';
        }
    }

    /**
     * Truncate a field value to a maximum length to avoid DML errors.
     */
    private static String truncateField(String value, Integer maxLength) {
        if (String.isBlank(value)) return value;
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}
