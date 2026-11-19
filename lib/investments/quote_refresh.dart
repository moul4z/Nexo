import 'package:shared_preferences/shared_preferences.dart';

import 'foreign_quotes.dart';
import 'investment_models.dart';
import 'investment_quotes.dart';
import 'investment_repository.dart';

/// One round of quotes: the B3 through brapi (when configured) and the
/// United States through the Nexo server. Every asset is tried; a failure
/// in one keeps the last price of the others. Each price keeps its date,
/// which the screen shows ("cotação de dd/MM").
class QuoteRefresh {
  /// Up to 20 B3 codes per round (free plan of the API).
  static const maxCodes = 20;

  static Future<({int updated, List<String> problems, int codes})> round(
      {required List<InvestmentPosition> b3,
      required List<InvestmentPosition> foreign,
      int? usdFx,
      bool Function()? alive,
      InvestmentRepository? repository}) async {
    final repo = repository ?? InvestmentRepository();
    var updated = 0;
    final problems = <String>[];
    if (foreign.isNotEmpty) {
      final source = SupabaseForeignQuotes.instance;
      if (source == null) {
        problems.add(
            'Cotação dos EUA precisa da sua conta em Sincronizar dispositivos.');
      } else {
        try {
          final tickers = foreign.map((p) => p.investment.ticker).toSet();
          final got = await source.fetch(tickers);
          for (final p in foreign) {
            final q = got[p.investment.ticker];
            if (q == null) continue;
            await repo.price(p.investment.id, q.priceMicros, q.date, 'mercado',
                fxMicros: usdFx);
          }
          updated += got.length;
          final missing = tickers.difference(got.keys.toSet());
          if (missing.isNotEmpty) {
            problems.add(
                'Sem cotação para ${missing.join(', ')}. Confira o código ou informe o preço.');
          }
        } on QuoteFailure catch (e) {
          problems.add(e.message);
        }
      }
    }
    final token = await InvestmentQuoteSettings.token();
    final tickers = b3.map((p) => p.investment.ticker).toSet();
    for (final ticker in tickers.take(maxCodes)) {
      if (alive != null && !alive()) break;
      try {
        final quote = await InvestmentQuotes().fetch(ticker, token: token);
        if (quote.market != null) {
          // Optional metadata must never prevent the core price update.
          try {
            await MarketCache.save(ticker, quote.market!);
          } catch (_) {}
        }
        for (final p in b3.where((p) => p.investment.ticker == ticker)) {
          await repo.price(
              p.investment.id, quote.priceMicros, quote.date, 'brapi');
        }
        updated++;
      } on QuoteFailure catch (e) {
        problems.add('$ticker: ${e.message}');
      }
    }
    return (updated: updated, problems: problems, codes: tickers.length);
  }

  /// With the app closed: once a day, after the B3 closes (18h), the
  /// closing price of every asset with a code. Never more than once a day,
  /// to respect the free plans.
  static Future<void> daily({int? usdFx, DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (at.hour < 18) return;
    final brapiOn = await InvestmentQuoteSettings.enabled();
    if (!brapiOn && SupabaseForeignQuotes.instance == null) return;
    final prefs = await SharedPreferences.getInstance();
    final today =
        '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
    if (prefs.getString('nexo_quotes_daily') == today) return;
    final quotable = (await InvestmentRepository().load())
        .where((p) => p.quantity > 0 && p.investment.canQuote)
        .toList();
    if (quotable.isEmpty) return;
    if (!await InvestmentQuoteSettings.claimRefresh()) return;
    await prefs.setString('nexo_quotes_daily', today);
    await round(
        b3: brapiOn
            ? quotable.where((p) => !p.investment.foreign).toList()
            : const [],
        foreign: quotable.where((p) => p.investment.foreign).toList(),
        usdFx: usdFx);
  }
}
