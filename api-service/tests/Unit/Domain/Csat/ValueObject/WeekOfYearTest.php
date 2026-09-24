<?php

declare(strict_types=1);

namespace Tests\Unit\Domain\Csat\ValueObject;

use App\Domain\Csat\ValueObject\WeekOfYear;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class WeekOfYearTest extends TestCase
{
    public function test_can_create_valid_week_without_year(): void
    {
        $weekOfYear = new WeekOfYear(10);
        self::assertSame(10, $weekOfYear->week());
        self::assertNull($weekOfYear->year());
    }

    public function test_can_create_valid_week_with_year(): void
    {
        $weekOfYear = new WeekOfYear(52, 2024);
        self::assertSame(52, $weekOfYear->week());
        self::assertSame(2024, $weekOfYear->year());
    }

    public function test_throws_exception_for_week_below_1(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('Week number must be between 1 and 53.');
        new WeekOfYear(0);
    }

    public function test_throws_exception_for_week_above_53(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('Week number must be between 1 and 53.');
        new WeekOfYear(54);
    }

    public function test_throws_exception_when_week_is_invalid_for_year(): void
    {
        // 2021 only has 52 weeks
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('Week 53 is not valid for year 2021.');
        new WeekOfYear(53, 2021);
    }

    public function test_accepts_week_53_when_year_allows_it(): void
    {
        // 2015 had 53 weeks
        $weekOfYear = new WeekOfYear(53, 2015);
        self::assertSame(53, $weekOfYear->week());
        self::assertSame(2015, $weekOfYear->year());
    }

    public function test_throws_exception_for_negative_year(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new WeekOfYear(10, -50);
    }

    public function test_throws_exception_for_year_before_2000(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new WeekOfYear(10, 1999);
    }

    public function test_throws_exception_for_year_far_in_the_future(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new WeekOfYear(10, 99999);
    }
}
