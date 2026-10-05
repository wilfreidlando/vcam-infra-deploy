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

    public function test_metrics_are_hidden_from_the_internet(): void
    {
        $this->get('/metrics', ['X-Forwarded-For' => '203.0.113.7'])->assertNotFound();
    }
}
