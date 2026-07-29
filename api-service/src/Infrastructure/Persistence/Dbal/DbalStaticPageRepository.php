<?php

declare(strict_types=1);

namespace App\Infrastructure\Persistence\Dbal;

use App\Domain\Content\Entity\StaticPage;
use App\Domain\Content\Exception\StaticPageNotFoundException;
use App\Domain\Content\Repository\StaticPageRepositoryInterface;
use App\Domain\Content\ValueObject\Content;
use App\Domain\Content\ValueObject\Slug;
use App\Domain\Content\ValueObject\StaticPageId;
use App\Domain\Content\ValueObject\Title;
use App\Infrastructure\Persistence\Schema\Tables;
use DateTimeImmutable;
use Doctrine\DBAL\Connection;

final readonly class DbalStaticPageRepository implements StaticPageRepositoryInterface
{
    public function __construct(private Connection $connection)
    {
    }

    public function save(StaticPage $page): void
    {
        $data = [
            'slug' => $page->slug()->value(),
            'title' => $page->title()->value(),
            'content' => $page->content()->value(),
            'created_at' => $page->createdAt()->format('Y-m-d H:i:s'),
            'updated_at' => $page->updatedAt()?->format('Y-m-d H:i:s'),
            'published' => $page->published() ? 1 : 0,
        ];

        if ($page->id() === null) {
            $this->connection->insert(Tables::STATIC_PAGES, $data);

            $id = (int)$this->connection->lastInsertId();
            $page->setId(new StaticPageId($id));
        } else {
            $this->connection->update(Tables::STATIC_PAGES, $data, ['id' => $page->id()->value()]);
        }
    }

    public function findById(StaticPageId $id): StaticPage
    {
        $row = $this->connection->fetchAssociative(
            sprintf('SELECT * FROM %s WHERE id = ?', Tables::STATIC_PAGES),
            [$id->value()]
        );

        if (!$row) {
            throw StaticPageNotFoundException::forId($id->value());
        }

        return $this->hydrate($row);
    }

    public function findBySlug(Slug $slug): StaticPage
    {
        $row = $this->connection->fetchAssociative(
            sprintf('SELECT * FROM %s WHERE slug = ?', Tables::STATIC_PAGES),
            [$slug->value()]
        );

        if (!$row) {
            throw StaticPageNotFoundException::forSlug($slug->value());
        }

        return $this->hydrate($row);
    }

    public function findAll(): array
    {
        $rows = $this->connection->fetchAllAssociative(
            sprintf('SELECT * FROM %s ORDER BY title ASC', Tables::STATIC_PAGES),
        );

        return array_map([$this, 'hydrate'], $rows);
    }

    /**
     * @param array<string, mixed> $row
     */
    private function hydrate(array $row): StaticPage
    {
        return new StaticPage(
            id: new StaticPageId((int)$row['id']),
            slug: new Slug($row['slug']),
            title: new Title($row['title']),
            content: new Content($row['content']),
            createdAt: new DateTimeImmutable($row['created_at']),
            updatedAt: $row['updated_at'] ? new DateTimeImmutable($row['updated_at']) : null,
            published: (bool)$row['published'],
        );
    }
}
