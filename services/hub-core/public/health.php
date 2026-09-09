<?php
declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');

$result = [
    'status' => 'ok',
    'service' => 'hub-core',
    'database' => 'unknown',
    'timestamp' => gmdate('c'),
];

try {
    $host = getenv('DB_HOST') ?: 'mysql';
    $port = getenv('DB_PORT') ?: '3306';
    $db = getenv('DB_DATABASE') ?: '';
    $user = getenv('DB_USERNAME') ?: '';
    $pass = getenv('DB_PASSWORD') ?: '';
    $pdo = new PDO("mysql:host={$host};port={$port};dbname={$db};charset=utf8mb4", $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 3,
    ]);
    $pdo->query('SELECT 1');
    $result['database'] = 'ok';
} catch (Throwable $e) {
    http_response_code(503);
    $result['status'] = 'degraded';
    $result['database'] = 'unavailable';
}

echo json_encode($result, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
