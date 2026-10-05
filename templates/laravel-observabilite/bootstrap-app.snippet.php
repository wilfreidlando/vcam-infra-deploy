<?php

// À fusionner dans bootstrap/app.php (Laravel 11 et suivants), dans ->withRouting(...) :
//
//   use App\Http\Controllers\MetricsController;
//   use App\Http\Middleware\OnlyFromPrivateNetwork;
//   use Illuminate\Support\Facades\Route;
//
//   ->withRouting(
//       web: __DIR__.'/../routes/web.php',
//       commands: __DIR__.'/../routes/console.php',
//       health: '/up',
//       then: function (): void {
//           // Hors du groupe « web » : pas de session ni de cookie à chaque collecte (toutes les 30 s).
//           // Réservé au réseau privé : jamais de métriques publiques.
//           Route::get('/metrics', MetricsController::class)
//               ->middleware(OnlyFromPrivateNetwork::class)
//               ->name('metrics');
//       },
//   )
