<?php

declare(strict_types=1);

use Dotenv\Dotenv;

// Detect env (dev|prod|test)
$env = $_ENV['APP_ENV'] ?? $_SERVER['APP_ENV'] ?? 'dev';
$envFile = '.env.' . $env;

$dotenv = Dotenv::createImmutable(BASE_DIR, $envFile);
// The file is optional; real environment variables take precedence over it.
$dotenv->safeLoad();
$dotenv->required(['DB_NAME', 'DB_USER', 'DB_PASS', 'DB_HOST']);
