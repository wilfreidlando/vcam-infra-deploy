<?php

namespace App\Http\Controllers;

use Illuminate\Http\Response;
use Illuminate\Queue\Failed\CountableFailedJobProvider;
use Illuminate\Queue\Failed\FailedJobProviderInterface;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Queue;
use Throwable;

/**
 * Métriques de l'application au format texte de Prometheus.
 *
 * Alloy les lit toutes les 30 secondes sur le réseau « observability » (labels
 * observability.metrics.* du compose). Jamais publiques : voir OnlyFromPrivateNetwork.
 *
 * À ADAPTER : PREFIX (le nom de l'application, avec des « _ ») et FILES (les files que votre application utilise). Ajoutez ensuite les
 * chiffres qui comptent pour VOTRE métier (commandes, paiements en attente…) : une métrique = un nombre qu'on voudrait voir en courbe
 * ou sur lequel on voudrait être prévenu.
 *
 * Pas de env() ici : Laravel le déconseille hors de config/ (avec `php artisan config:cache`, le fichier .env n'est plus lu), et une valeur lue par
 * env() ne peut pas être fixée dans un test. Dans nos conteneurs les variables sont de vraies variables d'environnement (env_file de compose) :
 * env() fonctionnerait, mais config() est la seule voie testable et la seule qui marche partout. Les valeurs viennent de
 * config('app.deployment') et config('app.version'), à déclarer dans config/app.php :
 *     'deployment' => env('DEPLOYMENT', 'prod'),
 *     'version' => env('APP_VERSION', 'inconnue'),
 */
class MetricsController extends Controller
{
    private const PREFIX = 'mon_saas';

    /** Les files traitées par l'application (celles de config/horizon.php ou de « queue:work --queue= »). */
    private const FILES = ['default'];

    public function __construct(
        private readonly FailedJobProviderInterface $echouees,
    ) {}

    public function __invoke(): Response
    {
        $out = [];

        $this->metric($out, 'info', 'gauge', 'Informations de version (valeur toujours 1).', 1, [
            'deployment' => (string) config('app.deployment', 'prod'),
            'version' => (string) config('app.version', 'inconnue'),
        ]);
        $this->metric($out, 'up', 'gauge', "1 si l'application répond.", 1);
        $this->metric($out, 'database_up', 'gauge', '1 si la base de données répond.', $this->databaseUp() ? 1 : 0);
        $this->metric($out, 'cache_up', 'gauge', '1 si le cache répond.', $this->cacheUp() ? 1 : 0);

        foreach (self::FILES as $file) {
            $taille = $this->entier(fn () => Queue::size($file));
            if ($taille !== null) {
                $this->metric($out, 'queue_size', 'gauge', 'Tâches en attente, par file.', $taille, ['queue' => $file]);
            }
        }

        // Le fournisseur de tâches en échec de Laravel : ni requête directe, ni Schema (l'architecture de certains projets les interdit).
        $echecs = $this->entier(fn () => $this->echouees instanceof CountableFailedJobProvider ? $this->echouees->count() : null);
        if ($echecs !== null) {
            $this->metric($out, 'failed_jobs_total', 'gauge', 'Tâches en échec enregistrées.', $echecs);
        }

        // Battement du planificateur (facultatif : voir bootstrap-app.snippet.php). Absent ou ancien = il ne tourne plus.
        $battement = $this->entier(fn () => Cache::get('scheduler:heartbeat'));
        if ($battement !== null) {
            $this->metric($out, 'scheduler_last_run_timestamp_seconds', 'gauge', 'Dernier battement du planificateur (horodatage Unix).', $battement);
        }

        return response(implode("\n", $out)."\n", 200, ['Content-Type' => 'text/plain; version=0.0.4; charset=utf-8']);
    }

    /**
     * @param  list<string>  $out
     * @param  array<string, string>  $labels
     */
    private function metric(array &$out, string $name, string $type, string $help, int|float $value, array $labels = []): void
    {
        $full = self::PREFIX.'_'.$name;
        $pairs = [];
        foreach ($labels as $key => $label) {
            $pairs[] = $key.'="'.str_replace(['\\', '"', "\n"], ['\\\\', '\\"', '\\n'], $label).'"';
        }

        // HELP et TYPE une seule fois par nom : plusieurs lignes pour des files différentes ne doivent pas les répéter (format invalide).
        if (! in_array('# TYPE '.$full.' '.$type, $out, true)) {
            $out[] = '# HELP '.$full.' '.$help;
            $out[] = '# TYPE '.$full.' '.$type;
        }
        $out[] = $full.($pairs === [] ? '' : '{'.implode(',', $pairs).'}').' '.$value;
    }

    private function databaseUp(): bool
    {
        try {
            DB::select('select 1');

            return true;
        } catch (Throwable) {
            return false;
        }
    }

    private function cacheUp(): bool
    {
        try {
            Cache::get('metrics-ping');

            return true;
        } catch (Throwable) {
            return false;
        }
    }

    /** Un entier, ou null si la mesure échoue ou n'existe pas : une mesure en panne ne doit jamais faire échouer /metrics. */
    private function entier(callable $fn): ?int
    {
        try {
            $valeur = $fn();

            return is_numeric($valeur) ? (int) $valeur : null;
        } catch (Throwable) {
            return null;
        }
    }
}
