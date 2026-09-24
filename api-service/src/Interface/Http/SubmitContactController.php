<?php

declare(strict_types=1);

namespace App\Interface\Http;

use App\Application\Contact\UseCase\SubmitContactMessageUseCase;
use App\Infrastructure\Http\JsonResponse;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

final readonly class SubmitContactController
{
    public function __construct(private SubmitContactMessageUseCase $useCase)
    {
    }

    public function __invoke(ServerRequestInterface $request): ResponseInterface
    {
        $data = json_decode((string) $request->getBody(), true);
        $data = is_array($data) ? $data : [];

        $name = $data['name'] ?? '';
        $email = $data['email'] ?? '';
        $message = $data['message'] ?? '';

        if (!is_string($name) || !is_string($email) || !is_string($message)) {
            return new JsonResponse(['error' => 'name, email and message must be strings.'], 400);
        }

        $contactMessage = $this->useCase->execute($name, $email, $message);

        return new JsonResponse(
            ['id' => $contactMessage->id()?->value()],
            201,
        );
    }
}
