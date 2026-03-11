#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Terraform Function Analyzer - Professional Edition
Includes:
- Parallel scanning for improved performance.
- Inline fix suggestions for actionable feedback.
- Dynamic analysis of Terraform files based on a policy.
- Static generation of a security and governance report.
- Clean JSON + colored text output for analysis.
- Conditional build failure based on severity level.
- Robust policy normalization and STDIN parsing.
- Polished reporting with tables and summaries.
- Concise summary-only output mode for CI/CD.
"""
import json
import os
import re
import sys
import argparse
import yaml
import concurrent.futures
from collections import defaultdict
from typing import Dict, Any, List, Set, Optional

class Colors:
    HEADER = '\x1b[95m'
    BLUE = '\x1b[94m'
    CYAN = '\x1b[96m'
    GREEN = '\x1b[92m'
    WARNING = '\x1b[93m'
    FAIL = '\x1b[91m'
    ENDC = '\x1b[0m'
    BOLD = '\x1b[1m'
    UNDERLINE = '\x1b[4m'

# --- Static Data for Documentation Generation ---
RISK_HIGH = "🔴 HIGH"
RISK_MEDIUM = "🟡 MEDIUM"
RISK_INFO = "🟢 INFORMATIONAL"

CRITICAL_FUNCTIONS = [
    {"name": "file()", "risk": RISK_HIGH, "desc": "Reads the contents of a file...", "impl": "⚠️ **Path Traversal & Arbitrary File Read.**..."},
    {"name": "templatefile()", "risk": RISK_HIGH, "desc": "Renders a file as a template...", "impl": "⚠️ **Template Injection & Code Execution.**..."},
    {"name": "rsadecrypt()", "risk": RISK_HIGH, "desc": "Decrypts an RSA-encrypted ciphertext...", "impl": "⚠️ **Private Key Handling.**..."},
    {"name": "base64decode()", "risk": RISK_MEDIUM, "desc": "Decodes a Base64-encoded string.", "impl": "⚠️ **Credential Exposure & Injection.**..."},
    {"name": "sensitive()", "risk": RISK_INFO, "desc": "Marks a value as sensitive...", "impl": "While this function is a security *feature*..."},
    {"name": "nonsensitive()", "risk": RISK_HIGH, "desc": "Removes the \"sensitive\" marking...", "impl": "⚠️ **Sensitive Data Exposure.**..."},
    {"name": "filebase64()", "risk": RISK_HIGH, "desc": "Reads a file and returns its contents...", "impl": "⚠️ **File Content Exposure & Path Traversal.**..."}
]

# --- Documentation Generation ---
def generate_static_report():
    """Generates and prints a static Markdown report for security and governance."""
    from datetime import datetime, timezone

    report_lines = [
        "# 🔒 TERRAFORM FUNCTION SECURITY ANALYSIS REPORT",
        f"\n_Generated: {datetime.now(timezone.utc).isoformat()}_\n",
        "This document describes Terraform functions that commonly pose security or governance risks,",
        "their severity, and recommended mitigations.\n",
        "---\n",
        "## ⚠️ Function risk matrix\n"
    ]

    for fn in CRITICAL_FUNCTIONS:
        name = fn.get("name", "<unknown>")
        risk = fn.get("risk", "")
        desc = fn.get("desc", "").strip()
        impl = fn.get("impl", "").strip()
        report_lines.append(f"### `{name}` — {risk}")
        if desc:
            report_lines.extend(["", desc])
        if impl:
            report_lines.extend(["", "**Notes / Implementation risk:**", "", impl])
        report_lines.extend(["", "---", ""])

    report_lines.extend([
        "## ✅ Recommended mitigations and best-practices\n",
        "- Avoid reading local files from Terraform with `file()` on untrusted inputs; use external provisioning steps instead.",
        "- Keep secrets out of repo; use Vault/Secrets Manager and pass secrets via secure mechanisms.",
        "- Avoid `templatefile()` with user-controlled templates — sanitize inputs or render templates outside Terraform.",
        "- Treat `base64decode()` and similar decoding functions as potentially exposing secrets; prefer secret backends.",
        "- Use `sensitive()` to mark outputs/variables and prefer provider mechanisms for secret handling.\n",
        "## 🔧 Suggested policy examples (YAML)\n",
        "```yaml",
        "prohibited:",
        "  file: \"Prohibited — arbitrary file reads are not allowed.\"",
        "  templatefile: \"Prohibited — remote/template injection risk.\"",
        "",
        "restricted:",
        "  base64decode:",
        "    reason: \"Decoding may reveal credentials or secrets.\"",
        "    severity: \"WARNING\"",
        "    suggestion: \"Avoid decoding secrets in Terraform; use secret managers.\"",
        "```\n",
        "## 📚 Additional notes\n",
        "- This report is generated from the `CRITICAL_FUNCTIONS` table present in `tf_security_scan.py`.",
        "- You can extend this function to write the output to a file (e.g. `--docs-out <file.md>`).\n"
    ])

    print("\n".join(report_lines))

# --- Policy Handling ---
def normalize_policy(policy_data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Normalizes the policy for efficient lookups."""
    normalized = {"prohibited": {}, "restricted": {}}
    default_suggestion = "Review usage against security best practices."

    if isinstance(policy_data.get('prohibited'), dict):
        for func, reason in policy_data['prohibited'].items():
            normalized["prohibited"][func] = {
                "reason": reason, "severity": "CRITICAL",
                "suggestion": "This function is prohibited; consider a different approach."
            }

    if isinstance(policy_data.get('restricted'), dict):
        for func, details in policy_data['restricted'].items():
            if isinstance(details, dict):
                normalized["restricted"][func] = {
                    "reason": details.get("reason", "No reason specified."),
                    "severity": details.get("severity", "WARNING").upper(),
                    "suggestion": details.get("suggestion", default_suggestion)
                }
            else:
                normalized["restricted"][func] = {
                    "reason": details, "severity": "WARNING", "suggestion": default_suggestion
                }
    return normalized

def load_policy_file(policy_path: str) -> Dict[str, Any]:
    """Loads and normalizes a policy file from YAML or JSON."""
    try:
        with open(policy_path, 'r', encoding='utf-8') as f:
            raw_policy = yaml.safe_load(f) if policy_path.endswith(('.yaml', '.yml')) else json.load(f)
        return normalize_policy(raw_policy)
    except (IOError, yaml.YAMLError, json.JSONDecodeError) as e:
        sys.exit(f"{Colors.FAIL}Error: Could not load or parse policy file '{policy_path}'. {e}{Colors.ENDC}")

# --- File Scanning Logic ---
def _get_violation(func: str, occurrence: Dict, policy: Dict) -> Optional[Dict]:
    """Checks for and returns a violation dictionary if a function call matches policy."""
    if func in policy['prohibited']:
        return {**occurrence, **policy['prohibited'][func]}
    if func in policy['restricted']:
        return {**occurrence, **policy['restricted'][func]}
    return None

def scan_single_file(file_path: str, func_regex: re.Pattern, policy: Dict[str, Any]) -> tuple:
    """Scans a single Terraform file for function calls and policy violations."""
    function_calls, occurrences, violations = defaultdict(int), [], []
    comment_regex = re.compile(r'^\s*(#|//|/\*).*')
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                if comment_regex.match(line):
                    continue
                for func in func_regex.findall(line):
                    function_calls[func] += 1
                    occurrence = {"function": func, "file": file_path, "line": line_num, "code_line": line.strip()}
                    occurrences.append(occurrence)
                    violation = _get_violation(func, occurrence, policy)
                    if violation:
                        violations.append(violation)
    except IOError as e:
        print(f"{Colors.WARNING}Could not read {file_path}: {e}{Colors.ENDC}", file=sys.stderr)
    return function_calls, occurrences, violations

def find_tf_files(directory: str) -> List[str]:
    """Finds all .tf files in a directory recursively."""
    return [os.path.join(root, file) for root, _, files in os.walk(directory) for file in files if file.endswith('.tf')]

def aggregate_scan_results(futures: Dict) -> tuple:
    """Aggregates results from parallel file scans."""
    total_calls, total_occurrences, total_violations = defaultdict(int), [], []
    for future in concurrent.futures.as_completed(futures):
        try:
            calls, occurrences, violations = future.result()
            for func, count in calls.items():
                total_calls[func] += count
            total_occurrences.extend(occurrences)
            total_violations.extend(violations)
        except Exception as e:
            print(f"Error processing a file during scan: {e}", file=sys.stderr)
    return total_calls, total_occurrences, total_violations

def scan_terraform_files(directory: str, all_functions: Set[str], policy: Dict[str, Any], context_lines: int) -> Dict[str, Any]:
    """Scans Terraform files in parallel and aggregates the results."""
    func_regex = re.compile(r'\b(' + '|'.join(re.escape(f) for f in all_functions) + r')\b\s*\(')
    tf_files = find_tf_files(directory)

    with concurrent.futures.ThreadPoolExecutor() as executor:
        future_to_file = {executor.submit(scan_single_file, fp, func_regex, policy): fp for fp in tf_files}
        calls, occurrences, violations = aggregate_scan_results(future_to_file)

    for v in violations:
        v["context"] = extract_context(v['file'], v['line'], context_lines, v['function'])

    return {
        "scanned_files": len(tf_files),
        "function_calls": dict(calls),
        "occurrences": occurrences,
        "violations": violations
    }

# --- Reporting and Output ---
def extract_context(file_path: str, target_line: int, context_lines: int, func: str) -> List[str]:
    """Extracts context lines around a target line, highlighting the function call."""
    context_output = []
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        start, end = max(0, target_line - context_lines - 1), min(len(lines), target_line + context_lines)
        for i in range(start, end):
            line_num = i + 1
            prefix = f"{Colors.FAIL}>" if line_num == target_line else " "
            clean_line = lines[i].rstrip("\n").replace(func, f"{Colors.BOLD}{Colors.FAIL}{func}{Colors.ENDC}")
            context_output.append(f"{prefix} {line_num:2d}:{Colors.ENDC} {clean_line}")
    except IOError as e:
        context_output.append(f"# Could not read context: {e}")
    return context_output

def print_json_report(scan_results: Dict[str, Any]):
    """Prints the scan results in JSON format, cleaning ANSI color codes."""
    for v in scan_results.get('violations', []):
        if 'context' in v:
            v['context'] = [re.sub(r'\x1b\[[0-9;]*m', '', line) for line in v['context']]
    print(json.dumps(scan_results, indent=2))

def print_text_report(scan_results: Dict[str, Any], summary_only: bool):
    """Prints a human-readable text report."""
    violations = scan_results.get('violations', [])
    print(f"\n{Colors.BOLD}# 🔄 CI/CD TERRAFORM FUNCTION ANALYSIS{Colors.ENDC}")
    print("=" * 50)
    print(f"- Files Scanned: {scan_results['scanned_files']}")
    print(f"- Unique Functions Used: {len(scan_results['function_calls'])}")
    print(f"- Total Function Calls: {sum(scan_results['function_calls'].values())}")
    print(f"- {Colors.FAIL}Security/Policy Violations: {len(violations)}{Colors.ENDC}")

    if not violations:
        return

    print("\n## 🚨 VIOLATIONS SUMMARY")
    print(f"{'Function':<15} {'Severity':<10} {'File:Line':<30} {'Suggestion'}")
    print("-" * 80)
    for v in violations:
        color = Colors.FAIL if v['severity'] == 'CRITICAL' else Colors.WARNING
        print(f"{v['function']:<15} {color}{v['severity']:<10}{Colors.ENDC} {v['file']}:{v['line']:<25} {v['suggestion']}")

    if not summary_only:
        print("\n## 📜 VIOLATION DETAILS")
        for v in violations:
            color = Colors.FAIL if v['severity'] == 'CRITICAL' else Colors.WARNING
            print(f"\n[{color}{v['severity']}{Colors.ENDC}] `{v['function']}()` in {v['file']}:{v['line']}")
            print(f"   Reason: {v['reason']}")
            print(f"   💡 Suggestion: {Colors.CYAN}{v['suggestion']}{Colors.ENDC}")
            for ctx_line in v['context']:
                print(ctx_line)

def determine_exit_code(violations: List[Dict], fail_on_severity: str, output_format: str) -> int:
    """Determines the exit code based on violation severity."""
    if not violations:
        if output_format == "text":
            print(f"\n{Colors.GREEN}✅ No violations detected. Build passing.{Colors.ENDC}")
        return 0

    severity_map = {'WARNING': 1, 'CRITICAL': 2}
    fail_level = severity_map.get(fail_on_severity, 1)
    highest_violation_level = max(severity_map.get(v.get('severity', 'WARNING'), 1) for v in violations)

    if highest_violation_level >= fail_level:
        if output_format == "text":
            print(f"\n{Colors.FAIL}Build failed: Violations met or exceeded threshold (>= {fail_on_severity or 'WARNING'}).{Colors.ENDC}")
        return 1

    if output_format == "text":
        print(f"\n{Colors.GREEN}✅ Violations found, but none met the --fail-on '{fail_on_severity}' threshold. Build will pass.{Colors.ENDC}")
    return 0

def generate_cicd_report(scan_results: Dict[str, Any], output_format: str, fail_on_severity: str, summary_only: bool) -> int:
    """Orchestrates report generation and determines the final exit code."""
    if output_format == "json":
        print_json_report(scan_results)
    else:
        print_text_report(scan_results, summary_only)
    return determine_exit_code(scan_results.get('violations', []), fail_on_severity, output_format)

# --- Main Execution ---
def setup_arg_parser() -> argparse.ArgumentParser:
    """Sets up and returns the argument parser."""
    parser = argparse.ArgumentParser(description="Professional Terraform Function Analyzer", formatter_class=argparse.RawTextHelpFormatter)
    scan_group = parser.add_argument_group('Scanning Options')
    scan_group.add_argument("metadata_source", nargs='?', help="Path to metadata JSON file, or '-' for stdin.")
    scan_group.add_argument("scan_directory", nargs='?', help="Directory with Terraform (.tf) files to scan.")
    scan_group.add_argument("--policy", help="Path to policy YAML/JSON file.")

    control_group = parser.add_argument_group('Output and Control Options')
    control_group.add_argument("--output", choices=["text", "json"], default="text", help="Output format.")
    control_group.add_argument("--context-lines", type=int, default=2, help="Number of context lines around a match.")
    control_group.add_argument("--fail-on", choices=["WARNING", "CRITICAL"], help="Fail if violations of this severity or higher are found.")
    control_group.add_argument("--summary-only", action="store_true", help="Show only a summary table.")

    doc_group = parser.add_argument_group('Documentation')
    doc_group.add_argument("--generate-docs", action="store_true", help="Generate a static security report and exit.")
    return parser

def load_metadata(metadata_source: str) -> Dict[str, Any]:
    """Loads metadata from a file path or stdin."""
    try:
        if metadata_source == '-':
            content = sys.stdin.read()
            json_start = content.find('{')
            if json_start == -1:
                raise json.JSONDecodeError("No JSON object found in stdin", content, 0)
            return json.loads(content[json_start:])
        else:
            with open(metadata_source, 'r', encoding='utf-8') as f:
                return json.load(f)
    except json.JSONDecodeError as e:
        sys.exit(f"{Colors.FAIL}Error: Failed to parse metadata JSON. {e}{Colors.ENDC}")
    except FileNotFoundError:
        sys.exit(f"{Colors.FAIL}Error: Metadata file not found at '{metadata_source}'.{Colors.ENDC}")

def main():
    """Main execution function."""
    parser = setup_arg_parser()
    args = parser.parse_args()

    if args.generate_docs:
        generate_static_report()
        sys.exit(0)

    if not all([args.metadata_source, args.scan_directory, args.policy]):
        parser.error("metadata_source, scan_directory, and --policy are required for scanning.")

    metadata = load_metadata(args.metadata_source)
    policy = load_policy_file(args.policy)
    function_names = {k.replace("core::", "") for k in metadata.get("function_signatures", {})}

    scan_results = scan_terraform_files(args.scan_directory, function_names, policy, args.context_lines)
    exit_code = generate_cicd_report(scan_results, args.output, args.fail_on, args.summary_only)
    sys.exit(exit_code)

if __name__ == "__main__":
    main()

# --- Example Usage ---
# To generate documentation:
# python3 tf_security_scan.py --generate-docs > terraform_security_scan_report.md
#
# For human-readable scan output:
# terraform metadata functions -json | python3 tf_security_scan.py - . --policy whitelist.yml --output text
#
# For CI/CD with build failure on CRITICAL violations:
# terraform metadata functions -json | python3 tf_security_scan.py - . --policy whitelist.yml --output json --fail-on CRITICAL
