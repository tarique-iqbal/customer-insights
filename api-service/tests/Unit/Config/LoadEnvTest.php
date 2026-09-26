<?php

declare(strict_types=1);

namespace Tests\Unit\Config;

use Dotenv\Exception\ValidationException;
use PHPUnit\Framework\TestCase;

final class LoadEnvTest extends TestCase
{
    private const REQUIRED = ['DB_NAME', 'DB_USER', 'DB_PASS', 'DB_HOST'];
    private const ENV_NAME = 'loadenvtest';

    /** @var array<string, mixed> */
    private array $envBackup;

    /** @var array<string, mixed> */
    private array $serverBackup;

    protected function setUp(): void
    {
        $this->envBackup = $_ENV;
        $this->serverBackup = $_SERVER;

        foreach (self::REQUIRED as $name) {
            unset($_ENV[$name], $_SERVER[$name]);
        }

        $_ENV['APP_ENV'] = self::ENV_NAME;
        $_SERVER['APP_ENV'] = self::ENV_NAME;
    }

    protected function tearDown(): void
    {
        $_ENV = $this->envBackup;
        $_SERVER = $this->serverBackup;

        if (is_file($this->envFile())) {
            unlink($this->envFile());
        }
    }

    public function test_loads_without_an_env_file_when_the_variables_are_already_set(): void
    {
        $_ENV['DB_NAME'] = 'from-env';
        $_ENV['DB_USER'] = 'user';
        $_ENV['DB_PASS'] = 'pass';
        $_ENV['DB_HOST'] = 'host';

        $this->loadEnv();

        self::assertSame('from-env', $_ENV['DB_NAME']);
    }

    public function test_fails_clearly_when_there_is_no_env_file_and_the_variables_are_missing(): void
    {
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage('DB_NAME');

        $this->loadEnv();
    }

    public function test_real_environment_variables_win_over_the_env_file(): void
    {
        file_put_contents(
            $this->envFile(),
            "DB_NAME=from-file\nDB_USER=file-user\nDB_PASS=file-pass\nDB_HOST=from-file\n",
        );
        $_ENV['DB_HOST'] = 'from-env';

        $this->loadEnv();

        self::assertSame('from-env', $_ENV['DB_HOST']);
        self::assertSame('from-file', $_ENV['DB_NAME']);
    }

    private function envFile(): string
    {
        return BASE_DIR . '/.env.' . self::ENV_NAME;
    }

    private function loadEnv(): void
    {
        require BASE_DIR . '/config/load_env.php';
    }
}
