<?php

declare(strict_types=1);

namespace App\Infrastructure\Csv;

use App\Domain\Csat\ValueObject\CsatWeeklyScore;
use App\Domain\Csat\ValueObject\Score;
use App\Domain\Csat\ValueObject\UserId;
use App\Domain\Csat\ValueObject\Week;
use App\Domain\Csat\ValueObject\Year;
use Generator;
use SplFileObject;
use function count;

final class CsatCsvParser
{
    public function parse(SplFileObject $file, int $week, int $year): Generator
    {
        $file->setFlags(SplFileObject::READ_CSV);

        foreach ($file as $row) {
            if (!is_countable($row) || count($row) < 2) {
                continue;
            }

            [$userId, $rating] = $row;

            if (!is_numeric($userId) || (int) $userId <= 0) {
                continue;
            }

            if (!is_numeric($rating) || $rating < 1 || $rating > 5) {
                continue;
            }

            yield new CsatWeeklyScore(
                new UserId((int) $userId),
                new Score((int) $rating),
                new Week($week),
                new Year($year),
            );
        }
    }
}
