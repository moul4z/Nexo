import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/investments/investment_models.dart';
import 'package:nexo/services/b3_import.dart';

/// The B3 investor-area "Negociação" export, rebuilt in memory.
List<int> workbook(List<List<CellValue?>> rows, {String sheet = 'Negociação'}) {
  final excel = Excel.createExcel();
  final s = excel[sheet];
  for (final r in rows) {
    s.appendRow(r);
  }
  excel.delete('Sheet1');
  return excel.encode()!;
}

void main() {
  test('reads buys and sells, Brazilian numbers and dates, stable fingerprints',
      () {
    final bytes = workbook([
      [
        TextCellValue('Data do Negócio'),
        TextCellValue('Tipo de Movimentação'),
        TextCellValue('Mercado'),
        TextCellValue('Prazo/Vencimento'),
        TextCellValue('Instituição'),
        TextCellValue('Código de Negociação'),
        TextCellValue('Quantidade'),
        TextCellValue('Preço'),
        TextCellValue('Valor')
      ],
      [
        TextCellValue('05/09/2026'),
        TextCellValue('Compra'),
        TextCellValue('Mercado à Vista'),
        TextCellValue('-'),
        TextCellValue('XP INVESTIMENTOS CCTVM S/A'),
        TextCellValue('PETR4F'),
        IntCellValue(10),
        TextCellValue('R\$ 38,50'),
        TextCellValue('385,00')
      ],
      [
        TextCellValue('12/10/2026'),
        TextCellValue('Venda'),
        TextCellValue('Mercado à Vista'),
        TextCellValue('-'),
        TextCellValue('XP INVESTIMENTOS CCTVM S/A'),
        TextCellValue('PETR4'),
        DoubleCellValue(4),
        DoubleCellValue(40.1),
        DoubleCellValue(160.4)
      ],
      [
        TextCellValue(''),
        TextCellValue(''),
        null,
        null,
        null,
        TextCellValue(''),
        null,
        null,
        null
      ],
      [
        TextCellValue('sem data'),
        TextCellValue('Compra'),
        null,
        null,
        null,
        TextCellValue('ITSA4'),
        IntCellValue(5),
        DoubleCellValue(9),
        null
      ],
    ]);
    final result = B3Import.parse(bytes);
    expect(result.trades, hasLength(2));
    final buy = result.trades.first;
    expect(buy.date, DateTime(2026, 9, 5));
    expect(buy.kind, 'buy');
    expect(buy.ticker, 'PETR4', reason: 'fractional F dropped');
    expect(buy.quantity, 10);
    expect(buy.priceCents, 3850);
    expect(buy.totalCents, 38500);
    expect(buy.institution, 'XP INVESTIMENTOS CCTVM S/A');
    final sell = result.trades.last;
    expect(sell.kind, 'sell');
    expect(sell.totalCents, 16040);
    expect(sell.fingerprint, 'b3:2026-10-12:sell:PETR4:4:16040');
    expect(result.skipped, ['linha 5: data ilegível']);
  });

  test('an imported trade enters the portfolio as whole shares', () {
    // The file counts shares; the portfolio stores six decimal places. Ten
    // shares used to be stored as 0.00001 of a share.
    final trade = B3Trade(
        date: DateTime(2026, 9, 5),
        kind: 'buy',
        ticker: 'PETR4',
        institution: 'CORRETORA EXEMPLO',
        quantity: 10,
        priceCents: 3850,
        totalCents: 38500,
        market: 'Mercado à Vista');
    final op = trade.toOperation('inv', createdAt: DateTime(2026, 9, 5));
    expect(op.id, trade.fingerprint);
    expect(op.quantity, 10 * investmentScale);
    final position = InvestmentPosition(
        Investment(
            id: 'inv',
            name: 'PETR4',
            assetClass: 'Ações',
            ticker: 'PETR4',
            priceMicros: trade.priceCents * 10000,
            priceAt: trade.date),
        [op]);
    expect(position.quantity, 10 * investmentScale);
    expect(position.value, 38500, reason: '10 shares at R\$ 38,50');
    expect(position.averageCost, 3850);
  });

  test('a sheet without the expected header yields nothing, not an error', () {
    final bytes = workbook([
      [TextCellValue('Qualquer coisa'), TextCellValue('Outra')],
      [TextCellValue('a'), TextCellValue('b')],
    ]);
    final result = B3Import.parse(bytes);
    expect(result.trades, isEmpty);
    expect(result.skipped, isEmpty);
  });
}
