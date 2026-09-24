<?php

declare(strict_types=1);

namespace App\Application\Content\UseCase;

use App\Domain\Content\Entity\StaticPage;
use App\Domain\Content\Repository\StaticPageRepositoryInterface;

final readonly class ListStaticPagesUseCase
{
    public function __construct(private StaticPageRepositoryInterface $repository)
    {
    }

    /**
     * @return StaticPage[]
     */
    public function execute(): array
    {
        return $this->repository->findAllPublished();
    }
}
