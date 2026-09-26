<?php

declare(strict_types=1);

namespace App\Interface\Http;

use App\Infrastructure\Http\JsonResponse;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

final readonly class HealthController
{
    public function __invoke(ServerRequestInterface $request): ResponseInterface
    {
        return new JsonResponse(['status' => 'ok']);
    }
}
