<?php

declare(strict_types=1);

namespace Tests\Functional\Interface\Http;

use App\Infrastructure\Persistence\Schema\Tables;
use Tests\Infrastructure\Database\FunctionalTestCase;
use PHPUnit\Framework\Attributes\DataProvider;

final class CalculateCsatControllerTest extends FunctionalTestCase
{
    public static function week_provider(): array
    {
        return [
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 5, 20, 2025),
                        (2, 4, 20, 2025),
                        (3, 3, 20, 2024),
                        (4, 2, 20, 2024),
                        (5, 1, 20, 2023),
                        (6, 5, 20, 2023)',
                    Tables::CSAT_SCORES
                ),
                50,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 5, 20, 2025),
                        (2, 4, 20, 2025),
                        (3, 5, 20, 2024),
                        (4, 4, 20, 2024),
                        (5, 5, 20, 2023)',
                    Tables::CSAT_SCORES
                ),
                100,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (2, 1, 20, 2025),
                        (3, 2, 20, 2024),
                        (4, 1, 20, 2024),
                        (5, 2, 20, 2023)',
                    Tables::CSAT_SCORES
                ),
                0,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 3, 20, 2025),
                        (3, 3, 20, 2023),
                        (4, 3, 20, 2024)',
                    Tables::CSAT_SCORES
                ),
                0,
            ],
        ];
    }

    #[DataProvider('week_provider')]
    public function test_week_http_response_is_ok(string $sql, int $expectedNpsScore): void
    {
        $this->connection->executeStatement($sql);

        $request = $this->psrFactory->createServerRequest('GET', '/api/csat/20');
        $response = $this->kernel->handle($request);

        self::assertSame(200, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertNull($data['year']);
        self::assertEquals(20, $data['week']);
        self::assertEquals($expectedNpsScore, $data['score']);
    }

    public function test_week_has_no_data_http_response_is_ok(): void
    {
        $request = $this->psrFactory->createServerRequest('GET', '/api/csat/51');
        $response = $this->kernel->handle($request);

        self::assertEquals(200, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertNull($data['year']);
        self::assertEquals(51, $data['week']);
        self::assertEquals(0, $data['score']);
    }

    public static function year_week_provider(): array
    {
        return [
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 5, 20, 2025),
                        (2, 4, 20, 2025),
                        (3, 3, 20, 2025),
                        (4, 2, 20, 2025),
                        (5, 1, 20, 2025),
                        (6, 4, 20, 2025)',
                    Tables::CSAT_SCORES
                ),
                50,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 5, 20, 2025),
                        (2, 4, 20, 2025),
                        (3, 5, 20, 2025),
                        (4, 4, 20, 2025)',
                    Tables::CSAT_SCORES
                ),
                100,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (2, 1, 20, 2025),
                        (3, 2, 20, 2025),
                        (4, 3, 20, 2025)',
                    Tables::CSAT_SCORES
                ),
                0,
            ],
            [
                sprintf(
                    'INSERT INTO %s (user_id, score, week, year) VALUES
                        (1, 3, 20, 2025),
                        (2, 2, 20, 2025)',
                    Tables::CSAT_SCORES
                ),
                0,
            ],
        ];
    }

    #[DataProvider('year_week_provider')]
    public function test_year_week_http_response_is_ok(string $sql, int $expectedNpsScore): void
    {
        $this->connection->executeStatement($sql);

        $request = $this->psrFactory->createServerRequest('GET', '/api/csat/2025/20');
        $response = $this->kernel->handle($request);

        self::assertEquals(200, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertEquals(2025, $data['year']);
        self::assertEquals(20, $data['week']);
        self::assertEquals($expectedNpsScore, $data['score']);
    }

    public function test_invalid_week_http_response_is_400(): void
    {
        $request = $this->psrFactory->createServerRequest('GET', '/api/csat/55');
        $response = $this->kernel->handle($request);

        self::assertEquals(400, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertArrayHasKey('error', $data);
    }

    public function test_year_far_in_the_future_http_response_is_400(): void
    {
        $request = $this->psrFactory->createServerRequest('GET', '/api/csat/99999/20');
        $response = $this->kernel->handle($request);

        self::assertEquals(400, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertArrayHasKey('error', $data);
    }
}
