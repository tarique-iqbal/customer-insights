<?php

declare(strict_types=1);

namespace Tests\Unit\Infrastructure\Exception;

use PHPUnit\Framework\TestCase;
use App\Domain\Contact\Exception\ContactMessageException;
use App\Infrastructure\Exception\ExceptionHandler;
use League\Route\Http\Exception\MethodNotAllowedException;
use League\Route\Http\Exception\NotFoundException;
use PHPUnit\Framework\Attributes\DataProvider;
use Psr\Log\LoggerInterface;
use RuntimeException;

final class ExceptionHandlerTest extends TestCase
{
    public function test_report_logs_and_outputs_exception_message(): void
    {
        $logger = $this->createMock(LoggerInterface::class);
        $exception = new RuntimeException('Something went wrong');

        $logger->expects($this->once())
            ->method('error')
            ->with(
                $this->equalTo('Something went wrong'),
                $this->callback(function ($context) use ($exception) {
                    return isset($context['exception']) && $context['exception'] === $exception;
                }),
            );

        $handler = new ExceptionHandler($logger);

        ob_start();
        $handler->report($exception);
        $output = ob_get_clean();

        $this->assertStringContainsString('Unhandled error/exception: Something went wrong', $output);
    }

    /**
     * @return array<string, array{0: \Throwable, 1: int}>
     */
    public static function exceptionProvider(): array
    {
        return [
            'not found' => [new NotFoundException(), 404],
            'method not allowed' => [new MethodNotAllowedException(['GET']), 405],
            'contact message' => [new ContactMessageException('Invalid email'), 422],
            'unexpected' => [new RuntimeException('boom'), 500],
        ];
    }

    #[DataProvider('exceptionProvider')]
    public function test_buildResponse_always_includes_cors_headers(\Throwable $exception, int $expectedStatus): void
    {
        $handler = new ExceptionHandler($this->createMock(LoggerInterface::class));

        $response = $handler->buildResponse($exception);

        self::assertSame($expectedStatus, $response->getStatusCode());
        self::assertTrue($response->hasHeader('Access-Control-Allow-Origin'));
        self::assertTrue($response->hasHeader('Access-Control-Allow-Methods'));
        self::assertTrue($response->hasHeader('Access-Control-Allow-Headers'));
    }
}
