<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Réserve une route au réseau privé du serveur (Alloy, sur le réseau « observability »).
 *
 * Tout ce qui vient d'Internet passe par nginx-proxy, qui ajoute TOUJOURS l'en-tête
 * X-Forwarded-For. Une requête qui l'a est refusée en 404 (on ne confirme pas que la route
 * existe) ; une requête directe, sans cet en-tête, est acceptée. Ne jamais publier /metrics.
 */
class OnlyFromPrivateNetwork
{
    public function handle(Request $request, Closure $next): Response
    {
        abort_if($request->headers->has('X-Forwarded-For'), 404);

        return $next($request);
    }
}
