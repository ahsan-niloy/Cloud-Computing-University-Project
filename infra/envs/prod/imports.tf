import {
  to = module.app.aws_iam_role.ledger
  id = "aura-ledger-ec2-role"
}

import {
  to = module.app.aws_iam_role_policy.ledger_secrets
  id = "aura-ledger-ec2-role:aura-ledger-secrets-read"
}

import {
  to = module.app.aws_iam_role_policy_attachment.ledger_ssm
  id = "aura-ledger-ec2-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = module.app.aws_iam_instance_profile.ledger
  id = "aura-ledger-ec2-profile"
}

import {
  to = module.app.aws_ssm_parameter.db_host
  id = "/aura/dev/db_host"
}
