#!/usr/bin/env python3
"""
Enhanced Terraform Function Metadata Analyzer v2.0
Advanced analysis of terraform metadata functions -json output for CI/CD intelligence
"""

import json
import re
import sys
import argparse
import datetime
from collections import defaultdict, Counter
from typing import Dict, List, Set, Any, Optional, Tuple
from pathlib import Path
from dataclasses import dataclass, asdict, field
from enum import Enum

class RiskLevel(Enum):
    CRITICAL = "🔴 CRITICAL"
    HIGH = "🟠 HIGH"
    MEDIUM = "🟡 MEDIUM"
    LOW = "🟢 LOW"
    INFO = "🔵 INFO"

@dataclass
class FunctionAnalysis:
    name: str
    category: str
    risk_level: RiskLevel
    security_implications: List[str] = field(default_factory=list)
    compliance_notes: List[str] = field(default_factory=list)
    usage_recommendations: List[str] = field(default_factory=list)
    requires_approval: bool = False
    is_deterministic: bool = True

@dataclass
class ViolationDetail:
    file_path: str
    line_number: int
    function_name: str
    violation_type: str
    severity: RiskLevel
    context: str
    recommendation: str

# --- Constants for Function Categorization ---
FUNCTION_CATEGORIES = {
    # Security Critical
    'base64decode': ('Security_Critical', RiskLevel.CRITICAL, ['Credential exposure', 'Injection attacks', 'Data leakage'], ['PCI DSS', 'SOX compliance'], ['Sanitize inputs', 'Use in secure contexts only']),
    'rsadecrypt': ('Security_Critical', RiskLevel.CRITICAL, ['Private key exposure', 'Cryptographic vulnerabilities'], ['FIPS 140-2', 'Common Criteria'], ['Key rotation', 'Secure key storage']),
    'file': ('File_Operations', RiskLevel.HIGH, ['Path traversal', 'Information disclosure', 'SSRF'], ['File access controls', 'Directory traversal prevention'], ['Validate paths', 'Use relative paths']),
    'filebase64': ('File_Operations', RiskLevel.HIGH, ['Data exfiltration', 'Binary file exposure'], ['Data classification', 'Access logging'], ['Monitor file access', 'Encrypt sensitive files']),
    'templatefile': ('Template_Processing', RiskLevel.HIGH, ['Template injection', 'Code execution', 'XSS'], ['Input validation', 'Output encoding'], ['Sanitize template variables', 'Use trusted templates']),
    'nonsensitive': ('Security_Critical', RiskLevel.HIGH, ['Sensitive data exposure', 'Compliance violations'], ['Data governance', 'Audit trails'], ['Justify usage', 'Alternative solutions']),
    # Medium Risk
    'bcrypt': ('Cryptographic', RiskLevel.MEDIUM, ['Weak salt generation', 'Timing attacks'], ['Password policy compliance'], ['Use strong cost factors', 'Monitor performance']),
    'sensitive': ('Security_Critical', RiskLevel.MEDIUM, ['Over-classification', 'Performance impact'], ['Data classification policy'], ['Appropriate usage', 'Performance testing']),
    # Non-deterministic (Prohibited)
    'uuid': ('Non_Deterministic', RiskLevel.HIGH, ['Non-reproducible infrastructure', 'State drift'], ['Infrastructure consistency', 'Reproducible builds'], ['Use deterministic alternatives', 'External generation']),
    'timestamp': ('Non_Deterministic', RiskLevel.HIGH, ['Non-reproducible infrastructure', 'Plan instability'], ['Infrastructure consistency'], ['Use fixed timestamps', 'External time sources']),
    'plantimestamp': ('Non_Deterministic', RiskLevel.MEDIUM, ['Plan-time dependencies', 'Cache invalidation'], ['Build reproducibility'], ['Acceptable for specific use cases']),
}


AUTO_CATEGORY_PATTERNS = [
    (['cidr', 'ip', 'subnet', 'host'], ('Networking', RiskLevel.LOW, [], ['Network security'], ['Validate IP ranges'], False, True)),
    (['hash', 'sha', 'md5'], ('Cryptographic', RiskLevel.MEDIUM, ['Hash collisions'], ['Cryptographic standards'], ['Use strong algorithms'], False, True)),
    (['str', 'trim', 'split', 'join'], ('String_Manipulation', RiskLevel.LOW, [], [], ['Standard usage'], False, True)),
    (['to', 'bool', 'number', 'string'], ('Type_Conversion', RiskLevel.LOW, [], [], ['Validate inputs'], False, True)),
    (['list', 'set', 'map', 'element'], ('Collection_Operations', RiskLevel.LOW, [], [], ['Check bounds'], False, True)),
    (['abs', 'ceil', 'floor', 'max', 'min'], ('Mathematical', RiskLevel.LOW, [], [], ['Handle edge cases'], False, True)),
]

class TerraformFunctionAnalyzer:
    """Analyzes Terraform metadata and files for security and governance."""

    def __init__(self, metadata_json: str):
        self.metadata = json.loads(metadata_json)
        self.functions = self.metadata.get('function_signatures', {})
        self.function_analysis = self._analyze_all_functions()
        self.non_deterministic_functions = {n for n, a in self.function_analysis.items() if not a.is_deterministic}

    def _analyze_all_functions(self) -> Dict[str, FunctionAnalysis]:
        """Performs a comprehensive analysis of all functions from metadata."""
        analysis = {}
        for func_name, func_info in self.functions.items():
            clean_name = func_name.replace('core::', '')
            if clean_name in FUNCTION_CATEGORIES:
                category, risk, implications, compliance, recommendations = FUNCTION_CATEGORIES[clean_name]
                analysis[clean_name] = FunctionAnalysis(
                    name=clean_name, category=category, risk_level=risk,
                    security_implications=implications, compliance_notes=compliance,
                    usage_recommendations=recommendations,
                    requires_approval=risk in [RiskLevel.CRITICAL, RiskLevel.HIGH],
                    is_deterministic=category != 'Non_Deterministic'
                )
            else:
                analysis[clean_name] = self._auto_categorize_function(clean_name)
        return analysis

    def _auto_categorize_function(self, name: str) -> FunctionAnalysis:
        """Automatically categorizes a function based on predefined name patterns."""
        for keywords, details in AUTO_CATEGORY_PATTERNS:
            if any(kw in name.lower() for kw in keywords):
                cat, risk, impl, comp, rec, req_app, is_det = details
                return FunctionAnalysis(name, cat, risk, impl, comp, rec, req_app, is_det)
        return FunctionAnalysis(name, 'Miscellaneous', RiskLevel.LOW, usage_recommendations=['Review usage'])

    # --- Report Generation ---
    def _generate_security_report_header(self, report: List[str]):
        report.extend([
            "# 🔒 COMPREHENSIVE TERRAFORM SECURITY ANALYSIS",
            "=" * 70,
            f"Generated: {datetime.datetime.now().isoformat()}",
            f"Total Functions Analyzed: {len(self.function_analysis)}",
            ""
        ])

    def _generate_security_report_summary(self, report: List[str]):
        risk_summary = Counter(a.risk_level for a in self.function_analysis.values())
        report.extend([
            "## 📊 EXECUTIVE SUMMARY",
            f"- {risk_summary.get(RiskLevel.CRITICAL, 0)} Critical Risk Functions",
            f"- {risk_summary.get(RiskLevel.HIGH, 0)} High Risk Functions",
            f"- {risk_summary.get(RiskLevel.MEDIUM, 0)} Medium Risk Functions",
            f"- {risk_summary.get(RiskLevel.LOW, 0)} Low Risk Functions",
            f"- {len(self.non_deterministic_functions)} Non-Deterministic Functions",
            ""
        ])

    def _generate_critical_functions_section(self, report: List[str]):
        critical_funcs = {n: a for n, a in self.function_analysis.items() if a.risk_level == RiskLevel.CRITICAL}
        if not critical_funcs:
            return
        report.extend(["## 🚨 CRITICAL RISK FUNCTIONS", "These functions pose significant security risks and require immediate attention:", ""])
        for name, analysis in sorted(critical_funcs.items()):
            func_info = self.functions.get(name) or self.functions.get(f"core::{name}", {})
            report.extend([
                f"### `{name}()`",
                f"**Risk Level:** {analysis.risk_level.value}",
                f"**Category:** {analysis.category}",
                f"**Description:** {func_info.get('description', 'No description available.')}",
                ""
            ])
            if analysis.security_implications:
                report.append("**Security Implications:**")
                report.extend([f"- ⚠️  {impl}" for impl in analysis.security_implications])
                report.append("")
            if analysis.compliance_notes:
                report.append("**Compliance Considerations:**")
                report.extend([f"- 📋 {note}" for note in analysis.compliance_notes])
                report.append("")
            if analysis.usage_recommendations:
                report.append("**Recommendations:**")
                report.extend([f"- 💡 {rec}" for rec in analysis.usage_recommendations])
                report.append("")

    def _generate_nondeterministic_section(self, report: List[str]):
        if not self.non_deterministic_functions:
            return
        report.extend(["## ⚡ NON-DETERMINISTIC FUNCTIONS", "These functions break infrastructure reproducibility:", ""])
        for func_name in sorted(self.non_deterministic_functions):
            analysis = self.function_analysis[func_name]
            impact = ', '.join(analysis.security_implications)
            report.extend([f"- `{func_name}()` - {analysis.risk_level.value}", f"  Impact: {impact}"])
        report.append("")

    def _generate_categories_section(self, report: List[str]):
        categories = defaultdict(list)
        for name, analysis in self.function_analysis.items():
            categories[analysis.category].append((name, analysis))

        report.append("## 📂 FUNCTION CATEGORIES")
        for category, functions in sorted(categories.items()):
            report.extend([f"### {category.replace('_', ' ')}", f"Functions: {len(functions)}"])
            risk_groups = defaultdict(list)
            for name, analysis in functions:
                risk_groups[analysis.risk_level].append(name)
            for risk_level in sorted(risk_groups.keys(), key=lambda r: r.name, reverse=True):
                 report.append(f"- {risk_level.value}: {', '.join(sorted(risk_groups[risk_level]))}")
            report.append("")

    def generate_security_report(self) -> str:
        """Generates a detailed security analysis report in Markdown."""
        report = []
        self._generate_security_report_header(report)
        self._generate_security_report_summary(report)
        self._generate_critical_functions_section(report)
        self._generate_nondeterministic_section(report)
        self._generate_categories_section(report)
        return "\n".join(report)

    def _generate_policy_header(self, policy: List[str]):
        policy.extend([
            "# 📋 ENHANCED TERRAFORM GOVERNANCE POLICY",
            f"Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}",
            "Version: 2.0", ""
        ])

    def _generate_prohibited_policy_section(self, policy: List[str]):
        prohibited = [n for n, a in self.function_analysis.items() if not a.is_deterministic and a.risk_level in [RiskLevel.CRITICAL, RiskLevel.HIGH]]
        if not prohibited:
            return
        policy.extend(["## 🚫 PROHIBITED FUNCTIONS", "The following functions are prohibited in all environments:", ""])
        for func in sorted(prohibited):
            analysis = self.function_analysis[func]
            reason = ', '.join(analysis.security_implications)
            policy.extend([f"- ❌ `{func}()` - {analysis.risk_level.value}", f"  Reason: {reason}", ""])

    def _generate_restricted_policy_section(self, policy: List[str]):
        restricted = [n for n, a in self.function_analysis.items() if a.requires_approval and a.is_deterministic]
        if not restricted:
            return
        policy.extend(["## ⚠️  RESTRICTED FUNCTIONS - SECURITY APPROVAL REQUIRED", "These functions require security team approval and justification:", ""])
        for func in sorted(restricted):
            analysis = self.function_analysis[func]
            guideline = analysis.usage_recommendations[0] if analysis.usage_recommendations else "N/A"
            policy.extend([f"- 🔶 `{func}()` - {analysis.risk_level.value}", f"  Category: {analysis.category}", f"  Guidelines: {guideline}", ""])

    def _generate_approved_policy_section(self, policy: List[str]):
        approved = [n for n, a in self.function_analysis.items() if not a.requires_approval and a.is_deterministic]
        policy.extend(["## ✅ PRE-APPROVED FUNCTIONS", "These functions are approved for general use with standard review:", ""])

        approved_by_cat = defaultdict(list)
        for func in approved:
            approved_by_cat[self.function_analysis[func].category].append(func)

        for category, funcs in sorted(approved_by_cat.items()):
            policy.append(f"### {category.replace('_', ' ')}")
            for func in sorted(funcs):
                policy.append(f"- ✅ `{func}()`")
            policy.append("")

    def _generate_policy_footer(self, policy: List[str]):
        policy.extend([
            "## 🔄 APPROVAL PROCESS",
            "1. **Prohibited Functions**: Automatic rejection in CI/CD",
            "2. **Restricted Functions**: Manual security review required",
            "3. **Approved Functions**: Automated approval with audit logging",
            "4. **New Functions**: Default to restricted until reviewed",
            "",
            "## 📊 MONITORING & COMPLIANCE",
            "- All function usage logged and audited",
            "- Monthly compliance reports generated",
            "- Automated policy violation detection",
            "- Integration with security incident response"
        ])

    def generate_governance_policy(self) -> str:
        """Generates a governance policy document based on the function analysis."""
        policy = []
        self._generate_policy_header(policy)
        self._generate_prohibited_policy_section(policy)
        self._generate_restricted_policy_section(policy)
        self._generate_approved_policy_section(policy)
        self._generate_policy_footer(policy)
        return "\n".join(policy)

    def generate_ci_cd_report(self, scan_results: Dict[str, Any]) -> str:
        """Generates a CI/CD-friendly report from scan results."""
        if not scan_results:
            return "# 🔍 CI/CD SCAN REPORT\nNo scan results available."

        report = []
        self._add_ci_cd_report_header(report, scan_results)
        self._add_violation_summary(report, scan_results.get('violations', []))
        self._add_function_usage_stats(report, scan_results.get('functions_found', {}))

        return "\n".join(report)

    def _add_ci_cd_report_header(self, report: List[str], scan_results: Dict[str, Any]):
        """Adds the header section to the CI/CD report."""
        report.extend([
            "# 🔍 CI/CD TERRAFORM FUNCTION SCAN REPORT",
            "=" * 70,
            f"Directory Scanned: {scan_results['scan_metadata']['directory']}",
            f"Files Processed: {scan_results['files_scanned']}",
            f"Timestamp: {scan_results['scan_metadata']['timestamp']}",
            ""
        ])

    def _add_violation_summary(self, report: List[str], violations: List):
        """Adds the violation summary section to the CI/CD report."""
        if not violations:
            return

        critical_violations = self._filter_violations_by_severity(violations, RiskLevel.CRITICAL)
        high_violations = self._filter_violations_by_severity(violations, RiskLevel.HIGH)

        report.extend([
            "## 🚨 VIOLATION SUMMARY",
            f"- Critical Violations: {len(critical_violations)}",
            f"- High Risk Violations: {len(high_violations)}",
            f"- Total Violations: {len(violations)}",
            ""
        ])

        if critical_violations or high_violations:
            self._add_blocking_violations(report, critical_violations + high_violations)

    def _filter_violations_by_severity(self, violations: List, severity: RiskLevel) -> List:
        """Filters violations by severity level."""
        return [v for v in violations if
                (isinstance(v, ViolationDetail) and v.severity == severity) or
                (isinstance(v, dict) and v.get('severity') == severity.value)]

    def _add_blocking_violations(self, report: List[str], violations: List):
        """Adds blocking violations details to the report."""
        report.append("## ❌ BLOCKING VIOLATIONS")
        for violation in violations:
            self._format_violation_entry(report, violation)

    def _format_violation_entry(self, report: List[str], violation):
        """Formats a single violation entry for the report."""
        if isinstance(violation, ViolationDetail):
            report.extend([
                f"- File: {violation.file_path}:{violation.line_number}",
                f"  Function: `{violation.function_name}()` - {violation.severity.value}",
                f"  Context: {violation.context}",
                f"  Action Required: {violation.recommendation}",
                ""
            ])
        elif isinstance(violation, dict):
            report.extend([
                f"- File: {violation.get('file_path')}:{violation.get('line_number')}",
                f"  Function: `{violation.get('function_name')}()` - {violation.get('severity')}",
                f"  Context: {violation.get('context')}",
                f"  Action Required: {violation.get('recommendation')}",
                ""
            ])

    def _add_function_usage_stats(self, report: List[str], functions_found: Dict):
        """Adds function usage statistics to the report."""
        if not functions_found:
            return

        report.extend([
            "## 📈 FUNCTION USAGE STATISTICS",
            f"Total Function Calls: {sum(functions_found.values())}",
            "Top 10 Used Functions:"
        ])

        for func, count in Counter(functions_found).most_common(10):
            risk = self._get_function_risk_display(func)
            report.append(f"- `{func}()`: {count} calls - {risk}")
        report.append("")

    def _get_function_risk_display(self, func: str) -> str:
        """Gets the risk level display string for a function."""
        if func in self.function_analysis:
            return self.function_analysis[func].risk_level.value
        return "🔵 INFO"

    # --- File Scanning ---
    def scan_terraform_files(self, directory: str = ".") -> Dict[str, Any]:
        """Scans Terraform files in a directory for function usage and violations."""
        results = self._initialize_scan_results(directory)
        function_pattern = re.compile(r'\b([a-z_][a-z0-9_]*)\s*\(', re.IGNORECASE)

        for tf_file in Path(directory).rglob("*.tf"):
            try:
                content = tf_file.read_text(encoding='utf-8')
                results['files_scanned'] += 1
                lines = content.split('\n')
                self._process_file_content(content, str(tf_file), lines, function_pattern, results)
            except Exception as e:
                print(f"Error scanning {tf_file}: {e}", file=sys.stderr)
        return results

    def _initialize_scan_results(self, directory: str) -> Dict[str, Any]:
        """Initializes the dictionary to store scan results."""
        return {
            'scan_metadata': {'timestamp': datetime.datetime.now().isoformat(), 'directory': directory, 'analyzer_version': '2.0'},
            'files_scanned': 0, 'functions_found': Counter(), 'violations': [],
            'file_details': defaultdict(list), 'risk_analysis': defaultdict(int)
        }

    def _process_file_content(self, content: str, file_path: str, lines: List[str], pattern: re.Pattern, results: Dict):
        """Processes the content of a single file to find function calls and violations."""
        for match in pattern.finditer(content):
            func_name = match.group(1).lower()
            if func_name in self.function_analysis:
                self._process_function_match(match, func_name, content, file_path, lines, results)

    def _process_function_match(self, match: re.Match, func_name: str, content: str, file_path: str, lines: List[str], results: Dict):
        """Processes a single function match found in the file."""
        line_num = content[:match.start()].count('\n') + 1
        context = lines[line_num - 1].strip() if line_num <= len(lines) else ""

        self._update_function_statistics(func_name, file_path, line_num, context, results)
        self._check_for_violations(self.function_analysis[func_name], file_path, line_num, context, results)

    def _update_function_statistics(self, func_name: str, file_path: str, line_num: int, context: str, results: Dict):
        """Updates function usage statistics and file details."""
        analysis = self.function_analysis[func_name]

        results['functions_found'][func_name] += 1
        results['risk_analysis'][analysis.risk_level] += 1

        results['file_details'][file_path].append({
            'function': func_name,
            'line': line_num,
            'context': context,
            'risk_level': analysis.risk_level.value,
            'category': analysis.category
        })

    def _check_for_violations(self, analysis: FunctionAnalysis, file_path: str, line_num: int, context: str, results: Dict):
        """Checks for and records policy violations for a given function call."""
        if not analysis.is_deterministic:
            rec = analysis.usage_recommendations[0] if analysis.usage_recommendations else "Review usage"
            results['violations'].append(ViolationDetail(file_path, line_num, analysis.name, 'non_deterministic', analysis.risk_level, context, rec))

        if analysis.risk_level in [RiskLevel.CRITICAL, RiskLevel.HIGH]:
            rec = analysis.usage_recommendations[0] if analysis.usage_recommendations else "Security review required"
            results['violations'].append(ViolationDetail(file_path, line_num, analysis.name, 'high_risk', analysis.risk_level, context, rec))

    # --- Data Export ---
    def export_json_report(self, scan_results: Optional[Dict] = None) -> Dict[str, Any]:
        """Exports a comprehensive analysis and scan results as a JSON object."""
        function_analysis_serializable = self._serialize_function_analysis()
        risk_summary_serializable = self._serialize_risk_summary()
        serializable_scan_results = self._serialize_scan_results(scan_results)

        return {
            'metadata': {
                'analyzer_version': '2.0',
                'timestamp': datetime.datetime.now().isoformat()
            },
            'function_analysis': function_analysis_serializable,
            'risk_summary': risk_summary_serializable,
            'scan_results': serializable_scan_results,
        }

    def _serialize_function_analysis(self) -> Dict[str, Any]:
        """Converts function analysis to JSON-serializable format."""
        function_analysis_serializable = {}
        for name, analysis in self.function_analysis.items():
            analysis_dict = asdict(analysis)
            analysis_dict['risk_level'] = analysis.risk_level.value
            function_analysis_serializable[name] = analysis_dict
        return function_analysis_serializable

    def _serialize_risk_summary(self) -> Dict[str, int]:
        """Converts risk summary to JSON-serializable format."""
        risk_summary_serializable = {}
        for risk in RiskLevel:
            count = sum(1 for a in self.function_analysis.values() if a.risk_level == risk)
            risk_summary_serializable[risk.value] = count
        return risk_summary_serializable

    def _serialize_scan_results(self, scan_results: Optional[Dict]) -> Optional[Dict[str, Any]]:
        """Converts scan results to JSON-serializable format."""
        if not scan_results:
            return None

        serializable_scan_results = scan_results.copy()
        self._serialize_violations(serializable_scan_results, scan_results)
        self._serialize_risk_analysis(serializable_scan_results, scan_results)

        return serializable_scan_results

    def _serialize_violations(self, serializable_results: Dict, original_results: Dict):
        """Converts violation objects to JSON-serializable format."""
        if 'violations' not in original_results:
            return

        serializable_results['violations'] = []
        for violation in original_results['violations']:
            if isinstance(violation, ViolationDetail):
                violation_dict = asdict(violation)
                violation_dict['severity'] = violation.severity.value
                serializable_results['violations'].append(violation_dict)
            else:
                serializable_results['violations'].append(violation)

    def _serialize_risk_analysis(self, serializable_results: Dict, original_results: Dict):
        """Converts risk analysis enum keys to JSON-serializable format."""
        if 'risk_analysis' not in original_results:
            return

        risk_analysis_serializable = {}
        for risk_level, count in original_results['risk_analysis'].items():
            key = risk_level.value if isinstance(risk_level, RiskLevel) else str(risk_level)
            risk_analysis_serializable[key] = count
        serializable_results['risk_analysis'] = risk_analysis_serializable

def setup_arg_parser() -> argparse.ArgumentParser:
    """Sets up and returns the argument parser for the CLI."""
    parser = argparse.ArgumentParser(
        description='Enhanced Terraform Function Metadata Analyzer v2.0',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Analyze metadata from stdin and print reports
  terraform metadata functions -json | python3 analyzer_v2.py -

  # Scan a directory and export a JSON report
  python3 analyzer_v2.py metadata.json --scan-dir ./terraform --json-output report.json
        """
    )
    parser.add_argument('metadata_file', help='Metadata JSON file or - for stdin')
    parser.add_argument('--scan-dir', '-d', help='Terraform directory to scan')
    parser.add_argument('--json-output', '-j', help='Export JSON report to a file')
    parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose output')
    return parser

def main():
    """Main execution function for the CLI."""
    parser = setup_arg_parser()
    args = parser.parse_args()

    try:
        metadata_json = sys.stdin.read() if args.metadata_file == '-' else Path(args.metadata_file).read_text()
        analyzer = TerraformFunctionAnalyzer(metadata_json)
    except Exception as e:
        print(f"Error during initialization: {e}", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"🔍 Analyzing {len(analyzer.function_analysis)} functions...", file=sys.stderr)

    print(analyzer.generate_security_report())
    print("\n" + "="*70 + "\n")
    print(analyzer.generate_governance_policy())

    scan_results = None
    if args.scan_dir:
        if args.verbose:
            print(f"📂 Scanning Terraform files in: {args.scan_dir}", file=sys.stderr)
        scan_results = analyzer.scan_terraform_files(args.scan_dir)
        print("\n" + "="*70 + "\n")
        print(analyzer.generate_ci_cd_report(scan_results))

    if args.json_output:
        json_report = analyzer.export_json_report(scan_results)
        try:
            with open(args.json_output, 'w') as f:
                json.dump(json_report, f, indent=2, default=str)
            if args.verbose:
                print(f"📄 JSON report exported to: {args.json_output}", file=sys.stderr)
        except IOError as e:
            print(f"Error exporting JSON: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()

"""
Usage:
Terraform Function Metadata Analyzer:
terraform metadata functions -json | python3 analyzer_v2.py -

If you exported the schema into a json file:
python3 analyzer_v2.py metadata.json --scan-dir . --json-output report.json
"""
