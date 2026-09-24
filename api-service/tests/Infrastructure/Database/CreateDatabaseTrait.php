<?php

declare(strict_types=1);

namespace Tests\Infrastructure\Database;

use App\Infrastructure\Persistence\Schema\Tables;
use Doctrine\DBAL\Connection;

trait CreateDatabaseTrait
{
    protected function createSchema(Connection $connection): void
    {
        $connection->executeStatement(
            sprintf(
                'CREATE TABLE IF NOT EXISTS %s (
                    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                    user_id INT UNSIGNED NOT NULL,
                    score SMALLINT UNSIGNED NOT NULL,
                    week SMALLINT UNSIGNED NOT NULL,
                    year SMALLINT UNSIGNED NOT NULL,
                    UNIQUE KEY unique_user_week_year (user_id, week, year),
                    KEY idx_year_week (year, week)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;',
                Tables::CSAT_SCORES
            )
        );

        $connection->executeStatement(
            sprintf(
                'CREATE TABLE IF NOT EXISTS %s (
                    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                    name VARCHAR(255) NOT NULL,
                    email VARCHAR(255) NOT NULL,
                    message TEXT NOT NULL,
                    submitted_at DATETIME NOT NULL
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;',
                Tables::CONTACT_MESSAGES
            )
        );

        $connection->executeStatement(
            sprintf(
                'CREATE TABLE IF NOT EXISTS %s (
                    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                    slug VARCHAR(100) NOT NULL UNIQUE,
                    title VARCHAR(255) NOT NULL,
                    content LONGTEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NULL,
                    published TINYINT(1) NOT NULL DEFAULT 1
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;',
                Tables::STATIC_PAGES
            )
        );
    }

    protected function truncateTable(Connection $connection): void
    {
        $connection->executeStatement(sprintf('TRUNCATE TABLE %s', Tables::CSAT_SCORES));
        $connection->executeStatement(sprintf('TRUNCATE TABLE %s', Tables::CONTACT_MESSAGES));
        $connection->executeStatement(sprintf('TRUNCATE TABLE %s', Tables::STATIC_PAGES));
    }
}
