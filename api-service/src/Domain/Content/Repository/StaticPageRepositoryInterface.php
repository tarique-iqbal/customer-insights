<?php

declare(strict_types=1);

namespace App\Domain\Content\Repository;

use App\Domain\Content\Entity\StaticPage;
use App\Domain\Content\ValueObject\Slug;
use App\Domain\Content\ValueObject\StaticPageId;

interface StaticPageRepositoryInterface
{
    public function save(StaticPage $page): void;

    public function findById(StaticPageId $id): StaticPage;

    public function findBySlug(Slug $slug): StaticPage;

    /**
     * @return StaticPage[]
     */
    public function findAll(): array;

    /**
     * @return StaticPage[]
     */
    public function findAllPublished(): array;
}
