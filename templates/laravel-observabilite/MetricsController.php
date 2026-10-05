<?php

namespace App\Http\Controllers;

use Illuminate\Http\Response;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\Schema;
use Throwable;

/**
 * Métriques de l'application au format texte de Prometheus.
 *
 * Alloy les lit toutes les 30 secondes sur le réseau « observability » (labels
 * observability.metrics.* du compose). Jamais publiques : voir OnlyFromPrivateNetwork.
 *
 * À ADAPTER : PREFIX (le nom de l'application, avec des « _ »). Ajoutez ensuite les chiffres qui
 * comptent pour VOTRE métier (commandes, paiements en attente…) : une métrique = un nombre qu'on
 * voudrait voir en courbe ou sur lequel on voudrait être prévenu.
 */
class MetricsController extends Controller
{
    private const PREFIX = 'mon_saas';

    public function __invoke(): Response
    {
        $out = [];

        $this->metric($out, 'info', 'gauge', 'Informations de version (valeur toujours 1).', 1, [
            'deployment' => (string) env('DEPLOYMENT', 'prod'),
            'version' => (string) env('APP_VERSION', 'inconnue'),
        ]);
        $this->metric($out, 'up', 'gauge', "1 si l'application répond.", 1);
        $this->metric($out, 'database_up', 'gauge', '1 si la base de données répond.', $this->databaseUp() ? 1 : 0);
        $this->metric($out, 'cache_up', 'gauge', '1 si le cache répond.', $this->cacheUp() ? 1 : 0);

        $failed = $this->failedJobs();
        if ($failed !== null) {
            $this->metric($out, 'failed_jobs_total', 'gauge', 'Jobs en échec enregistrés (table failed_jobs).', $failed);
        }

        $size = $this->queueSize();
        if ($size !== null) {
            $this->metric($out, 'queue_size', 'gauge', 'Jobs en attente dans la file par défaut.', $size);
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

        $out[] = '# HELP '.$full.' '.$help;
        $out[] = '# TYPE '.$full.' '.$type;
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

    private function failedJobs(): ?int
    {
        try {
            return Schema::hasTable('failed_jobs') ? (int) DB::table('failed_jobs')->count() : null;
        } catch (Throwable) {
            return null;
        }
    }

    private function queueSize(): ?int
    {
        try {
            return Queue::size();
        } catch (Throwable) {
            return null;
        }
    }
}
