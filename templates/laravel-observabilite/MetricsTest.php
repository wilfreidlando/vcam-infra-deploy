<?php

namespace Tests\Feature;

use Tests\TestCase;

/**
 * Les deux garanties à ne jamais perdre : les métriques existent pour le réseau privé, et
 * elles sont INTROUVABLES depuis Internet (tout ce qui passe par nginx-proxy porte X-Forwarded-For).
 */
class MetricsTest extends TestCase
{
    public function test_metrics_are_served_on_the_private_network(): void
    {
        $response = $this->get('/metrics');

        $response->assertOk();
        $this->assertStringContainsString('text/plain', (string) $response->headers->get('Content-Type'));
        $this->assertStringContainsString('_up 1', $response->getContent());
    }

    /**
     * Les étiquettes viennent de la configuration (config('app.deployment'), config('app.version')), pas de env() : un test peut alors les fixer,
     * et elles ne dépendent pas de la manière dont l'environnement est fourni (fichier .env, variables du conteneur).
     */
    public function test_labels_come_from_the_configuration_not_from_env(): void
    {
        config(['app.deployment' => 'staging', 'app.version' => 'abc123']);

        $contenu = $this->get('/metrics')->getContent();

        $this->assertStringContainsString('deployment="staging"', $contenu);
        $this->assertStringContainsString('version="abc123"', $contenu);
    }

    /** Un nom de métrique n'a qu'un seul « # TYPE » : plusieurs lignes étiquetées (une par file) ne doivent pas le répéter. */
    public function test_type_lines_are_not_repeated(): void
    {
        $types = array_filter(explode("\n", (string) $this->get('/metrics')->getContent()), fn (string $l) => str_starts_with($l, '# TYPE'));

        $this->assertSame([], array_filter(array_count_values($types), fn (int $n) => $n > 1));
    }

    public function test_metrics_are_hidden_from_the_internet(): void
    {
        $this->get('/metrics', ['X-Forwarded-For' => '203.0.113.7'])->assertNotFound();
    }
}
