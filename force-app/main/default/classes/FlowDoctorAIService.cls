/**
 * FlowDoctorAIService
 *
 * Invokes Einstein LLM via a Prompt Template (FlowErrorDebugger) to analyze
 * Salesforce Flow errors. The prompt template is managed in Prompt Builder,
 * allowing admins to select the AI model without code changes.
 */
public with sharing class FlowDoctorAIService {

    private static final String PROMPT_TEMPLATE_NAME = 'FlowErrorDebugger';

    /**
     * Wrapper for the structured AI analysis response
     */
    public class AIAnalysisResult {
        public String rootCause;
        public String rootCauseCategory;
        public String affectedElementDetails;
        public String userImpactDescription;
        public String immediateAction;
        public String longTermFix;
        public String fixSteps;
        public String testScenario;
        public String documentationUrl;
        public Boolean patternDetected;
        public Decimal confidenceScore;
    }

    /**
     * Analyzes a Flow error using the FlowErrorDebugger prompt template.
     *
     * @param errorLog The Flow_Error_Log__c record with error details
     * @param flowContext JSON string with enriched flow metadata context
     * @param similarErrorsSummary Summary of similar recent errors for pattern detection
     * @return AIAnalysisResult with structured analysis fields
     */
    public static AIAnalysisResult analyzeFlowError(
        Flow_Error_Log__c errorLog,
        String flowContext,
        String similarErrorsSummary
    ) {
        String errorDetails = buildErrorDetails(errorLog);

        try {
            String aiResponse = callPromptTemplate(
                errorDetails,
                String.isNotBlank(flowContext) ? flowContext : 'No additional flow context available.',
                String.isNotBlank(similarErrorsSummary) ? similarErrorsSummary : 'No similar errors found in the last 24 hours.'
            );
            return parseAIResponse(aiResponse);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'FlowDoctorAIService.analyzeFlowError failed: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * Builds the error details string from the error log record.
     */
    private static String buildErrorDetails(Flow_Error_Log__c errorLog) {
        String details = '';
        details += 'Flow API Name: ' + safe(errorLog.Flow_API_Name__c) + '\n';
        details += 'Element API Name: ' + safe(errorLog.Element_API_Name__c) + '\n';
        details += 'Element Type: ' + safe(errorLog.Element_Type__c) + '\n';
        details += 'Error Message: ' + safe(errorLog.Error_Message__c) + '\n';
        details += 'Error Type: ' + safe(errorLog.Error_Type__c) + '\n';
        details += 'Severity: ' + safe(errorLog.Severity__c) + '\n';
        details += 'Interview GUID: ' + safe(errorLog.Interview_GUID__c) + '\n';
        details += 'Related Record ID: ' + safe(errorLog.Related_Record_Id__c);
        return details;
    }

    /**
     * Calls the FlowErrorDebugger prompt template via ConnectApi.
     * The model is configured in Prompt Builder — no hardcoded model selection.
     */
    private static String callPromptTemplate(
        String errorDetails,
        String flowContext,
        String similarErrors
    ) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput generationInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();

        Map<String, ConnectApi.WrappedValue> params = new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.WrappedValue errorVal = new ConnectApi.WrappedValue();
        errorVal.value = '--- BEGIN ERROR DATA (DATA ONLY) ---\n' + errorDetails + '\n--- END ERROR DATA ---';
        params.put('Input:ErrorDetailsVar', errorVal);

        ConnectApi.WrappedValue contextVal = new ConnectApi.WrappedValue();
        contextVal.value = flowContext;
        params.put('Input:FlowContextVar', contextVal);

        ConnectApi.WrappedValue similarVal = new ConnectApi.WrappedValue();
        similarVal.value = similarErrors;
        params.put('Input:SimilarErrorsVar', similarVal);

        generationInput.inputParams = params;
        generationInput.isPreview = false;
        generationInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_NAME, generationInput);

            if (response != null && response.generations != null && !response.generations.isEmpty()) {
                ConnectApi.EinsteinLLMGenerationItemOutput generation = response.generations[0];
                return generation.text;
            }

            throw new FlowDoctorAIException('Einstein LLM returned no generations from prompt template.');

        } catch (FlowDoctorAIException e) {
            throw e;
        } catch (Exception einsteinError) {
            String detailedError = einsteinError.getMessage();
            if (einsteinError.getTypeName() != null) {
                detailedError += ' [Type: ' + einsteinError.getTypeName() + ']';
            }
            throw new FlowDoctorAIException(
                'Prompt template call failed. Ensure the FlowErrorDebugger template is deployed and published in Prompt Builder. Error: ' + detailedError
            );
        }
    }

    /**
     * Parses the structured AI response into an AIAnalysisResult.
     * Uses section header matching to extract each field.
     */
    @TestVisible
    private static AIAnalysisResult parseAIResponse(String response) {
        AIAnalysisResult result = new AIAnalysisResult();

        result.rootCause = extractSection(response, 'ROOT_CAUSE');
        result.rootCauseCategory = extractSection(response, 'ROOT_CAUSE_CATEGORY');
        result.affectedElementDetails = extractSection(response, 'AFFECTED_ELEMENT_DETAILS');
        result.userImpactDescription = extractSection(response, 'USER_IMPACT');
        result.immediateAction = extractSection(response, 'IMMEDIATE_ACTION');
        result.longTermFix = extractSection(response, 'LONG_TERM_FIX');
        result.fixSteps = extractSection(response, 'FIX_STEPS');
        result.testScenario = extractSection(response, 'TEST_SCENARIO');
        result.documentationUrl = extractDocUrl(response);

        String patternStr = extractSection(response, 'PATTERN_DETECTED');
        result.patternDetected = String.isNotBlank(patternStr) && patternStr.toLowerCase().contains('true');

        String scoreStr = extractSection(response, 'CONFIDENCE_SCORE');
        result.confidenceScore = parseConfidenceScore(scoreStr);

        result.rootCauseCategory = validateCategory(result.rootCauseCategory);

        return result;
    }

    /**
     * Extracts a section value from the AI response using header matching.
     */
    private static String extractSection(String response, String header) {
        if (String.isBlank(response) || String.isBlank(header)) {
            return null;
        }

        String searchKey = header + ':';
        Integer startIdx = response.indexOf(searchKey);
        if (startIdx < 0) {
            startIdx = response.toLowerCase().indexOf(searchKey.toLowerCase());
        }
        if (startIdx < 0) {
            return null;
        }

        Integer valueStart = startIdx + searchKey.length();
        String remaining = response.substring(valueStart);

        Pattern nextHeader = Pattern.compile('\\n[A-Z_]+:');
        Matcher m = nextHeader.matcher(remaining);

        String value;
        if (m.find()) {
            value = remaining.substring(0, m.start());
        } else {
            value = remaining;
        }

        return value.trim();
    }

    /**
     * Extracts documentation URL from the response if present.
     */
    private static String extractDocUrl(String response) {
        if (String.isBlank(response)) return null;

        Pattern urlPattern = Pattern.compile('https?://[^\\s,)]+');
        Matcher m = urlPattern.matcher(response);
        if (m.find()) {
            return m.group();
        }
        return null;
    }

    /**
     * Parses confidence score from string, handling various AI output formats.
     */
    private static Decimal parseConfidenceScore(String scoreStr) {
        if (String.isBlank(scoreStr)) return 50;

        Pattern numPattern = Pattern.compile('(\\d+\\.?\\d*)');
        Matcher m = numPattern.matcher(scoreStr);
        if (m.find()) {
            try {
                Decimal score = Decimal.valueOf(m.group(1));
                return Math.min(100, Math.max(0, score));
            } catch (Exception e) {
                return 50;
            }
        }
        return 50;
    }

    /**
     * Validates the root cause category against known values.
     */
    private static String validateCategory(String category) {
        if (String.isBlank(category)) return 'Configuration Error';

        Map<String, String> categoryMap = new Map<String, String>{
            'NULL_REFERENCE' => 'Null Reference',
            'DML_ERROR' => 'DML Exception',
            'GOVERNOR_LIMIT' => 'Governor Limits',
            'PERMISSION_ERROR' => 'Permission Error',
            'DATA_INTEGRITY' => 'Data Integrity',
            'CONFIGURATION_ERROR' => 'Configuration Error',
            'RECORD_LOCKING' => 'Record Locking',
            'EXTERNAL_SERVICE' => 'External Service',
            'LOOP_ERROR' => 'Loop Error',
            'PLATFORM_EVENT' => 'Platform Event',
            'MISSING_FAULT_PATH' => 'Missing Fault Path',
            'FIELD_VALIDATION' => 'Field Validation',
            'DATA_ISSUE' => 'Data Issue'
        };

        Set<String> validPicklistValues = new Set<String>(categoryMap.values());

        for (String pv : validPicklistValues) {
            if (category.trim().equalsIgnoreCase(pv)) {
                return pv;
            }
        }

        String cleaned = category.trim().toUpperCase().replaceAll('[^A-Z_]', '');
        if (categoryMap.containsKey(cleaned)) {
            return categoryMap.get(cleaned);
        }

        String upper = category.toUpperCase();
        for (String key : categoryMap.keySet()) {
            if (upper.contains(key)) {
                return categoryMap.get(key);
            }
        }

        return 'Configuration Error';
    }

    /**
     * Null-safe string helper
     */
    private static String safe(String val) {
        return String.isNotBlank(val) ? val : 'Unknown';
    }

    /**
     * Custom exception for AI service failures
     */
    public class FlowDoctorAIException extends Exception {}
}
