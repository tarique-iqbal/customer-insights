<?php

declare(strict_types=1);

namespace Tests\Functional\Interface\Http;

use App\Infrastructure\Http\JsonResponse;
use Tests\Infrastructure\Database\FunctionalTestCase;

final class HealthControllerTest extends FunctionalTestCase
{
    public function test_healthz_returns_ok_as_json(): void
    {
        $request = $this->psrFactory->createServerRequest('GET', '/healthz');
        $response = $this->kernel->handle($request);

        self::assertInstanceOf(JsonResponse::class, $response);
        self::assertSame(200, $response->getStatusCode());
        self::assertSame(
            ['status' => 'ok'],
            json_decode($response->getBody()->getContents(), true),
        );
    }
}
