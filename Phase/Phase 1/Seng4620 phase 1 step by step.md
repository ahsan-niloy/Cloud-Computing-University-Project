# Phase 1, Step by Step (Own AWS Account)

Run these steps from a terminal using the AWS CLI. That's better than clicking through the console for three reasons:

- The commands themselves become audit evidence.
- It counts against "click-ops" less.
- You can save them as `phase1/setup.sh` in your GitHub repo, which gives you a head start on Phase 6.

Per the course AI policy, I give you the commands and explain them, but **you write the three policy JSON files yourselves**. I explain what goes in each one and what will break if you get it wrong.

---

## Step 0: Secure the account (do this first)

1. **Root user:** turn on MFA, then stop using root for everyday work.
2. **Admin identities:** create one admin user each for you and Kareena, using IAM Identity Center or an IAM user with `AdministratorAccess`. Turn on MFA for both.
3. **Budget alert:** go to Billing → Budgets and create a $10 monthly budget that emails you both.
4. **CLI:** install AWS CLI v2, then run `aws configure sso` (or `aws configure` if you made IAM users). Check it works:
   ```bash
   aws sts get-caller-identity
   ```
   It should show your admin user, **not** root.

## Step 1: Pick regions and set variables

I recommend **ca-central-1 (Montreal) as primary and ca-west-1 (Calgary) as DR**. Keeping Canadian banking data inside Canada is a strong design argument. ca-west-1 is usually an opt-in region, so check its status first:

```bash
aws account get-region-opt-status --region-name ca-west-1
```

If it says `DISABLED`, enable it under Account → AWS Regions. That can take a few minutes. If you'd rather skip the opt-in, use us-east-1 and us-west-2 instead.

Set these variables once per terminal session. The suffix makes bucket names globally unique and must be lowercase:

```bash
export PRIMARY=ca-central-1
export DR=ca-west-1
export SUFFIX=aura-ak-2026        # change to something unique
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

Also check whether account-level Block Public Access is on. If it is, it will silently block your public website later:

```bash
aws s3control get-public-access-block --account-id $ACCOUNT_ID
```

If this command errors with "no configuration," nothing is set at the account level, which is fine.

## Step 2: Create all six buckets

**Primary region:**

```bash
# Marketing site
aws s3api create-bucket --bucket aura-marketing-$SUFFIX --region $PRIMARY \
  --create-bucket-configuration LocationConstraint=$PRIMARY

# Compliance (Object Lock must be enabled at creation; this also turns on versioning)
aws s3api create-bucket --bucket aura-compliance-$SUFFIX --region $PRIMARY \
  --create-bucket-configuration LocationConstraint=$PRIMARY \
  --object-lock-enabled-for-bucket

# Logs
aws s3api create-bucket --bucket aura-logs-$SUFFIX --region $PRIMARY \
  --create-bucket-configuration LocationConstraint=$PRIMARY
```

**DR region:**

```bash
aws s3api create-bucket --bucket aura-marketing-replica-$SUFFIX --region $DR \
  --create-bucket-configuration LocationConstraint=$DR

aws s3api create-bucket --bucket aura-compliance-replica-$SUFFIX --region $DR \
  --create-bucket-configuration LocationConstraint=$DR \
  --object-lock-enabled-for-bucket
```

The compliance replica must have Object Lock too. If it doesn't, replication of locked objects fails.

**Turn on versioning** for the marketing buckets. Replication requires it, and the Object Lock buckets already have it.

```bash
aws s3api put-bucket-versioning --bucket aura-marketing-$SUFFIX \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-versioning --bucket aura-marketing-replica-$SUFFIX --region $DR \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-versioning --bucket aura-logs-$SUFFIX \
  --versioning-configuration Status=Enabled
```

**Set encryption explicitly on all five buckets.** AWS turns SSE-S3 on by default, but the rubric penalizes "default settings." Setting it yourself shows the choice was intentional:

```bash
aws s3api put-bucket-encryption --bucket aura-compliance-$SUFFIX \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Repeat this for each bucket, adding `--region $DR` for the replicas.

## Step 3: Turn on WORM retention for the compliance bucket

```bash
aws s3api put-object-lock-configuration --bucket aura-compliance-$SUFFIX \
  --object-lock-configuration \
  '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":1}}}'
```

⚠️ **Use 1 day only.** Compliance mode cannot be shortened or removed by anyone, including root. Every object you upload will be undeletable for 1 day, and you can't delete the bucket until all retention periods expire. In the handbook, write that production retention would be multiple years and that 1 day is a test value.

## Step 4: Set up the logs bucket and access logging

1. Leave the logs bucket **fully private**, with all four Block Public Access settings on.
2. **Write the logs bucket policy yourselves.** It must allow the service principal `logging.s3.amazonaws.com` to `s3:PutObject` into `aura-logs-$SUFFIX/*`. Add conditions so only _your_ marketing bucket can write logs there:
   - `aws:SourceArn` set to the marketing bucket's ARN
   - `aws:SourceAccount` set to your account ID

   Without those conditions, any bucket in any account could write logs into yours. That's a good point to bring up in the review.

3. Apply the policy, then turn on logging:

   ```bash
   aws s3api put-bucket-policy --bucket aura-logs-$SUFFIX --policy file://logs-policy.json

   aws s3api put-bucket-logging --bucket aura-marketing-$SUFFIX --bucket-logging-status \
     '{"LoggingEnabled":{"TargetBucket":"aura-logs-'$SUFFIX'","TargetPrefix":"logs/marketing/"}}'
   ```

## Step 5: Set up the marketing site (primary and replica)

**Do these steps on both marketing buckets**, adding `--region $DR` for the replica.

1. **Open only the "policy" side of Block Public Access.** Keep ACLs blocked, because a public bucket policy is the controlled way to allow public reads:

   ```bash
   aws s3api put-public-access-block --bucket aura-marketing-$SUFFIX \
     --public-access-block-configuration \
     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
   ```

   Be ready to explain why you kept the ACL settings on.

2. **Turn on static website hosting:**

   ```bash
   aws s3 website s3://aura-marketing-$SUFFIX --index-document index.html --error-document error.html
   ```

3. **Write the marketing bucket policy yourselves.** This is the graded deliverable. You need two statements:
   - **Allow:** `Principal "*"`, `s3:GetObject`, on `bucket/*`.
   - **Deny:** `Principal "*"`, `NotAction s3:GetObject`, on both the bucket and `bucket/*`. Apply it only when **both** of these are true:
     - the request comes from outside your team's IP range (`NotIpAddress` on `aws:SourceIp`), **and**
     - the caller is not your admin role/users or the replication role (`ArnNotLike` on `aws:PrincipalArn`).

   ⚠️ The second condition matters. If you use the IP check alone, the replication role's requests come from AWS's own network, not your IP. The deny would then **silently break replication into the replica bucket**. It would also lock you out whenever you work from a different Wi-Fi network. Two condition keys in the same `Condition` block are ANDed together, so the deny only fires when both are true. Make sure you can explain that.

   ```bash
   aws s3api put-bucket-policy --bucket aura-marketing-$SUFFIX --policy file://marketing-policy.json
   ```

4. **Upload your pages to the primary bucket only.** Replication will copy them to the replica.

## Step 6: Set up replication (DR)

1. **Write the replication role yourselves.**
   - **Trust policy:** allows `s3.amazonaws.com` to assume the role.
   - **Permissions policy, on the source buckets:** `s3:GetReplicationConfiguration` and `s3:ListBucket`.
   - **Permissions policy, on source objects:** `s3:GetObjectVersionForReplication`, `s3:GetObjectVersionAcl`, `s3:GetObjectVersionTagging`, **`s3:GetObjectRetention`**, **`s3:GetObjectLegalHold`**. The last two are required for Object Lock.
   - **Permissions policy, on destination objects:** `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:ReplicateTags`.
   - Scope every permission to your specific bucket ARNs, never `*`.

2. **Create the role and attach the policy:**

   ```bash
   aws iam create-role --role-name aura-s3-replication-role \
     --assume-role-policy-document file://replication-trust.json
   aws iam put-role-policy --role-name aura-s3-replication-role \
     --policy-name aura-replication --policy-document file://replication-permissions.json
   ```

3. **Write a replication config file for each source bucket.** Each one contains:
   - the role ARN
   - one rule with `Status: Enabled`, `Priority: 1`, and an empty `Filter`
   - `DeleteMarkerReplication: Disabled`
   - the destination bucket ARN

   Then apply them:

   ```bash
   aws s3api put-bucket-replication --bucket aura-compliance-$SUFFIX \
     --replication-configuration file://replication-compliance.json
   aws s3api put-bucket-replication --bucket aura-marketing-$SUFFIX \
     --replication-configuration file://replication-marketing.json
   ```

   You can optionally add Replication Time Control (RTC) for a 15-minute SLA. It costs extra. Even if you skip it, mention it as the production answer to Elena's "real-time" requirement.

## Step 7: Upload test content (only after replication is configured)

Objects that already exist are not replicated, so upload everything only now:

```bash
echo '<h1>Welcome to Aura Digital Bank</h1>' > index.html
echo '<h1>Page not found</h1>' > error.html
aws s3 cp index.html s3://aura-marketing-$SUFFIX/ --content-type text/html
aws s3 cp error.html s3://aura-marketing-$SUFFIX/ --content-type text/html

# Any dummy PDF works
aws s3 cp form-001.pdf s3://aura-compliance-$SUFFIX/onboarding/form-001.pdf
```

**Verify everything:**

```bash
# Retention is applied (shows COMPLIANCE and the retain-until date)
aws s3api get-object-retention --bucket aura-compliance-$SUFFIX --key onboarding/form-001.pdf

# Replication finished (PENDING first, then COMPLETED)
aws s3api head-object --bucket aura-compliance-$SUFFIX --key onboarding/form-001.pdf

# The replica copy exists (shows ReplicationStatus: REPLICA)
aws s3api head-object --bucket aura-compliance-replica-$SUFFIX --key onboarding/form-001.pdf --region $DR
```

Open both website endpoint URLs in a browser. You'll find each one in the console under the bucket's Properties → Static website hosting. Screenshot both pages working.

## Step 8: Deletion-denial evidence

Get the specific version ID of the PDF:

```bash
aws s3api list-object-versions --bucket aura-compliance-$SUFFIX --prefix onboarding/form-001.pdf
```

Try to **permanently delete that version** while logged in as an admin:

```bash
aws s3api delete-object --bucket aura-compliance-$SUFFIX \
  --key onboarding/form-001.pdf --version-id <VERSION_ID>
```

You should get `AccessDenied` because of Object Lock. Screenshot the terminal so it shows `get-caller-identity` (proving you're an admin), the delete command, and the error.

For a second piece of evidence, try the same thing in the console: toggle "Show versions" on, select the version, delete, and screenshot the error.

Don't do a normal delete without a version ID. That "succeeds" by adding a delete marker, and it will confuse your evidence.

## Step 9: Lifecycle rules

**Write the lifecycle configurations yourselves:**

- **Compliance bucket:** filter on prefix `onboarding/`. Transition to `GLACIER` or `DEEP_ARCHIVE` after 90 days. Add a `NoncurrentVersionTransition` too.
- **Logs bucket:** filter on prefix `logs/`. Transition after 90 days. Optionally expire old noncurrent versions so storage costs don't keep growing.

```bash
aws s3api put-bucket-lifecycle-configuration --bucket aura-compliance-$SUFFIX \
  --lifecycle-configuration file://lifecycle-compliance.json
aws s3api put-bucket-lifecycle-configuration --bucket aura-logs-$SUFFIX \
  --lifecycle-configuration file://lifecycle-logs.json
```

Screenshot or save the output of `get-bucket-lifecycle-configuration` for both.

## Step 10: MFA Delete (decide and document)

MFA Delete can't coexist with lifecycle rules, so it can't go on the compliance or logs buckets. You have two options:

- **Option A: put it on the marketing bucket.** It requires **root access keys** plus root's MFA code:
  ```bash
  aws s3api put-bucket-versioning --bucket aura-marketing-$SUFFIX \
    --versioning-configuration Status=Enabled,MFADelete=Enabled \
    --mfa "<root MFA device ARN> <6-digit code>"
  ```
  Get the MFA device ARN from root's Security credentials page. **Create the root access key, run the command, then delete the key immediately.** Long-lived root keys are a serious security risk, and Maya would flag them.
- **Option B: skip it and justify it in writing.** Object Lock in Compliance mode is stronger than MFA Delete for the compliance documents, and MFA Delete is incompatible with the required lifecycle policy.

Option A plus a written justification for the compliance bucket earns the most rubric credit.

---

## Final checklist

- [ ] Primary and replica website URLs, with screenshots of both working
- [ ] `marketing-policy.json`: the exact policy deliverable
- [ ] Deletion denial evidence (CLI and console)
- [ ] `get-object-retention` output
- [ ] `head-object` output showing replication COMPLETED and the replica
- [ ] Lifecycle configs for compliance and logs buckets
- [ ] MFA Delete status or written justification
- [ ] All commands saved as `phase1/setup.sh` in your repo
- [ ] Team charter submitted

Work through it in order. If any command errors, paste the error here and I'll help you debug it. You can also send me your policy JSON drafts before you apply them, and I'll review them for mistakes.
