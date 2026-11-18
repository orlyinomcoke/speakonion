<?php
// Serves the app (index.html) with per-page share tags, so Facebook/Messenger/X previews
// show the topic title, the current split and the share image. The app itself is unchanged.
$html = file_get_contents(__DIR__ . '/index.html');
$cfg = @file_get_contents(__DIR__ . '/config.js') ?: '';
preg_match("/SUPABASE_URL:\s*'([^']+)'/", $cfg, $u);
preg_match("/SUPABASE_ANON_KEY:\s*'([^']+)'/", $cfg, $k);
$base = 'https://' . ($_SERVER['HTTP_HOST'] ?? 'speakonion.online');
$path = rawurldecode(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/');
$path = rtrim($path, '/');
if ($path === '') $path = '/';

$title = 'Speak Onion · Pick a side. Hear the other.';
$desc = 'Vote on hot topics, see where everyone stands, then chat anonymously 1-on-1 with someone who disagrees.';
$status = 200;

function so_get($url, $key) {
  $cache = sys_get_temp_dir() . '/so_' . md5($url);
  if (is_file($cache) && filemtime($cache) > time() - 120) return json_decode(file_get_contents($cache), true);
  $ch = curl_init($url);
  curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 4,
    CURLOPT_HTTPHEADER => ["apikey: $key", "Authorization: Bearer $key"]]);
  $body = curl_exec($ch); $ok = curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200; curl_close($ch);
  if (!$ok) return null;
  @file_put_contents($cache, $body);
  return json_decode($body, true);
}
// Must match slugify() in index.html
function so_slug($t) {
  $t = mb_strtolower($t, 'UTF-8');
  if (class_exists('Normalizer')) $t = preg_replace('/\p{Mn}+/u', '', Normalizer::normalize($t, Normalizer::FORM_KD));
  else $t = @iconv('UTF-8', 'ASCII//TRANSLIT//IGNORE', $t);
  $t = str_replace(["'", "\u{2019}"], '', $t);
  $t = trim(preg_replace('/[^a-z0-9]+/', '-', $t), '-');
  $t = rtrim(substr($t, 0, 60), '-');
  return $t === '' ? 'topic' : $t;
}

$static = ['/terms' => ['Terms of Use · Speak Onion', 'The rules for using Speak Onion.'],
           '/privacy' => ['Privacy Policy · Speak Onion', 'How Speak Onion handles your data under the Data Privacy Act.']];
if (isset($static[$path])) {
  [$title, $desc] = $static[$path];
} elseif ($path !== '/' && !preg_match('#^/(admin|signin|account)#', $path) && !empty($u[1])) {
  $topics = so_get($u[1] . '/rest/v1/topics?select=id,title,label_a,label_b,created_at&order=created_at.asc', $k[1]);
  $found = null;
  if (is_array($topics)) {
    $used = [];
    usort($topics, fn($a, $b) => [strtotime($a['created_at']), $a['id']] <=> [strtotime($b['created_at']), $b['id']]);
    foreach ($topics as $t) {
      $s = so_slug($t['title']); $slug = $s; $n = 2;
      while (isset($used[$slug])) $slug = $s . '-' . $n++;
      $used[$slug] = true;
      if ('/' . $slug === $path) { $found = $t; break; }
    }
  }
  if ($found) {
    $votes = so_get($u[1] . '/rest/v1/public_votes?select=side&topic_id=eq.' . urlencode($found['id']), $k[1]) ?: [];
    $a = count(array_filter($votes, fn($v) => $v['side'] === 'a')); $tot = count($votes);
    $title = $found['title'];
    if ($tot) {
      $pa = (int) round($a * 100 / $tot);
      $desc = "{$found['label_a']} {$pa}% · {$found['label_b']} " . (100 - $pa) . "% · $tot vote" . ($tot === 1 ? '' : 's') . ". Pick a side, then chat anonymously with someone who disagrees.";
    } else {
      $desc = "{$found['label_a']} or {$found['label_b']}? Be the first to vote, then chat anonymously with someone who disagrees.";
    }
  } elseif (is_array($topics)) {
    $status = 404;
  }
}
$e = fn($s) => htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
$url = $base . ($path === '/' ? '/' : $path);
$tags = '<title>' . $e($title) . '</title>
<meta name="description" content="' . $e($desc) . '">
<link rel="canonical" href="' . $e($url) . '">
<meta property="og:site_name" content="Speak Onion">
<meta property="og:type" content="website">
<meta property="og:url" content="' . $e($url) . '">
<meta property="og:title" content="' . $e($title) . '">
<meta property="og:description" content="' . $e($desc) . '">
<meta property="og:image" content="' . $e($base) . '/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Speak Onion: Pick a side. Hear the other.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="' . $e($title) . '">
<meta name="twitter:description" content="' . $e($desc) . '">
<meta name="twitter:image" content="' . $e($base) . '/og-image.png">';
// drop the static tags from index.html and put ours in
$html = preg_replace('#<title>.*?</title>#s', '', $html, 1);
$html = preg_replace('#\s*<meta (name="description"|property="og:[^"]+"|name="twitter:[^"]+")[^>]*>#', '', $html);
$html = preg_replace('#<meta charset="utf-8">#', "<meta charset=\"utf-8\">\n" . $tags, $html, 1);
http_response_code($status);
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-cache');
echo $html;
