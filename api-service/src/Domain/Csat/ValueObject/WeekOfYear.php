<?php

declare(strict_types=1);

namespace App\Domain\Csat\ValueObject;

use DateTimeImmutable;
use InvalidArgumentException;

final readonly class WeekOfYear
{
    public function __construct(
        private int $week,
        private ?int $year = null,
    ) {
        if ($this->week < 1 || $this->week > 53) {
            throw new InvalidArgumentException('Week number must be between 1 and 53.');
        }

        if ($year !== null) {
            new Year($year);

            $maxWeek = (int) (new DateTimeImmutable("{$this->year}-12-28"))->format('W');

            if ($this->week > $maxWeek) {
                throw new InvalidArgumentException(
                    sprintf('Week %d is not valid for year %d.', $this->week, $this->year),
                );
            }
        }
    }

    public function week(): int
    {
        return $this->week;
    }

    public function year(): ?int
    {
        return $this->year;
    }
}
