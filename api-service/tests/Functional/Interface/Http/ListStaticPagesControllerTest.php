<?php

declare(strict_types=1);

namespace Tests\Functional\Interface\Http;

use App\Application\Content\UseCase\CreateStaticPageUseCase;
use App\Domain\Content\Entity\StaticPage;
use App\Domain\Content\ValueObject\Content;
use App\Domain\Content\ValueObject\Slug;
use App\Domain\Content\ValueObject\Title;
use App\Infrastructure\Http\JsonResponse;
use App\Infrastructure\Persistence\Dbal\DbalStaticPageRepository;
use DateTimeImmutable;
use Tests\Infrastructure\Database\FunctionalTestCase;

final class ListStaticPagesControllerTest extends FunctionalTestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        $repository = new DbalStaticPageRepository($this->connection);
        $createUseCase = new CreateStaticPageUseCase($repository);

        $createUseCase->execute(
            slug: 'about-us',
            title: 'About Us',
            content: 'This is the About Us page.',
        );

        $createUseCase->execute(
            slug: 'faq',
            title: 'FAQ',
            content: 'This is the FAQ page.',
        );
    }

    public function test_it_does_not_return_unpublished_static_pages(): void
    {
        $repository = new DbalStaticPageRepository($this->connection);
        $repository->save(new StaticPage(
            id: null,
            slug: new Slug('draft-page'),
            title: new Title('Draft Page'),
            content: new Content('Not ready yet.'),
            createdAt: new DateTimeImmutable(),
            published: false,
        ));

        $request = $this->psrFactory->createServerRequest('GET', '/api/static-pages');
        $response = $this->kernel->handle($request);

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertSame(['about-us', 'faq'], array_column($data, 'slug'));
    }

    public function test_it_returns_list_of_static_pages_as_json(): void
    {
        $request = $this->psrFactory->createServerRequest('GET', '/api/static-pages');
        $response = $this->kernel->handle($request);

        self::assertInstanceOf(JsonResponse::class, $response);
        self::assertSame(200, $response->getStatusCode());

        $data = json_decode($response->getBody()->getContents(), true);

        self::assertCount(2, $data);

        self::assertSame('about-us', $data[0]['slug']);
        self::assertSame('About Us', $data[0]['title']);
        self::assertSame('faq', $data[1]['slug']);
        self::assertSame('FAQ', $data[1]['title']);
    }
}
