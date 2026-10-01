# Phases 1 & 2: Detailed Breakdown

This assumes AWS, since the rubric references S3, SSM, Secrets Manager, Terraform and CloudFormation. The code snippets below are syntax references in the spirit of the "AI as tutor" policy. You still need to write the final policies yourself, adapt them, and be able to defend every line in the phase review.

**One question first:** is your class using **AWS Academy Learner Lab** or real personal/team accounts? Learner Lab typically limits you to us-east-1/us-west-2 and won't let you create IAM roles (you get a pre-made `LabRole`). That changes Phase 2 a lot, so I've flagged where it matters.

---

## Phase 1: Brand Launch & Compliance Retention

**Due: during Lab 2.** The **team charter** is also due with Phase 1, so don't forget it.

### Bucket layout

A clean design uses three primary buckets plus their replicas:

| Bucket | Purpose | Public? | Key features |
|---|---|---|---|
| `aura-marketing-<suffix>` | Static site | Yes (read-only) | Website hosting, bucket policy |
| `aura-compliance-<suffix>` | Onboarding PDFs | No | Versioning, Object Lock (Compliance), lifecycle, replication |
| `aura-logs-<suffix>` | Access logs | No | Lifecycle to Glacier |
| `*-replica` versions in a 2nd region | DR | Marketing replica public, compliance replica private | Replication targets |

Splitting buckets by sensitivity is itself a defensible architecture decision: different blast radius, different policies. A single shared bucket would be a weak answer.

**Region choice:** the doc suggests us-east-1 → us-west-2, which is safe. You could also argue **ca-central-1 (Montreal) → ca-west-1 (Calgary)** for Canadian data residency, which is a strong story for a bank. Note that ca-west-1 is an opt-in region you'd have to enable, and it won't be available in Learner Lab.

### Step 1: Marketing portal (public static hosting)

1. Create the bucket and turn off "Block Public Access" **for this bucket only**. Keep account-level BPA in mind: if it's on, it overrides the bucket setting.
2. Enable static website hosting and set `index.html`. Add an `error.html` too; it's a nice touch.
3. Upload a one-line `index.html`. AI and anything goes here, since UI is out of scope.
4. Attach the bucket policy.

**The policy deliverable has two parts.** It must (a) allow public read and (b) explicitly deny other operations from unauthorized networks. Structurally:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadOnly",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET/*"
    },
    {
      "Sid": "DenyNonReadFromUntrustedNetworks",
      "Effect": "Deny",
      "Principal": "*",
      "NotAction": "s3:GetObject",
      "Resource": ["arn:aws:s3:::BUCKET", "arn:aws:s3:::BUCKET/*"],
      "Condition": { "NotIpAddress": { "aws:SourceIp": ["YOUR.TEAM.IP/32"] } }
    }
  ]
}
```

Things you need to understand to defend this:

- **`NotAction` + `Deny`** means "deny everything *except* GetObject." Be ready to explain why that differs from `Action: s3:*`.
- **Lockout risk:** if your IP changes (home vs. campus Wi-Fi), you lock yourself out of managing the bucket. The root user can always delete a bucket policy, so it's recoverable, but plan for it. Some teams add an exception condition for their admin role ARN (`aws:PrincipalArn`) instead of relying on IP alone. Think about which is more defensible.
- **The HTTPS problem:** S3 *website endpoints* are HTTP only, which clashes with Maya's encryption-in-transit mandate. Two options:
  - Keep the website endpoint and acknowledge the gap in your handbook. This is acceptable for the phase, but weaker.
  - Put **CloudFront** in front (HTTPS, with Origin Access Control). This is stronger, but then the bucket isn't directly public, so you'd need to explain how that still meets "publicly accessible." Raise it as a design decision in the review; graders like seeing that you noticed the tension.

### Step 2: WORM storage for onboarding forms

Use **S3 Object Lock in Compliance mode**.

- **Governance vs. Compliance:** Governance mode can be bypassed by anyone with `s3:BypassGovernanceRetention`, which an admin has. The requirement says "even by users with administrator privileges," so **Compliance mode** is the correct answer. Know this distinction cold; it's a likely review question.
- Object Lock requires **versioning**. It's easiest to enable at bucket creation.
- ⚠️ **Compliance mode can't be undone, not even by root**, until retention expires, and you can't delete the bucket while locked objects exist. **Use a short default retention** (1–7 days) for the dummy PDF. Set it long enough to take your evidence screenshot, and short enough not to be stuck with it all semester. Document "in production this would be 7 years" in the handbook.
- Turn on **default encryption**. SSE-S3 is simplest; SSE-KMS gives Maya key-level audit, but it adds complexity to replication (see below).

### Step 3: The deletion-denial evidence (big gotcha)

In a versioned bucket, **a normal "Delete" succeeds**. It just adds a *delete marker*, and the object version is still there. If you click Delete normally, you'll get a green success message and no evidence.

To get the real "Access Denied" you must try to **permanently delete the specific version**:

- **Console:** toggle **"Show versions"**, select the actual version ID of the PDF, delete it, and type "permanently delete". It should fail.
- **CLI (better evidence, shows the exact command):**
  ```bash
  aws s3api delete-object --bucket aura-compliance-xxx \
    --key onboarding/form-001.pdf --version-id <VERSION_ID>
  ```
  This should return `AccessDenied` mentioning Object Lock.

Screenshot both the attempt and the error, and show you were logged in as an admin. Bonus evidence: run `aws s3api get-object-retention` to show the mode and retain-until date.

### Step 4: MFA Delete (it's in the rubric)

The "Compliance & Perimeter Defense" rubric line names **MFA Delete** specifically. Facts to know:

- Only the **root user** can enable it, and only via **CLI/API** with root's MFA device.
- It requires versioning.
- ⚠️ AWS documents that **lifecycle configurations aren't supported on MFA Delete–enabled buckets**. You can't put MFA Delete on the same bucket as your 90-day lifecycle rule. Options:
  - Enable it on a bucket without lifecycle (e.g., the marketing bucket or the replica).
  - Explain in the handbook that Object Lock Compliance mode makes MFA Delete redundant for the compliance bucket.

  Verify this against current AWS docs before you commit, and treat it as a design-decision discussion point.

### Step 5: Lifecycle policies

- On the **compliance bucket**, transition objects to **S3 Glacier Flexible Retrieval or Glacier Deep Archive after 90 days**. Locked objects can still transition storage classes; Object Lock and lifecycle transitions coexist fine.
- For **"application logs"**: you don't have an app yet in Phase 1, so enable **S3 server access logging** on the marketing bucket into `aura-logs`, then apply the 90-day rule there. This gives you real logs to tier and a head start on Maya's auditing requirement.
- Use **prefix filters** (`onboarding/`, `logs/`) and know why: rules shouldn't apply blindly to everything.
- Cost-defense line for Elena: Deep Archive costs a small fraction of Standard storage per GB. Look up current pricing for your region rather than quoting from memory.
- Also consider a rule to expire noncurrent versions or delete markers on the logs bucket, so versioning doesn't silently grow costs.

### Step 6: Cross-region replication (DR)

Requirements and gotchas:

- **Versioning on both** source and destination.
- An **IAM role** that S3 assumes to replicate.
- **Object Lock buckets:** the destination must *also* have Object Lock enabled, and the replication role needs extra permissions (`s3:GetObjectRetention`, `s3:GetObjectLegalHold` on the source). Missing these is the #1 reason replication silently fails.
- **SSE-KMS:** if you used KMS keys, the replication rule needs KMS settings and the role needs decrypt/encrypt permissions in both regions. SSE-S3 avoids this.
- **Existing objects are NOT replicated.** Create the rule first, then upload your PDF, or the replica stays empty. (S3 Batch Replication can backfill, but it's unnecessary hassle here.)
- **"Real-time":** standard CRR is asynchronous and usually fast. **S3 Replication Time Control (RTC)** adds a 15-minute SLA and metrics for extra cost. Mention it as the production answer for Elena's SLA, even if you skip it.
- **The deliverable asks for primary *and replica public URLs*.** That means you should also replicate the **marketing bucket** and enable website hosting plus the public policy on the replica. The compliance replica stays private.

**Verify replication:** on the source object, `aws s3api head-object` shows `ReplicationStatus: COMPLETED`. Screenshot it.

### Phase 1 evidence checklist

- [ ] Primary website endpoint URL (working screenshot)
- [ ] Replica website endpoint URL (working screenshot)
- [ ] Bucket policy JSON (exact)
- [ ] Admin deletion attempt on a specific version showing Access Denied (console and/or CLI)
- [ ] Object retention output (Compliance mode)
- [ ] Lifecycle rule configuration (JSON or screenshot)
- [ ] Replication rule plus `ReplicationStatus: COMPLETED`
- [ ] MFA Delete status (if implemented) or written justification
- [ ] Team charter

---

## Phase 2: Core Ledger MVP & Machine Identity

**Due: during Lab 3.**

### The core idea

The PHP app must get the DB password from **Secrets Manager** at runtime using **only the EC2 instance's IAM role** (instance profile). No access keys on the box, no `.env` file, no environment variables. The AWS SDK's default credential chain automatically picks up temporary, auto-rotating credentials from the instance metadata service (IMDS). That's the whole point: **credentials that are never stored and expire on their own**. Be able to explain that chain in your review.

### Step 1: Compute

- **Instance:** t3.micro/t2.micro (free tier) with Amazon Linux 2023.
- **Network:** Phase 4 rebuilds everything in a custom VPC, and the rubric says "no default settings used." You can either:
  - Use the default VPC now and migrate later (faster now, rework later), or
  - Build a minimal custom VPC now (more work now, less rework).

  Either way, note the choice in the handbook.
- **IMDSv2 required** (`HttpTokens=required`). This is a solid security talking point: it blocks SSRF-style credential theft against the metadata service.
- **Security group:** HTTP from your IP only, or 0.0.0.0/0 for 80 if you want. Avoid opening SSH to the world. Use **SSM Session Manager** instead of SSH now, which sets you up for Phase 4's "no exposed admin ports" requirement. AL2023 ships with the SSM agent; the role just needs `AmazonSSMManagedInstanceCore`.
- **EBS encryption** on.

### Step 2: Secrets management

The requirement says "database passwords **and dynamic parameters**." A clean split:

- **Secrets Manager:** the DB credential, e.g. `aura/dev/ledger-db` containing JSON like `{"username":"ledger_app","password":"..."}`.
- **SSM Parameter Store:** non-secret config like `/aura/dev/db_host`, `/aura/dev/app_env`.

This shows you know the difference: Secrets Manager costs a small monthly fee per secret but supports **automatic rotation**, which is Maya's mandate. Parameter Store standard parameters are free. Mention that rotation will be enabled once RDS exists in Phase 3, since RDS integrates with Secrets Manager's managed rotation.

### Step 3: Machine identity (IAM), the key deliverable

You need:

1. **An IAM role** with a trust policy allowing `ec2.amazonaws.com` to assume it.
2. **An instance profile** wrapping that role, attached to the instance.
3. **A least-privilege permission policy.** Structure:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadLedgerSecretOnly",
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "arn:aws:secretsmanager:REGION:ACCOUNT:secret:aura/dev/ledger-db-??????"
  }]
}
```

Things to understand:

- **The `-??????` suffix:** Secrets Manager appends 6 random characters to secret ARNs. Using `*` instead is overly permissive and a likely deduction.
- If you add Parameter Store, grant `ssm:GetParameter` on the specific parameter ARNs only. Add `kms:Decrypt` only if you use a customer-managed KMS key, ideally with a `kms:ViaService` condition.
- **"Only the designated instance":** the identity policy alone proves *the role* can read it. To make the claim airtight, add a **resource policy on the secret itself** that denies `GetSecretValue` to every principal except that role. Use `aws:PrincipalArn` in a Deny statement, and include an exception for your admin role so you don't lock yourselves out. Identity policy plus resource policy is defense in depth, and it's a great thing to show in the review.
- **⚠️ Learner Lab:** if you can't create roles, you'll be stuck with `LabRole`, which is broad. In that case, document what the *ideal* scoped policy would be and why, and ask your instructor how they want it handled.

### Step 4: The PHP script

This is fully AI-permitted under the course policy. On the instance: install `php`, `php-cli`, `php-json`, `httpd`, Composer, then `composer require aws/aws-sdk-php`.

```php
<?php
require 'vendor/autoload.php';

use Aws\SecretsManager\SecretsManagerClient;
use Aws\Exception\AwsException;

$client = new SecretsManagerClient([
    'region'  => 'us-east-1',   // your region
    'version' => 'latest'
    // No credentials here on purpose: SDK uses the instance profile via IMDS
]);

try {
    $result = $client->getSecretValue(['SecretId' => 'aura/dev/ledger-db']);
    $secret = json_decode($result['SecretString'], true);

    $masked = substr($secret['password'], 0, 2) . str_repeat('*', 8);
    echo "<h2>Aura Ledger: Secret Retrieval Check</h2>";
    echo "Status: SUCCESS<br>";
    echo "Retrieved at: " . date('c') . "<br>";
    echo "DB user: " . htmlspecialchars($secret['username']) . "<br>";
    echo "DB password: " . $masked . " (masked)<br>";
    echo "Secret version: " . $result['VersionId'];
} catch (AwsException $e) {
    http_response_code(500);
    echo "Secret retrieval FAILED: " . $e->getAwsErrorCode();
}
```

**Mask the password**, even though it's dummy. Printing secrets on a webpage in your evidence would look bad to a "CISO" grader.

### Step 5: Secrets retrieval evidence (make it strong)

- Screenshot the PHP page showing SUCCESS.
- **CloudTrail:** find the `GetSecretValue` event. It shows the caller as `assumed-role/<YourRole>/i-0abc...`, which is the instance ID. This is the best possible proof that the *machine identity* fetched the secret, not a human or a static key.
- Optionally run `aws sts get-caller-identity` on the instance (via Session Manager) to show it's running as the role, and show that `~/.aws/credentials` doesn't exist and no AWS env vars are set (`env | grep AWS` returns nothing).

### Step 6: Golden image

Three acceptable paths:

| Option | Effort | Best for |
|---|---|---|
| **HashiCorp Packer (HCL)** | Medium | Strongest answer. It's code, version-controlled, and ties directly into Phase 6 IaC |
| EC2 Image Builder | Medium | AWS-native pipeline, more console-heavy |
| User-data script → "Create Image" | Low | Acceptable per the doc, but closest to click-ops |

I'd recommend Packer, given the CTO's no-click-ops mandate and since it's great DevOps portfolio material.

**What goes in the image:**
- OS updates (`dnf update -y`)
- Apache plus PHP runtime and extensions
- Composer and the AWS SDK
- SSM agent (already present) and optionally the CloudWatch agent
- Your app code (or pull at boot; either is defensible)

**What must NOT go in the image:**
- Secrets, keys, credentials of any kind. Secrets come at runtime; that's the entire point of this phase.
- Leftover SSH host keys or shell history (cleanup step at the end of the build)

Also encrypt the AMI's snapshots and use a versioned naming scheme (`aura-ledger-golden-v1-YYYYMMDD`). Phase 5's Auto Scaling Group will launch from this AMI, so build it well now.

### Phase 2 evidence checklist

- [ ] Running instance with role attached (screenshot)
- [ ] PHP page showing successful, masked secret retrieval
- [ ] CloudTrail `GetSecretValue` event showing the instance's assumed role
- [ ] IAM trust policy plus permission policy JSON (exact)
- [ ] Secret resource policy (if you add it)
- [ ] Proof of no static creds (`get-caller-identity`, no credentials file, no env vars)
- [ ] Packer template or user-data script
- [ ] AMI ID and a test instance launched from it

---

## Suggested split for a 3-person team

- **Person A:** marketing bucket, bucket policy, website plus replica site
- **Person B:** compliance bucket, Object Lock, lifecycle, replication, deletion test
- **Person C:** Phase 2 IAM, Secrets Manager, and the Packer image. Start this early, since Phase 2 lands right after.

Everyone should understand all of it, though, since any of you can be questioned in the review.

## Before you start: cost and safety

- Set an **AWS Budget alert** (e.g., $10) on day one.
- Phase 1 costs pennies. Phase 2's main cost is EC2 hours, so stop the instance when you're not working. CloudFront and RTC add small costs if used.
- Keep every screenshot and CLI output in a shared evidence folder, named by phase, from the start.

Let me know the Learner Lab answer and I can adjust the Phase 2 IAM plan, or walk through any concept in more depth (Object Lock modes, IMDS, the credential chain, Packer structure).
