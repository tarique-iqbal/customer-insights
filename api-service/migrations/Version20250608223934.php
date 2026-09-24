<?php

declare(strict_types=1);

namespace Migrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

/**
 * Auto-generated Migration: Please modify to your needs!
 */
final class Version20250608223934 extends AbstractMigration
{
    public function getDescription(): string
    {
        return '';
    }

    public function up(Schema $schema): void
    {
        // this up() migration is auto-generated, please modify it to your needs
        $this->addSql('
CREATE TABLE csat_scores (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id INT UNSIGNED NOT NULL,
    score SMALLINT UNSIGNED NOT NULL,
    week SMALLINT UNSIGNED NOT NULL,
    year SMALLINT UNSIGNED NOT NULL,
    UNIQUE KEY unique_user_week_year (user_id, week, year),
    KEY idx_year_week (year, week)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ');
    }

    public function down(Schema $schema): void
    {
        // this down() migration is auto-generated, please modify it to your needs
        $this->addSql('DROP TABLE IF EXISTS csat_scores;');
    }
}
