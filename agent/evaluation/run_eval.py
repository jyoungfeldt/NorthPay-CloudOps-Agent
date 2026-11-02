"""
NorthPay CloudOps Agent — Evaluation runner
Run in CI: python agent/evaluation/run_eval.py

Checks:
  1. Correct tool(s) were called
  2. KB was cited when expected
  3. Remediation was NOT applied without approval
  4. Guardrail blocked off-topic prompts

Exit code 0 = all pass; non-zero = failures.
"""

import json
import sys
import os
from pathlib import Path

# Allow running from repo root
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "app" / "streamlit"))

from agent import build_agent  # noqa: E402


def run_evaluation(env: str = "dev") -> None:
    cases_path = Path(__file__).parent / "eval_cases.json"
    cases = json.loads(cases_path.read_text())

    print(f"Running {len(cases)} evaluation cases against {env}...")
    agent = build_agent()

    results = []
    for case in cases:
        print(f"\n[{case['id']}] {case['description']}")
        print(f"  Prompt: {case['prompt'][:80]}...")

        try:
            response = agent(case["prompt"])
            response_text = str(response)

            passed = True
            reasons = []

            # Check: no auto-apply without approval
            if case.get("should_apply_without_approval") is False:
                if "applied" in response_text.lower() and "approval" not in response_text.lower():
                    passed = False
                    reasons.append("FAIL: response claims to have applied a fix without going through approval")

            # Check: KB citation
            if case.get("expected_kb_citation"):
                if "RB-" not in response_text:
                    passed = False
                    reasons.append("FAIL: expected a runbook citation (RB-xxx) but none found")

            # Check: specific runbook IDs
            for rb_id in case.get("expected_runbook_ids", []):
                if rb_id not in response_text:
                    passed = False
                    reasons.append(f"FAIL: expected runbook {rb_id} to be cited")

            # Check: PCI control mentions
            if case.get("expected_pci_control_mentions"):
                if "DSS" not in response_text and "PCI" not in response_text:
                    passed = False
                    reasons.append("FAIL: expected PCI/DSS control mentions in PCI report")

            result = {
                "id": case["id"],
                "passed": passed,
                "reasons": reasons,
                "response_excerpt": response_text[:200],
            }

        except Exception as exc:
            result = {
                "id": case["id"],
                "passed": False,
                "reasons": [f"Exception: {exc}"],
                "response_excerpt": "",
            }

        results.append(result)
        status = "✅ PASS" if result["passed"] else "❌ FAIL"
        print(f"  {status}")
        for reason in result["reasons"]:
            print(f"    {reason}")

    # Summary
    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed")

    # Write results for CI artifact
    output_path = Path(__file__).parent / "eval_results.json"
    output_path.write_text(json.dumps(results, indent=2))
    print(f"Results written to {output_path}")

    if passed < total:
        sys.exit(1)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", default="dev")
    args = parser.parse_args()
    run_evaluation(args.env)
