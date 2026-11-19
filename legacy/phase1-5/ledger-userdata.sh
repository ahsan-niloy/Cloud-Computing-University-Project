#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y httpd php php-cli php-json php-xml php-mbstring unzip

# Composer + AWS SDK, installed outside the web root so it can't be browsed
export HOME=/root COMPOSER_ALLOW_SUPERUSER=1
mkdir -p /opt/aura && cd /opt/aura
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php
composer require aws/aws-sdk-php --no-interaction

cat > /var/www/html/index.php << 'PHP'
<?php
require '/opt/aura/vendor/autoload.php';

use Aws\SecretsManager\SecretsManagerClient;
use Aws\Ssm\SsmClient;
use Aws\Exception\AwsException;

$region = 'ca-central-1';
// No credentials here on purpose: the SDK gets temporary ones from the instance role (IMDSv2)
$secrets = new SecretsManagerClient(['region' => $region, 'version' => 'latest']);
$ssm     = new SsmClient(['region' => $region, 'version' => 'latest']);

header('Content-Type: text/html; charset=utf-8');
echo "<h2>Aura Ledger: Secret Retrieval Check</h2>";
try {
    $res    = $secrets->getSecretValue(['SecretId' => 'aura/dev/ledger-db']);
    $secret = json_decode($res['SecretString'], true);
    $env    = $ssm->getParameter(['Name' => '/aura/dev/app_env'])['Parameter']['Value'];

    echo "Status: SUCCESS<br>";
    echo "Retrieved at: " . date('c') . "<br>";
    echo "Environment (Parameter Store): " . htmlspecialchars($env) . "<br>";
    echo "DB user: " . htmlspecialchars($secret['username']) . "<br>";
    echo "DB password: " . substr($secret['password'], 0, 2) . str_repeat('*', 8) . " (masked)<br>";
    echo "Secret version: " . htmlspecialchars($res['VersionId']);
} catch (AwsException $e) {
    http_response_code(500);
    echo "Secret retrieval FAILED: " . htmlspecialchars($e->getAwsErrorCode());
}
PHP

systemctl enable --now httpd
