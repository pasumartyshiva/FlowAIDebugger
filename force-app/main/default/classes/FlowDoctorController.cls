public with sharing class FlowDoctorController {
    
    @AuraEnabled(cacheable=true)
    public static List<Flow_Error_Log__c> getRecentErrors(Integer limitCount) {
        return [
            SELECT Id, Name, Flow_API_Name__c, Flow_Label__c, Element_API_Name__c,
                   Element_Type__c, Error_Message__c, Error_Timestamp__c, 
                   Severity__c, Status__c, AI_Analysis_Complete__c,
                   User__r.Name
            FROM Flow_Error_Log__c
            ORDER BY Error_Timestamp__c DESC
            LIMIT :limitCount
        ];
    }
    
    @AuraEnabled(cacheable=true)
    public static Flow_Error_Analysis__c getErrorAnalysis(Id errorLogId) {
        List<Flow_Error_Analysis__c> results = [
            SELECT Root_Cause__c, Root_Cause_Category__c, Affected_Element_Details__c,
                   User_Impact_Description__c, Immediate_Action__c, Long_Term_Fix__c,
                   Fix_Steps__c, Test_Scenario__c, Documentation_URL__c,
                   Pattern_Detected__c, Confidence_Score__c
            FROM Flow_Error_Analysis__c
            WHERE Flow_Error_Log__c = :errorLogId
            LIMIT 1
        ];
        
        return results.isEmpty() ? null : results[0];
    }
    
    @AuraEnabled(cacheable=true)
    public static List<AggregateResult> getTopErrors(Integer limitCount, Integer hours) {
        DateTime since = System.now().addHours(-hours);
        
        return [
            SELECT Flow_API_Name__c flowApiName, Flow_Label__c flowLabel,
                   COUNT(Id) errorCount, MAX(Id) lastErrorId,
                   MAX(Severity__c) maxSeverity
            FROM Flow_Error_Log__c
            WHERE Error_Timestamp__c >= :since
            GROUP BY Flow_API_Name__c, Flow_Label__c
            ORDER BY COUNT(Id) DESC
            LIMIT :limitCount
        ];
    }
    
    @AuraEnabled
    public static void markErrorResolved(Id errorLogId, String resolutionNotes) {
        Flow_Error_Log__c errorLog = [
            SELECT Id, Error_Timestamp__c
            FROM Flow_Error_Log__c
            WHERE Id = :errorLogId
            LIMIT 1
        ];

        Long resolutionMinutes = (System.now().getTime() - errorLog.Error_Timestamp__c.getTime()) / 60000;

        errorLog.Status__c = 'Resolved';
        errorLog.Resolution_Notes__c = resolutionNotes;
        errorLog.Resolution_Time_Minutes__c = resolutionMinutes;

        update errorLog;
    }

    @AuraEnabled
    public static void updateErrorStatus(Id errorLogId, String status) {
        Flow_Error_Log__c errorLog = [
            SELECT Id, Error_Timestamp__c
            FROM Flow_Error_Log__c
            WHERE Id = :errorLogId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        errorLog.Status__c = status;

        if (status == 'Resolved') {
            Long resolutionMinutes = (System.now().getTime() - errorLog.Error_Timestamp__c.getTime()) / 60000;
            errorLog.Resolution_Time_Minutes__c = resolutionMinutes;
        }

        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Flow_Error_Log__c>{ errorLog }).getRecords();
    }

    @AuraEnabled
    public static void updateErrorOwner(Id errorLogId, Id ownerId) {
        Flow_Error_Log__c errorLog = new Flow_Error_Log__c(
            Id = errorLogId,
            User__c = ownerId
        );
        update Security.stripInaccessible(AccessType.UPDATABLE, new List<Flow_Error_Log__c>{ errorLog }).getRecords();
    }

    /**
     * Triggers AI analysis for a single error and returns the result.
     * Unlike getErrorAnalysis (cacheable), this is imperative and will
     * kick off analysis if none exists yet.
     */
    @AuraEnabled
    public static Flow_Error_Analysis__c runAnalysisForError(Id errorLogId) {
        // Check if analysis already exists
        List<Flow_Error_Analysis__c> existing = [
            SELECT Root_Cause__c, Root_Cause_Category__c, Affected_Element_Details__c,
                   User_Impact_Description__c, Immediate_Action__c, Long_Term_Fix__c,
                   Fix_Steps__c, Test_Scenario__c, Documentation_URL__c,
                   Pattern_Detected__c, Confidence_Score__c
            FROM Flow_Error_Analysis__c
            WHERE Flow_Error_Log__c = :errorLogId
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }

        // No analysis yet — trigger it asynchronously
        FlowErrorAnalysisService.performAIAnalysisAsync(new Set<Id>{ errorLogId });

        // Return null — UI should poll/refresh after a delay
        return null;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getActiveUsers() {
        List<Map<String, String>> users = new List<Map<String, String>>();
        for (User u : [SELECT Id, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 200]) {
            users.add(new Map<String, String>{ 'label' => u.Name, 'value' => u.Id });
        }
        return users;
    }
}
