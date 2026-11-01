import 'package:http/http.dart' as http;
import 'package:manga_reader/widgets/common.dart';

class HtmlScraperUtils {
  const HtmlScraperUtils._();

  static String normalizeImgUrl(
    String? raw, {
    String? baseUrl,
    String? referer,
  }) {
    if (raw == null) return '';
    var u = raw
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .replaceAll('\t', '');
    if (u.isEmpty) return '';
    final lower = u.toLowerCase();
    if (lower.startsWith('data:') ||
        lower.startsWith('javascript:') ||
        lower.startsWith('about:')) {
      return '';
    }
    if (u.startsWith('//')) {
      u = 'https:$u';
    } else if (!u.startsWith('http://') && !u.startsWith('https://') && !u.startsWith('file://')) {
      if (baseUrl != null && baseUrl.isNotEmpty) {
        final parsed = Uri.tryParse(baseUrl);
        if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
          final origin = '${parsed.scheme}://${parsed.host}${parsed.hasPort ? ':${parsed.port}' : ''}';
          u = u.startsWith('/') ? '$origin$u' : '$origin/$u';
        }
      }
    }
    if (u.contains(' ')) {
      u = u.replaceAll(' ', '%20');
    }
    if (referer != null && referer.isNotEmpty && u.startsWith('http')) {
      ImageReferers.register(u, referer);
    }
    return u;
  }

  static String extractImgFromTag(
    String imgTag, {
    String? baseUrl,
    String? referer,
  }) {
    const attrs = [
      'data-src',
      'data-lazy-src',
      'data-cfsrc',
      'data-original',
      'data-echo',
      'data-bg',
      'src',
    ];
    for (final attr in attrs) {
      final m = RegExp(
        '(?:^|\\s)$attr\\s*=\\s*(?:"([^"]+)"|\'([^\']+)\'|([^\\s>"\']+))',
        caseSensitive: false,
      ).firstMatch(imgTag);
      if (m != null) {
        final rawVal = m.group(1) ?? m.group(2) ?? m.group(3);
        final candidate = normalizeImgUrl(rawVal, baseUrl: baseUrl, referer: referer);
        if (isValidContentImage(candidate)) return candidate;
      }
    }
    for (final attr in const ['data-srcset', 'srcset']) {
      final m = RegExp(
        '(?:^|\\s)$attr\\s*=\\s*(?:"([^"]+)"|\'([^\']+)\')',
        caseSensitive: false,
      ).firstMatch(imgTag);
      if (m != null) {
        final rawSet = m.group(1) ?? m.group(2) ?? '';
        final firstPart = rawSet.trim().split(RegExp(r'[\s,]+')).firstOrNull;
        final candidate = normalizeImgUrl(firstPart, baseUrl: baseUrl, referer: referer);
        if (isValidContentImage(candidate)) return candidate;
      }
    }
    final bgMatch = RegExp(
      r'''background(?:-image)?\s*:\s*url\(\s*['"]?([^'")\s]+)['"]?\s*\)''',
      caseSensitive: false,
    ).firstMatch(imgTag);
    if (bgMatch != null) {
      final candidate = normalizeImgUrl(bgMatch.group(1), baseUrl: baseUrl, referer: referer);
      if (isValidContentImage(candidate)) return candidate;
    }
    return '';
  }

  static bool isValidContentImage(String url) {
    if (url.isEmpty || url.length < 8) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('data:')) return false;
    if (lower.endsWith('.svg') || lower.contains('.svg?')) return false;
    if (lower.contains('placeholder') ||
        lower.contains('1x1') ||
        lower.contains('blank.') ||
        lower.contains('spacer.')) {
      return false;
    }
    return true;
  }

  static String unescapeHtml(String text) {
    var out = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&rsquo;', "'")
        .replaceAll('&lsquo;', "'")
        .replaceAll('&ldquo;', '"')
        .replaceAll('&rdquo;', '"')
        .replaceAll('&ndash;', '–')
        .replaceAll('&mdash;', '—')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#8217;', "'")
        .replaceAll('&#8216;', "'")
        .replaceAll('&#8220;', '"')
        .replaceAll('&#8221;', '"')
        .replaceAll('&hellip;', '...');
    if (out.contains('&#')) {
      out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
        final code = int.tryParse(m.group(1)!);
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      });
      out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      });
    }
    return out;
  }

  static void checkResponseHealth(http.Response res, String sourceName) {
    if (res.statusCode == 403) {
      throw Exception('$sourceName is protected by Cloudflare (HTTP 403). Please open in WebView to verify.');
    }
    if (res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504) {
      throw Exception('$sourceName server is temporarily down for maintenance (HTTP ${res.statusCode}).');
    }
    if (res.statusCode >= 400) {
      throw Exception('$sourceName returned an error (HTTP ${res.statusCode}).');
    }
    final bodyLower = res.body.toLowerCase();
    if (bodyLower.contains('scheduled maintenance') ||
        bodyLower.contains('under maintenance') ||
        bodyLower.contains('maintenance mode') ||
        (bodyLower.contains('maintenance') && bodyLower.contains('sorry for the inconvenience')) ||
        (bodyLower.contains('maintenance') && bodyLower.contains('everything is fine'))) {
      throw Exception('$sourceName is currently undergoing scheduled maintenance. Please try again later.');
    }
    if (bodyLower.contains('cf-browser-verification') ||
        (bodyLower.contains('ray id') && (bodyLower.contains('cloudflare') || bodyLower.contains('attention required!')))) {
      throw Exception('$sourceName is protected by Cloudflare. Please open in WebView to verify.');
    }
  }
}

