<?php

declare(strict_types=1);

namespace Tests\Integration\Infrastructure\Csv;

use App\Domain\Csat\ValueObject\CsatWeeklyScore;
use App\Domain\Csat\ValueObject\Score;
use App\Domain\Csat\ValueObject\UserId;
use App\Domain\Csat\ValueObject\Week;
use App\Domain\Csat\ValueObject\Year;
use App\Infrastructure\Csv\CsatCsvParser;
use org\bovigo\vfs\vfsStream;
use PHPUnit\Framework\TestCase;
use SplFileObject;

final class CsatCsvParserTest extends TestCase
{
    private string $filePath;

    protected function setUp(): void
    {
        $root = vfsStream::setup(sys_get_temp_dir());
        $file = vfsStream::newFile('csat_week_2024_10.csv')
            ->withContent("1,5\n2,4\n3,3\nfallacy,5\n4,invalid\n5,\n,7\n7,-2\n8,7\n")
            ->at($root);

        $this->filePath = $file->url();
    }

    public function test_parses_valid_csat_scores_from_csv(): void
    {
        $parser = new CsatCsvParser();
        $file = new SplFileObject($this->filePath);
        $week = 10;
        $year = 2024;

        $results = iterator_to_array($parser->parse($file, $week, $year));

        self::assertCount(3, $results);

        self::assertInstanceOf(CsatWeeklyScore::class, $results[0]);
        self::assertEquals(new UserId(1), $results[0]->userId);
        self::assertEquals(new Score(5), $results[0]->score);
        self::assertEquals(new Week($week), $results[0]->week);
        self::assertEquals(new Year($year), $results[0]->year);

        self::assertEquals(new UserId(2), $results[1]->userId);
        self::assertEquals(new Score(4), $results[1]->score);

        self::assertEquals(new UserId(3), $results[2]->userId);
        self::assertEquals(new Score(3), $results[2]->score);
    }

    public function test_skips_rows_with_a_non_positive_user_id_without_throwing(): void
    {
        $root = vfsStream::setup(sys_get_temp_dir());
        $file = vfsStream::newFile('csat_week_2024_11.csv')
            ->withContent("0,4\n-5,3\n9,5\n")
            ->at($root);

        $parser = new CsatCsvParser();
        $results = iterator_to_array($parser->parse(new SplFileObject($file->url()), 11, 2024));

        self::assertCount(1, $results);
        self::assertEquals(new UserId(9), $results[0]->userId);
    }
}
