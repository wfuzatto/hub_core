<?php
declare(strict_types=1);
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>HUB Core</title>
  <style>body{font-family:system-ui,sans-serif;max-width:760px;margin:10vh auto;padding:24px;color:#172033}code{background:#f1f4f8;padding:2px 6px;border-radius:6px}.ok{color:#087a3d}</style>
</head>
<body>
  <h1>HUB Core</h1>
  <p class="ok"><strong>Infraestrutura online.</strong></p>
  <p>Este é o núcleo Docker do HUB. Os módulos são serviços independentes atrás do gateway HTTPS.</p>
  <p>Healthcheck: <code>/health.php</code></p>
</body>
</html>
