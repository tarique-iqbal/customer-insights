<?php

declare(strict_types=1);

namespace Tests\Integration\Application\Csat\UseCase;

use App\Application\Csat\UseCase\ImportCsatResponsesUseCase;
use App\Infrastructure\Csv\CsatCsvParser;
use App\Infrastructure\Persistence\Dbal\DbalCsatRepository;
use App\Infrastructure\Persistence\Schema\Tables;
use Tests\Infrastructure\Database\IntegrationTestCase;
use org\bovigo\vfs\vfsStream;
use SplFileObject;

final class ImportCsatResponsesUseCaseTest extends IntegrationTestCase
{
    private ImportCsatResponsesUseCase $useCase;

    protected function setUp(): void
    {
        parent::setUp();

        $repository = new DbalCsatRepository($this->connection);
        $parser = new CsatCsvParser();
        $this->useCase = new ImportCsatResponsesUseCase($repository, $parser);
    }

    public function test_import_from_file_skips_existing_feedback_and_saves_new(): void
    {
        $this->connection->insert(Tables::CSAT_SCORES, [
            'user_id' => 1,
            'score' => 5,
            'week' => 12,
            'year' => 2024,
        ]);

        $root = vfsStream::setup(sys_get_temp_dir());
        $file = vfsStream::newFile('csat_week_2024_12.csv')
            ->withContent("user_id,rating\n1,5\n2,4\n3,3\n")
            ->at($root);

        $file = new SplFileObject($file->url());
        $this->useCase->importFromFile($file, 12, 2024);

        $result = $this->connection->fetchAllAssociative(
            sprintf('SELECT * FROM %s ORDER BY user_id ASC', Tables::CSAT_SCORES)
        );

        self::assertCount(3, $result);
        self::assertEquals([
            ['id' => 1, 'user_id' => 1, 'score' => 5, 'week' => 12, 'year' => 2024],
            ['id' => 2, 'user_id' => 2, 'score' => 4,  'week' => 12, 'year' => 2024],
            ['id' => 3, 'user_id' => 3, 'score' => 3,  'week' => 12, 'year' => 2024],
        ], $result);
    }
}
