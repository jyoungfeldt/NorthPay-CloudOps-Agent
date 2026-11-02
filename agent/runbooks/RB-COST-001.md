# RB-COST-001: EC2 Cost Anomaly Investigation and Rightsizing

**Runbook ID:** RB-COST-001  
**Applies to:** All NorthPay AWS accounts  
**PCI-DSS Controls:** N/A (operational)  
**Last updated:** 2026-10-01  
**Owner:** NorthPay Platform Engineering  

---

## Problem

AWS Cost Explorer has detected an anomaly — spending on EC2 is significantly above
the expected baseline. This runbook guides investigation and remediation.

---

## Detection

- Cost Explorer anomaly alert
- CloudWatch billing alarm breach
- Finance team escalation

---

## Investigation Steps

### Step 1: Identify the anomaly source

```bash
# Find which service, region, and account drove the increase
aws ce get-anomalies \
  --date-interval Start=<YYYY-MM-DD>,End=<YYYY-MM-DD> \
  --total-impact NumericOperator=GREATER_THAN,StartValue=50
```

### Step 2: Break down by instance type

```bash
# Which instance types are costing the most?
aws ce get-cost-and-usage \
  --time-period Start=<START>,End=<END> \
  --granularity DAILY \
  --group-by Type=DIMENSION,Key=INSTANCE_TYPE \
  --metrics UnblendedCost
```

### Step 3: Find idle or underutilised instances

```bash
# Check Compute Optimizer for rightsizing recommendations
aws compute-optimizer get-ec2-instance-recommendations \
  --filters Name=Finding,Values=OVER_PROVISIONED
```

---

## Common Causes

| Cause | Indicator | Fix |
|---|---|---|
| Forgotten load test | Spike on a specific date, ended by end of day | Terminate instances |
| Auto Scaling runaway | Gradual increase, many instances | Fix ASG cooldown/scale-in |
| Wrong instance type deployed | High per-hour cost for few instances | Rightsize or use Spot |
| Data transfer | Cost in `AWS Data Transfer` not `EC2` | Review cross-AZ traffic |
| Unattached EBS volumes | Low compute cost but EBS cost growing | See RB-COST-002 |

---

## Rightsizing Actions

After identifying over-provisioned instances:

```bash
# Check current utilization (last 14 days average CPU)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=<INSTANCE_ID> \
  --start-time $(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average
```

If average CPU < 10% for 14 days: recommend rightsizing down one instance size.  
If average CPU < 5% for 14 days: consider consolidating workloads or terminating.

---

## Escalation

If the anomaly is > $500 or involves production infrastructure:
1. Page the on-call engineer via PagerDuty.
2. Open a cost review Jira ticket.
3. Present findings in the next weekly engineering review.
