/**
 * FlowDoctorAIService
 *
 * Invokes Einstein/Agentforce LLM via ConnectApi to analyze Salesforce Flow errors.
 * Uses a structured prompt with Sonnet-class reasoning to diagnose root causes,
 * classify error categories, and produce actionable fix recommendations.
 */
public with sharing class FlowDoctorAIService {

    private static final String APP_NAME = 'PromptBuilderPreview';

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
     * Analyzes a Flow error using Einstein LLM and returns structured diagnosis.
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
        String prompt = buildPrompt(errorLog, flowContext, similarErrorsSummary);

        try {
            String aiResponse = callEinsteinLLM(prompt);
            return parseAIResponse(aiResponse);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'FlowDoctorAIService.analyzeFlowError failed: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * Calls ConnectApi.EinsteinLLM.generateMessages with the assembled prompt.
     */
    private static String callEinsteinLLM(String prompt) {
        ConnectApi.EinsteinLlmGenerationsInput input = new ConnectApi.EinsteinLlmGenerationsInput();
        input.promptTextorId = prompt;

        ConnectApi.EinsteinLlmAdditionalConfigInput config = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        config.applicationName = APP_NAME;
        input.additionalConfig = config;

        ConnectApi.EinsteinLLMGenerationsOutput output = ConnectApi.EinsteinLLM.generateMessages(input);

        if (output.generations != null && !output.generations.isEmpty()) {
            return output.generations[0].text;
        }

        throw new FlowDoctorAIException('Einstein LLM returned no generations.');
    }

    /**
     * Builds the comprehensive diagnostic prompt for analyzing a Flow error.
     * The prompt is designed to extract maximum diagnostic value by providing
     * the AI with full context about the failing Flow, element, error pattern,
     * and Salesforce-specific knowledge.
     */
    private static String buildPrompt(
        Flow_Error_Log__c errorLog,
        String flowContext,
        String similarErrorsSummary
    ) {
        String prompt = '';

        // ── System-level instruction ──
        prompt += 'You are Flow AI Debugger, an expert Salesforce Flow debugger and diagnostician. ';
        prompt += 'You have deep knowledge of Salesforce Flow architecture, Apex, SOQL, DML, ';
        prompt += 'governor limits, sharing rules, field-level security, record-triggered flows, ';
        prompt += 'screen flows, scheduled flows, platform events, and process automation best practices.\n\n';

        // ── Task definition ──
        prompt += 'TASK: Analyze the following Salesforce Flow error and provide a structured diagnosis.\n\n';

        // ── Error details ──
        prompt += '=== ERROR DETAILS ===\n';
        prompt += 'Flow API Name: ' + safe(errorLog.Flow_API_Name__c) + '\n';
        prompt += 'Element API Name: ' + safe(errorLog.Element_API_Name__c) + '\n';
        prompt += 'Element Type: ' + safe(errorLog.Element_Type__c) + '\n';
        prompt += 'Error Message: ' + safe(errorLog.Error_Message__c) + '\n';
        prompt += 'Error Type: ' + safe(errorLog.Error_Type__c) + '\n';
        prompt += 'Severity: ' + safe(errorLog.Severity__c) + '\n';
        prompt += 'Interview GUID: ' + safe(errorLog.Interview_GUID__c) + '\n';
        prompt += 'Related Record ID: ' + safe(errorLog.Related_Record_Id__c) + '\n\n';

        // ── Flow metadata context ──
        if (String.isNotBlank(flowContext)) {
            prompt += '=== FLOW METADATA CONTEXT ===\n';
            prompt += flowContext + '\n\n';
        }

        // ── Similar errors for pattern detection ──
        if (String.isNotBlank(similarErrorsSummary)) {
            prompt += '=== SIMILAR RECENT ERRORS (last 24 hours) ===\n';
            prompt += similarErrorsSummary + '\n\n';
        }

        // ── Common Salesforce Flow error knowledge base ──
        prompt += '=== COMMON FLOW ERROR CATEGORIES ===\n';
        prompt += 'Use these categories to classify the root cause:\n';
        prompt += '- NULL_REFERENCE: Null variable/field access, uninitialized collections, missing record lookups\n';
        prompt += '- DML_ERROR: Validation rules, required fields, duplicate rules, trigger exceptions\n';
        prompt += '- GOVERNOR_LIMIT: SOQL 101, DML 150, CPU timeout, heap size in loops\n';
        prompt += '- PERMISSION_ERROR: FLS violations, CRUD access, sharing rule restrictions, profile limits\n';
        prompt += '- DATA_INTEGRITY: Wrong data types, formula errors, cross-object issues, invalid references\n';
        prompt += '- CONFIGURATION_ERROR: Missing flow elements, broken references, invalid API names\n';
        prompt += '- RECORD_LOCKING: Record lock contention, concurrent updates, mixed DML\n';
        prompt += '- EXTERNAL_SERVICE: Callout failures, timeout, invalid endpoints, auth errors\n';
        prompt += '- LOOP_ERROR: Infinite loops, DML/SOQL inside loops, collection size issues\n';
        prompt += '- PLATFORM_EVENT: Event publishing failures, replay ID issues, subscriber errors\n\n';

        // ── Output format instruction ──
        prompt += '=== REQUIRED OUTPUT FORMAT ===\n';
        prompt += 'Respond in EXACTLY this format with these section headers. ';
        prompt += 'Each section must start on a new line with the header followed by a colon. ';
        prompt += 'Do NOT use markdown, bullets, or numbering. Use plain text only.\n\n';

        prompt += 'ROOT_CAUSE: [Specific technical explanation of why this error occurred. ';
        prompt += 'Reference the exact element, field, or operation that failed. 2-4 sentences max.]\n\n';

        prompt += 'ROOT_CAUSE_CATEGORY: [Exactly one of: NULL_REFERENCE, DML_ERROR, GOVERNOR_LIMIT, ';
        prompt += 'PERMISSION_ERROR, DATA_INTEGRITY, CONFIGURATION_ERROR, RECORD_LOCKING, ';
        prompt += 'EXTERNAL_SERVICE, LOOP_ERROR, PLATFORM_EVENT]\n\n';

        prompt += 'AFFECTED_ELEMENT_DETAILS: [What the failing element does, what data it processes, ';
        prompt += 'and what downstream elements depend on it. 2-3 sentences.]\n\n';

        prompt += 'USER_IMPACT: [How this error affects end users. Does it block a business process? ';
        prompt += 'Is data lost? Are notifications missed? 1-2 sentences.]\n\n';

        prompt += 'IMMEDIATE_ACTION: [The single most important thing an admin should do RIGHT NOW ';
        prompt += 'to stop the bleeding. Be specific with exact steps in Flow Builder.]\n\n';

        prompt += 'LONG_TERM_FIX: [The proper architectural fix. Include best practices like ';
        prompt += 'fault paths, error handling, bulkification, or redesign suggestions. 2-3 sentences.]\n\n';

        prompt += 'FIX_STEPS: [Step-by-step instructions to fix the issue. Each step separated by a semicolon. ';
        prompt += 'Example: Open Flow Builder for MyFlow; Navigate to the Get Records element; ';
        prompt += 'Add a Decision element after it to check if records were found; Add a Fault path ';
        prompt += 'to handle the error gracefully]\n\n';

        prompt += 'TEST_SCENARIO: [A specific test case the admin should run after fixing. ';
        prompt += 'Include the trigger condition, expected input, and expected outcome.]\n\n';

        prompt += 'PATTERN_DETECTED: [true if the similar errors suggest a systemic/recurring issue, false otherwise]\n\n';

        prompt += 'CONFIDENCE_SCORE: [A number between 0 and 100 indicating how confident you are ';
        prompt += 'in this diagnosis. 90+ means the error message clearly maps to a known issue. ';
        prompt += '50-89 means likely correct but could be other causes. Below 50 means uncertain.]\n';

        return prompt;
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

        // Validate root cause category against known values
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
            // Try case-insensitive
            startIdx = response.toLowerCase().indexOf(searchKey.toLowerCase());
        }
        if (startIdx < 0) {
            return null;
        }

        Integer valueStart = startIdx + searchKey.length();

        // Find the end: next section header or end of string
        // Section headers are uppercase words followed by colon at start of line
        String remaining = response.substring(valueStart);

        // Look for next section header pattern (UPPERCASE_WORD:)
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

        // Extract first number from the string
        Pattern numPattern = Pattern.compile('(\\d+\\.?\\d*)');
        Matcher m = numPattern.matcher(scoreStr);
        if (m.find()) {
            try {
                Decimal score = Decimal.valueOf(m.group(1));
                // Clamp to 0-100
                return Math.min(100, Math.max(0, score));
            } catch (Exception e) {
                return 50;
            }
        }
        return 50;
    }

    /**
     * Validates the root cause category against known values.
     * Falls back to CONFIGURATION_ERROR if the AI returns an unknown category.
     */
    private static String validateCategory(String category) {
        if (String.isBlank(category)) return 'Configuration Error';

        // Map from AI prompt categories to picklist values
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

        // Also accept the picklist values directly
        Set<String> validPicklistValues = new Set<String>(categoryMap.values());

        // Check if it's already a valid picklist value (AI sometimes returns the display name)
        for (String pv : validPicklistValues) {
            if (category.trim().equalsIgnoreCase(pv)) {
                return pv;
            }
        }

        // Clean to uppercase underscore format and look up
        String cleaned = category.trim().toUpperCase().replaceAll('[^A-Z_]', '');
        if (categoryMap.containsKey(cleaned)) {
            return categoryMap.get(cleaned);
        }

        // Fuzzy match - check if any key is contained in the AI response
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
