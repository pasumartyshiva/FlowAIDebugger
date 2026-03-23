import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getDashboardData from '@salesforce/apex/FlowDebuggerDashboardController.getDashboardData';
import getAggregatedErrors from '@salesforce/apex/FlowDebuggerDashboardController.getAggregatedErrors';
import runAdHocAnalysis from '@salesforce/apex/FlowDebuggerDashboardController.runAdHocAnalysis';
import getDebuggerConfig from '@salesforce/apex/FlowDebuggerDashboardController.getDebuggerConfig';
import getMetricsSummary from '@salesforce/apex/FlowDebuggerDashboardController.getMetricsSummary';
import getErrorAnalysis from '@salesforce/apex/FlowDoctorController.getErrorAnalysis';
import markErrorResolved from '@salesforce/apex/FlowDoctorController.markErrorResolved';
import updateErrorStatus from '@salesforce/apex/FlowDoctorController.updateErrorStatus';
import updateErrorOwner from '@salesforce/apex/FlowDoctorController.updateErrorOwner';
import getActiveUsers from '@salesforce/apex/FlowDoctorController.getActiveUsers';

const SEVERITY_OPTIONS = [
  { label: 'All', value: 'All' },
  { label: 'Critical', value: 'Critical' },
  { label: 'High', value: 'High' },
  { label: 'Medium', value: 'Medium' },
  { label: 'Low', value: 'Low' }
];

const STATUS_OPTIONS = [
  { label: 'New', value: 'New' },
  { label: 'Analyzed', value: 'Analyzed' },
  { label: 'In Progress', value: 'In Progress' },
  { label: 'Resolved', value: 'Resolved' },
  { label: 'Ignored', value: 'Ignored' }
];

const PAGE_SIZE_OPTIONS = [
  { label: '5', value: '5' },
  { label: '10', value: '10' },
  { label: '25', value: '25' },
  { label: '50', value: '50' }
];

const MESSAGE_TRUNCATE_LENGTH = 60;
const SEARCH_DEBOUNCE_DELAY = 300;

const LOADING_MESSAGES = [
  { main: 'Sending Error Data...', sub: 'Preparing error context for Einstein', progress: 15 },
  { main: 'Calling Prompt Template...', sub: 'FlowErrorDebugger template is processing', progress: 35 },
  { main: 'Einstein is Analyzing...', sub: 'Diagnosing root cause and impact', progress: 55 },
  { main: 'Generating Fix Steps...', sub: 'Creating actionable recommendations', progress: 75 },
  { main: 'Almost Done...', sub: 'Finalizing analysis report', progress: 90 }
];

const FUN_TIPS = [
  'Einstein AI uses a prompt template — you can switch models in Setup > Prompt Builder.',
  'Errors with 10+ occurrences in 10 minutes are auto-flagged as Critical severity.',
  'The confidence score tells you how reliably the AI matched the error to a known pattern.',
  'You can export your error data as CSV for offline analysis or reporting.',
  'Use Edit mode to bulk-update Status and Owner for multiple errors at once.'
];

function getConfidenceExplanation(score) {
  if (score >= 90) return 'High confidence — error clearly maps to a known issue pattern (Einstein AI).';
  if (score >= 50) return 'Moderate confidence — likely correct, but other causes possible (Einstein AI).';
  if (score > 20) return 'Low confidence — analysis may need manual review (Einstein AI).';
  if (score === 20) return 'Fallback analysis — keyword-based rules, Einstein was unavailable.';
  return 'Not yet analyzed. Run AI Analysis to generate a confidence score.';
}

const SAMPLE_ERRORS = [
  {
    id: 'sample_001', flowName: 'Case_Auto_Assignment_Flow', errorCount: 12,
    status: 'New', ownerId: '', ownerName: '',
    latestErrorMessage: 'FIELD_CUSTOM_VALIDATION_EXCEPTION: Case Owner cannot be blank when Status is Escalated. Review the assignment criteria in the Decision element.',
    severity: 'Critical', isCritical: true, isAnalyzed: true,
    rootCause: 'The flow attempts to assign cases without validating that the Owner field is populated. When the assignment queue is empty or the round-robin assignment fails, the Owner field remains null, triggering the validation rule.',
    immediateAction: 'Add a Decision element before the Update Records element to check if the Owner field is populated. If null, assign to a default queue.',
    fixSteps: ['Open the Case_Auto_Assignment_Flow in Flow Builder', 'Add a Decision element after the Get Records that fetches available agents', 'In the Decision, check if the assignment result is not null', 'Add a fault path that assigns to the Default_Case_Queue', 'Save and activate the new version'],
    confidenceScore: 92
  },
  {
    id: 'sample_002', flowName: 'Lead_Conversion_Process', errorCount: 7,
    status: 'Analyzed', ownerId: '', ownerName: '',
    latestErrorMessage: 'DUPLICATE_VALUE: duplicate value found: Lead_External_Id__c duplicates value on record with id: 00Q5e000008xyz',
    severity: 'High', isCritical: false, isAnalyzed: true,
    rootCause: 'The Lead conversion flow creates Contact records without checking for existing duplicates on the Lead_External_Id__c field.',
    immediateAction: 'Add a duplicate check before the Create Records element. Query existing Contacts by Lead_External_Id__c before creating.',
    fixSteps: ['Add a Get Records element to query Contact by Lead_External_Id__c', 'Add a Decision element to check if a matching Contact exists', 'If exists, update the existing Contact instead of creating new', 'If not exists, proceed with Contact creation', 'Add error handling for the Create Records element'],
    confidenceScore: 87
  },
  {
    id: 'sample_003', flowName: 'Opportunity_Stage_Update', errorCount: 3,
    status: 'In Progress', ownerId: '', ownerName: '',
    latestErrorMessage: 'INSUFFICIENT_ACCESS_OR_READONLY: insufficient access rights on cross-reference id: 006Dn000007kABC',
    severity: 'Medium', isCritical: false, isAnalyzed: true,
    rootCause: 'The flow runs in system context but references related records that the running user does not have access to.',
    immediateAction: 'Review the sharing settings for the Opportunity and related Account objects.',
    fixSteps: ['Check the flow\'s Run Mode setting', 'Change to System Mode if business logic requires cross-object updates', 'Alternatively, update the permission set to grant Edit access on Account', 'Test with a user who has the minimum required permissions'],
    confidenceScore: 78
  },
  {
    id: 'sample_004', flowName: 'Invoice_PDF_Generator', errorCount: 18,
    status: 'New', ownerId: '', ownerName: '',
    latestErrorMessage: 'LIMIT_EXCEEDED: Too many SOQL queries: 101. The flow exceeded the governor limit for SOQL queries in a single transaction.',
    severity: 'Critical', isCritical: true, isAnalyzed: true,
    rootCause: 'The Invoice PDF Generator flow contains a Loop element that executes a Get Records element inside each iteration.',
    immediateAction: 'Move the Get Records element outside the Loop. Collect all needed data before entering the loop.',
    fixSteps: ['Identify the Get Records element inside the Loop', 'Move it before the Loop element', 'Store results in a Collection variable', 'Inside the loop, filter the collection instead of querying', 'Test with invoices containing 50+ line items'],
    confidenceScore: 95
  },
  {
    id: 'sample_005', flowName: 'Contact_Email_Verification', errorCount: 2,
    status: 'New', ownerId: '', ownerName: '',
    latestErrorMessage: 'An unhandled fault has occurred in this flow. The flow tried to update a record that is currently locked by another process (approval).',
    severity: 'Low', isCritical: false, isAnalyzed: false,
    rootCause: 'Not yet analyzed.', immediateAction: 'Run AI Analysis to generate recommendations.',
    fixSteps: [], confidenceScore: 0
  },
  {
    id: 'sample_006', flowName: 'Account_Territory_Assignment', errorCount: 5,
    status: 'Analyzed', ownerId: '', ownerName: '',
    latestErrorMessage: 'MIXED_DML_OPERATION: DML operation on setup object is not permitted after you have updated a non-setup object.',
    severity: 'High', isCritical: false, isAnalyzed: true,
    rootCause: 'The flow updates both a custom object and a User record in the same transaction.',
    immediateAction: 'Separate the User update into a Platform Event-triggered flow.',
    fixSteps: ['Split the flow into two flows', 'Flow 1: Update Territory_Assignment__c', 'Flow 1: Publish a Platform Event', 'Flow 2: Subscribe and update User record'],
    confidenceScore: 90
  }
];

const SAMPLE_DASHBOARD_DATA = {
  totalErrors24h: 47, criticalFlowsCount: 2, aiAnalyzedCount: 5,
  avgResolutionTime: '23m', errorsTrendPercent: 12
};

const SAMPLE_METRICS = {
  topErrorFlows: [
    { name: 'Invoice_PDF_Generator', errorCount: 18 },
    { name: 'Case_Auto_Assignment_Flow', errorCount: 12 },
    { name: 'Lead_Conversion_Process', errorCount: 7 },
    { name: 'Account_Territory_Assignment', errorCount: 5 },
    { name: 'Opportunity_Stage_Update', errorCount: 3 }
  ]
};

export default class FlowDebuggerDashboard extends LightningElement {
  @track dashboardData = null;
  @track aggregatedErrors = [];
  @track config = null;
  @track metricsData = null;
  @track activeUsers = [];

  @track timeRange = '24h';
  @track severityFilter = 'All';
  @track searchTerm = '';
  @track isLoading = true;
  @track showMetrics = false;
  @track showHelpModal = false;
  @track usingSampleData = false;
  @track sampleDataDismissed = false;
  @track allExpanded = false;

  // Edit mode
  @track isEditMode = false;
  @track editSnapshot = null;
  @track pendingEdits = {};
  @track showConfirmModal = false;

  // Pagination
  @track currentPage = 1;
  @track pageSize = '10';

  // Analysis loading
  @track isAnalyzing = false;
  @track loadingMessageIndex = 0;
  @track currentTipIndex = 0;
  loadingInterval;

  wiredDashboardResult;
  wiredConfigResult;
  searchDebounceTimer;

  severityOptions = SEVERITY_OPTIONS;
  statusOptions = STATUS_OPTIONS;
  pageSizeOptions = PAGE_SIZE_OPTIONS;

  connectedCallback() {
    this.loadData();
  }

  @wire(getActiveUsers)
  wiredUsers({ data, error }) {
    if (data) {
      this.activeUsers = [{ label: 'Unassigned', value: '' }, ...data];
    } else if (error) {
      this.activeUsers = [{ label: 'Unassigned', value: '' }];
    }
  }

  get userOptions() {
    return this.activeUsers.length > 0 ? this.activeUsers : [{ label: 'Unassigned', value: '' }];
  }

  @wire(getDebuggerConfig)
  wiredConfig(result) {
    this.wiredConfigResult = result;
    if (result.data) this.config = result.data;
  }

  @wire(getDashboardData)
  wiredDashboard(result) {
    this.wiredDashboardResult = result;
    if (result.data) this.dashboardData = result.data;
  }

  loadData() {
    this.isLoading = true;
    this.currentPage = 1;
    Promise.all([
      getAggregatedErrors({ timeRangeFilter: this.timeRange, severityFilter: this.severityFilter, searchTerm: this.searchTerm }),
      getMetricsSummary({ timeRange: this.timeRange })
    ])
      .then(([errors, metrics]) => {
        if (errors && errors.length > 0) {
          this.aggregatedErrors = errors;
          this.metricsData = metrics || {};
          this.usingSampleData = false;
        } else {
          this.loadSampleData();
        }
        this.isLoading = false;
      })
      .catch(() => { this.loadSampleData(); this.isLoading = false; });
  }

  loadSampleData() {
    if (this.sampleDataDismissed) {
      this.aggregatedErrors = []; this.dashboardData = null; this.metricsData = null; this.usingSampleData = false;
      return;
    }
    let filtered = SAMPLE_ERRORS.map(e => ({ ...e }));
    if (this.severityFilter !== 'All') filtered = filtered.filter(e => e.severity === this.severityFilter);
    if (this.searchTerm) {
      const term = this.searchTerm.toLowerCase();
      filtered = filtered.filter(e => e.flowName.toLowerCase().includes(term) || e.latestErrorMessage.toLowerCase().includes(term));
    }
    this.aggregatedErrors = filtered;
    this.dashboardData = SAMPLE_DASHBOARD_DATA;
    this.metricsData = SAMPLE_METRICS;
    this.usingSampleData = true;
  }

  dismissSampleData(event) {
    if (event) event.preventDefault();
    this.sampleDataDismissed = true; this.usingSampleData = false;
    this.aggregatedErrors = []; this.dashboardData = null; this.metricsData = null;
  }

  handleTimeRangeChange(event) {
    const range = event.currentTarget.dataset.range;
    if (range) { this.timeRange = range; this.loadData(); }
  }

  handleSeverityFilterChange(event) { this.severityFilter = event.detail.value; this.loadData(); }

  handleSearch(event) {
    this.searchTerm = event.detail.value || '';
    clearTimeout(this.searchDebounceTimer);
    this.searchDebounceTimer = setTimeout(() => this.loadData(), SEARCH_DEBOUNCE_DELAY);
  }

  handleRefresh() {
    this.sampleDataDismissed = false;
    this.isLoading = true;
    this.currentPage = 1;
    Promise.all([
      refreshApex(this.wiredDashboardResult), refreshApex(this.wiredConfigResult),
      getAggregatedErrors({ timeRangeFilter: this.timeRange, severityFilter: this.severityFilter, searchTerm: this.searchTerm }),
      getMetricsSummary({ timeRange: this.timeRange })
    ])
      .then(([, , errors, metrics]) => {
        if (errors && errors.length > 0) {
          this.aggregatedErrors = errors; this.metricsData = metrics || {}; this.usingSampleData = false;
        } else { this.loadSampleData(); }
        this.isLoading = false;
        this.showToast('Success', 'Dashboard refreshed', 'success');
      })
      .catch(() => { this.loadSampleData(); this.isLoading = false; });
  }

  // ── Pagination ──
  get totalPages() { return Math.max(1, Math.ceil(this.aggregatedErrors.length / parseInt(this.pageSize, 10))); }
  get isPrevDisabled() { return this.currentPage <= 1; }
  get isNextDisabled() { return this.currentPage >= this.totalPages; }
  get paginationLabel() { return `Page ${this.currentPage} of ${this.totalPages} (${this.aggregatedErrors.length} total)`; }

  get paginatedErrors() {
    const size = parseInt(this.pageSize, 10);
    const start = (this.currentPage - 1) * size;
    const end = start + size;
    return this.aggregatedErrors.slice(start, end);
  }

  handlePrevPage() { if (this.currentPage > 1) this.currentPage--; }
  handleNextPage() { if (this.currentPage < this.totalPages) this.currentPage++; }
  handlePageSizeChange(event) {
    this.pageSize = event.detail.value;
    this.currentPage = 1;
  }

  // ── Expand / Collapse ──
  handleRowToggle(event) {
    event.stopPropagation();
    const errorId = event.currentTarget.dataset.errorId;
    const error = this.aggregatedErrors.find(e => e.id === errorId);
    if (error) {
      error.showDetail = !error.showDetail;
      this.aggregatedErrors = [...this.aggregatedErrors];
      this.updateAllExpandedState();
      if (error.showDetail && !error.isAnalyzed && !this.usingSampleData) this.loadErrorAnalysis(error);
    }
  }

  handleToggleExpandAll() {
    const newState = !this.allExpanded;
    this.aggregatedErrors.forEach(e => { e.showDetail = newState; });
    this.aggregatedErrors = [...this.aggregatedErrors];
    this.allExpanded = newState;
    if (newState && !this.usingSampleData) {
      this.aggregatedErrors.forEach(e => { if (!e.isAnalyzed) this.loadErrorAnalysis(e); });
    }
  }

  updateAllExpandedState() {
    this.allExpanded = this.aggregatedErrors.length > 0 && this.aggregatedErrors.every(e => e.showDetail);
  }

  // ── Edit Mode ──
  handleEnterEditMode() {
    this.editSnapshot = this.aggregatedErrors.map(e => ({ id: e.id, status: e.status, ownerId: e.ownerId || '', ownerName: e.ownerName || '' }));
    this.pendingEdits = {};
    this.aggregatedErrors.forEach(e => { e.isSelected = false; });
    this.aggregatedErrors = [...this.aggregatedErrors];
    this.isEditMode = true;
  }

  handleCancelEdit() {
    if (this.editSnapshot) {
      this.editSnapshot.forEach(snap => {
        const error = this.aggregatedErrors.find(e => e.id === snap.id);
        if (error) {
          error.status = snap.status;
          error.ownerId = snap.ownerId;
          error.ownerName = snap.ownerName;
          error.isSelected = false;
        }
      });
      this.aggregatedErrors = [...this.aggregatedErrors];
    }
    this.isEditMode = false;
    this.editSnapshot = null;
    this.pendingEdits = {};
  }

  handleRowSelect(event) {
    const errorId = event.currentTarget.dataset.errorId;
    const checked = event.detail.checked;
    const error = this.aggregatedErrors.find(e => e.id === errorId);
    if (error) {
      error.isSelected = checked;
      this.aggregatedErrors = [...this.aggregatedErrors];
    }
  }

  handleSelectAll(event) {
    const checked = event.detail.checked;
    // Only toggle current page rows
    const pageIds = new Set(this.paginatedErrors.map(e => e.id));
    this.aggregatedErrors.forEach(e => {
      if (pageIds.has(e.id)) e.isSelected = checked;
    });
    this.aggregatedErrors = [...this.aggregatedErrors];
  }

  get isAllSelected() {
    const page = this.paginatedErrors;
    return page.length > 0 && page.every(e => e.isSelected);
  }

  get isSaveDisabled() {
    return Object.keys(this.pendingEdits).length === 0;
  }

  handleStatusChange(event) {
    const errorId = event.currentTarget.dataset.errorId;
    const newStatus = event.detail.value;
    const error = this.aggregatedErrors.find(e => e.id === errorId);
    if (!error) return;
    error.status = newStatus;
    if (!this.pendingEdits[errorId]) this.pendingEdits[errorId] = {};
    this.pendingEdits[errorId].status = newStatus;
    this.pendingEdits = { ...this.pendingEdits };
    this.aggregatedErrors = [...this.aggregatedErrors];
  }

  handleOwnerChange(event) {
    const errorId = event.currentTarget.dataset.errorId;
    const newOwnerId = event.detail.value;
    const error = this.aggregatedErrors.find(e => e.id === errorId);
    if (!error) return;
    error.ownerId = newOwnerId;
    // Find the user name from options
    const userOpt = this.activeUsers.find(u => u.value === newOwnerId);
    if (userOpt) error.ownerName = userOpt.label;
    if (!this.pendingEdits[errorId]) this.pendingEdits[errorId] = {};
    this.pendingEdits[errorId].ownerId = newOwnerId;
    this.pendingEdits = { ...this.pendingEdits };
    this.aggregatedErrors = [...this.aggregatedErrors];
  }

  handleSaveEdits() {
    const editIds = Object.keys(this.pendingEdits);
    if (editIds.length === 0) {
      this.showToast('Info', 'No changes to save', 'info');
      return;
    }
    this.showConfirmModal = true;
  }

  handleCancelConfirm() { this.showConfirmModal = false; }

  handleConfirmSave() {
    this.showConfirmModal = false;
    const editIds = Object.keys(this.pendingEdits);

    if (this.usingSampleData) {
      this.showToast('Success', `${editIds.length} record(s) updated (sample mode)`, 'success');
      this.isEditMode = false; this.editSnapshot = null; this.pendingEdits = {};
      this.aggregatedErrors.forEach(e => { e.isSelected = false; });
      this.aggregatedErrors = [...this.aggregatedErrors];
      return;
    }

    const promises = [];
    editIds.forEach(errorId => {
      const edits = this.pendingEdits[errorId];
      if (edits.status !== undefined) promises.push(updateErrorStatus({ errorLogId: errorId, status: edits.status }));
      if (edits.ownerId !== undefined) promises.push(updateErrorOwner({ errorLogId: errorId, ownerId: edits.ownerId || null }));
    });

    Promise.all(promises)
      .then(() => {
        this.showToast('Success', `${editIds.length} record(s) updated successfully`, 'success');
        this.isEditMode = false; this.editSnapshot = null; this.pendingEdits = {};
        this.aggregatedErrors.forEach(e => { e.isSelected = false; });
        this.aggregatedErrors = [...this.aggregatedErrors];
      })
      .catch(err => this.handleError('Error saving changes', err));
  }

  get hasPendingChanges() { return Object.keys(this.pendingEdits).length > 0; }
  get pendingChangeCount() { return Object.keys(this.pendingEdits).length; }

  get pendingChangesSummary() {
    return Object.keys(this.pendingEdits).map(errorId => {
      const error = this.aggregatedErrors.find(e => e.id === errorId);
      const snap = this.editSnapshot ? this.editSnapshot.find(s => s.id === errorId) : null;
      const edits = this.pendingEdits[errorId];
      return {
        id: errorId,
        flowName: error ? error.flowName : errorId,
        statusChanged: edits.status !== undefined && snap && edits.status !== snap.status,
        oldStatus: snap ? snap.status : '',
        newStatus: edits.status || '',
        ownerChanged: edits.ownerId !== undefined && snap && edits.ownerId !== snap.ownerId
      };
    });
  }

  // ── Analysis Actions ──
  handleRunAnalysisClick(event) {
    event.stopPropagation();
    const errorId = event.currentTarget.dataset.errorId;
    const error = this.aggregatedErrors.find(e => e.id === errorId);
    if (error) this.handleRunAnalysisForError(error);
  }

  loadErrorAnalysis(error) {
    getErrorAnalysis({ errorId: error.id })
      .then(analysis => {
        if (analysis) {
          error.rootCause = analysis.rootCause || 'Analysis pending...';
          error.immediateAction = analysis.immediateAction || 'Review error logs';
          error.fixSteps = analysis.fixSteps ? analysis.fixSteps.split('\n') : [];
          error.confidenceScore = analysis.confidenceScore || 0;
          error.isAnalyzed = true;
          this.aggregatedErrors = [...this.aggregatedErrors];
        }
      })
      .catch(err => this.handleError('Error loading analysis', err));
  }

  handleRunAdHoc() {
    this.isLoading = true;
    runAdHocAnalysis()
      .then(() => {
        this.isLoading = false;
        this.showToast('Analysis Started', 'Ad-hoc analysis initiated.', 'success');
        setTimeout(() => this.loadData(), 2000);
      })
      .catch(error => { this.isLoading = false; this.handleError('Error running analysis', error); });
  }

  handleRunAnalysisForError(error) {
    if (this.usingSampleData) {
      this.showToast('Info', 'AI analysis is simulated in sample mode', 'info');
      return;
    }
    this.startAnalysisAnimation();
    error.isAnalyzing = true;
    this.aggregatedErrors = [...this.aggregatedErrors];
    getErrorAnalysis({ errorId: error.id })
      .then(analysis => {
        if (analysis) {
          error.rootCause = analysis.rootCause || 'Analysis pending...';
          error.immediateAction = analysis.immediateAction || 'Review error logs';
          error.fixSteps = analysis.fixSteps ? analysis.fixSteps.split('\n') : [];
          error.confidenceScore = analysis.confidenceScore || 0;
          error.isAnalyzed = true;
          error.isAnalyzing = false;
          this.aggregatedErrors = [...this.aggregatedErrors];
          this.showToast('Success', 'Analysis complete', 'success');
        }
        this.stopAnalysisAnimation();
      })
      .catch(err => { this.stopAnalysisAnimation(); this.handleError('Error analyzing', err); });
  }

  // ── Analysis Loading Animation ──
  startAnalysisAnimation() {
    this.isAnalyzing = true;
    this.loadingMessageIndex = 0;
    this.currentTipIndex = Math.floor(Math.random() * FUN_TIPS.length);
    this.loadingInterval = setInterval(() => {
      if (this.loadingMessageIndex < LOADING_MESSAGES.length - 1) this.loadingMessageIndex++;
    }, 3000);
  }

  stopAnalysisAnimation() {
    this.isAnalyzing = false;
    if (this.loadingInterval) { clearInterval(this.loadingInterval); this.loadingInterval = null; }
  }

  get loadingMessage() { return LOADING_MESSAGES[this.loadingMessageIndex].main; }
  get loadingSubMessage() { return LOADING_MESSAGES[this.loadingMessageIndex].sub; }
  get analysisProgress() { return LOADING_MESSAGES[this.loadingMessageIndex].progress; }
  get funTip() { return FUN_TIPS[this.currentTipIndex]; }

  // ── Export CSV ──
  handleExportPDF() {
    const errors = this.formattedErrors;
    if (!errors || errors.length === 0) { this.showToast('Info', 'No error data to export', 'info'); return; }

    const csvRows = [];
    csvRows.push(['Flow Name', 'Errors (24h)', 'Status', 'Owner', 'Severity', 'AI Analyzed', 'Confidence Score', 'Error Message', 'Root Cause', 'Immediate Action', 'Fix Steps'].join(','));
    errors.forEach(err => {
      csvRows.push([
        this.csvEscape(err.flowName), err.errorCount, this.csvEscape(err.status),
        this.csvEscape(err.ownerDisplayName), this.csvEscape(err.severity),
        err.isAnalyzed ? 'Yes' : 'No', err.confidenceScore + '%',
        this.csvEscape(err.latestErrorMessage), this.csvEscape(err.rootCause),
        this.csvEscape(err.immediateAction), this.csvEscape((err.fixSteps || []).join('; '))
      ].join(','));
    });

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', 'FlowAIDebugger_Report_' + new Date().toISOString().slice(0, 10) + '.csv');
    link.style.display = 'none';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
    this.showToast('Success', 'Report exported as CSV', 'success');
  }

  csvEscape(value) {
    if (value == null) return '""';
    const str = String(value);
    if (str.includes(',') || str.includes('"') || str.includes('\n')) return '"' + str.replace(/"/g, '""') + '"';
    return str;
  }

  // ── Modals ──
  handleOpenHelp() { this.showHelpModal = true; }
  handleCloseHelp() { this.showHelpModal = false; }
  toggleMetrics() { this.showMetrics = !this.showMetrics; }

  showToast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }

  handleError(title, error) {
    console.error(title, error);
    let message = 'An unexpected error occurred';
    if (error && error.body && error.body.message) message = error.body.message;
    else if (error && error.message) message = error.message;
    this.showToast(title, message, 'error');
  }

  // ── Computed Properties ──
  get expandAllIcon() { return this.allExpanded ? 'utility:chevrondown' : 'utility:chevronright'; }
  get expandAllLabel() { return this.allExpanded ? 'Collapse All' : 'Expand All'; }
  get errorCountLabel() { const c = this.aggregatedErrors.length; return `${c} error${c !== 1 ? 's' : ''}`; }
  get detailColspan() { return this.isEditMode ? 11 : 10; }

  get summaryCards() {
    const data = this.dashboardData || {};
    const totalErrors = data.totalErrors24h || 0;
    const criticalFlows = data.criticalFlowsCount || 0;
    const aiAnalyzed = data.aiAnalyzedCount || 0;
    const avgResolution = data.avgResolutionTime || '0m';

    let errorSeverity = 'good';
    if (totalErrors > 50) errorSeverity = 'critical';
    else if (totalErrors > 25) errorSeverity = 'high';
    else if (totalErrors > 10) errorSeverity = 'medium';
    else if (totalErrors > 0) errorSeverity = 'warn';

    let errorTrend = 'neutral', errorTrendIcon = 'utility:dash', errorTrendText = 'No change';
    if (data.errorsTrendPercent > 0) { errorTrend = 'up'; errorTrendIcon = 'utility:arrowup'; errorTrendText = `+${data.errorsTrendPercent}%`; }
    else if (data.errorsTrendPercent < 0) { errorTrend = 'down'; errorTrendIcon = 'utility:arrowdown'; errorTrendText = `${data.errorsTrendPercent}%`; }

    return [
      { id: 1, label: 'Total Errors (24h)', value: totalErrors, icon: 'utility:error', severity: errorSeverity, trend: errorTrend, trendIcon: errorTrendIcon, trendText: errorTrendText },
      { id: 2, label: 'Critical Flows', value: criticalFlows, icon: 'utility:warning', severity: criticalFlows > 0 ? 'critical' : 'good', trend: 'neutral', trendIcon: 'utility:dash', trendText: 'No change' },
      { id: 3, label: 'AI Analyzed', value: aiAnalyzed, icon: 'utility:einstein', severity: 'info', trend: 'neutral', trendIcon: 'utility:dash', trendText: 'No change' },
      { id: 4, label: 'Avg Resolution', value: avgResolution, icon: 'utility:clock', severity: 'neutral', trend: 'neutral', trendIcon: 'utility:dash', trendText: 'No change' }
    ];
  }

  get formattedErrors() {
    // Use paginated subset
    return this.paginatedErrors.map(error => ({
      ...error,
      detailKey: error.id + '_detail',
      status: error.status || 'New',
      ownerId: error.ownerId || '',
      ownerDisplayName: error.ownerName || 'Unassigned',
      isEditable: this.isEditMode,
      isSelected: error.isSelected || false,
      truncatedMessage: error.latestErrorMessage && error.latestErrorMessage.length > MESSAGE_TRUNCATE_LENGTH
        ? error.latestErrorMessage.substring(0, MESSAGE_TRUNCATE_LENGTH) + '...' : error.latestErrorMessage || 'No error message',
      rootCause: error.rootCause || 'Not yet analyzed.',
      immediateAction: error.immediateAction || 'Run AI Analysis to generate recommendations.',
      fixSteps: error.fixSteps || [],
      hasFixSteps: error.fixSteps && error.fixSteps.length > 0,
      confidenceScore: error.confidenceScore || 0,
      confidenceExplanation: getConfidenceExplanation(error.confidenceScore || 0),
      showDetail: error.showDetail || false,
      chevronIcon: error.showDetail ? 'utility:chevrondown' : 'utility:chevronright'
    }));
  }

  get isPlatformEventsOn() { return this.config && this.config.isPlatformEventsEnabled; }
  get configStatus() { return this.isPlatformEventsOn ? 'ON' : 'OFF'; }
  get isAdHocDisabled() { return this.isPlatformEventsOn; }
  get isEmptyState() { return !this.isLoading && this.aggregatedErrors.length === 0; }

  get timeRange24hVariant() { return this.timeRange === '24h' ? 'brand' : 'neutral'; }
  get timeRange7dVariant() { return this.timeRange === '7d' ? 'brand' : 'neutral'; }
  get timeRange30dVariant() { return this.timeRange === '30d' ? 'brand' : 'neutral'; }
  get timeRangeAllVariant() { return this.timeRange === 'all' ? 'brand' : 'neutral'; }
  get metricsChevronIcon() { return this.showMetrics ? 'utility:chevrondown' : 'utility:chevronright'; }

  get topErrorFlows() {
    if (!this.metricsData || !this.metricsData.topErrorFlows) return [];
    return this.metricsData.topErrorFlows.map((flow, index) => ({ id: index, rank: index + 1, name: flow.name, count: flow.errorCount }));
  }

  get hasTopFlows() { return this.topErrorFlows && this.topErrorFlows.length > 0; }
}
