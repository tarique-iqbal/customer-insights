<?php

declare(strict_types=1);

namespace Tests\Integration\Infrastructure\Persistence\Dbal;

use App\Domain\Content\Entity\StaticPage;
use App\Domain\Content\Exception\StaticPageNotFoundException;
use App\Domain\Content\Repository\StaticPageRepositoryInterface;
use App\Domain\Content\ValueObject\Content;
use App\Domain\Content\ValueObject\Slug;
use App\Domain\Content\ValueObject\StaticPageId;
use App\Domain\Content\ValueObject\Title;
use App\Infrastructure\Persistence\Dbal\DbalStaticPageRepository;
use DateTimeImmutable;
use Tests\Infrastructure\Database\IntegrationTestCase;

final class DbalStaticPageRepositoryTest extends IntegrationTestCase
{
    private StaticPageRepositoryInterface $repository;

    protected function setUp(): void
    {
        parent::setUp();

        $this->repository = new DbalStaticPageRepository($this->connection);
    }

    private function createPage(string $slug, string $title, string $content, bool $published = true): StaticPage
    {
        $page = new StaticPage(
            id: null,
            slug: new Slug($slug),
            title: new Title($title),
            content: new Content($content),
            createdAt: new DateTimeImmutable(),
            published: $published,
        );
        $this->repository->save($page);

        return $page;
    }

    public function test_it_inserts_and_fetches_a_static_page_by_id(): void
    {
        $page = $this->createPage('about-us', 'About Us', 'This is about us page.');

        $fetched = $this->repository->findById($page->id());

        self::assertSame('about-us', (string) $fetched->slug());
        self::assertSame('About Us', (string) $fetched->title());
        self::assertSame('This is about us page.', (string) $fetched->content());
    }

    public function test_findById_throws_exception_when_page_not_found(): void
    {
        $this->expectException(StaticPageNotFoundException::class);
        $this->expectExceptionMessage('StaticPage not found for id 999');

        $this->repository->findById(new StaticPageId(999));
    }

    public function test_it_finds_a_static_page_by_slug(): void
    {
        $page = $this->createPage('faq', 'FAQ', 'Frequently Asked Questions.');

        $fetched = $this->repository->findBySlug(new Slug('faq'));

        self::assertSame($page->id()->value(), $fetched->id()->value());
        self::assertSame('FAQ', (string) $fetched->title());
    }

    public function test_findBySlug_throws_exception_when_page_not_found(): void
    {
        $this->expectException(StaticPageNotFoundException::class);
        $this->expectExceptionMessage('StaticPage not found for slug "random-slug"');

        $this->repository->findBySlug(new Slug('random-slug'));
    }

    public function test_it_returns_all_static_pages(): void
    {
        $this->createPage('page-one', 'Page One', 'First page content.');
        $this->createPage('page-two', 'Page Two', 'Second page content.');

        $pages = $this->repository->findAll();

        self::assertCount(2, $pages);

        $slugs = array_map(fn (StaticPage $p) => (string) $p->slug(), $pages);
        self::assertContains('page-one', $slugs);
        self::assertContains('page-two', $slugs);
    }

    public function test_findAllPublished_excludes_unpublished_pages(): void
    {
        $this->createPage('page-one', 'Page One', 'First page content.');
        $this->createPage('page-two', 'Page Two', 'Second page content.', published: false);

        $pages = $this->repository->findAllPublished();

        self::assertCount(1, $pages);
        self::assertSame('page-one', (string) $pages[0]->slug());
        self::assertCount(2, $this->repository->findAll());
    }

    public function test_it_updates_a_static_page(): void
    {
        $page = $this->createPage('faq', 'FAQ', 'Frequently Asked Questions.');

        $page->update(new Title('Updated FAQ'), new Content('Updated content.'));
        $this->repository->save($page);

        $fetched = $this->repository->findById($page->id());

        self::assertSame('Updated FAQ', (string) $fetched->title());
        self::assertSame('Updated content.', (string) $fetched->content());
        self::assertNotNull($fetched->updatedAt());
    }
}
