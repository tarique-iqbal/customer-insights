<?php

declare(strict_types=1);

namespace Tests\Integration\Application\Csat\UseCase;

use App\Application\Csat\Query\CalculateWeeklyCsatScoreQuery;
use App\Application\Csat\UseCase\CalculateWeeklyCsatScoreUseCase;
use App\Domain\Csat\ValueObject\WeekOfYear;
use App\Infrastructure\Persistence\Dbal\DbalCsatRepository;
use App\Infrastructure\Persistence\Schema\Tables;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Infrastructure\Database\IntegrationTestCase;

final class CalculateWeeklyCsatScoreUseCaseTest extends IntegrationTestCase
{
    private CalculateWeeklyCsatScoreUseCase $useCase;

    protected function setUp(): void
    {
        parent::setUp();

        $repository = new DbalCsatRepository($this->connection);
        $this->useCase = new CalculateWeeklyCsatScoreUseCase($repository);
    }

    public static function weekly_score_provider(): array
    {
        return [
            [
                [
                    [1, 5, 21, 2024],
                    [2, 3, 21, 2024],
                    [3, 4, 21, 2024],
                ],
                66.67,
            ],
            [
                [
                    [1, 5, 21, 2024],
                    [2, 4, 21, 2024],
                    [3, 4, 21, 2024],
                ],
                100.00,
            ],
            [
                [], 0.0
            ],
        ];
    }

    #[DataProvider('weekly_score_provider')]
    public function test_calculates_correct_csat_score(array $weeklyScore, float $expectedCsatScore): void
    {
        $this->insertSampleScores($weeklyScore);

        $weekOfYear = new WeekOfYear(21, 2024);
        $query = new CalculateWeeklyCsatScoreQuery($weekOfYear);
        $score = $this->useCase->execute($query);

        $this->assertSame($expectedCsatScore, $score);
    }

    private function insertSampleScores(array $rows): void
    {
        foreach ($rows as [$userId, $score, $week, $year]) {
            $this->connection->insert(Tables::CSAT_SCORES, [
                'user_id' => $userId,
                'score' => $score,
                'week' => $week,
                'year' => $year,
            ]);
        }
    }
}
