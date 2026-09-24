<?php

declare(strict_types=1);

namespace Tests\Integration\Interface\Cli;

use App\Infrastructure\Persistence\Schema\Tables;
use Tests\Infrastructure\Database\IntegrationTestCase;
use App\Interface\Cli\ImportCsatCommand;
use org\bovigo\vfs\vfsStream;
use org\bovigo\vfs\vfsStreamFile;
use Symfony\Component\Console\Application;
use Symfony\Component\Console\Tester\CommandTester;

final class ImportCsatCommandTest extends IntegrationTestCase
{
    private vfsStreamFile $csvFile;

    protected function setUp(): void
    {
        parent::setUp();

        $root = vfsStream::setup(sys_get_temp_dir());
        $this->csvFile = vfsStream::newFile('csat_week_2024_12.csv')
            ->withContent("user_id,rating\n13,5\n14,4\n15,\n,3\n16,4\n17,-2")
            ->at($root);
    }

    public function test_imports_csat_csv_into_database(): void
    {
        $application = new Application();
        $command = $this->container->get(ImportCsatCommand::class);
        $application->add($command);

        $command = $application->find('csat:import');

        $commandTester = new CommandTester($command);
        $commandTester->execute(['file' => $this->csvFile->url()]);

        $commandTester->assertCommandIsSuccessful();

        $output = $commandTester->getDisplay();
        self::assertStringContainsString('csat:import', $output);

        $rows = $this->connection->fetchAllAssociative(sprintf('SELECT * FROM %s', Tables::CSAT_SCORES));
        self::assertCount(3, $rows);
    }
}
