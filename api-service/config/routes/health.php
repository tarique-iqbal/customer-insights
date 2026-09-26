<?php

declare(strict_types=1);

use App\Interface\Http\HealthController;
use League\Route\Router;

return function (Router $router): void {
    $router->map('GET', '/healthz', HealthController::class);
};
