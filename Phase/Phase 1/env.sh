export PRIMARY=ca-central-1
export DR=ca-west-1
export SUFFIX=ak-seng4620-x7k2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)