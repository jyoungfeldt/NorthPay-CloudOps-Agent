# NorthPay CloudOps Agent

[![CI](https://github.com/jyoungfeldt/northpay-cloudops-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/jyoungfeldt/northpay-cloudops-agent/actions/workflows/ci.yml)

An AI agent that acts as a junior cloud operations engineer. It finds security and cost problems in NorthPay's AWS accounts, explains each finding using the company's runbooks, proposes a fix, and applies it only after a human approves it.

> **Related project:** [NorthPay Payments Platform on EKS](https://github.com/jyoungfeldt/northpay-eks-platform) — the agent can triage security findings and alerts from that cluster.

---

## The Problem

NorthPay's cloud operations team deals with a constant stream of Security Hub findings, AWS Config non-compliance alerts, cost anomalies, and PCI-DSS audit requests. Triaging and reporting on these manually takes hours every week, and remediations require careful human review before anything changes in production.

This project automates the triage, explanation, and remediation proposal — with a human in the loop for every change.

---

## What it Does

```
User: "Which S3 buckets are public, and what does our runbook say to do?"

Agent:
  1. Calls Security Hub tool  → finds 3 public buckets
  2. Calls Knowledge Base     → retrieves NorthPay runbook RB-S3-001
  3. Explains the PCI-DSS control at risk and proposes BlockPublicAccess
  4. Sends approval request   → Step Functions pauses, SNS sends email/Slack link
  5. Human approves           → Lambda applies PutPublicAccessBlock on each bucket
  6. Logs the action          → DynamoDB audit trail with 90-day TTL
```

---

## Architecture

```
 Ops Engineer
      │
      ▼
 Streamlit Chat UI
      │  chat prompt
      ▼
 ┌──────────────────────────────────────────────────────────────┐
 │  Amazon Bedrock AgentCore  (Strands Agents SDK)              │
 │                                                              │
 │  Claude 3.5 Sonnet  ─  ReAct loop  ─  Bedrock Guardrails    │
 │                                                              │
 │  Tools:                    Knowledge Base (RAG):             │
 │  ├── Security Hub query    ├── S3: NorthPay runbooks         │
 │  ├── Cost Explorer query   ├── Bedrock KB (Titan Embed V2)   │
 │  ├── IAM Analyzer query    └── OpenSearch Serverless         │
 │  └── propose_and_request_approval                            │
 └───────────────────────┬──────────────────────────────────────┘
                         │ tool calls
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    Lambda           Lambda          Lambda
  (Security Hub)  (Cost Explorer)  (IAM Analyzer)   ← read-only IAM
         │
         ▼ propose fix
  Step Functions  ──────────────────────────▶  SNS  ──▶  Human
  (waitForTaskToken)                                        │
         │◀──────────────────── approve / reject ───────────┘
         │
         ▼ approved
  Remediation Lambda  ──▶  AWS APIs  (e.g. PutPublicAccessBlock)
         │
         ▼
  DynamoDB audit log  (every tool call + every approval)
```

---

## Stack

| Component | Service |
|---|---|
| Agent runtime | Strands Agents SDK on Amazon Bedrock AgentCore |
| Model | Claude 3.5 Sonnet (Bedrock Converse API) |
| Tool actions | Lambda — Security Hub, Cost Explorer, IAM Analyzer, Remediation |
| Knowledge / RAG | Bedrock Knowledge Base over S3, Titan Embeddings V2, OpenSearch Serverless |
| Approval | Step Functions `waitForTaskToken` — pauses until human approves or rejects |
| Safety | Bedrock Guardrails (topic policy + PII filter), least-privilege IAM per tool |
| Audit | DynamoDB — every tool call and approval logged, 90-day TTL |
| Interface | Streamlit chat UI |
| Evaluation | 25-prompt test suite in GitHub Actions CI |

---

## Design Decisions

### Strands Agents SDK over native Bedrock Agents
Bedrock Agents (the managed service) is well-integrated but limits control over the ReAct loop and tool retry logic. Strands gives full control over agent behavior and is the foundation for multi-agent patterns if this project grows to include a security analyst agent and a cost analyst agent coordinated by a supervisor.

### Step Functions `waitForTaskToken` for approval
A clean, serverless pause-and-wait pattern. The state machine suspends until a human clicks approve or reject in the email/Slack link. The alternative — polling a DynamoDB flag — is simpler but doesn't scale and doesn't produce a visual execution history (which is a useful demo artifact).

### Hierarchical chunking for the Knowledge Base
Runbooks have a natural parent/child structure: a top-level summary and detailed remediation steps. Hierarchical chunking stores parent chunks at 1500 tokens for context and child chunks at 300 tokens for retrieval precision. This improves citation quality compared to fixed-size chunking.

### Read-only by default
All query Lambda functions have IAM policies that allow only read operations. The remediation Lambda is a separate function with a separate scoped role and cannot run without a valid Step Functions approval token. This separation is demonstrated explicitly in the demo.

### Bedrock Guardrails for scope control
The guardrail denies off-topic requests, anonymizes PII in responses, and blocks any prompt that attempts to extract credentials. Essential for a tool that has read access to security findings and cost data.

---

## Runbooks in the Knowledge Base

| ID | Topic | PCI-DSS Control |
|---|---|---|
| RB-S3-001 | S3 public access — detection and remediation | DSS 3.4, 7.2 |
| RB-S3-002 | S3 bucket encryption at rest | DSS 3.5 |
| RB-IAM-001 | IAM users with console access but no MFA | DSS 8.3 |
| RB-IAM-002 | IAM access keys older than 90 days | DSS 8.6 |
| RB-IAM-003 | Overly permissive IAM policies (`Allow *`) | DSS 7.1 |
| RB-EC2-001 | Security groups with `0.0.0.0/0` ingress | DSS 1.3 |
| RB-EC2-002 | Unencrypted EBS volumes | DSS 3.5 |
| RB-RDS-001 | RDS instances not encrypted | DSS 3.5 |
| RB-RDS-002 | RDS publicly accessible | DSS 1.3 |
| RB-CT-001 | CloudTrail not enabled or incomplete | DSS 10.2 |
| RB-COST-001 | EC2 rightsizing — cost anomaly investigation | — |
| RB-COST-002 | Unattached EBS volumes and unused Elastic IPs | — |

---

## Prerequisites

- AWS account with Bedrock model access enabled for Claude 3.5 Sonnet (`us-east-1`)
- Terraform ≥ 1.8
- Python 3.12+

### GitHub Secrets

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | IAM role assumed via GitHub OIDC (no long-lived keys) |
| `AWS_REGION` | e.g. `us-east-1` |

---

## Deploy

```bash
# 1. Deploy infrastructure
cd terraform/environments/dev
terraform init
terraform apply

# 2. Upload runbooks (triggers Bedrock KB sync)
aws s3 sync agent/runbooks/ s3://$(terraform output -raw runbooks_bucket_name)/runbooks/

# 3. Run the chat UI locally
cd app/streamlit
pip install -r requirements.txt
export KNOWLEDGE_BASE_ID=$(cd ../../terraform/environments/dev && terraform output -raw knowledge_base_id)
export GUARDRAIL_ID=$(cd ../../terraform/environments/dev && terraform output -raw guardrail_id)
# ... (see terraform outputs for remaining env vars)
streamlit run app.py
```

---

## Demo

📹 [Watch the 5-minute demo](https://www.loom.com/YOUR_LINK) — covers all three scenarios below.

### Scenario 1: Public S3 buckets
```
"Which S3 buckets are public, and what does our runbook say to do?"
```
Agent queries Security Hub, retrieves RB-S3-001, cites the PCI DSS 3.4 control, proposes `PutPublicAccessBlock`, waits for approval, then applies the fix.

### Scenario 2: Cost anomaly
```
"Why did our bill jump last week?"
```
Agent queries Cost Explorer anomalies, identifies the service and region responsible, and suggests rightsizing actions per RB-COST-001.

### Scenario 3: PCI audit report
```
"Summarize our PCI-relevant findings for an auditor."
```
Agent queries Security Hub with a PCI filter, maps each finding to a DSS control via the Knowledge Base, and produces a structured markdown report.

---

## Evaluation

The CI pipeline runs 25 test prompts on every push to `main` and asserts that the agent calls the correct tools, cites a runbook when one exists, and does not apply any remediation without an approval token.

```bash
cd agent/evaluation
python run_eval.py --env dev
```

---

## Architecture Diagram

The draw.io source is at [`docs/architecture.drawio`](docs/architecture.drawio). Open it at [app.diagrams.net](https://app.diagrams.net) or with the draw.io VS Code extension.

---

## Cost

| Resource | Approx. monthly cost |
|---|---|
| Bedrock model tokens (light usage) | $2–10 |
| Bedrock Knowledge Base + OpenSearch Serverless | $5–15 |
| Lambda, Step Functions, DynamoDB, S3 | < $3 combined |
| **Total** | **~$10–30/month** |

---

## Teardown

```bash
cd terraform/environments/dev
terraform destroy
```

The OpenSearch Serverless collection backing the Knowledge Base can take 5–10 minutes to delete.

---

## Repository Structure

```
northpay-cloudops-agent/
├── .github/workflows/
│   └── ci.yml              # lint → unit tests → Terraform validate → eval suite
├── agent/
│   ├── evaluation/         # 25-prompt eval suite + runner
│   ├── runbooks/           # 12 Markdown runbooks uploaded to S3
│   └── tools/              # Lambda function source (security_hub, cost_explorer, remediate)
├── app/streamlit/          # Chat UI (agent.py + app.py)
├── docs/
│   └── architecture.drawio
└── terraform/
    ├── modules/            # bedrock-agent, lambda-tools, knowledge-base,
    │                       # step-functions, dynamodb, guardrails
    └── environments/dev/
```
