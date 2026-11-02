# RB-IAM-001: IAM Users with Console Access but No MFA

**Runbook ID:** RB-IAM-001  
**Applies to:** All NorthPay AWS accounts  
**PCI-DSS Controls:** DSS 8.3 (Multi-factor authentication for all access into the CDE)  
**Last updated:** 2026-10-01  
**Owner:** NorthPay Cloud Security Team  

---

## Problem

An IAM user has AWS Console access but has not enabled MFA. PCI DSS Requirement 8.3
mandates multi-factor authentication for all non-consumer user access into the
Cardholder Data Environment (CDE) and for all remote access to the network.

This is a **CRITICAL** finding. A credential compromise (phishing, leaked password)
on an account without MFA gives an attacker full console access.

---

## Detection

Security Hub finding type: `Software and Configuration Checks/Industry and Regulatory Standards/PCI DSS`  
Finding title: `IAM.5 — MFA should be enabled for all IAM users that have console password`

Also detected by: AWS Config rule `mfa-enabled-for-iam-console-access`

---

## Risk

| Scenario | Impact |
|---|---|
| Password phishing | Full AWS console access without a second factor |
| Password leak (GitHub, Slack, etc.) | Same as above |
| PCI audit | Non-compliance finding, potential fine |

---

## Remediation

### Automated remediation
The CloudOps Agent does NOT auto-remediate this finding. Forcing MFA requires the user
to be present to enroll their device.

### Manual steps
1. Notify the user directly: "Your IAM account requires MFA. You have 48 hours to enroll."
2. Provide the enrollment link: https://console.aws.amazon.com/iam/home#/security_credentials
3. After 48 hours, if MFA is still not enabled:
   ```bash
   # Disable console access (does not delete the user)
   aws iam delete-login-profile --user-name <USERNAME>
   ```
4. Re-enable console access after the user sets up MFA:
   ```bash
   aws iam create-login-profile --user-name <USERNAME> --password-reset-required
   ```

---

## Prevention

Add this IAM policy to all IAM groups to block all actions until MFA is enrolled:

```json
{
  "Effect": "Deny",
  "NotAction": [
    "iam:CreateVirtualMFADevice",
    "iam:EnableMFADevice",
    "iam:GetUser",
    "iam:ListMFADevices",
    "sts:GetSessionToken"
  ],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": {
      "aws:MultiFactorAuthPresent": "false"
    }
  }
}
```

---

## PCI DSS Context

PCI DSS 8.3.1 requires MFA for all non-consumer user access to system components in the
Cardholder Data Environment. Failure to comply can result in:
- Failed PCI audit and loss of card processing ability
- Regulatory fines from card brands (Visa, Mastercard)
- Mandatory forensic investigation if a breach occurs
