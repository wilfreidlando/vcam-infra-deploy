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

// ── Facultatif : le battement du planificateur (une alerte peut prévenir quand « schedule:work » ne tourne plus).
// Dans un fournisseur de services (boot) : écrit l'heure chaque minute ; MetricsController la publie.
//
//   use Illuminate\Console\Scheduling\Schedule;
//   use Illuminate\Support\Facades\Cache;
//
//   $this->callAfterResolving(Schedule::class, static function (Schedule $planning): void {
//       $planning->call(static fn () => Cache::put('scheduler:heartbeat', time(), 600))
//           ->everyMinute()->name('scheduler-heartbeat')->withoutOverlapping(1);
//   });
